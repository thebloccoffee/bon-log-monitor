import AVFoundation
import Combine

/// Per-channel audio levels from a Mac audio input: the camera over HDMI into a
/// capture card, the camera in USB Streaming mode, or a mic/recorder. PC Remote over
/// USB carries no audio, so the camera link itself can't feed these.
final class AudioMeter: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct Device: Identifiable, Hashable { let id: String; let name: String }
    /// dBFS, -160...0.
    struct Channel: Equatable { var level: Float; var peak: Float }

    @Published private(set) var devices: [Device] = []
    @Published var deviceID: String? { didSet { if deviceID != oldValue { restart() } } }
    @Published var enabled = true { didSet { if enabled != oldValue { restart() } } }
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var message = ""

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "boonlogmonitor.audio")
    private var poll: Timer?
    private var deviceWatch: [NSObjectProtocol] = []
    /// Our own peak hold: the hold value decays after `holdTime`.
    private var holds: [(value: Float, at: Date)] = []
    private static let holdTime: TimeInterval = 1.5

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceWatch.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
            })
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if ok { self.restart() } else { self.message = "Microphone access denied (System Settings › Privacy)" }
            }
        }
    }

    private static func audioDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
    }

    private func refreshDevices() {
        devices = Self.audioDevices().map { Device(id: $0.uniqueID, name: $0.localizedName) }
        if deviceID == nil || !devices.contains(where: { $0.id == deviceID }) {
            // Prefer something that looks like a camera or capture card over the built-in mic.
            let hint = ["sony", "fx", "capture", "hdmi", "cam link", "usb"]
            deviceID = devices.first { d in hint.contains { d.name.lowercased().contains($0) } }?.id ?? devices.first?.id
        }
    }

    private func restart() {
        let id = deviceID, on = enabled
        poll?.invalidate()
        poll = nil
        channels = []
        holds = []
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            var note = ""
            if on, let id, let dev = AVCaptureDevice(uniqueID: id) {
                if let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) {
                    self.session.addInput(input)
                    if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                } else {
                    note = "Couldn't open \(dev.localizedName)"
                }
            } else if on {
                note = "No audio input found"
            }
            self.session.commitConfiguration()
            if on, note.isEmpty { self.session.startRunning() }
            DispatchQueue.main.async {
                self.message = note
                if on, note.isEmpty { self.startPolling() }
            }
        }
    }

    private func startPolling() {
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.read() }
    }

    private func read() {
        guard let conn = output.connections.first else { return }
        let now = Date()
        let levels = conn.audioChannels.map { $0.averagePowerLevel }
        if holds.count != levels.count { holds = levels.map { ($0, now) } }
        channels = levels.enumerated().map { i, level in
            if level >= holds[i].value || now.timeIntervalSince(holds[i].at) > Self.holdTime { holds[i] = (level, now) }
            return Channel(level: level, peak: holds[i].value)
        }
    }

    // Samples aren't used; an attached output is what makes the connection meter.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
