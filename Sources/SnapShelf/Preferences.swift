import AppKit
import SwiftUI
import SnapShelfCore

final class CapturePreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var controls: HoverControls { didSet { save(controls, key: "hoverControls.v1") } }
    @Published var window: WindowAppearance { didSet { save(window, key: "windowAppearance.v1") } }
    @Published var visualSearchEnabled: Bool { didSet { defaults.set(visualSearchEnabled, forKey: "visualSearchEnabled.v1") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        visualSearchEnabled = defaults.object(forKey: "visualSearchEnabled.v1") as? Bool ?? true
        controls = defaults.data(forKey: "hoverControls.v1").flatMap { try? JSONDecoder().decode(HoverControls.self, from: $0) } ?? HoverControls()
        window = defaults.data(forKey: "windowAppearance.v1").flatMap { try? JSONDecoder().decode(WindowAppearance.self, from: $0) } ?? WindowAppearance()
    }
    private func save<T: Encodable>(_ value: T, key: String) { if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } }
    func backgroundImage(for screen: NSScreen?) -> CGImage? {
        let url: URL?
        switch window.background {
        case .wallpaper: url = (screen ?? NSScreen.main).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        case .image: url = window.imagePath.map { URL(fileURLWithPath: $0) }
        default: url = nil
        }
        return url.flatMap { try? Imaging.load($0) }
    }
    func frameWindow(_ image: CGImage, screen: NSScreen?) throws -> CGImage {
        try Imaging.frameWindow(image, background: backgroundImage(for: screen), style: window.background,
                                color: NSColor(hex: window.colorHex).cgColor, padding: window.padding,
                                shadow: window.shadow, dimming: window.dimming)
    }
    func chooseBackground(root: URL) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let folder = root.appendingPathComponent("Backgrounds", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("window.png")
            try Imaging.png(Imaging.load(source)).write(to: target, options: .atomic)
            window.imagePath = target.path; window.background = .image
        } catch { AppDelegate.shared?.store.error = error.localizedDescription }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0x9BAED1
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var rgbHex: String {
        let color = usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}

struct HoverControlsSettings: View {
    @ObservedObject var preferences: CapturePreferences
    var body: some View {
        Form {
            Section("Corner actions") {
                ForEach(ActionCorner.allCases) { corner in
                    Picker(corner.title, selection: Binding(get: { preferences.controls[corner] }, set: { preferences.controls[corner] = $0 })) {
                        ForEach(ScreenshotAction.allCases) { action in Label(action.title, systemImage: action.symbol).tag(action) }
                    }
                }
            }
            Section("On hover") {
                Slider(value: $preferences.controls.buttonSize, in: 28...40, step: 2) { Text("Button size") }
                Slider(value: $preferences.controls.dimming, in: 0.1...0.6) { Text("Dim screenshot") }
                Toggle("Hide date", isOn: $preferences.controls.hideDate)
            }
            Button("Restore Controls") { preferences.controls = HoverControls() }
        }.formStyle(.grouped)
    }
}

struct WindowAppearanceSettings: View {
    @ObservedObject var preferences: CapturePreferences
    let root: URL
    var body: some View {
        Form {
            Section("Window captures") {
                Picker("Background", selection: $preferences.window.background) {
                    ForEach(FrameBackground.allCases) { style in Text(style.title).tag(style) }
                }
                if preferences.window.background == .solid {
                    ColorPicker("Color", selection: Binding(get: { Color(nsColor: NSColor(hex: preferences.window.colorHex)) }, set: { preferences.window.colorHex = NSColor($0).rgbHex }), supportsOpacity: false)
                }
                if preferences.window.background == .image {
                    Button("Choose Image…") { preferences.chooseBackground(root: root) }
                    if preferences.window.imagePath != nil { Label("Custom image saved", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                }
                Slider(value: $preferences.window.padding, in: 0.03...0.20) { Text("Padding") }
                Slider(value: $preferences.window.dimming, in: 0...0.5) { Text("Dim background") }
                Toggle("Window shadow", isOn: $preferences.window.shadow)
            }
            Button("Restore Background") { preferences.window = WindowAppearance() }
        }.formStyle(.grouped)
    }
}
