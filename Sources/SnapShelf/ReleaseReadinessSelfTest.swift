import AppKit
import SwiftUI
import ImageIO
import SnapShelfCore

enum ReleaseReadinessSelfTest {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw SelfTest.Failure(description: message) }; checks += 1; print("PASS \(message)")
        }
        func settle(_ seconds: Double = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Still-Readiness-\(UUID())")
        let suite = "Still.Readiness.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let clipboard = NSPasteboard.withUniqueName()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite); clipboard.releaseGlobally() }
        let preferences = CapturePreferences(defaults: defaults); preferences.visualSearchEnabled = false
        let store = try CaptureStore(root: root, preferences: preferences, startVisualIndexing: false, pasteboard: clipboard)
        let context = CGContext(data: nil,width: 800,height: 500,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemIndigo.cgColor); context.fill(CGRect(x: 0,y: 0,width: 800,height: 500))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 60,y: 70,width: 680,height: 360))
        let image = context.makeImage()!
        let a = try store.add(image,title: "One"), b = try store.add(image,title: "Two"), c = try store.add(image,title: "Three"), d = try store.add(image,title: "Four")
        try expect(store.compactShelf.recent.map(\.id) == [d.id,c.id,b.id] && store.compactShelf.older.map(\.id) == [a.id], "Queue keeps three current captures and a genuinely pending older stack")
        store.finishShelfDrag(d.id,succeeded: true); store.consume(c.id); store.consume(b.id); store.consume(a.id)
        let interaction = ShelfInteraction()
        try expect(interaction.shouldHideWhenEmpty(queueCount: store.pendingCount), "Automatic shelf hides after the final successful action")
        interaction.present(expanded: true,manuallyOpened: true)
        try expect(!interaction.shouldHideWhenEmpty(queueCount: store.pendingCount), "Explicit History stays open with an empty queue")
        let fresh = try store.add(image,title: "Fresh")
        try expect(store.compactShelf.recent.map(\.id) == [fresh.id] && store.compactShelf.older.isEmpty, "A fresh capture never resurrects handled history")
        store.markReviewed(fresh.id)
        let newer = try store.add(image,title: "After viewing")
        try expect(store.compactShelf.recent.map(\.id) == [newer.id], "A previously viewed preview stays in History when a new capture arrives")
        store.consume(newer.id)
        store.dismissCurrentPreviews()
        try expect(store.shelf.isEmpty && store.history.count == 6, "Closing the preview dismisses the whole queue and preserves History")
        let sharing = try store.add(image,title: "Retina",metadata: { var m = CaptureMetadata(kind: "Region"); m.pixelScale = 2; return m }())
        try expect(store.copyForSharing(sharing,preset: .screenSize), "Sharing starts a background export")
        let deadline = Date().addingTimeInterval(15)
        while store.copiedID != sharing.id && Date() < deadline { settle() }
        let shared = clipboard.data(forType: .png).flatMap { CGImageSourceCreateWithData($0 as CFData,nil) }.flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }
        try expect(shared?.width == 400 && shared?.height == 250, "Copy for Sharing places a real 1× image on an isolated clipboard")
        try expect(store.captures.first { $0.id == sharing.id }?.onShelf == false && (try Imaging.load(store.disk.url(sharing))).width == 800, "Sharing consumes only its queue entry and preserves original resolution")
        let secret = try store.add(image,title: "Secret",privateCapture: true)
        try expect(!store.history.contains { $0.id == secret.id } && !store.indexing.contains(secret.id), "Private captures stay outside History and background OCR")
        try expect(!(try String(contentsOf: store.disk.indexURL)).contains(secret.id.uuidString), "Private metadata is absent from the persisted index")
        let privateProject = WalkthroughModel(items: [secret],store: store)
        try expect(!privateProject.saveProject(), "A private capture cannot be persisted through a walkthrough")
        try expect(store.disk.url(secret).deletingLastPathComponent() == store.disk.privateImages, "Private image files are isolated from the searchable Images folder")
        store.retainPrivate(secret.id); store.consume(secret.id)
        try expect(store.captures.contains { $0.id == secret.id }, "An open private editor or export retains its source")
        store.releasePrivate(secret.id)
        try expect(!store.captures.contains { $0.id == secret.id }, "Handled private captures leave memory after their final user closes")
        store.clearPrivateCaptures()
        try expect(!FileManager.default.fileExists(atPath: store.disk.privateImages.path), "Quitting clears leased private files as well as private memory")
        let oldDate = Date().addingTimeInterval(-50*86400)
        store.consume(newer.id)
        for i in store.captures.indices { store.captures[i].createdAt = oldDate; store.captures[i].onShelf = false }
        store.update(a.id) { $0.favorite = true }; store.update(b.id) { $0.pinnedAt = Date() }; store.update(c.id) { $0.onShelf = true }
        let project = Walkthrough(steps: [WalkthroughStep(id: d.id,title: "Protected source")])
        let projects = root.appendingPathComponent("Walkthroughs"); try FileManager.default.createDirectory(at: projects,withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: projects.appendingPathComponent("\(project.id).json"))
        // Set defaults without publishing an asynchronous cleanup while testing the transaction.
        defaults.set(30,forKey: "retentionDays.v1")
        preferences.retentionDays = 30
        let retainedStore = store
        let brokenProject = projects.appendingPathComponent("broken.json")
        try Data("invalid project".utf8).write(to: brokenProject)
        let beforeCleanup = store.captures
        retainedStore.cleanupExpiredCaptures()
        try expect(store.captures == beforeCleanup && store.cleanupStatus.hasPrefix("Cleanup paused"), "Unreadable walkthrough metadata pauses retention without deleting images")
        try FileManager.default.removeItem(at: brokenProject)
        let candidates = try retainedStore.retentionCandidates()
        try expect(Set(candidates.map(\.id)) == [fresh.id,sharing.id,newer.id], "Retention protects favorites, pins, queued captures, and walkthrough sources")
        let trash = root.appendingPathComponent("TestTrash"); try FileManager.default.createDirectory(at: trash,withIntermediateDirectories: true)
        var moves = 0, failed = false
        do { try retainedStore.trashCaptures([fresh.id],trash: { url in
            moves += 1; if moves == 2 { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(url.lastPathComponent); try FileManager.default.moveItem(at: url,to: destination); return destination
        }) } catch { failed = true }
        try expect(failed && retainedStore.captures.contains { $0.id == fresh.id } && FileManager.default.fileExists(atPath: retainedStore.disk.url(fresh).path), "A partial Trash failure restores files and library membership")
        try retainedStore.trashCaptures([fresh.id],trash: { url in let target = trash.appendingPathComponent(url.lastPathComponent); try FileManager.default.moveItem(at: url,to: target); return target })
        try expect(!retainedStore.captures.contains { $0.id == fresh.id } && !(try retainedStore.disk.load()).contains { $0.id == fresh.id }, "Successful deletion persists and cannot return on restart")
        // Disable real cleanup before running the main loop again.
        retainedStore.preferences.retentionDays = 0
        let editor = try EditorController(item: a,store: store), canvas = editor.model.canvas!
        canvas.frame = CGRect(x: 0,y: 0,width: 700,height: 440)
        let revision = store.captures.first { $0.id == a.id }!.revision; editor.save()
        try expect(store.captures.first { $0.id == a.id }!.revision == revision, "Saving an unchanged editor does not rewrite pixels or re-index")
        let mark = Mark(tool: .text,points: [CGPoint(x: 100,y: 100)],color: .red,width: 4,text: "First")
        canvas.beginInlineEditing(mark); canvas.inlineField?.stringValue = "Inline feedback"; canvas.finishInlineEditing(commit: true)
        try expect(canvas.state.marks.first?.text == "Inline feedback" && editor.model.dirty, "Inline text commits as an editable annotation")
        canvas.beginInlineEditing(canvas.state.marks[0]); canvas.inlineField?.stringValue = "Canceled"; canvas.finishInlineEditing(commit: false)
        try expect(canvas.state.marks.first?.text == "Inline feedback", "Escape cancels inline changes without overwriting text")
        canvas.undo(nil); try expect(canvas.state.marks.isEmpty, "Inline text creation supports undo")
        canvas.redo(nil); editor.save()
        try expect(store.captures.first { $0.id == a.id }?.editDocument?.annotations.first?.text == "Inline feedback", "Inline annotations remain editable after saving")
        var callbacks: [Bool] = []
        let countdown = CaptureCountdown(seconds: 3,screen: nil) { callbacks.append($0) }
        countdown.finish(canceled: true); countdown.finish(canceled: false)
        try expect(callbacks == [true], "Canceling a delayed capture completes exactly once")
        // Native views render into bitmap caches without appearing on the desktop.
        let output = ProcessInfo.processInfo.environment["STILL_QA_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        func snapshot<V: View>(_ name: String,_ view: V,_ size: CGSize) throws {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))); host.sizingOptions = []; host.frame = CGRect(origin: .zero,size: size)
            let window = NSWindow(contentRect: CGRect(origin: .zero,size: size),styleMask: [.borderless],backing: .buffered,defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded(); settle(0.08); host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SelfTest.Failure(description: "Could not allocate \(name) snapshot") }
            host.cacheDisplay(in: host.bounds,to: bitmap)
            guard let png = bitmap.representation(using: .png,properties: [:]) else { throw SelfTest.Failure(description: "Could not encode \(name) snapshot") }
            try png.write(to: output.appendingPathComponent("\(name).png")); window.contentView = nil; window.close()
            try expect(bitmap.pixelsWide > 100 && !png.isEmpty,"Offscreen \(name) renders without opening a window")
        }
        try snapshot("library",LibraryView(store: store),CGSize(width: 1080,height: 720))
        try snapshot("editor",EditorView(model: editor.model, item: a, store: store, controller: editor),CGSize(width: 1000,height: 700))
        try snapshot("export",ExportView(item: a,store: store),CGSize(width: 470,height: 510))
        try snapshot("privacy",PrivacySettings(store: store, preferences: preferences),CGSize(width: 580,height: 570))
        try snapshot("controls",HoverControlsSettings(preferences: preferences),CGSize(width: 580,height: 570))
        interaction.present(expanded: true,manuallyOpened: true)
        try snapshot("history-shelf",ShelfView(store: store,interaction: interaction),CGSize(width: 760,height: 210))
        let batch = WalkthroughModel(items: [b,c],store: store); batch.mode = "compare"
        batch.refreshDifference(); let compareDeadline = Date().addingTimeInterval(20)
        while batch.comparing && Date() < compareDeadline { settle() }
        try expect(batch.difference?.changedPixels == 0,"Compare computes identical captures without false differences")
        // Capture the comparison layout independently of whether there are changes.
        try snapshot("compare",ComparisonView(model: batch),CGSize(width: 700,height: 600))
        editor.model.dirty = false; editor.window?.close()
        return checks
    }
}
