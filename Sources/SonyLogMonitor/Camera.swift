import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import MonitorCore

/// One frame of live view. Sony's SDK hands back JPEGs (decoded to CGImage); a file
/// played through AVFoundation hands back pixel buffers.
enum Frame {
    case pixelBuffer(CVPixelBuffer)
    case image(CGImage)
}

enum SettingID: String, CaseIterable {
    case pictureProfile = "Picture profile"
    case fNumber = "F-stop"
    case iso = "ISO"
    case shutter = "Shutter"
    case whiteBalance = "White balance"
    case exposureComp = "Exposure comp."
    case focusMode = "Focus mode"
    case focusArea = "Focus area"
}

struct CameraSetting: Identifiable, Equatable {
    let id: SettingID
    var value: String
    /// Values the camera accepts right now (the camera can narrow these, e.g. by lens).
    var options: [String]
    var writable = true
}

/// Base class for anything that feeds the monitor: the demo source, or a Sony camera
/// over libgphoto2. The renderer pulls `currentFrame()` every draw.
class CameraController: ObservableObject {
    @Published var status = ""
    @Published var connected = false
    @Published var settings: [CameraSetting] = []
    @Published var isRecording = false
    @Published var recordingStarted: Date?

    /// Scene-linear exposure offset the shader applies. Only the demo source uses it,
    /// to fake what a real exposure change would do to the image.
    var previewGainStops: Double { 0 }

    func currentFrame() -> Frame? { nil }
    func set(_ id: SettingID, to value: String) {}
    func toggleRecording() {}
    /// Touch focus. `x`, `y` are 0...1 across the live view frame, origin top-left.
    func focus(x: Double, y: Double) {}
    func disconnect() {}
    /// Like disconnect(), but blocks until the camera session is closed (app quit).
    func shutdown() { disconnect() }

    func setting(_ id: SettingID) -> CameraSetting? { settings.first { $0.id == id } }
}

/// ZV-E10 factory picture profiles; other Sony bodies may number them differently.
/// Only the log ones matter to the monitor, and the sidebar can override the curve.
enum PictureProfile {
    static let label: [String: String] = [
        "0": "Off", "1": "PP1 (Movie)", "2": "PP2 (Still)", "3": "PP3 (ITU709)", "4": "PP4 (ITU709 800%)",
        "5": "PP5 (Cine1)", "6": "PP6 (Cine2)", "7": "PP7 (S-Log2)", "8": "PP8 (S-Log3 / S-Gamut3.Cine)",
        "9": "PP9 (S-Log3 / S-Gamut3)", "10": "PP10 (HLG2)",
    ]

    private static let logByRaw: [String: LogProfile] = ["7": .slog2SGamut, "8": .slog3SGamut3Cine, "9": .slog3SGamut3]

    /// The log curve a displayed profile records, or nil for a non-log profile.
    static func logProfile(forDisplay display: String) -> LogProfile? {
        guard let raw = label.first(where: { $0.value == display })?.key else { return nil }
        return logByRaw[raw]
    }
}

// MARK: - Demo camera

/// Plays a log clip from disk (or a generated S-Log3 test chart) and simulates the
/// exposure controls, so the 709 view and overlays can be tried without the camera.
final class DemoCamera: CameraController {
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var loopObserver: NSObjectProtocol?
    private var lastBuffer: CVPixelBuffer?
    private let testChart = TestChart.make()

    // Baseline the simulated exposure is relative to. The real ZV-E10 accepts ISO 500
    // in PP8 (S-Log3), so that's the floor here.
    private let baseISO = 500.0, baseF = 4.0, baseShutter = 1.0 / 50

    override init() {
        super.init()
        connected = true
        status = "Demo: S-Log3 test chart"
        settings = [
            CameraSetting(id: .fNumber, value: "F4.0", options: ["F1.4", "F1.8", "F2.0", "F2.8", "F4.0", "F5.6", "F8.0", "F11", "F16"]),
            CameraSetting(id: .iso, value: "500", options: ["500", "640", "800", "1000", "1250", "1600", "2000", "2500", "3200", "6400", "12800"]),
            CameraSetting(id: .shutter, value: "1/50", options: ["1/25", "1/30", "1/50", "1/60", "1/100", "1/125", "1/250", "1/500", "1/1000"]),
            CameraSetting(id: .whiteBalance, value: "5600K", options: ["Auto", "Daylight", "Tungsten", "3200K", "4300K", "5600K", "6500K"]),
            CameraSetting(id: .exposureComp, value: "0.0", options: ["-2.0", "-1.0", "0.0", "+1.0", "+2.0"], writable: false),
        ]
    }

