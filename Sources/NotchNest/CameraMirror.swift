import AVFoundation

/// Webcam preview for the Mirror widget. The camera only runs while the preview is on screen.
@Observable @MainActor
final class CameraMirror {
    private(set) var isRunning = false
    private(set) var denied = false
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var configured = false
    @ObservationIgnored private let queue = DispatchQueue(label: "NotchNest.camera")

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { self.run() } else { self.denied = true }
                    }
                }
            }
        default:
            denied = true
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let session = session
        queue.async { session.stopRunning() }
    }

    private func run() {
        if !configured {
            let builtIn = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
            guard let device = builtIn ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                denied = true
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .medium
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            configured = true
        }
        denied = false
        isRunning = true
        let session = session
        queue.async { session.startRunning() }
    }
}
