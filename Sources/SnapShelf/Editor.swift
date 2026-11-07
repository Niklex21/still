import AppKit
import SwiftUI
import SnapShelfCore

enum MarkTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, pen, text, pin, highlight, redact, crop, extract
    var icon: String { switch self { case .select: return "cursorarrow"; case .pin: return "1.circle"; case .extract: return "text.viewfinder"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .ellipse: return "circle"; case .pen: return "pencil.tip"; case .text: return "textformat"; case .highlight: return "highlighter"; case .redact: return "rectangle.fill"; case .crop: return "crop" } }
    var name: String { self == .extract ? "Select Text" : self == .pin ? "Numbered Pin" : rawValue.capitalized }
}
struct Mark {
    var id = UUID()
    var tool: MarkTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var number = 0
    var archive: Annotation {
        let c = color.usingColorSpace(.sRGB) ?? .red
        return Annotation(id: id, tool: tool.rawValue, points: points, color: [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent)], width: Double(width), text: text, number: number)
    }
    init(tool: MarkTool, points: [CGPoint], color: NSColor, width: CGFloat, text: String = "", number: Int = 0) { self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text; self.number = number }
    init?(_ a: Annotation) {
        guard let tool = MarkTool(rawValue: a.tool), a.color.count == 4, !a.points.isEmpty else { return nil }
        id = a.id; self.tool = tool; points = a.points; color = NSColor(srgbRed: a.color[0], green: a.color[1], blue: a.color[2], alpha: a.color[3]); width = a.width; text = a.text; number = a.number
    }
}
struct CanvasState { var image: CGImage; var marks: [Mark]; var crop: CGRect? }

final class EditorModel: ObservableObject {
    @Published var tool: MarkTool = .arrow
    @Published var color = Color(red: 1, green: 0.36, blue: 0.35)
    @Published var width: Double = 5
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var dirty = false
    @Published var status = "Drag on the image to draw an arrow."
    var pasteboard = NSPasteboard.general
    @Published var zoomLabel = "Fit"
    @Published var selected: UUID?
    @Published var recognizedText = ""
    @Published var showText = false
    @Published var suggestions: [TextRegion] = []
    @Published var scanning = false
    var canvas: AnnotationCanvas!
    var save: (() -> Void)?
}

