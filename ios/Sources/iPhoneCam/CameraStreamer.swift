import AVFoundation
import VideoToolbox
import Network
import Darwin
import Combine

class CameraStreamer: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var status: String = "Tap Start to begin"
    @Published var localIP: String = ""
    @Published var resolution: String = "—"
    @Published var fps: Int = 0
    @Published var isCapturing: Bool = false
    @Published var isStreaming: Bool = false

    // MARK: - Private

    var captureSession: AVCaptureSession?
    private var compressionSession: VTCompressionSession?
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let streamQueue = DispatchQueue(label: "cam.stream", qos: .userInteractive)

    private var frameCount = 0
    private var fpsTimer: Timer?
    private var parameterSetsData: Data? // cached SPS+PPS

    // MARK: - Public

    func start() {
        localIP = getLocalIP()
        requestCameraPermission { [weak self] in
            self?.setupCapture()
            self?.startTCPServer()
        }
    }

    func stop() {
        fpsTimer?.invalidate()
        captureSession?.stopRunning()
        if let cs = compressionSession { VTCompressionSessionInvalidate(cs) }
        compressionSession = nil
        activeConnection?.cancel()
        listener?.cancel()
        captureSession = nil
        parameterSetsData = nil
        DispatchQueue.main.async {
            self.isCapturing = false
            self.isStreaming = false
            self.status = "Tap Start to begin"
            self.fps = 0
        }
    }

    // MARK: - Permissions

    private func requestCameraPermission(completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { completion() }
                else { DispatchQueue.main.async { self.status = "Camera permission denied" } }
            }
        default:
            DispatchQueue.main.async { self.status = "Camera permission denied — check Settings" }
        }
    }

    // MARK: - Capture session

    private func setupCapture() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.status = "Camera unavailable" }
            return
        }

        session.beginConfiguration()

        // Pick the highest supported resolution
        let presets: [AVCaptureSession.Preset] = [.hd4K3840x2160, .hd1920x1080, .hd1280x720]
        let chosen = presets.first { session.canSetSessionPreset($0) } ?? .high
        session.sessionPreset = chosen

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: streamQueue)
        output.alwaysDiscardsLateVideoFrames = true
        session.addOutput(output)

        // Lock landscape orientation
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

        // Setup VideoToolbox with chosen dimensions
        let w = chosen == .hd4K3840x2160 ? 3840 : (chosen == .hd1920x1080 ? 1920 : 1280)
        let h = chosen == .hd4K3840x2160 ? 2160 : (chosen == .hd1920x1080 ? 1080 : 720)

        guard setupVideoToolbox(width: w, height: h) else { return }

        captureSession = session
        session.startRunning()

        // FPS counter timer
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.fps = self.frameCount
                self.frameCount = 0
            }
        }

        DispatchQueue.main.async {
            self.isCapturing = true
            self.resolution = resolutionLabel
            self.status = "Waiting for PC..."
        }
    }

    // MARK: - VideoToolbox

    private func setupVideoToolbox(width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            DispatchQueue.main.async { self.status = "VideoToolbox setup failed (\(status))" }
            return false
        }

        // Low-latency, real-time settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // High bitrate: 50 Mbps for 4K, 15 Mbps for 1080p
        let bitrate: Int = width >= 3840 ? 50_000_000 : 15_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))

        // Keyframe every 2 seconds
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))

        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        return true
    }

    // MARK: - TCP server

    private func startTCPServer() {
        guard let listener = try? NWListener(using: .tcp, on: 4747) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            // Drop previous connection if any
            self.activeConnection?.cancel()
            self.activeConnection = connection
            self.parameterSetsData = nil // force resend of SPS+PPS on reconnect

            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async { self.isStreaming = true; self.status = "Streaming to PC" }
                case .failed, .cancelled:
                    DispatchQueue.main.async { self.isStreaming = false; self.status = "Waiting for PC..." }
                default: break
                }
            }
            connection.start(queue: self.streamQueue)
        }

        listener.start(queue: streamQueue)
    }

    // MARK: - Frame sending

    private func sendData(_ data: Data) {
        guard let connection = activeConnection else { return }
        connection.send(content: data, completion: .idempotent)
    }

    private func parameterSets(from formatDesc: CMFormatDescription) -> Data {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )

        var data = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if let ptr = ptr {
                data += Data([0x00, 0x00, 0x00, 0x01])
                data += Data(UnsafeBufferPointer(start: ptr, count: size))
            }
        }
        return data
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard activeConnection != nil else { return }

        // Detect IDR (keyframe)
        let isKeyFrame: Bool = {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let first = attachments.first {
                return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            }
            return true
        }()

        var annexB = Data()

        // Prepend SPS+PPS on keyframes (cache them to avoid duplicate extractions)
        if isKeyFrame, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let ps = parameterSets(from: fmt)
            parameterSetsData = ps
            annexB += ps
        }

        // Convert AVCC → Annex-B
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
            annexB += raw[offset..<offset + naluLen]
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
        VTCompressionSessionEncodeFrame(
            cs,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded = encoded else { return }
            self?.handleEncodedFrame(encoded)
        }
    }
}
