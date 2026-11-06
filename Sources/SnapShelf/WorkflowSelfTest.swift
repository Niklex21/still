import AppKit
import SnapShelfCore
import PDFKit

enum WorkflowSelfTest {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw SelfTest.Failure(description: message) }; checks += 1; print("PASS \(message)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Still-Workflow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureStore(root: root, startVisualIndexing: false)
        let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        context.translateBy(x: 0, y: 500); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ("Contact alex@example.com" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        ("The next step is ready" as NSString).draw(at: CGPoint(x: 40, y: 350), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!, item = try store.add(image, title: "Editable test", metadata: CaptureMetadata(application: "Test", kind: "Window"))
        let editor = try EditorController(item: item, store: store), canvas = editor.model.canvas!
        canvas.state.marks = [Mark(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 600, y: 440)], color: .red, width: 4), Mark(tool: .pin, points: [CGPoint(x: 700, y: 200)], color: .blue, width: 5, text: "Feedback", number: 1)]
        canvas.state.crop = CGRect(x: 10, y: 10, width: 760, height: 460); canvas.changed(); editor.save()
        try expect(!editor.model.dirty, "Editor saves editable objects")
        let reopenedStore = try CaptureStore(root: root, startVisualIndexing: false), saved = reopenedStore.captures[0]
        let reopened = try EditorController(item: saved, store: reopenedStore)
        try expect(saved.editDocument?.annotations.count == 2, "Annotations survive library round trip")
        try expect(reopened.model.canvas.state.image.width == 800, "Editor reopens unflattened base")
        try expect(reopened.model.canvas.state.marks.map(\.id) == canvas.state.marks.map(\.id), "Annotation identities survive reopen")
        let cropped = try reopened.model.canvas.render()
        try expect(cropped.width == 760 && cropped.height == 460, "Reversible crop exports exact dimensions")
        reopened.model.canvas.checkpoint(); reopened.model.canvas.state.marks.removeFirst(); reopened.model.canvas.changed(); reopened.model.canvas.undo(nil)
        try expect(reopened.model.canvas.state.marks.count == 2, "Reopened markup supports undo")
        reopened.model.canvas.state.crop = nil
        try expect(try reopened.model.canvas.render().width == 800, "Removing crop recovers original extent")
        let beforeImage = try Data(contentsOf: store.disk.url(saved)), beforeDocument = store.captures[0].editDocument
        let backup = root.appendingPathComponent("index-backup.json")
        try FileManager.default.moveItem(at: store.disk.indexURL, to: backup)
        try FileManager.default.createDirectory(at: store.disk.indexURL, withIntermediateDirectories: false)
        let failedBase = "\(item.id)-edit-base-\(UUID()).png"
        var saveFailed = false
        do { try store.saveEdit(item.id, image: image, document: EditDocument(baseFilename: failedBase, annotations: []), base: image) } catch { saveFailed = true }
        try expect(saveFailed, "Failed index write reports a failed edit save")
        try expect(try Data(contentsOf: store.disk.url(saved)) == beforeImage && store.captures[0].editDocument == beforeDocument, "Failed edit save restores rendered pixels and prior editable document")
        try expect(!FileManager.default.fileExists(atPath: store.disk.images.appendingPathComponent(failedBase).path), "Failed save cleans only its new immutable base")
        try FileManager.default.removeItem(at: store.disk.indexURL); try FileManager.default.moveItem(at: backup, to: store.disk.indexURL)
        let words = try Imaging.recognizeRegions(image), lines = try Imaging.recognizeRegions(image, words: false)
        try expect(words.contains { $0.text.contains("alex@example.com") }, "Real OCR recognizes selectable email")
        let email = words.first { $0.text.contains("alex@example.com") }!
        try expect(email.rect.minY < 130 && email.rect.maxY > 60, "OCR boxes use top-left coordinates")
        try expect(words.contains { $0.text.lowercased() == "ready" && $0.rect.minY > 300 }, "OCR retains lower-line word positions")
        let sensitive = lines.filter { SensitiveText.contains($0.text) }
        try expect(sensitive.count == 1, "Suggestions target sensitive line only")
        let model = EditorModel(), redaction = AnnotationCanvas(image: image, model: model); model.canvas = redaction
        redaction.applyRedactions(sensitive.map { var region = $0; region.rect = region.rect.insetBy(dx: -4, dy: -3); return region })
        let redacted = try redaction.render(), text = try Imaging.recognize(redacted)
        try expect(!text.contains("example.com") && text.lowercased().contains("ready"), "Applied redaction removes sensitive OCR only")
        let pixel = NSBitmapImageRep(cgImage: redacted).colorAt(x: Int(email.rect.midX), y: Int(email.rect.midY))!.usingColorSpace(.sRGB)!
        try expect(pixel.redComponent < 0.01 && pixel.alphaComponent > 0.99, "Redaction exports opaque black pixels")
        for format in ExportFormat.allCases {
            var options = ExportOptions(); options.format = format; options.scale = 0.5
            let data = try options.encode(redacted), source = CGImageSourceCreateWithData(data as CFData, nil)!, decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            try expect(decoded.width == 400 && decoded.height == 250, "\(format.rawValue) export decodes at requested resolution")
            try expect(CGImageSourceGetType(source) as String? == format.type.identifier, "\(format.rawValue) encoded format is correct")
            try expect(!(try Imaging.recognize(decoded)).contains("example.com"), "\(format.rawValue) does not leak redacted OCR")
        }
        let second = try store.add(image, title: "Second step")
        let project = Walkthrough(steps: [WalkthroughStep(id: item.id, title: "First step", caption: "Start here"), WalkthroughStep(id: second.id, title: "Second step", caption: "Then finish")])
        let batch = WalkthroughModel(items: [], store: store, project: project), composite = try batch.composite()
        try expect(composite.width == 1064 && composite.height > 1000, "Walkthrough combines images with captions")
        batch.mode = "horizontal"; let combined = try batch.composite()
        try expect(combined.width == 2096 && combined.height < combined.width, "Side-by-side combine is horizontal")
        let document = PDFDocument(data: try batch.pdf())
        try expect(document?.pageCount == 2, "PDF exports one step per page")
        try expect(document?.string?.contains("First step") == true && document?.string?.contains("Then finish") == true, "PDF includes readable titles and captions")
        batch.saveProject()
        let url = root.appendingPathComponent("Walkthroughs/\(project.id).json")
        try expect(try JSONDecoder().decode(Walkthrough.self, from: Data(contentsOf: url)) == project, "Walkthrough ordering and captions persist")
        let engine = SemanticSearch(); try expect(engine.available, "Apple sentence embedding model is available")
        var meaning = Capture(title: "Picture", width: 100, height: 100)
        meaning.visualIndex = VisualIndex(summary: "An automobile driving along a highway.", keywords: ["vehicle"], revision: 0)
        try expect(!meaning.matches("car on a road") && engine.rank([meaning], query: "car on a road").first?.id == meaning.id, "Local semantic search finds synonym-only match")
        return checks
    }
}
