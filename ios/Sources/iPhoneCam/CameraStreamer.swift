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

    // BSD sockets — no entitlement required (NWListener crashes on free-cert sideloads)
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var serverRunning = false

    private let streamQueue = DispatchQueue(label: "cam.stream", qos: .userInteractive)
    private let setupQueue  = DispatchQueue(label: "cam.setup",  qos: .userInitiated)

    private var frameCount = 0
    private var fpsTimer: Timer?

    override init() {
        super.init()
        localIP = getLocalIP()
    }

    // MARK: - Public

    func start() {
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

    // MARK: - Permissions

    private func requestCameraPermission(completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { completion() }
                else { DispatchQueue.main.async { self?.status = "Camera permission denied" } }
            }
        default:
            DispatchQueue.main.async { self.status = "Camera permission denied — check Settings" }
        }
    }

    // MARK: - Capture setup (runs on setupQueue)

    private func setupCapture() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.status = "Camera unavailable" }
            return
        }

        session.beginConfiguration()

        let presets: [AVCaptureSession.Preset] = [.hd4K3840x2160, .hd1920x1080, .hd1280x720]
        let chosen = presets.first { session.canSetSessionPreset($0) } ?? .high
        session.sessionPreset = chosen
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: streamQueue)
        output.alwaysDiscardsLateVideoFrames = true
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
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

        guard setupVideoToolbox(width: w, height: h) else { return }

        captureSession = session
        session.startRunning()
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
        var session: VTCompressionSession?
        let err = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        guard err == noErr, let session = session else {
            DispatchQueue.main.async { self.status = "Encoder setup failed (\(err))" }
            return false
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let bitrate = width >= 3840 ? 50_000_000 : 15_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: 60))
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        return true
    }

    // MARK: - BSD socket TCP server

    private func startTCPServer() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            DispatchQueue.main.async { self.status = "Socket error" }
            return
        }

        var reuseVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,  &reuseVal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,  &reuseVal, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = CFSwapInt16HostToBig(4747)
        addr.sin_addr   = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            DispatchQueue.main.async { self.status = "Port 4747 bind failed" }
            return
        }

        Darwin.listen(fd, 1)
        serverFD = fd
        serverRunning = true

        streamQueue.async { self.acceptLoop() }
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
            guard fd >= 0 else { break }

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

    // MARK: - Helpers

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
