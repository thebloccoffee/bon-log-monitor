import AppKit
import Combine
import Foundation
import MonitorCore

enum SourceKind: String, CaseIterable, Identifiable {
    case sony = "Sony camera (USB)"
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
    @Published var source: SourceKind = .sony { didSet { if source != oldValue { switchSource() } } }
    @Published private(set) var camera: CameraController = GPhotoCamera() { didSet { followPictureProfile() } }

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

    func reconnect() {
        guard source == .sony else { return }
        camera.disconnect()
        camera = GPhotoCamera()
    }

    private func switchSource() {
        camera.disconnect()
        switch source {
        case .demo: camera = DemoCamera()
        case .sony: camera = GPhotoCamera()
        }
    }
}