final class EditorController: NSWindowController, NSWindowDelegate {
    let item: Capture
    let store: CaptureStore
    let model = EditorModel()
    private var privateLease = false
    init(item: Capture, store: CaptureStore) throws {
        self.item = item; self.store = store
        let image: CGImage
        if let document = item.editDocument {
            guard document.version == 1, URL(fileURLWithPath: document.baseFilename).lastPathComponent == document.baseFilename else { throw CocoaError(.fileReadCorruptFile) }
            image = try Imaging.load(store.disk.baseURL(item, filename: document.baseFilename))
        } else { image = try Imaging.load(store.disk.url(item)) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Annotate — \(item.title)"; window.minSize = NSSize(width: 850, height: 600); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if item.isPrivate { store.retainPrivate(item.id); privateLease = true }
        model.pasteboard = store.pasteboard
        model.canvas = AnnotationCanvas(image: image, model: model)
        if let doc = item.editDocument { model.canvas.state.marks = doc.annotations.compactMap(Mark.init); model.canvas.state.crop = doc.crop }
        model.status = "\(image.width) × \(image.height) · Shift constrains shapes"
        model.save = { [weak self] in self?.save() }
        let host = NSHostingView(rootView: EditorView(model: model, item: item, store: store, controller: self)); host.sizingOptions = []; window.contentView = host
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func save() {
        model.canvas.finishInlineEditing(commit: true)
        guard model.dirty else { model.status = "Saved"; return }
        do { try store.saveEdit(item.id, image: model.canvas.render(), document: EditDocument(baseFilename: "\(item.id)-edit-base-\(UUID()).png", annotations: model.canvas.state.marks.map(\.archive), crop: model.canvas.state.crop), base: model.canvas.state.image); model.dirty = false; model.status = "Saved · annotations remain editable" }
        catch { model.status = "Could not save: \(error.localizedDescription)" }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.canvas.finishInlineEditing(commit: true)
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save your annotations?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: save(); return !model.dirty; case .alertSecondButtonReturn: return true; default: return false }
    }
    func windowWillClose(_ notification: Notification) {
        if privateLease { privateLease = false; store.releasePrivate(item.id) }
        AppDelegate.shared?.editors.removeValue(forKey: item.id)
    }
    deinit { if privateLease { store.releasePrivate(item.id) } }
    func revert() {
        let alert = NSAlert(); alert.messageText = "Revert to the original image?"; alert.informativeText = "This resets this editing session. You can undo before saving."; alert.addButton(withTitle: "Revert"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do { model.canvas.replace(try Imaging.load(store.disk.url(item, original: true))) } catch { model.status = error.localizedDescription }
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let item: Capture
    @ObservedObject var store: CaptureStore
    unowned let controller: EditorController
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(MarkTool.allCases, id: \.self) { tool in
                    Button { model.tool = tool; model.status = tool == .select ? "Select, move, or resize · Double-click text or pins to edit · Delete removes" : tool.name; if tool == .extract { model.canvas.scanText() } } label: {
                        Image(systemName: tool.icon).font(.system(size: 16)).frame(width: 36, height: 32).background(model.tool == tool ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(model.tool == tool ? accent : .primary)
                    }.buttonStyle(.plain).help(tool.name).accessibilityLabel(tool.name)
                }
                Divider().frame(height: 32).padding(.horizontal, 8)
                ColorPicker("Color", selection: $model.color, supportsOpacity: false).labelsHidden().frame(width: 38)
                VStack(spacing: 3) { Text("Size \(Int(model.width))").font(.system(size: 9)).foregroundStyle(.secondary); Slider(value: $model.width, in: 2...20, step: 1).frame(width: 72) }
                Spacer(minLength: 4)
                Button { model.canvas.suggestRedactions() } label: { Image(systemName: "eye.slash") }.help("Suggest redactions").disabled(model.scanning)
                Button { model.canvas.undo(nil) } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo ⌘Z")
                Button { model.canvas.redo(nil) } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo ⇧⌘Z")
            }.padding(10).background(.bar)
            Divider()
            HStack(spacing: 0) {
                CanvasRepresentable(canvas: model.canvas).padding(24).background(Color(nsColor: .underPageBackgroundColor))
                if model.showText {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Recognized text").font(.headline); Spacer(); Button { model.showText = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        TextEditor(text: $model.recognizedText).font(.system(size: 13)).scrollContentBackground(.hidden)
                        Button("Copy Text") { store.pasteboard.clearContents(); model.pasteboard.setString(model.recognizedText, forType: .string); model.status = "Text copied" }.disabled(model.recognizedText.isEmpty)
                    }.padding(16).frame(width: 260)
                }
                if !model.suggestions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Review redactions").font(.headline); Spacer(); Button { model.suggestions = []; model.canvas.needsDisplay = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        Text("Suggestions may miss sensitive information.").font(.caption).foregroundStyle(.secondary)
                        ScrollView { ForEach(model.suggestions) { region in
                            HStack { Text(region.text).lineLimit(2).font(.caption); Spacer(); Button("Redact") { model.canvas.applyRedactions([region]) } }
                        } }
                        Button("Redact All") { model.canvas.applyRedactions(model.suggestions) }.buttonStyle(.borderedProminent)
                    }.padding(16).frame(width: 250)
                }
            }
            Divider()
            HStack {
                HStack(spacing: 4) {
                    Button { model.canvas.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out · ⌘−")
                    Menu(model.zoomLabel) {
                        Button("Fit") { model.canvas.fitImage() }
                        Button("100% pixels") { model.canvas.actualPixels() }
                        Button("200% pixels") { model.canvas.actualPixels(multiplier: 2) }
                    }.frame(width: 68)
                    Button { model.canvas.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in · ⌘+")
                }.buttonStyle(.borderless)
                Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.canvas.state.crop != nil { Button("Reset Crop") { model.canvas.checkpoint(); model.canvas.state.crop = nil; model.canvas.changed() }.font(.system(size: 11)) }
                Button("Revert Original…") { controller.revert() }.buttonStyle(.plain).font(.system(size: 11)).padding(.trailing, 10)
                Button("Export…") { controller.save(); if !model.dirty, let current = store.captures.first(where: { $0.id == item.id }) { store.export(current) } }
                Button("Copy") {
                    controller.save()
                    if !model.dirty, let current = store.captures.first(where: { $0.id == item.id }), store.copy(current) { model.status = "Copied image to clipboard." }
                }
                Button("Save") { controller.save() }.keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            }.padding(14).background(.ultraThinMaterial)
        }
        .onChange(of: model.color) { _, _ in model.canvas.restyleSelection() }
        .onChange(of: model.width) { _, _ in model.canvas.restyleSelection() }
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let canvas: AnnotationCanvas
    func makeNSView(context: Context) -> AnnotationCanvas { canvas }
    func updateNSView(_ nsView: AnnotationCanvas, context: Context) { nsView.needsDisplay = true }
}

final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    var state: CanvasState
    unowned let model: EditorModel
    var past: [CanvasState] = []
    var future: [CanvasState] = []
    var pending: Mark?
    var start: CGPoint?
    var regions: [TextRegion] = []
    var contentGeneration = 0
    var viewport = EditorViewport()
    private var spaceHeld = false
    private var panStart: CGPoint?
    private var panOrigin = CGPoint.zero
    private(set) var inlineField: NSTextField?
    private var inlineMark: Mark?
    private var finishingInline = false
    var selectionStart: [CGPoint]?
    var resizing = false
    var selectionCheckpointed = false
    var selectedIndex: Int? { state.marks.firstIndex { $0.id == model.selected } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, model: EditorModel) { state = CanvasState(image: image, marks: []); self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    var imageSize: CGSize { CGSize(width: state.image.width, height: state.image.height) }
    var imageRect: CGRect { viewport.rect(image: imageSize, bounds: bounds.size) }
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        DispatchQueue.main.async { [weak self] in self?.updateZoomDisplay() }
    }
    func updateZoomDisplay() {
        let value = imageRect.width / max(1,imageSize.width) * backingScale * 100
        let label = viewport.zoom == 1 && viewport.pan == .zero ? "Fit" : "\(Int(value.rounded()))%"
        if model.zoomLabel != label { model.zoomLabel = label }
        needsDisplay = true
    }
    func fitImage() { finishInlineEditing(commit: true); viewport = EditorViewport(); updateZoomDisplay() }
    func actualPixels(multiplier: CGFloat = 1) {
        finishInlineEditing(commit: true)
        viewport.actualPixels(image: imageSize, bounds: bounds.size, backingScale: backingScale)
        viewport.zoom = min(32, viewport.zoom * multiplier); constrainPan(); updateZoomDisplay()
    }
    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        finishInlineEditing(commit: true)
        viewport.setZoom(viewport.zoom * factor, around: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY), image: imageSize, bounds: bounds.size)
        constrainPan(); updateZoomDisplay()
    }
    func constrainPan() {
        let rect = imageRect
        let xLimit = rect.width > bounds.width ? (rect.width - bounds.width) / 2 + 40 : 0
        let yLimit = rect.height > bounds.height ? (rect.height - bounds.height) / 2 + 40 : 0
        viewport.pan.x = min(xLimit,max(-xLimit,viewport.pan.x)); viewport.pan.y = min(yLimit,max(-yLimit,viewport.pan.y))
    }
    override func magnify(with event: NSEvent) { zoom(by: max(0.2, 1 + event.magnification), around: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { zoom(by: exp(event.scrollingDeltaY * 0.01), around: convert(event.locationInWindow, from: nil)) }
        else { finishInlineEditing(commit: true); viewport.pan.x += event.scrollingDeltaX; viewport.pan.y += event.scrollingDeltaY; constrainPan(); updateZoomDisplay() }
    }
    override func resetCursorRects() {
        let cursor: NSCursor = spaceHeld ? .openHand : [.text,.extract].contains(model.tool) ? .iBeam : model.tool == .select ? .arrow : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }
    override func resignFirstResponder() -> Bool { spaceHeld = false; return super.resignFirstResponder() }
    func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), r = imageRect
        return CGPoint(x: min(CGFloat(state.image.width), max(0, (p.x - r.minX) * CGFloat(state.image.width) / max(1, r.width))), y: min(CGFloat(state.image.height), max(0, (p.y - r.minY) * CGFloat(state.image.height) / max(1, r.height))))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard imageRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: imageRect.minX, yBy: imageRect.minY); transform.scale(by: imageRect.width / CGFloat(state.image.width)); transform.concat()
        drawImageAndMarks(omitInline: true)
        if let pending { drawMark(pending) }
        NSColor.controlAccentColor.setStroke()
        if inlineField == nil, let i = selectedIndex { let rect = markBounds(state.marks[i]).insetBy(dx: -5, dy: -5); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke(); NSColor.controlAccentColor.setFill(); NSBezierPath(rect: CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 12, height: 12)).fill() }
        if let crop = state.crop { NSColor.systemMint.setStroke(); NSBezierPath(rect: crop).stroke() }
        if model.tool == .extract { NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); regions.forEach { NSBezierPath(rect: $0.rect).fill() } }
        NSColor.systemOrange.withAlphaComponent(0.3).setFill(); model.suggestions.forEach { NSBezierPath(rect: $0.rect).fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
    func drawImageAndMarks(omitInline: Bool = false) {
        let size = NSSize(width: state.image.width, height: state.image.height)
        NSImage(cgImage: state.image, size: size).draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for mark in state.marks {
            if omitInline, mark.id == inlineMark?.id {
                if mark.tool == .pin { var pin = mark; pin.text = ""; drawMark(pin) }
            } else { drawMark(mark) }
        }
    }
    func drawMark(_ mark: Mark) {
        guard let p = mark.points.first, let q = mark.points.last else { return }
        let rect = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
        let path = NSBezierPath(); path.lineWidth = mark.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        mark.color.setStroke(); mark.color.setFill()
        switch mark.tool {
        case .select, .extract: break
        case .pin:
            let radius = max(18, mark.width * 3)
            NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)).fill()
            let value = "\(mark.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: radius, weight: .bold), .foregroundColor: NSColor.white]
            let size = value.size(withAttributes: attrs)
            value.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
            if !mark.text.isEmpty { (mark.text as NSString).draw(at: CGPoint(x: p.x + radius + 8, y: p.y - radius / 2), withAttributes: [.font: NSFont.systemFont(ofSize: max(16, mark.width * 4), weight: .semibold), .foregroundColor: mark.color]) }
        case .arrow:
            path.move(to: p); path.line(to: q); path.stroke()
            let angle = atan2(q.y - p.y, q.x - p.x), length = max(16, mark.width * 4)
            let head = NSBezierPath(); head.move(to: q)
            head.line(to: CGPoint(x: q.x - length * cos(angle - .pi / 6), y: q.y - length * sin(angle - .pi / 6)))
            head.line(to: CGPoint(x: q.x - length * cos(angle + .pi / 6), y: q.y - length * sin(angle + .pi / 6))); head.close(); head.fill()
        case .rectangle: let shape = NSBezierPath(rect: rect); shape.lineWidth = mark.width; shape.stroke()
        case .ellipse: let shape = NSBezierPath(ovalIn: rect); shape.lineWidth = mark.width; shape.stroke()
        case .pen: path.move(to: p); for point in mark.points.dropFirst() { path.line(to: point) }; path.stroke()
        case .highlight: mark.color.withAlphaComponent(0.32).setFill(); NSBezierPath(rect: rect).fill()
        case .redact: NSColor.black.setFill(); NSBezierPath(rect: rect.integral).fill()
        case .crop: NSColor.systemMint.setStroke(); path.appendRect(rect); path.setLineDash([8, 5], count: 2, phase: 0); path.stroke()
        case .text:
            let font = NSFont.systemFont(ofSize: max(18, mark.width * 5), weight: .semibold)
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.7); shadow.shadowBlurRadius = 2
            (mark.text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: mark.color, .shadow: shadow])
        }
    }
    override func mouseDown(with event: NSEvent) {
        finishInlineEditing(commit: true)
        window?.makeFirstResponder(self)
        if spaceHeld {
            panStart = convert(event.locationInWindow, from: nil); panOrigin = viewport.pan; return
        }
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let p = point(event); start = p
        if model.tool == .select {
            if let i = selectedIndex, markBounds(state.marks[i]).insetBy(dx: -14, dy: -14).contains(p), hypot(markBounds(state.marks[i]).maxX + 5 - p.x, markBounds(state.marks[i]).maxY + 5 - p.y) < 24 { resizing = true }
            else { model.selected = state.marks.reversed().first { hit($0, at: p) }?.id; resizing = false }
            if let i = selectedIndex { selectionStart = state.marks[i].points; selectionCheckpointed = false; if event.clickCount == 2 { editLabel(i) } }
            needsDisplay = true; return
        }
        model.selected = nil
        if model.tool == .extract { model.recognizedText = regions.filter { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }.map(\.text).joined(separator: " "); model.showText = true; return }
        if model.tool == .pin {
            checkpoint(); var mark = Mark(tool: .pin, points: [p, p], color: NSColor(model.color), width: CGFloat(model.width)); mark.number = (state.marks.filter { $0.tool == .pin }.map(\.number).max() ?? 0) + 1; state.marks.append(mark); changed(); return
        }
        let scale = CGFloat(state.image.width) / max(1, imageRect.width)
        let mark = Mark(tool: model.tool, points: [p, p], color: NSColor(model.color), width: CGFloat(model.width) * min(3, max(1, scale)))
        if model.tool == .text { beginInlineEditing(mark); start = nil; return }
        pending = mark; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let panStart {
            let point = convert(event.locationInWindow, from: nil)
            viewport.pan = CGPoint(x: panOrigin.x + point.x - panStart.x, y: panOrigin.y + point.y - panStart.y)
            constrainPan(); updateZoomDisplay(); return
        }
        guard let start else { return }
        let end = endpoint(event)
        if model.tool == .select, let i = selectedIndex, let points = selectionStart {
            if !selectionCheckpointed { checkpoint(); selectionCheckpointed = true }
            if resizing, points.count == 2, state.marks[i].tool != .text && state.marks[i].tool != .pin {
                state.marks[i].points[1] = EditGeometry.endpoint(from: points[0], to: point(event), square: event.modifierFlags.contains(.shift), bounds: CGSize(width: state.image.width, height: state.image.height))
            } else {
                let dx = end.x - start.x, dy = end.y - start.y
                let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0, minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
                let x = min(CGFloat(state.image.width) - maxX, max(-minX, dx)), y = min(CGFloat(state.image.height) - maxY, max(-minY, dy))
                state.marks[i].points = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
            }
            changed(); return
        }
        if model.tool == .extract {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            model.recognizedText = regions.filter { rect.intersects($0.rect) }.map(\.text).joined(separator: " "); return
        }
        guard pending != nil else { return }
        if pending!.tool == .pen { pending!.points.append(end) } else { pending!.points[1] = end }; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if panStart != nil { panStart = nil; return }
        defer { pending = nil; start = nil; selectionStart = nil; resizing = false; needsDisplay = true }
        guard var mark = pending, let start else { return }
        let end = endpoint(event)
        guard hypot(end.x - start.x, end.y - start.y) > 3 else { return }
        if mark.tool != .pen { mark.points[1] = end }
        if mark.tool == .crop {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).integral
            if rect.width > 1 && rect.height > 1 { checkpoint(); state.crop = rect; changed() }
        } else { checkpoint(); state.marks.append(mark); changed() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = true; window?.invalidateCursorRects(for: self); return }
        if event.modifierFlags.intersection([.command,.control,.option]).isEmpty,
           let tool = ["v":MarkTool.select,"a":.arrow,"r":.rectangle,"o":.ellipse,"p":.pen,"t":.text,"n":.pin,"h":.highlight,"b":.redact,"c":.crop,"x":.extract][event.charactersIgnoringModifiers ?? ""] {
            model.tool = tool; model.status = tool.name; if tool == .extract { scanText() }; window?.invalidateCursorRects(for: self); needsDisplay = true; return
        }
        if [51, 117].contains(event.keyCode), let i = selectedIndex { checkpoint(); state.marks.remove(at: i); model.selected = nil; changed(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", model.tool == .extract { model.pasteboard.clearContents(); model.pasteboard.setString(model.recognizedText, forType: .string); model.status = "Text copied"; return }
        if event.keyCode == 53 { pending = nil; start = nil; needsDisplay = true } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; panStart = nil; window?.invalidateCursorRects(for: self) } else { super.keyUp(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "0": fitImage()
        case "1": actualPixels()
        case "2": actualPixels(multiplier: 2)
        case "+", "=": zoom(by: 1.25)
        case "-": zoom(by: 1 / 1.25)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    func endpoint(_ event: NSEvent) -> CGPoint {
        guard let start else { return point(event) }
        let constrained = event.modifierFlags.contains(.shift) && [.rectangle, .ellipse, .highlight, .redact, .crop].contains(model.tool)
        return EditGeometry.endpoint(from: start, to: point(event), square: constrained, bounds: CGSize(width: state.image.width, height: state.image.height))
    }
    func markBounds(_ mark: Mark) -> CGRect {
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        var rect = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        if mark.tool == .text { rect.size = (mark.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: max(18, mark.width * 5), weight: .semibold)]) }
        if mark.tool == .pin { let r = max(18, mark.width * 3); rect = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2 * r + CGFloat(mark.text.count) * mark.width * 2.5, height: 2 * r) }
        return rect
    }
    func hit(_ mark: Mark, at point: CGPoint) -> Bool {
        guard markBounds(mark).insetBy(dx: -10, dy: -10).contains(point) else { return false }
        if mark.tool == .arrow || mark.tool == .pen {
            return zip(mark.points, mark.points.dropFirst()).contains { a, b in
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
                return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) < max(10, mark.width)
            }
        }
        return true
    }
    func editLabel(_ i: Int) {
        guard [.text, .pin].contains(state.marks[i].tool) else { return }
        beginInlineEditing(state.marks[i])
    }
    func beginInlineEditing(_ mark: Mark) {
        finishInlineEditing(commit: true)
        guard let point = mark.points.first else { return }
        inlineMark = mark
        let scale = imageRect.width / imageSize.width
        let offset: CGFloat = mark.tool == .pin ? max(18,mark.width * 3) + 8 : 0
        let origin = CGPoint(x: imageRect.minX + (point.x + offset) * scale, y: imageRect.minY + point.y * scale)
        let field = NSTextField(string: mark.text)
        field.font = .systemFont(ofSize: max(13,min(36,mark.width * (mark.tool == .pin ? 4 : 5) * scale)), weight: .semibold)
        field.isEditable = true; field.isSelectable = true; field.usesSingleLineMode = false; field.lineBreakMode = .byWordWrapping
        field.placeholderString = mark.tool == .pin ? "Pin caption" : "Type text · Return to finish"
        field.frame = CGRect(x: max(4,min(bounds.width - 244,origin.x)), y: max(4,min(bounds.height - 64,origin.y)), width: min(360,max(240,bounds.width - origin.x - 8)), height: 60)
        field.delegate = self; inlineField = field; addSubview(field)
        window?.makeFirstResponder(field); field.selectText(nil); needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { finishInlineEditing(commit: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishInlineEditing(commit: false); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) { textView.insertNewlineIgnoringFieldEditor(nil) }
            else { finishInlineEditing(commit: true) }; return true
        }
        return false
    }
    func finishInlineEditing(commit: Bool) {
        guard !finishingInline, let field = inlineField, var mark = inlineMark else { return }
        finishingInline = true
        let text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        inlineField = nil; inlineMark = nil; field.delegate = nil; window?.makeFirstResponder(self); field.removeFromSuperview()
        defer { finishingInline = false; needsDisplay = true }
        guard commit else { return }
        mark.text = text
        if let index = state.marks.firstIndex(where: { $0.id == mark.id }) {
            guard state.marks[index].text != text else { return }; checkpoint()
            if text.isEmpty && mark.tool == .text { state.marks.remove(at: index) } else { state.marks[index] = mark }
            changed()
        } else if !text.isEmpty { checkpoint(); state.marks.append(mark); changed() }
    }
    func restyleSelection() {
        guard let i = selectedIndex else { return }; checkpoint(); state.marks[i].color = NSColor(model.color); state.marks[i].width = CGFloat(model.width); changed()
    }
    func scanText() {
        model.showText = true; model.scanning = true
        guard let rendered = try? render() else { model.scanning = false; return }
        // Recognition uses rendered pixels, so blacked-out text cannot leak through OCR.
        let generation = contentGeneration
        let offset = state.crop?.origin ?? .zero
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Imaging.recognizeRegions(rendered) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.model.scanning = false; guard generation == self.contentGeneration else { return }
                switch result {
                case .success(let found): self.regions = found.map { var r = $0; r.rect = r.rect.offsetBy(dx: offset.x, dy: offset.y); return r }; self.model.recognizedText = found.map(\.text).joined(separator: " "); self.needsDisplay = true
                case .failure(let error): self.model.status = error.localizedDescription
                }
            }
        }
    }
    func suggestRedactions() {
        guard !model.scanning, let rendered = try? render() else { return }; model.scanning = true
        let generation = contentGeneration
        let offset = state.crop?.origin ?? .zero
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Imaging.recognizeRegions(rendered, words: false).filter { SensitiveText.contains($0.text) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.model.scanning = false; guard generation == self.contentGeneration else { return }
                switch result { case .success(let regions): self.model.suggestions = regions.map { var r = $0; r.rect = r.rect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -4, dy: -3); return r }; self.model.status = regions.isEmpty ? "No common sensitive patterns found" : "Review suggestions before applying"
                case .failure(let error): self.model.status = error.localizedDescription }
                self.needsDisplay = true
            }
        }
    }
    func applyRedactions(_ regions: [TextRegion]) {
        guard !regions.isEmpty else { return }; checkpoint()
        for region in regions { state.marks.append(Mark(tool: .redact, points: [region.rect.origin, CGPoint(x: region.rect.maxX, y: region.rect.maxY)], color: .black, width: 1)) }
        let ids = Set(regions.map(\.id)); let remaining = model.suggestions.filter { !ids.contains($0.id) }; self.regions = []; model.recognizedText = ""; changed(); model.suggestions = remaining
    }
    func checkpoint() { past.append(state); if past.count > 80 { past.removeFirst() }; future.removeAll() }
    func changed() { contentGeneration += 1; regions = []; model.recognizedText = ""; model.suggestions = []; model.dirty = true; model.canUndo = !past.isEmpty; model.canRedo = !future.isEmpty; needsDisplay = true }
    @objc func undo(_ sender: Any?) { guard let state = past.popLast() else { return }; future.append(self.state); self.state = state; changed() }
    @objc func redo(_ sender: Any?) { guard let state = future.popLast() else { return }; past.append(self.state); self.state = state; changed() }
    func replace(_ image: CGImage) { finishInlineEditing(commit: true); checkpoint(); viewport = EditorViewport(); state = CanvasState(image: image, marks: []); changed() }
    func render() throws -> CGImage {
        let width = state.image.width, height = state.image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Imaging.ImageError.invalid }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawImageAndMarks(); NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw Imaging.ImageError.invalid }; return state.crop.flatMap { image.cropping(to: $0.integral) } ?? image
    }
}
