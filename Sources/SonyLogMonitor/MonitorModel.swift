import AppKit
import Combine
import Foundation
import MonitorCore

enum SourceKind: String, CaseIterable, Identifiable {
    case sony = "Sony camera (USB)"
    case wifi = "Sony camera (Wi-Fi)"
    case demo = "Demo (file / test chart)"
    var id: String { rawValue }
}

enum ZebraMode: String, CaseIterable, Identifiable {
    case above = "Above"
    case range = "Range ±"
    var id: String { rawValue }
}

/// View + overlay state. Everything the shader needs comes out of `uniforms()`.
final class MonitorModel: ObservableObject {
    /// Last-used source, so a Wi-Fi rig comes back up on Wi-Fi.
    @Published var source: SourceKind = MonitorModel.savedSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "source")
            if source != oldValue { switchSource() }
        }
    }
    @Published private(set) var camera: CameraController = MonitorModel.initialCamera() { didSet { followPictureProfile() } }

    private static var savedSource: SourceKind {
        UserDefaults.standard.string(forKey: "source").flatMap(SourceKind.init(rawValue:)) ?? .sony
    }

    private static func initialCamera() -> CameraController {
        switch savedSource {
        case .demo: return DemoCamera()
        case .sony: return GPhotoCamera()
        case .wifi:
            let host = (UserDefaults.standard.string(forKey: "wifiHost") ?? "").trimmingCharacters(in: .whitespaces)
            return GPhotoCamera(wifiHost: host.isEmpty ? "0.0.0.0" : host)
        }
    }

    @Published var viewRec709 = true
    @Published var profile: LogProfile = .slog3SGamut3Cine
    /// When the camera's picture profile changes, pick the matching log curve and turn
    /// the 709 view on (log PP) or off (any other PP).
    @Published var followCameraProfile = true
    private var profileWatch: AnyCancellable?

    /// Phone view: the same picture + controls in Safari on the home network.
    let phone = PhoneServer()
    /// Audio levels from a Mac audio input (camera via capture card / USB streaming, or a mic).
    let audio = AudioMeter()
    @Published var showAudio = true
    @Published private(set) var phoneURL: String?

    /// For the app delegate's quit hook.
    static weak var current: MonitorModel?

    init() {
        Self.current = self
        followPictureProfile()
        phone.state = { [unowned self] in self.phoneState() }
        phone.command = { [unowned self] in self.phoneCommand($0) }
        phone.audio = { [unowned self] in
            self.showAudio ? self.audio.channels.map { [Double($0.level), Double($0.peak)] } : []
        }
        phone.start()
        if phone.port != 0, let ip = PhoneServer.lanAddress() {
            phoneURL = "http://\(ip):\(phone.port)"
        }
    }

    private func phoneState() -> [String: Any] {
        let elapsed = camera.recordingStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
        return [
            "view709": viewRec709, "zebra": zebraOn, "falseColor": falseColorOn, "skin": skinOn, "audio": showAudio,
            "recording": camera.isRecording, "elapsed": elapsed,
            "connected": camera.connected, "status": camera.status,
            "settings": camera.settings.map { s in
                ["id": s.id.rawValue, "value": s.value, "options": s.options, "writable": s.writable] as [String: Any]
            },
        ]
    }

    private func phoneCommand(_ q: [String: String]) {
        switch q["op"] {
        case "toggle":
            switch q["name"] {
            case "view709": viewRec709.toggle()
            case "zebra": zebraOn.toggle()
            case "falseColor": falseColorOn.toggle()
            case "skin": skinOn.toggle()
            case "audio": showAudio.toggle()
            default: break
            }
        case "record":
            if camera.connected { camera.toggleRecording() }
        case "focus":
            if let x = q["x"].flatMap(Double.init), let y = q["y"].flatMap(Double.init) { touchFocus(x: x, y: y) }
        case "set":
            if let raw = q["id"], let id = SettingID(rawValue: raw), let value = q["value"],
               camera.setting(id)?.options.contains(value) == true {
                camera.set(id, to: value)
            }
        default:
            break
        }
    }

    private func followPictureProfile() {
        profileWatch = camera.$settings
            .compactMap { $0.first { $0.id == .pictureProfile }?.value }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pp in
                guard let self, self.followCameraProfile else { return }
                if let log = PictureProfile.logProfile(forDisplay: pp) {
                    self.profile = log
                    self.viewRec709 = true
                } else {
                    self.viewRec709 = false
                }
            }
    }

    /// Width / height of the live view frame, set by the renderer, for mapping taps.
    var frameAspect: Double = 16.0 / 9
    /// Last touch-focus point (0...1, top-left origin) and when it was set, for the reticle.
    @Published var focusMark: (x: Double, y: Double, at: Date)?

    func touchFocus(x: Double, y: Double) {
        guard camera.connected else { return }
        camera.focus(x: x, y: y)
        focusMark = (x, y, Date())
    }

    @Published var zebraOn = false
    @Published var zebraMode: ZebraMode = .above
    /// Percent IRE, like the camera's zebra menu.
    @Published var zebraLevel = 95.0
    @Published var zebraTolerance = 5.0
    /// Measure zebras on the raw log signal (what the camera's own zebras do) instead
    /// of the 709 view.
    @Published var zebraOnLog = false

    @Published var falseColorOn = false
    @Published var skinOn = false
    @Published var skinLo = Exposure.defaultSkinLo * 100
    @Published var skinHi = Exposure.defaultSkinHi * 100

    func uniforms() -> MonitorUniforms {
        var u = MonitorUniforms()
        u.viewRec709 = viewRec709 ? 1 : 0
        u.profile = Float(profile.shaderIndex)
        u.gainStops = Float(camera.previewGainStops)
        u.zebraOn = zebraOn ? 1 : 0
        switch zebraMode {
        case .above:
            u.zebraLo = Float(zebraLevel / 100)
            u.zebraHi = 2
        case .range:
            u.zebraLo = Float((zebraLevel - zebraTolerance) / 100)
            u.zebraHi = Float((zebraLevel + zebraTolerance) / 100)
        }
        u.zebraOnLog = zebraOnLog ? 1 : 0
        u.falseColorOn = falseColorOn ? 1 : 0
        u.skinOn = skinOn ? 1 : 0
        u.skinLo = Float(skinLo / 100)
        u.skinHi = Float(skinHi / 100)
        return u
    }

    func openDemoClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Pick an S-Log clip shot on a Sony camera"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if source != .demo { source = .demo }
        (camera as? DemoCamera)?.open(url: url)
    }

    // MARK: Wi-Fi

    /// Camera IP for PC Remote over Wi-Fi; remembered between launches.
    @Published var wifiHost = UserDefaults.standard.string(forKey: "wifiHost") ?? "" {
        didSet { UserDefaults.standard.set(wifiHost, forKey: "wifiHost") }
    }
    @Published private(set) var wifiNote = ""
    @Published private(set) var wifiBusy = false
    @Published private(set) var foundCameras: [(name: String, host: String)] = []

    func findWiFiCameras() {
        wifiBusy = true
        wifiNote = "Searching the network…"
        DispatchQueue.global().async {
            let found = WiFiLink.discover()
            DispatchQueue.main.async {
                self.wifiBusy = false
                self.foundCameras = found
                if let first = found.first, self.wifiHost.isEmpty || !found.contains(where: { $0.host == self.wifiHost }) {
                    self.wifiHost = first.host
                }
                self.wifiNote = found.isEmpty
                    ? "No camera found. Is it on the same Wi-Fi with PC Remote on?"
                    : found.map { "\($0.name) at \($0.host)" }.joined(separator: ", ")
            }
        }
    }

    /// One-time pairing: the camera must be in Network › PC Remote Function › Pairing.
    func pairWiFi() {
        let host = wifiHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { wifiNote = "Enter or find the camera's IP first."; return }
        camera.shutdown()
        wifiBusy = true
        wifiNote = "On the camera: PC Remote Function › Pairing, then press OK…"
        DispatchQueue.global().async {
            let result = WiFiLink.pair(host: host)
            DispatchQueue.main.async {
                self.wifiBusy = false
                switch result {
                case .paired: self.wifiNote = "Paired. Connecting…"
                case .timedOut: self.wifiNote = "Pairing timed out. Start Pairing on the camera and try again."
                case .failed(let why): self.wifiNote = "Pairing failed: \(why)"
                }
                self.reconnect()
            }
        }
    }

    func reconnect() {
        guard source != .demo else { return }
        camera.disconnect()
        camera = makeCamera()
    }

    private func makeCamera() -> CameraController {
        switch source {
        case .demo: return DemoCamera()
        case .sony: return GPhotoCamera()
        case .wifi:
            let host = wifiHost.trimmingCharacters(in: .whitespaces)
            return GPhotoCamera(wifiHost: host.isEmpty ? "0.0.0.0" : host)
        }
    }

    private func switchSource() {
        camera.disconnect()
        camera = makeCamera()
    }
}