    func open(url: URL) {
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        p.play()
        player = p
        output = out
        lastBuffer = nil
        status = "Demo: \(url.lastPathComponent)"
    }

    func useTestChart() {
        player?.pause()
        player = nil
        output = nil
        lastBuffer = nil
        status = "Demo: S-Log3 test chart"
    }

    override func currentFrame() -> Frame? {
        guard let output else { return testChart.map(Frame.image) }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t),
           let buf = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            lastBuffer = buf
        }
        return lastBuffer.map(Frame.pixelBuffer)
    }

    override var previewGainStops: Double {
        let iso = Double(setting(.iso)?.value ?? "") ?? baseISO
        let f = Double(setting(.fNumber)?.value.dropFirst() ?? "") ?? baseF
        let shutter = Self.seconds(setting(.shutter)?.value ?? "") ?? baseShutter
        return log2(iso / baseISO) + 2 * log2(baseF / f) + log2(shutter / baseShutter)
    }

    override func set(_ id: SettingID, to value: String) {
        guard let i = settings.firstIndex(where: { $0.id == id }) else { return }
        settings[i].value = value
    }

    override func toggleRecording() {
        isRecording.toggle()
        recordingStarted = isRecording ? Date() : nil
    }

    static func seconds(_ shutter: String) -> Double? {
        if shutter.hasPrefix("1/"), let d = Double(shutter.dropFirst(2)) { return 1 / d }
        return Double(shutter.replacingOccurrences(of: "\"", with: ""))
    }
}

// MARK: - Sony camera (libgphoto2, PC Remote over USB)

