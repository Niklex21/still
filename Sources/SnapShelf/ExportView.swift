import AppKit
import SwiftUI
import SnapShelfCore

final class ExportController: NSWindowController, NSWindowDelegate {
    static var windows: [ExportController] = []
    init(item: Capture, store: CaptureStore) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Export Image"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = NSHostingView(rootView: ExportView(item: item, store: store)); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }
    static func show(_ item: Capture, store: CaptureStore) {
        AppDelegate.shared?.clearHoverTarget()
        let controller = ExportController(item: item, store: store); windows.append(controller)
        NSApp.activate(ignoringOtherApps: true); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
struct ExportView: View {
    let item: Capture
    @ObservedObject var store: CaptureStore
    @State private var options = ExportOptions()
    @State private var status = ""
    @State private var busy = false
    var dimensions: String {
        guard let (w, h) = try? options.dimensions(width: item.width, height: item.height) else { return "Image too large" }
        return "\(w) × \(h) pixels"
    }
    var body: some View {
        VStack(spacing: 16) {
            if let image = store.thumbnail(item) { Image(nsImage: image).resizable().scaledToFit().frame(height: 150) }
            Form {
                Picker("Format", selection: $options.format) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Size", selection: $options.scale) { Text("Original").tag(1.0); Text("75%").tag(0.75); Text("50%").tag(0.5); Text("25%").tag(0.25); Text("2×").tag(2.0) }
                TextField("Maximum width", value: $options.maxWidth, format: .number).help("Pixels; 0 preserves the chosen scale. Aspect ratio stays locked.")
                if options.format != .png { Slider(value: $options.quality, in: 0.1...1) { Text("Quality") } }
                Text(dimensions).font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("Prepare for Upload") { write(upload: true) }.help("Export this size and copy its path for ⌘⇧G in a file chooser")
                Spacer()
                Button("Save As…") { write(upload: false) }.buttonStyle(.borderedProminent)
            }.disabled(busy)
        }.padding(22)
    }
    func write(upload: Bool) {
        let url: URL
        if upload {
            // Stable per-capture export; history originals and editable documents stay untouched.
            let folder = store.disk.root.appendingPathComponent("Exports", isDirectory: true)
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { status = error.localizedDescription; return }
            url = folder.appendingPathComponent("\(item.id).\(options.format.fileExtension)")
        } else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [options.format.type]
            panel.nameFieldStringValue = item.title.replacingOccurrences(of: "/", with: "-") + "." + options.format.fileExtension
            guard panel.runModal() == .OK, let chosen = panel.url else { return }; url = chosen
        }
        busy = true; let options = options, source = store.disk.url(item)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { let data = try options.encode(Imaging.load(source)); try data.write(to: url, options: .atomic); return data.count }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let bytes):
                    if upload { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string); status = "Path copied · In the file chooser, press ⌘⇧G then ⌘V" }
                    else { store.consume(item.id); status = "Saved · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" }
                case .failure(let error): status = error.localizedDescription
                }
            }
        }
    }
}
