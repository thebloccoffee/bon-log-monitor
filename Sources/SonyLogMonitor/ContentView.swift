import MonitorCore
import SwiftUI

/// Brand palette: near-black panels with one warm accent.
enum Brand {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.29)
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let panel = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let line = Color.white.opacity(0.07)
    static let handle = "@jooonbon"
}

struct ContentView: View {
    @StateObject private var model = MonitorModel()
    @State private var showSidebar = true

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, showSidebar: $showSidebar)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MonitorView(model: model)
                        .background(Color.black)
                        .overlay(TouchFocusLayer(model: model))
                        .overlay(alignment: .topLeading) { PictureBadge(model: model, camera: model.camera) }
                        .overlay(alignment: .bottomTrailing) {
                            if model.showAudio { AudioMeters(meter: model.audio).padding(10) }
                        }
                    ReadoutStrip(camera: model.camera)
                }
                if showSidebar {
                    Rectangle().fill(Brand.line).frame(width: 1)
                    Sidebar(model: model, camera: model.camera)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Brand.bg)
        .frame(minWidth: 1000, minHeight: 620)
        .preferredColorScheme(.dark)
        .tint(Brand.accent)
    }
}

// MARK: - Top bar (brand + overlay toggles)

private struct TopBar: View {
    @ObservedObject var model: MonitorModel
    @Binding var showSidebar: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Room for the window's traffic lights (hidden title bar).
            Spacer().frame(width: 64)
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(Brand.accent).frame(width: 10, height: 10)
                Text("LOG MONITOR").font(.system(size: 13, weight: .heavy)).tracking(1.5)
            }
            Rectangle().fill(Brand.line).frame(width: 1, height: 18).padding(.horizontal, 6)
            ToggleChip(title: "Rec.709", key: "l", isOn: $model.viewRec709)
            ToggleChip(title: "Zebra", key: "z", isOn: $model.zebraOn)
            ToggleChip(title: "False Color", key: "f", isOn: $model.falseColorOn)
            ToggleChip(title: "Skin", key: "s", isOn: $model.skinOn, tint: Color(red: 0.98, green: 0.50, blue: 0.45))
            ToggleChip(title: "Audio", key: "a", isOn: $model.showAudio)
            Spacer()
            Text("Created by \(Brand.handle)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Capsule().stroke(Brand.accent.opacity(0.5), lineWidth: 1))
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right").font(.system(size: 14))
                    .foregroundStyle(showSidebar ? Brand.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("b", modifiers: [])
            .help("Show / hide settings (B)")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Brand.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

private struct ToggleChip: View {
    let title: String
    let key: KeyEquivalent
    @Binding var isOn: Bool
    var tint: Color = Brand.accent

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isOn ? tint : Color.white.opacity(0.07), in: Capsule())
                .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .help("\(title) (\(String(key.character).uppercased()))")
    }
}

