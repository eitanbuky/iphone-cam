import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var streamer = CameraStreamer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                // Title
                Text("iPhone Cam")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                // Camera preview
                if streamer.isCapturing {
                    CameraPreview(session: streamer.captureSession)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Status card
                VStack(spacing: 12) {
                    StatusRow(label: "IP Address", value: streamer.localIP.isEmpty ? "Detecting..." : streamer.localIP, valueColor: .cyan)
                    StatusRow(label: "Port", value: "4747", valueColor: .white)
                    StatusRow(label: "Resolution", value: streamer.resolution, valueColor: .white)
                    StatusRow(label: "Status", value: streamer.status, valueColor: streamer.isStreaming ? .green : .yellow)
                    if streamer.isStreaming {
                        StatusRow(label: "FPS", value: "\(streamer.fps)", valueColor: .green)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

                // Instructions when waiting
                if !streamer.isStreaming && streamer.isCapturing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On Windows, run:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("python receiver.py \(streamer.localIP)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.horizontal)
                }

                // Start / Stop button
                Button(action: {
                    if streamer.isCapturing {
                        streamer.stop()
                    } else {
                        streamer.start()
                    }
                }) {
                    Text(streamer.isCapturing ? "Stop" : "Start Camera")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(streamer.isCapturing ? Color.red.opacity(0.8) : Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
            }
            .padding(.top, 40)
        }
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
                .font(.subheadline)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
                .font(.subheadline.monospacedDigit())
        }
    }
}

// Live camera preview using UIViewRepresentable
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView()
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.setSession(session)
    }
}

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func setSession(_ session: AVCaptureSession?) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }
}
