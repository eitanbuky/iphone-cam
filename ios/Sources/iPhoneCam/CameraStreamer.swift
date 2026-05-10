import AVFoundation
import VideoToolbox
import Darwin

class CameraStreamer: NSObject, ObservableObject {

    @Published var status: String = "Tap Start to begin"
    @Published var localIP: String = ""
    @Published var resolution: String = "—"
    @Published var fps: Int = 0
    @Published var isCapturing: Bool = false
    @Published var isStreaming: Bool = false

    var captureSession: AVCaptureSession?
    private var compressionSession: VTCompressionSession?

    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var serverRunning = false

    // acceptQueue is separate from streamQueue so blocking accept() never starves camera frames
    private let streamQueue  = DispatchQueue(label: "cam.stream",  qos: .userInteractive)
    private let setupQueue   = DispatchQueue(label: "cam.setup",   qos: .userInitiated)
    private let acceptQueue  = DispatchQueue(label: "cam.accept",  qos: .utility)

    private var frameCount = 0
    private var fpsTimer: Timer?

    override init() {
        super.init()
        localIP = getLocalIP()
    }

    // MARK: - Public

    func start() {
        setStatus("Checking camera permission...")
        requestCameraPermission { [weak self] in
            self?.setupQueue.async { self?.setupCapture() }
        }
    }

    func stop() {
        serverRunning = false
        closeClient()
        if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
        setupQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            if let cs = self?.compressionSession { VTCompressionSessionInvalidate(cs) }
            self?.compressionSession = nil
            self?.captureSession = nil
            DispatchQueue.main.async {
                self?.fpsTimer?.invalidate()
                self?.isCapturing = false
                self?.isStreaming = false
                self?.status = "Tap Start to begin"
                self?.fps = 0
            }
        }
    }

    private func setStatus(_ msg: String) {
        DispatchQueue.main.async { self.status = msg }
    }

    // MARK: - Permissions

    private func requestCameraPermission(completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { completion() }
                else { self?.setStatus("Camera permission denied") }
            }
        default:
            setStatus("Camera permission denied — check Settings")
        }
    }

    // MARK: - Capture setup

    private func setupCapture() {
        setStatus("Creating capture session...")
        let session = AVCaptureSession()

        setStatus("Finding camera...")
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            setStatus("No back camera found")
            return
        }

        setStatus("Creating camera input...")
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            setStatus("Camera input failed")
            return
        }

        setStatus("Configuring session...")
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            setStatus("Cannot add camera input")
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let presets: [AVCaptureSession.Preset] = [.hd4K3840x2160, .hd1920x1080, .hd1280x720]
        let chosen = presets.first { session.canSetSessionPreset($0) } ?? .high
        session.sessionPreset = chosen

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: streamQueue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            setStatus("Cannot add video output")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)

        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }

        session.commitConfiguration()

        let resolutionLabel: String
        switch chosen {
        case .hd4K3840x2160: resolutionLabel = "4K (3840×2160)"
        case .hd1920x1080:   resolutionLabel = "1080p (1920×1080)"
        default:             resolutionLabel = "720p (1280×720)"
        }

        let w = chosen == .hd4K3840x2160 ? 3840 : (chosen == .hd1920x1080 ? 1920 : 1280)
        let h = chosen == .hd4K3840x2160 ? 2160 : (chosen == .hd1920x1080 ? 1080 : 720)

        setStatus("Starting H.264 encoder...")
        guard setupVideoToolbox(width: w, height: h) else { return }

        setStatus("Starting camera...")
        captureSession = session
        session.startRunning()

        setStatus("Opening TCP server...")
        startTCPServer()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isCapturing = true
            self.resolution = resolutionLabel
            self.status = "Waiting for PC..."
            self.fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.streamQueue.async {
                    let count = self.frameCount
                    self.frameCount = 0
                    DispatchQueue.main.async { self.fps = count }
                }
            }
        }
    }

    // MARK: - VideoToolbox

    private func setupVideoToolbox(width: Int, height: Int) -> Bool {
        var vtSession: VTCompressionSession?
        let err = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &vtSession
        )
        guard err == noErr, let vtSession = vtSession else {
            setStatus("Encoder init failed (\(err))")
            return false
        }
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let bitrate = width >= 3840 ? 50_000_000 : 15_000_000
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: 60))
        VTCompressionSessionPrepareToEncodeFrames(vtSession)
        compressionSession = vtSession
        return true
    }

    // MARK: - BSD socket TCP server

    private func startTCPServer() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { setStatus("Socket() failed"); return }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = CFSwapInt16HostToBig(4747)
        addr.sin_addr   = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            setStatus("Bind failed (port 4747 busy?)")
            return
        }

        Darwin.listen(fd, 1)
        serverFD = fd
        serverRunning = true

        // Accept loop runs on its own queue so it never blocks camera frames on streamQueue
        acceptQueue.async { self.acceptLoop() }
    }

    private func acceptLoop() {
        while serverRunning && serverFD >= 0 {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &addrLen)
                }
            }
            guard fd >= 0, serverRunning else { break }
            closeClient()
            clientFD = fd
            DispatchQueue.main.async { self.isStreaming = true; self.status = "Streaming to PC" }
        }
    }

    private func closeClient() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
            DispatchQueue.main.async { self.isStreaming = false; self.status = "Waiting for PC..." }
        }
    }

    private func sendData(_ data: Data) {
        guard clientFD >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(clientFD, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { closeClient(); return }
                sent += n
            }
        }
    }

    // MARK: - H.264 framing

    private func parameterSets(from formatDesc: CMFormatDescription) -> Data {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var data = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let ptr = ptr {
                data += Data([0x00, 0x00, 0x00, 0x01])
                data += Data(UnsafeBufferPointer(start: ptr, count: size))
            }
        }
        return data
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard clientFD >= 0 else { return }

        let isKeyFrame: Bool = {
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let first = arr.first {
                return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            }
            return true
        }()

        var annexB = Data()
        if isKeyFrame, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB += parameterSets(from: fmt)
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLen = CMBlockBufferGetDataLength(block)
        var raw = [UInt8](repeating: 0, count: totalLen)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLen, destination: &raw)

        var offset = 0
        while offset + 4 <= totalLen {
            let naluLen = Int(raw[offset]) << 24 | Int(raw[offset+1]) << 16 | Int(raw[offset+2]) << 8 | Int(raw[offset+3])
            offset += 4
            guard offset + naluLen <= totalLen else { break }
            annexB += Data([0x00, 0x00, 0x00, 0x01])
            annexB += raw[offset ..< offset + naluLen]
            offset += naluLen
        }

        sendData(annexB)
        frameCount += 1
    }

    // MARK: - IP helper

    private func getLocalIP() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "Unknown" }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let iface = current.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: iface.ifa_name) == "en0" {
                var addr = iface.ifa_addr.pointee
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                               &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: buf)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return "Unknown"
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cs = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(cs, imageBuffer: imageBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded = encoded else { return }
            self?.handleEncodedFrame(encoded)
        }
    }
}
