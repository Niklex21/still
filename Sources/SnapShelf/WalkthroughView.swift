import AppKit
import SwiftUI
import SnapShelfCore
import UniformTypeIdentifiers

final class WalkthroughModel: ObservableObject {
    @Published var project: Walkthrough
    @Published var mode = "walkthrough"
    @Published var comparison = 0.5
    @Published var difference: ImageDifference?
    @Published var differenceMode = false
    @Published var alignComparison = true
    @Published var tolerance = 24.0
    @Published var ignoredRegions: [CGRect] = []
    @Published var ignoringRegion = false
    @Published var comparing = false
    private var comparisonGeneration = 0
    private let comparisonQueue = DispatchQueue(label: "Still.Comparison", qos: .userInitiated)
    private var comparisonTask: DispatchWorkItem?
    @Published var status = ""
    @Published var preview: NSImage?
    @Published var dirty = false
    let store: CaptureStore
    init(items: [Capture], store: CaptureStore, project: Walkthrough? = nil) {
        self.store = store; dirty = project == nil; self.project = project ?? Walkthrough(steps: items.sorted { $0.createdAt < $1.createdAt }.map { WalkthroughStep(id: $0.id, title: $0.title) })
        mode = project?.layout ?? "walkthrough"; comparison = max(0, min(1, project?.comparison ?? 0.5))
    }
    var items: [Capture] { project.steps.compactMap { step in store.captures.first { $0.id == step.id } } }
    func capture(_ id: UUID) throws -> Capture {
        guard let item = store.captures.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }; return item
    }
    func input(_ step: WalkthroughStep, thumbnail: Bool = false) throws -> CGImage {
        let item = try capture(step.id), url = store.disk.url(item)
        if thumbnail {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { throw Imaging.ImageError.invalid }; return image
        }
        return try Imaging.load(url)
    }
    func composite(width: CGFloat = 1000) throws -> CGImage {
        let captions = mode == "walkthrough", factor = width / 1000, titleFont = NSFont.systemFont(ofSize: 24 * width / 1000, weight: .semibold), captionFont = NSFont.systemFont(ofSize: 17 * width / 1000)
        let sizes = try project.steps.map { step in let item = try capture(step.id); return CGSize(width: item.width, height: item.height) }
        let captionHeights = project.steps.map { step in
            CGFloat(max(96 * factor, 50 * factor + ceil(("\(project.steps.firstIndex { $0.id == step.id }! + 1). \(step.title)" as NSString).boundingRect(with: CGSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: titleFont]).height) + ceil((step.caption as NSString).boundingRect(with: CGSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: captionFont]).height)))
        }
        let layout = try BatchLayout(images: sizes, horizontal: mode == "horizontal", width: width, captions: captions, captionHeights: captionHeights)
        guard let ctx = CGContext(data: nil, width: Int(layout.size.width), height: Int(layout.size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Imaging.ImageError.invalid }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(origin: .zero, size: layout.size)); ctx.translateBy(x: 0, y: layout.size.height); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }; NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (i, step) in project.steps.enumerated() {
            try autoreleasepool {
            let image = try input(step, thumbnail: width <= 300), rect = layout.frames[i]
            if captions {
                let top = rect.minY - captionHeights[i] + 8 * factor
                let title = "\(i + 1). \(step.title)" as NSString
                let titleHeight = ceil(title.boundingRect(with: CGSize(width: rect.width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: titleFont]).height)
                title.draw(in: CGRect(x: rect.minX, y: top, width: rect.width, height: titleHeight + 4 * factor), withAttributes: [.font: titleFont, .foregroundColor: NSColor.black])
                (step.caption as NSString).draw(in: CGRect(x: rect.minX, y: top + titleHeight + 12 * factor, width: rect.width, height: captionHeights[i] - titleHeight - 24 * factor), withAttributes: [.font: captionFont, .foregroundColor: NSColor.darkGray])
            }
            NSImage(cgImage: image, size: .zero).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
        }
        guard let output = ctx.makeImage() else { throw Imaging.ImageError.invalid }; return output
    }
    func refreshDifference() {
        comparisonGeneration += 1; comparisonTask?.cancel()
        let generation = comparisonGeneration
        guard project.steps.count == 2 else { difference = nil; comparing = false; return }
        let urls = project.steps.compactMap { step in store.captures.first { $0.id == step.id }.map { store.disk.url($0) } }
        guard urls.count == 2 else { difference = nil; comparing = false; status = "A source screenshot is missing"; return }
        var options = DifferenceOptions(); options.align = alignComparison; options.tolerance = UInt8(tolerance); options.ignored = ignoredRegions
        comparing = true
        let task = DispatchWorkItem { [weak self] in
            func source(_ url: URL) throws -> CGImage {
                guard let file = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateThumbnailAtIndex(file,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary) else { throw Imaging.ImageError.invalid }
                return image
            }
            let result = Result { try ImageDifference.compare(source(urls[0]),source(urls[1]),options: options) }
            DispatchQueue.main.async {
                guard let self, self.comparisonGeneration == generation else { return }
                self.comparing = false
                switch result {
                case .success(let value): self.difference = value; self.status = ""
                case .failure(let error): self.difference = nil; self.status = error.localizedDescription
                }
            }
        }
        comparisonTask = task; comparisonQueue.asyncAfter(deadline: .now() + 0.1, execute: task)
    }
    deinit { comparisonTask?.cancel() }
    func exportDifference() {
        guard !comparing, let difference else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Difference.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Imaging.png(difference.overlay).write(to: url, options: .atomic); status = "Difference exported" } catch { status = error.localizedDescription }
    }
    func refreshPreview() {
        if mode == "compare" { refreshDifference(); return }
        // Thumbnail input avoids allocating full-resolution batches during typing.
        do { let image = try composite(width: 300); preview = NSImage(cgImage: image, size: .zero); status = "" } catch { preview = nil; status = error.localizedDescription }
    }
    @discardableResult func saveProject() -> Bool {
        do {
            guard !items.contains(where: \.isPrivate) else { status = "Private screenshots cannot be saved in a walkthrough"; return false }
            let folder = store.disk.root.appendingPathComponent("Walkthroughs", isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(project).write(to: folder.appendingPathComponent("\(project.id).json"), options: .atomic)
            status = "Walkthrough saved"; dirty = false; store.objectWillChange.send(); return true
        } catch { status = error.localizedDescription; return false }
    }
    func export(_ kind: String) {
        do {
            if kind == "markdown" {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export Here"
                guard panel.runModal() == .OK, let parent = panel.url else { return }
                let folder = parent.appendingPathComponent("Still Walkthrough \(UUID().uuidString.prefix(8))", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for step in project.steps { try autoreleasepool { try Imaging.png(input(step)).write(to: folder.appendingPathComponent("\(step.id).png"), options: .atomic) } }
                try project.markdown.write(to: folder.appendingPathComponent("Walkthrough.md"), atomically: true, encoding: .utf8)
            } else {
                let panel = NSSavePanel(); panel.allowedContentTypes = [kind == "pdf" ? .pdf : .png]; panel.nameFieldStringValue = project.title.replacingOccurrences(of: "/", with: "-") + "." + kind
                guard panel.runModal() == .OK, let url = panel.url else { return }
                if kind == "pdf" { try pdf().write(to: url, options: .atomic) }
                else { try Imaging.png(composite()).write(to: url, options: .atomic) }
            }
            status = "Exported"
        } catch { status = error.localizedDescription }
    }
    enum PDFError: LocalizedError {
        case captionTooLong
        var errorDescription: String? { "This caption is too long for a PDF page. Shorten it or export Markdown instead." }
    }
    func pdf() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Imaging.ImageError.invalid }
        let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold), captionFont = NSFont.systemFont(ofSize: 13)
        for (i, step) in project.steps.enumerated() {
            try autoreleasepool {
            let image = try input(step), title = "\(i + 1). \(step.title)" as NSString
            let titleHeight = ceil(title.boundingRect(with: CGSize(width: 778,height: 20000),options: [.usesLineFragmentOrigin,.usesFontLeading],attributes: [.font: titleFont]).height)
            let captionHeight = ceil((step.caption as NSString).boundingRect(with: CGSize(width: 778,height: 20000),options: [.usesLineFragmentOrigin,.usesFontLeading],attributes: [.font: captionFont]).height)
            let imageTop = 24 + titleHeight + 12 + captionHeight + 18
            let desiredImageHeight = min(453,CGFloat(image.height) * min(1,778 / CGFloat(image.width)))
            let page = CGRect(x: 0,y: 0,width: 842,height: max(595,imageTop + desiredImageHeight + 32))
            guard page.height <= 14000 else { throw PDFError.captionTooLong }
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [page], length: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.saveGState(); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(page); ctx.translateBy(x: 0, y: page.height); ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            title.draw(in: CGRect(x: 32,y: 24,width: 778,height: titleHeight+2),withAttributes: [.font: titleFont,.foregroundColor: NSColor.black])
            (step.caption as NSString).draw(in: CGRect(x: 32,y: 24+titleHeight+12,width: 778,height: captionHeight+2),withAttributes: [.font: captionFont,.foregroundColor: NSColor.darkGray])
            let scale = min(778 / CGFloat(image.width), (page.height-imageTop-32) / CGFloat(image.height)), size = CGSize(width: CGFloat(image.width)*scale,height: CGFloat(image.height)*scale)
            NSImage(cgImage: image, size: .zero).draw(in: CGRect(x: (842-size.width)/2,y: imageTop,width: size.width,height: size.height),from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
            NSGraphicsContext.restoreGraphicsState(); ctx.restoreGState(); ctx.endPDFPage()
            }
        }
        ctx.closePDF(); return data as Data
    }
}
final class WalkthroughController: NSWindowController, NSWindowDelegate {
    static var windows: [WalkthroughController] = []
    let model: WalkthroughModel
    init(items: [Capture], store: CaptureStore, project: Walkthrough? = nil) {
        model = WalkthroughModel(items: items, store: store, project: project)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Walkthrough"; window.minSize = CGSize(width: 850, height: 550); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = NSHostingView(rootView: WalkthroughView(model: model)); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save this walkthrough?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: return model.saveProject(); case .alertSecondButtonReturn: return true; default: return false }
    }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }
    static func show(items: [Capture], store: CaptureStore, project: Walkthrough? = nil) { AppDelegate.shared?.clearHoverTarget(); let c = WalkthroughController(items: items, store: store, project: project); windows.append(c); NSApp.activate(ignoringOtherApps: true); c.showWindow(nil); c.window?.makeKeyAndOrderFront(nil) }
}
struct WalkthroughView: View {
    @ObservedObject var model: WalkthroughModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title", text: $model.project.title).textFieldStyle(.plain).font(.headline)
                Picker("Layout", selection: $model.mode) { Text("Walkthrough").tag("walkthrough"); Text("Vertical").tag("vertical"); Text("Side by Side").tag("horizontal"); if model.project.steps.count == 2 { Text("Compare").tag("compare") } }.labelsHidden().frame(width: 160)
                Button("Save") { model.saveProject() }.keyboardShortcut("s", modifiers: .command)
                Menu("Export") { Button(model.mode == "compare" ? "Difference PNG…" : "PNG…") { if model.mode == "compare" { model.exportDifference() } else { model.export("png") } }.disabled(model.mode == "compare" && (model.comparing || model.difference == nil)); Button("PDF · One Step per Page…") { model.export("pdf") }; Button("Markdown + Images…") { model.export("markdown") } }.fixedSize()
            }.padding(16).background(.bar)
            Divider()
            HStack(spacing: 0) {
                List {
                    ForEach($model.project.steps) { $step in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\((model.project.steps.firstIndex { $0.id == step.id } ?? 0) + 1)").foregroundStyle(.secondary)
                                TextField("Step title", text: $step.title)
                                Button { model.project.move(step.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).help("Move earlier")
                                Button { model.project.move(step.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help("Move later")
                            }
                            TextField("Caption", text: $step.caption, axis: .vertical).lineLimit(2...4).font(.caption)
                        }.padding(.vertical, 8)
                    }
                }.frame(width: 310)
                Divider()
                if model.mode == "compare", model.items.count == 2 {
                    ComparisonView(model: model)
                } else {
                    ScrollView([.vertical, .horizontal]) { if let preview = model.preview { Image(nsImage: preview).resizable().scaledToFit().frame(width: min(1100, preview.size.width)) } }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .underPageBackgroundColor))
                }
            }
            HStack { Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(model.project.steps.count) steps").font(.caption).foregroundStyle(.secondary) }.padding(12)
        }.onAppear { model.refreshPreview() }.onChange(of: model.project) { _, _ in model.dirty = true; model.refreshPreview() }.onChange(of: model.mode) { _, value in model.project.layout = value }.onChange(of: model.comparison) { _, value in model.project.comparison = value }
    }
}