/// The original ZV-E10 isn't accepted by Sony's Camera Remote SDK (only the ZV-E10 II
/// is), so this drives it through libgphoto2's reverse-engineered Sony PTP support.
/// libgphoto2 isn't thread-safe, so every camera call runs on `queue`.
final class GPhotoCamera: CameraController {
    private static let keys: [SettingID: String] = [
        // gphoto2 has no name for Sony's Picture Profile property (PTP 0xD23F);
        // its raw values are 0 = off, 1...10 = PP1...PP10.
        .pictureProfile: "d23f",
        .fNumber: "f-number",
        .iso: "iso",
        .shutter: "shutterspeed",
        .whiteBalance: "whitebalance",
        .exposureComp: "exposurecompensation",
        .focusMode: "focusmode",
        .focusArea: "focusarea",
    ]
    /// Sony's touch AF grid (libgphoto2 "spotfocusarea" clamps to 639,479).
    private static let touchGrid = (w: 640.0, h: 480.0)
    /// The camera applies a change a second or two after accepting it, so a poll right
    /// after a set still reports the old value. Hold the user's choice this long.
    private static let pendingHold: TimeInterval = 4
    private static let pollInterval: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "sonylogmonitor.gphoto")
    private let lock = NSLock()
    private var latest: CGImage?
    private var running = true
    private var queuedSets: [(key: String, value: String)] = []
    /// Main-thread only: settings the user just changed, and until when to trust them.
    private var pending: [SettingID: (value: String, until: Date)] = [:]

    /// nil = USB; otherwise the camera's IP for PC Remote over Wi-Fi.
    private let wifiHost: String?
    private var relay: PTPIPRelay?

    init(wifiHost: String? = nil) {
        self.wifiHost = wifiHost
        super.init()
        status = wifiHost.map { "Connecting over Wi-Fi to \($0)…" } ?? "Connecting over USB…"
        queue.async { [weak self] in self?.run() }
    }

    /// Camera queue. Opens the camera over USB, or over Wi-Fi through the GUID relay.
    private func open(_ model: inout [CChar], _ err: inout [CChar]) -> OpaquePointer? {
        guard let host = wifiHost else {
            Self.stopAppleCameraDaemon()
            return gpb_open(&model, model.count, &err, err.count)
        }
        if relay == nil {
            let r = PTPIPRelay(host: host)
            guard r.start() else {
                err = Array("couldn't start local relay".utf8CString)
                return nil
            }
            relay = r
        }
        let port = relay!.port
        return gpb_open_path("ptpip:127.0.0.1:\(port):\(port)", "PTP/IP Camera", &model, model.count, &err, err.count)
    }

    override func currentFrame() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest.map(Frame.image)
    }

    override func set(_ id: SettingID, to value: String) {
        guard let key = Self.keys[id], let i = settings.firstIndex(where: { $0.id == id }) else { return }
        settings[i].value = value
        pending[id] = (value, Date().addingTimeInterval(Self.pendingHold))
        enqueue(key, Self.raw(id, value))
    }

    /// Picture profile is shown as "PP8 (S-Log3…)" but read and written as "8".
    private static func display(_ id: SettingID, _ raw: String) -> String {
        id == .pictureProfile ? (PictureProfile.label[raw] ?? raw) : raw
    }

    private static func raw(_ id: SettingID, _ display: String) -> String {
        guard id == .pictureProfile else { return display }
        return PictureProfile.label.first { $0.value == display }?.key ?? display
    }

    override func toggleRecording() {
        let start = !isRecording
        isRecording = start
        recordingStarted = start ? Date() : nil
        enqueue("movie", start ? "1" : "0")
    }

    /// Sends Sony's RemoteTouch, the same as touching the camera's own screen (and what
    /// Monitor & Control does): in MF that's a one-shot AF at the point, in AF it moves
    /// the spot / starts tracking per the camera's touch settings.
    override func focus(x: Double, y: Double) {
        let px = Int((min(max(x, 0), 1) * (Self.touchGrid.w - 1)).rounded())
        let py = Int((min(max(y, 0), 1) * (Self.touchGrid.h - 1)).rounded())
        enqueue(Self.remoteTouchKey, "\(px),\(py)")
    }

    private static let remoteTouchKey = "!remotetouch"

    /// Camera queue. Falls back to moving the flexible spot if RemoteTouch is refused.
    private func remoteTouch(_ c: OpaquePointer, _ value: String) {
        let xy = value.split(separator: ",").compactMap { UInt32($0) }
        guard xy.count == 2 else { return }
        let r = gpb_sony_control(c, 0xD2E4, (xy[0] << 16) | xy[1])
        if r == 0x2001 { return }
        let fallback = gpb_set(c, "spotfocusarea", value)
        DispatchQueue.main.async {
            self.status = fallback >= 0
                ? "Touch focus: camera refused remote touch (0x\(String(r, radix: 16))), moved AF spot instead"
                : "Touch focus failed (0x\(String(r, radix: 16)))"
        }
    }

    override func disconnect() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// run() occupies `queue` until it has closed the camera, so an empty sync block
    /// returns only after that. Without a clean close the camera keeps the old PTP
    /// session and the next launch can't claim it.
    override func shutdown() {
        disconnect()
        queue.sync {}
    }

    private func enqueue(_ key: String, _ value: String) {
        lock.lock()
        queuedSets.append((key, value))
        lock.unlock()
    }

    // MARK: Camera queue

    /// Keeps (re)connecting until disconnect(): the camera is briefly unavailable while
    /// it switches USB modes or another process lets go of it, and a replug should
    /// just resume.
    private func run() {
        defer { relay?.stop() }
        while isRunning {
            var model = [CChar](repeating: 0, count: 128)
            var err = [CChar](repeating: 0, count: 256)
            guard let c = open(&model, &err) else {
                let message = String(cString: err)
                let hint = wifiHost == nil
                    ? "PC Remote ON, USB, cable in"
                    : "camera on Wi-Fi, PC Remote ON, paired with this Mac"
                DispatchQueue.main.async {
                    self.connected = false
                    self.status = "Waiting for camera (\(message)) — \(hint)"
                }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            let name = String(cString: model)
            let via = wifiHost.map { "Wi-Fi \($0)" } ?? "USB"
            DispatchQueue.main.async {
                self.connected = true
                self.status = "Connected: \(name) (\(via))"
            }
            stream(c)
            gpb_close(c)
        }
    }

    /// Live view + settings until the camera drops or disconnect() is called.
    private func stream(_ c: OpaquePointer) {
        var lastPoll = Date.distantPast
        while isRunning {
            applyQueuedSets(c)
            if Date().timeIntervalSince(lastPoll) > Self.pollInterval {
                pollSettings(c)
                lastPoll = Date()
            }
            var data: UnsafePointer<UInt8>?
            var size: UInt = 0
            let r = gpb_preview(c, &data, &size)
            if r < 0 {
                let message = String(cString: gpb_result_string(r))
                DispatchQueue.main.async {
                    self.connected = false
                    self.status = "Camera lost (\(message)), reconnecting…"
                }
                return
            }
            if let data, size > 0, let img = Self.decodeJPEG(data, Int(size)) {
                lock.lock()
                latest = img
                lock.unlock()
            }
        }
    }

    /// macOS's ptpcamerad (the Photos / Image Capture camera service) claims PTP cameras
    /// as they're plugged in, and then gphoto2 can't see ours. launchd respawns it on
    /// demand, so stop it right before opening: once we hold the device it can't take it.
    private static func stopAppleCameraDaemon() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-x", "ptpcamerad"]
        try? p.run()
        p.waitUntilExit()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func applyQueuedSets(_ c: OpaquePointer) {
        lock.lock()
        let sets = queuedSets
        queuedSets.removeAll()
        lock.unlock()
        for s in sets {
            if s.key == Self.remoteTouchKey {
                remoteTouch(c, s.value)
                continue
            }
            let r = gpb_set(c, s.key, s.value)
            if r < 0 {
                let message = String(cString: gpb_result_string(r))
                DispatchQueue.main.async { self.status = "Couldn't set \(s.key) to \(s.value): \(message)" }
            }
        }
    }

    private func pollSettings(_ c: OpaquePointer) {
        var read: [CameraSetting] = []
        var current = [CChar](repeating: 0, count: 256)
        var choices = [CChar](repeating: 0, count: 16384)
        for id in SettingID.allCases {
            guard let key = Self.keys[id] else { continue }
            var readonly: Int32 = 0
            guard gpb_get(c, key, &current, current.count, &choices, choices.count, &readonly) >= 0 else { continue }
            let options = String(cString: choices).split(separator: "\n").map { Self.display(id, String($0)) }
            let value = Self.display(id, String(cString: current))
            read.append(CameraSetting(id: id, value: value, options: options.isEmpty ? [value] : options,
                                      writable: readonly == 0))
        }
        DispatchQueue.main.async { self.merge(read) }
    }

    /// Main thread. Keeps a just-set value until the camera reports it (or the hold
    /// expires), so the picker doesn't snap back while the camera catches up.
    private func merge(_ read: [CameraSetting]) {
        let now = Date()
        settings = read.map { s in
            var s = s
            if let p = pending[s.id] {
                if s.value == p.value || now > p.until {
                    pending[s.id] = nil
                } else {
                    s.value = p.value
                }
            }
            if !s.options.contains(s.value) { s.options.append(s.value) }
            return s
        }
    }

    private static func decodeJPEG(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> CGImage? {
        let data = Data(bytes: bytes, count: count) as CFData
        guard let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - Test chart

enum TestChart {
    /// Grey steps from -6 to +6 stops around 18% grey, plus a skin patch, all encoded
    /// as S-Log3 — what a correctly exposed S-Log3 chart would record.
    static func make(width: Int = 1280, height: Int = 720) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let steps = 13
        func put(_ x: Int, _ y: Int, _ lin: (Double, Double, Double)) {
            let i = (y * width + x) * 4
            let enc = [lin.0, lin.1, lin.2].map { UInt8(max(0, min(255, (ColorMath.linearToSlog3($0) * 255).rounded())))
            }
            px[i] = enc[0]; px[i + 1] = enc[1]; px[i + 2] = enc[2]; px[i + 3] = 255
        }
        for y in 0..<height {
            for x in 0..<width {
                if y < height / 2 {
                    let step = x * steps / width
                    let stops = Double(step - 6)
                    let v = 0.18 * pow(2, stops)
                    put(x, y, (v, v, v))
                } else if x < width / 2 {
                    // Smooth ramp, -8 to +6 stops.
                    let stops = -8 + 14 * Double(x) / Double(width / 2)
                    let v = 0.18 * pow(2, stops)
                    put(x, y, (v, v, v))
                } else {
                    // Light skin reflectance (roughly +1 stop over grey), scaled by row
                    // so the patch spans under- to over-exposed.
                    let row = Double(y - height / 2) / Double(height / 2)
                    let k = pow(2, 1.5 - 3 * row)
                    put(x, y, (0.42 * k, 0.30 * k, 0.24 * k))
                }
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