/// Top-left of the picture: what's being viewed, and REC like a camera's own display.
private struct PictureBadge: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var camera: CameraController

    var body: some View {
        HStack(spacing: 6) {
            if camera.isRecording {
                Text("● REC").font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
            }
            Text(model.viewRec709 ? "709 · \(model.profile.rawValue)" : "LOG")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

// MARK: - Audio meters

/// Camera-style vertical level meters, one per input channel, over the picture.
private struct AudioMeters: View {
    @ObservedObject var meter: AudioMeter
    private static let floor: Float = -48
    private static let ticks: [Float] = [0, -6, -12, -20, -30, -40]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if meter.channels.isEmpty {
                Text(meter.message.isEmpty ? "No audio" : meter.message)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    Scale(ticks: Self.ticks, floor: Self.floor)
                    ForEach(Array(meter.channels.enumerated()), id: \.offset) { i, ch in
                        VStack(spacing: 3) {
                            Bar(level: ch.level, peak: ch.peak, floor: Self.floor)
                            Text("CH\(i + 1)").font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    private static func fraction(_ db: Float, _ floor: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - floor) / -floor)))
    }

    private struct Bar: View {
        let level: Float, peak: Float, floor: Float
        var body: some View {
            GeometryReader { g in
                let h = g.size.height
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    LinearGradient(stops: [
                        .init(color: .green, location: 0), .init(color: .green, location: 0.70),
                        .init(color: .yellow, location: 0.76), .init(color: .yellow, location: 0.86),
                        .init(color: .red, location: 0.90), .init(color: .red, location: 1),
                    ], startPoint: .bottom, endPoint: .top)
                    .mask(alignment: .bottom) { Rectangle().frame(height: h * AudioMeters.fraction(level, floor)) }
                    Rectangle().fill(peak > -1 ? Color.red : Color.white)
                        .frame(height: 2)
                        .offset(y: -h * AudioMeters.fraction(peak, floor) + 1)
                        .opacity(peak > floor ? 1 : 0)
                }
            }
            .frame(width: 9, height: 120)
        }
    }

    private struct Scale: View {
        let ticks: [Float], floor: Float
        var body: some View {
            VStack(spacing: 3) {
                GeometryReader { g in
                    ForEach(ticks, id: \.self) { t in
                        Text(t == 0 ? "0" : "\(Int(t))")
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .position(x: g.size.width / 2, y: g.size.height * (1 - AudioMeters.fraction(t, floor)))
                    }
                }
                .frame(width: 16, height: 120)
                Text("dB").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Readout strip (camera-style exposure + record)

private struct ReadoutStrip: View {
    @ObservedObject var camera: CameraController

    /// Display order and short labels, like the camera's own info line.
    private static let order: [(SettingID, String)] = [
        (.fNumber, "IRIS"), (.shutter, "SHUTTER"), (.iso, "ISO"), (.whiteBalance, "WB"),
        (.exposureComp, "EV"), (.focusMode, "FOCUS"), (.focusArea, "AREA"), (.pictureProfile, "PP"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            RecordButton(camera: camera).padding(.horizontal, 14)
            Rectangle().fill(Brand.line).frame(width: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if camera.settings.isEmpty {
                        Text(camera.connected ? "Reading camera…" : "Connect the camera to adjust exposure")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                    }
                    ForEach(Self.order, id: \.0) { id, label in
                        if let s = camera.setting(id) { Readout(label: label, setting: s, camera: camera) }
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(camera.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(camera.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 220, alignment: .trailing)
            .padding(.horizontal, 12)
        }
        .frame(height: 58)
        .background(Brand.panel)
        .overlay(alignment: .top) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

private struct Readout: View {
    let label: String
    let setting: CameraSetting
    @ObservedObject var camera: CameraController

    var body: some View {
        Menu {
            ForEach(setting.options, id: \.self) { o in
                Button { camera.set(setting.id, to: o) } label: {
                    if o == setting.value { Label(o, systemImage: "checkmark") } else { Text(o) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Brand.accent)
                Text(setting.value)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!setting.writable)
        .opacity(setting.writable ? 1 : 0.5)
        .help(setting.id.rawValue)
    }
}

private struct RecordButton: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        HStack(spacing: 12) {
            Button { camera.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 2).frame(width: 34, height: 34)
                    RoundedRectangle(cornerRadius: camera.isRecording ? 3 : 12)
                        .fill(Color.red)
                        .frame(width: camera.isRecording ? 14 : 24, height: camera.isRecording ? 14 : 24)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [])
            .disabled(!camera.connected)
            .help(camera.isRecording ? "Stop (R)" : "Record (R)")

            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(elapsed(at: ctx.date))
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(camera.isRecording ? Color.red : Color.secondary)
            }
        }
    }

    private func elapsed(at now: Date) -> String {
        guard let start = camera.recordingStarted else { return "00:00:00" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

// MARK: - Touch focus

/// Click the picture to put the camera's AF spot there. Taps outside the letterboxed
/// frame are ignored.
private struct TouchFocusLayer: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        GeometryReader { geo in
            let rect = fitRect(geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        guard rect.contains(p) else { return }
                        model.touchFocus(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
                    }
                if let m = model.focusMark {
                    TimelineView(.periodic(from: m.at, by: 0.1)) { ctx in
                        let age = ctx.date.timeIntervalSince(m.at)
                        if age < 2 {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.green, lineWidth: 2)
                                .frame(width: 56, height: 56)
                                .scaleEffect(age < 0.2 ? 1.3 - age * 1.5 : 1)
                                .opacity(age > 1.5 ? (2 - age) * 2 : 1)
                                .position(x: rect.minX + m.x * rect.width, y: rect.minY + m.y * rect.height)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    private func fitRect(_ size: CGSize) -> CGRect {
        let a = model.frameAspect
        guard size.width > 0, size.height > 0, a > 0 else { return .zero }
        let viewAspect = size.width / size.height
        let w = a > viewAspect ? size.width : size.height * a
        let h = a > viewAspect ? size.width / a : size.height
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var camera: CameraController

    var body: some View {
        Form {
            Section("Camera") {
                Picker("Source", selection: $model.source) {
                    ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.source == .demo {
                    HStack {
                        Button("Open log clip…") { model.openDemoClip() }
                        Button("Test chart") { (camera as? DemoCamera)?.useTestChart() }
                    }
                } else if !camera.connected {
                    Button("Reconnect") { model.reconnect() }
                }
            }

            Section("Phone view") {
                if let url = model.phoneURL {
                    HStack(alignment: .top, spacing: 12) {
                        if let qr = QRCode.image(for: url) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 96, height: 96)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan with your phone's camera, or open in Safari:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text("Phone must be on the same Wi-Fi.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Not on a network, so phone view is off.").foregroundStyle(.secondary)
                }
            }

            Section("Focus") {
                Text(model.source == .demo ? "Touch focus needs the camera." : "Click the picture to focus there. Iris, shutter, ISO, WB and focus are in the bar under the picture.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.source == .demo {
                    Text("Demo: exposure changes are simulated on the picture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Audio") {
                AudioSection(meter: model.audio)
            }

            Section("Log profile") {
                Picker("Convert from", selection: $model.profile) {
                    ForEach(LogProfile.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Follow camera picture profile", isOn: $model.followCameraProfile)
                    .help("PP7/PP8/PP9 switch the Rec.709 view on with the matching curve; other profiles switch it off.")
            }

            Section("Zebra") {
                Picker("Mode", selection: $model.zebraMode) {
                    ForEach(ZebraMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(label: "Level", value: $model.zebraLevel, range: 0...109, unit: "%")
                if model.zebraMode == .range {
                    LabeledSlider(label: "±", value: $model.zebraTolerance, range: 1...20, unit: "%")
                }
                Toggle("Measure on log signal", isOn: $model.zebraOnLog)
                    .help("Off: zebras read the Rec.709 view. On: they read the raw log signal, like the camera's own zebras.")
            }

            Section("Skin / false color") {
                LabeledSlider(label: "Skin from", value: $model.skinLo, range: 30...90, unit: "%")
                LabeledSlider(label: "Skin to", value: $model.skinHi, range: 30...95, unit: "%")
                FalseColorLegend(skinLo: model.skinLo, skinHi: model.skinHi)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg)
        .safeAreaInset(edge: .bottom) {
            Text("Bon Log Monitor · Created by \(Brand.handle)")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Brand.panel)
        }
    }
}

private struct AudioSection: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        Picker("Input", selection: $meter.deviceID) {
            if meter.devices.isEmpty { Text("None").tag(String?.none) }
            ForEach(meter.devices) { Text($0.name).tag(Optional($0.id)) }
        }
        Text("Levels come from a Mac audio input: the camera via HDMI capture card or USB Streaming, or a mic. PC Remote USB carries no audio.")
            .font(.caption).foregroundStyle(.secondary)
        if !meter.message.isEmpty { Text(meter.message).font(.caption).foregroundStyle(.orange) }
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value))\(unit)").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

private struct FalseColorLegend: View {
    let skinLo: Double
    let skinHi: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(row.2).frame(width: 14, height: 10)
                    Text(row.0).font(.caption)
                    Spacer()
                    Text(row.1).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("Measured on the Rec.709 image. 18% grey = 41%.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var rows: [(String, String, Color)] {
        let s = Exposure.salmon
        var r = Exposure.fixedBands.map { b in
            (b.name, range(b.lo, b.hi), Color(red: b.rgb.0, green: b.rgb.1, blue: b.rgb.2))
        }
        r.insert(("Skin", "\(Int(skinLo))–\(Int(skinHi))%", Color(red: s.0, green: s.1, blue: s.2)), at: 3)
        return r
    }

    private func range(_ lo: Double, _ hi: Double) -> String {
        if lo < 0 { return "< \(Int(hi * 100))%" }
        if hi > 1 { return "≥ \(Int(lo * 100))%" }
        return "\(Int(lo * 100))–\(Int(hi * 100))%"
    }
}
