import AppKit
import SnapShelfCore
import Carbon

enum SelfTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        // A named pasteboard never replaces the user's clipboard during QA.
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: message) }; checks += 1; print("PASS \(message)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Still-SelfTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureStore(root: root, pasteboard: clipboard)
        let width = 600, height = 400
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 300, width: width, height: 100))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: 80))
        let source = context.makeImage()!
        let item = try store.add(source, title: "Test original")
        try expect(store.shelf.count == 1, "Imported image enters shelf")
        try expect(store.pendingCount == 1, "New capture awaits attention")
        try expect(FileManager.default.fileExists(atPath: store.disk.url(item, original: true).path), "Original is stored separately")
        let model = EditorModel(), canvas = AnnotationCanvas(image: source, model: model); model.canvas = canvas
        let rendered = try canvas.render()
        func color(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor { NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
        let top = color(rendered, 20, 20), bottom = color(rendered, 20, 380)
        try expect(top.redComponent > 0.9 && top.blueComponent < 0.1, "Rendering preserves top orientation")
        try expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1, "Rendering preserves bottom orientation")
        canvas.checkpoint()
        canvas.state.marks.append(Mark(tool: .redact, points: [CGPoint(x: 100, y: 120), CGPoint(x: 250, y: 220)], color: .red, width: 5))
        canvas.changed()
        let edited = try canvas.render(), redacted = color(edited, 150, 150)
        try expect(redacted.redComponent < 0.01 && redacted.greenComponent < 0.01 && redacted.blueComponent < 0.01, "Redaction writes opaque black pixels")
        try expect(color(edited, 300, 150).redComponent > 0.95, "Redaction leaves surrounding image intact")
        canvas.undo(nil)
        try expect(canvas.state.marks.isEmpty && model.canRedo, "Undo removes annotation and enables redo")
        canvas.redo(nil)
        try expect(canvas.state.marks.count == 1, "Redo restores annotation")
        try store.saveEdit(item.id, image: edited)
        let reloaded = try CaptureStore(root: root, pasteboard: clipboard)
        try expect(reloaded.captures.count == 1 && reloaded.captures[0].revision == 1, "Edits survive library reload")
        let original = try Imaging.load(store.disk.url(item, original: true))
        try expect(color(original, 150, 150).redComponent > 0.95, "Saved edit preserves original for revert")
        store.copy(store.captures[0])
        try expect(NSImage(pasteboard: clipboard) != nil, "Copy places an actual image on clipboard")
        try expect(store.copiedID == item.id, "Successful copy publishes visible confirmation")
        try expect(store.pendingCount == 0 && store.shelf.isEmpty && store.captures.count == 1, "Copy consumes the queue entry while preserving history")
        let afterCopy = try CaptureStore(root: root, pasteboard: clipboard)
        try expect(afterCopy.pendingCount == 0, "Handled state survives app restart")
        let viewed = try store.add(source, title: "Viewed screenshot")
        store.markReviewed(viewed.id)
        try expect(store.pendingCount == 0, "Viewing clears attention")
        let dismissed = try store.add(source, title: "Dismissed screenshot")
        store.update(dismissed.id) { $0.onShelf = false }
        try expect(store.pendingCount == 0 && store.captures.first(where: { $0.id == dismissed.id })?.reviewedAt != nil, "Dismissing records an action")
        let missing = try store.add(source, title: "Missing file")
        try FileManager.default.removeItem(at: store.disk.url(missing))
        try expect(!store.copy(missing), "Missing image cannot report a successful copy")
        try expect(store.pendingCount == 1 && store.copiedID != missing.id, "Failed copy keeps screenshot awaiting attention")
        let cropped = edited.cropping(to: CGRect(x: 50, y: 50, width: 200, height: 180))!
        canvas.replace(cropped)
        try expect(canvas.state.image.width == 200 && canvas.state.image.height == 180, "Crop uses source pixel dimensions")
        canvas.undo(nil)
        try expect(canvas.state.image.width == 600, "Undo restores full image after crop")
        let suite = "Still-Shortcut-Test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("off", forKey: "hotkeyPreset")
        let shortcuts = GlobalShortcutManager(defaults: preferences)
        shortcuts.start()
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        var occupied: EventHotKeyRef?
        var candidate: SnapShelfCore.KeyboardShortcut?
        for key in [UInt32(79), 80, 90, 113] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x54455354, id: 99), GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                occupied = ref; candidate = SnapShelfCore.KeyboardShortcut(keyCode: key, modifiers: modifiers); break
            }
        }
        guard let candidate, let occupied else { throw Failure(description: "Could not reserve an isolated test shortcut") }
        try expect(!shortcuts.assign(candidate, to: .region), "An occupied system hotkey is rejected")
        try expect(shortcuts.bindings[.region] == nil, "Failed hotkey registration preserves previous assignment")
        UnregisterEventHotKey(occupied)
        shortcuts.beginRecording(.region)
        try expect(shortcuts.assign(candidate, to: .region), "A custom shortcut registers after its conflict is released")
        try expect(GlobalShortcutManager(defaults: preferences).bindings[.region] == candidate, "Custom shortcut survives manager reload")
        shortcuts.beginRecording(.window)
        try expect(!shortcuts.assign(candidate, to: .window), "Duplicate app shortcuts are rejected")
        shortcuts.cancelRecording()
        try expect(shortcuts.recording == nil && shortcuts.bindings[.region] == candidate, "Cancelling recording restores existing shortcuts")
        try expect(shortcuts.assign(nil, to: .region), "A single shortcut can be disabled")
        try expect(GlobalShortcutManager(defaults: preferences).bindings[.region] == nil, "Disabled shortcut survives manager reload")
        let waitingBefore = store.pendingCount
        let first = try store.add(source, title: "Scroll past this screenshot")
        let second = try store.add(source, title: "Stop on this screenshot")
        let interaction = ShelfInteraction(reviewDelay: 0.04, settlingDelay: 0.03, expansionDelay: 0.01, collapseDelay: 0.04)
        var seen: Set<UUID> = []
        interaction.onViewed = { ids in seen.formUnion(ids); store.markReviewed(ids) }
        func advance(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func eventually(_ message: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { advance(0.01) }
            try expect(condition(), message)
        }
        interaction.pointerInside(true)
        interaction.pointer(over: first.id, inside: true)
        advance(0.02)
        try expect(!interaction.expanded && interaction.hoveredID == first.id, "Recent preview hover enables actions without expanding the shelf")
        interaction.stackHovered(true)
        advance(0.02)
        try eventually("Hovering the older stack expands the shelf") { interaction.expanded }
        interaction.visibleItems([first.id])
        interaction.pointer(over: first.id, inside: true)
        interaction.scrolled()
        try expect(interaction.scrolling && interaction.hoveredID == nil, "Scrolling suppresses thumbnail hover actions")
        interaction.visibleItems([second.id])
        advance(0.015)
        try expect(seen.isEmpty, "Passing thumbnails are not marked viewed during scrolling")
        advance(0.1)
        try eventually("Only the screenshot left visible after scrolling is marked viewed") { seen == [second.id] }
        try expect(store.pendingCount == waitingBefore + 1, "Stable thumbnail viewing decreases the unread counter")
        interaction.pointerInside(false)
        advance(0.06)
        try eventually("Leaving the shelf collapses it after the grace period") { !interaction.expanded }
        interaction.visibleItems([first.id])
        advance(0.06)
        try expect(!seen.contains(first.id), "A minimized stack does not mark waiting screenshots as viewed")
        interaction.pointerInside(true)
        interaction.scrolled()
        advance(0.015)
        try expect(!interaction.expanded, "Scrolling over a minimized stack does not trigger expansion")
        interaction.pointerInside(false)
        let thirdID = UUID()
        let frames = [first.id: CGRect(x: 8, y: 8, width: 150, height: 108), second.id: CGRect(x: 166, y: 8, width: 150, height: 108), thirdID: CGRect(x: 324, y: 8, width: 150, height: 108)]
        try expect(ShelfInteraction.visibleItems(frames: frames, size: CGSize(width: 200, height: 124)) == [first.id], "Partially hidden thumbnails remain unread")
        try expect(ShelfInteraction.visibleItems(frames: frames, size: CGSize(width: 560, height: 124)) == [first.id, second.id, thirdID], "Expanded viewport includes newly revealed thumbnails")
        interaction.present(expanded: false)
        try expect(interaction.shouldHideWhenMinimized(pendingCount: 0), "Minimized shelf hides once every capture is viewed")
        try expect(!interaction.shouldHideWhenMinimized(pendingCount: 1), "A new unread capture makes the minimized shelf available again")
        interaction.present(expanded: true)
        try expect(!interaction.shouldHideWhenMinimized(pendingCount: 0), "An explicitly reopened shelf stays available for reviewing history")
        interaction.setExpanded(false)
        try expect(interaction.shouldHideWhenMinimized(pendingCount: 0), "Leaving a fully reviewed expanded shelf hides its minimized view")
        interaction.present(expanded: true, manuallyOpened: true)
        interaction.pointerInside(true)
        interaction.pointerInside(false)
        advance(0.06)
        try expect(interaction.expanded && interaction.manuallyOpened, "A shortcut-opened shelf remains expanded after the pointer leaves")
        try expect(!interaction.shouldHideWhenMinimized(pendingCount: 0), "Viewing every screenshot does not dismiss a manually opened shelf")
        interaction.scrolled()
        advance(0.1)
        try expect(interaction.expanded, "Scrolling outside a manually opened shelf does not collapse it")
        interaction.dismiss()
        try expect(!interaction.expanded && !interaction.manuallyOpened, "Explicit dismissal clears the manual-open state")
        interaction.present(expanded: false)
        interaction.pointerInside(true)
        advance(0.02)
        interaction.pointerInside(false)
        advance(0.06)
        try expect(!interaction.expanded, "A subsequent automatic capture preview still collapses normally")
        var hoverEvents: [UUID?] = []
        interaction.onHoverChanged = { hoverEvents.append($0) }
        interaction.pointer(over: first.id, inside: true)
        try expect(hoverEvents.last! == first.id, "Hover target is available for screenshot shortcuts")
        interaction.beginDragging()
        try expect(interaction.dragging && interaction.hoveredID == nil, "Dragging suspends hover shortcuts and review timers")
        interaction.stackHovered(true)
        advance(0.02)
        try expect(!interaction.expanded, "Dragging a recent preview cannot expand the older stack")
        try expect(!interaction.shouldHideWhenMinimized(pendingCount: 0), "The last screenshot stays on screen during an active drag")
        let dragged = try store.add(source, title: "Drag this directly")
        let dragView = ScreenshotDragView.ImageDragView()
        dragView.onEnd = { success in
            store.finishShelfDrag(dragged.id, succeeded: success)
            interaction.endDragging()
        }
        dragView.completeDrag(success: false)
        try expect(store.captures.first(where: { $0.id == dragged.id })!.needsAttention, "Cancelled drag leaves screenshot unread")
        interaction.beginDragging()
        dragView.completeDrag(success: true)
        try expect(!store.captures.first(where: { $0.id == dragged.id })!.onShelf && !interaction.dragging, "Successful drop removes screenshot from previews and shelf after drag completion")
        var pinChanges = 0
        store.onPinsChanged = { pinChanges += 1 }
        let pin = try store.add(source, title: "Pinned test image")
        store.togglePin(pin.id)
        let pinned = store.captures.first(where: { $0.id == pin.id })!
        try expect(pinned.isPinned && !pinned.needsAttention, "Pinning marks viewed and preserves an independent floating image")
        let pinReload = try CaptureStore(root: root, pasteboard: clipboard)
        try expect(pinReload.captures.first(where: { $0.id == pin.id })!.isPinned, "Pin survives a library reload")
        let pinWindow = PinnedCaptureController(item: pinned, store: store, offset: 0, onHover: { _ in })
        try expect(pinWindow.window?.level == .floating && (pinWindow.window?.frame.maxX ?? 0) <= (NSScreen.main?.visibleFrame.maxX ?? 0), "Pinned window floats within its display")
        try expect(pinWindow.window?.styleMask.contains(.resizable) == true, "Pinned window can be resized")
        pinWindow.window?.performClose(nil)
        try expect(store.captures.first(where: { $0.id == pin.id })?.isPinned == false && pinChanges == 2, "Closing a pin unpins it without deleting the screenshot")
        store.togglePin(missing.id)
        try expect(store.captures.first(where: { $0.id == missing.id })?.isPinned == false, "Missing image cannot create an empty pin")
        try expect(shortcuts.assign(candidate, to: .copyHovered), "Hover shortcut can be customized independently")
        var otherRef: EventHotKeyRef?
        func reserveCandidate() -> OSStatus {
            RegisterEventHotKey(candidate.keyCode, candidate.modifiers, EventHotKeyID(signature: 0x54455354, id: 98), GetApplicationEventTarget(), 0, &otherRef)
        }
        try expect(reserveCandidate() == noErr, "Hover shortcuts do not capture keys when there is no hovered screenshot")
        if let otherRef { UnregisterEventHotKey(otherRef) }; otherRef = nil
        shortcuts.setHoveredTargetActive(true)
        try expect(reserveCandidate() != noErr, "Hover shortcut is registered while a screenshot is targeted")
        shortcuts.setHoveredTargetActive(false)
        try expect(reserveCandidate() == noErr, "Leaving the screenshot releases its keyboard shortcuts")
        if let otherRef { UnregisterEventHotKey(otherRef) }
        try expect(shortcuts.assign(nil, to: .copyHovered) && GlobalShortcutManager(defaults: preferences).bindings[.copyHovered] == nil, "Disabled hover shortcut stays disabled after reload")
        let edgeInteraction = ShelfInteraction(expansionDelay: 0.01, collapseDelay: 0.02)
        var expansions = 0
        edgeInteraction.onExpansion = { _ in expansions += 1 }
        edgeInteraction.pointerInside(true)
        edgeInteraction.stackHovered(true)
        let expansionDeadline = Date().addingTimeInterval(1)
        while !edgeInteraction.expanded && Date() < expansionDeadline { advance(0.01) }
        edgeInteraction.beginResize()
        // Native tracking areas send these when their layout changes, even if
        // the physical pointer is still in the panel's resulting frame.
        edgeInteraction.pointerInside(false)
        edgeInteraction.stackHovered(true)
        advance(0.04)
        try expect(edgeInteraction.expanded && expansions == 1, "Layout-generated exits cannot collapse an expanding shelf")
        edgeInteraction.finishResize(pointerInside: true)
        advance(0.05)
        try expect(edgeInteraction.expanded && expansions == 1, "A stationary pointer at the stack edge causes no resize loop")
        edgeInteraction.pointerInside(false)
        advance(0.04)
        try eventually("Physically leaving the settled panel collapses exactly once") { !edgeInteraction.expanded && expansions == 2 }
        for count in 1...20 {
            let compact = ShelfLayout.minimizedSize(recentCount: min(3, count), hasOlder: count > 3)
            let expandedSize = ShelfLayout.panelSize(expanded: true, compact: compact, current: compact, shelfCount: count, availableWidth: 1000)
            try expect(expandedSize.width >= compact.width && expandedSize.height >= compact.height, "Expansion contains all compact preview edges for \(count) screenshots")
        }
        let queueRoot = root.appendingPathComponent("Queue")
        let queue = try CaptureStore(root: queueRoot, pasteboard: clipboard)
        var queueItems: [Capture] = []
        for index in 0..<6 { queueItems.append(try queue.add(source, title: "Queue \(index)")) }
        let currentIDs = Array(queueItems.suffix(3).reversed().map(\.id))
        let olderIDs = Array(queueItems.prefix(3).reversed().map(\.id))
        try expect(queue.compactShelf.recent.map(\.id) == currentIDs && queue.compactShelf.older.map(\.id) == olderIDs, "Current batch has three previews with earlier captures in the older stack")
        let internalDrag = NSItemProvider()
        queue.beginShelfDrag(currentIDs[0])
        try expect(!importDrop([internalDrag], store: queue), "Dropping back into Still is rejected without consuming a preview")
        queue.finishShelfDrag(currentIDs[0], succeeded: false)
        try expect(queue.compactShelf.recent.map(\.id) == currentIDs && queue.activeDragID == nil, "Cancelling a drop preserves the current preview list and releases drag state")
        queue.finishShelfDrag(currentIDs[0], succeeded: true)
        try expect(queue.compactShelf.recent.map(\.id) == Array(currentIDs.dropFirst()), "Dragging out a current preview never promotes an older image")
        try expect(queue.compactShelf.older.map(\.id) == olderIDs && queue.captures.count == 6, "Dragging preserves older stack and complete local history")
        let queueReload = try CaptureStore(root: queueRoot, pasteboard: clipboard)
        try expect(queueReload.compactShelf.recent.map(\.id) == Array(currentIDs.dropFirst()) && queueReload.compactShelf.older.map(\.id) == olderIDs, "Current and older membership survive restart without refilling slots")
        queue.togglePin(currentIDs[1])
        queue.dismissCurrentPreviews()
        try expect(queue.compactShelf.recent.isEmpty && queue.compactShelf.older.isEmpty, "Closing dismisses the entire queue, including older stacked previews")
        try expect(queue.captures.count == 6 && queue.captures.first(where: { $0.id == currentIDs[1] })!.isPinned, "Closing previews preserves image history and independent pins")
        let afterClose = try CaptureStore(root: queueRoot, pasteboard: clipboard)
        try expect(afterClose.compactShelf.recent.isEmpty && afterClose.compactShelf.older.isEmpty, "A closed batch stays cleared after app restart")
        let fresh = try queue.add(source, title: "New batch")
        try expect(queue.compactShelf.recent.map(\.id) == [fresh.id] && queue.compactShelf.older.isEmpty, "A new screenshot cannot resurrect dismissed screenshots from History")
        let noSlots = ShelfLayout.minimizedSize(recentCount: 0, hasOlder: true)
        try expect(noSlots.width < ShelfLayout.minimizedSize(recentCount: 1, hasOlder: true).width, "An older-only stack reserves no empty preview slots")
        var legacy = queue.captures
        for i in legacy.indices { legacy[i].inPreview = nil; legacy[i].reviewedAt = i < 2 ? nil : Date() }
        try queue.disk.save(legacy)
        let migratedQueue = try CaptureStore(root: queueRoot, pasteboard: clipboard)
        try expect(migratedQueue.compactShelf.recent.map(\.id) == legacy.filter(\.needsAttention).prefix(3).map(\.id), "Old libraries migrate only unread captures into current previews")
        let display = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let size = CGSize(width: 400, height: 260)
        let defaultShelf = PanelPlacement.shelfFrame(size: size, screen: display, origin: nil)
        let defaultPin = PanelPlacement.pinFrame(size: size, screen: display, anchor: nil, depth: 0)
        let stackedPin = PanelPlacement.pinFrame(size: size, screen: display, anchor: nil, depth: 1)
        try expect(defaultShelf.minX == display.minX + 20 && defaultShelf.minY == display.minY + 20, "Shelf starts at the bottom left")
        try expect(defaultPin.maxX == display.maxX - 24 && defaultPin.minY == display.minY + 24, "Pins start at the bottom right")
        try expect(stackedPin.minX == defaultPin.minX - 16 && stackedPin.minY == defaultPin.minY + 16, "Additional pins overlap with a diagonal offset")
        PanelPlacement.save(CGPoint(x: 850, y: 180), key: "testAnchor", defaults: preferences)
        let anchor = PanelPlacement.savedPoint("testAnchor", defaults: preferences)
        try expect(anchor == CGPoint(x: 850, y: 180), "Latest floating position survives preference reload")
        let positionedPin = PanelPlacement.pinFrame(size: size, screen: display, anchor: anchor, depth: 0)
        try expect(positionedPin.maxX == 850 && positionedPin.minY == 180, "New pins use the latest shared position")
        let recovered = PanelPlacement.shelfFrame(size: size, screen: display, origin: CGPoint(x: -9000, y: 9000))
        try expect(display.contains(recovered), "Disconnected displays cannot strand a floating panel off screen")
        let capturePreferences = CapturePreferences(defaults: preferences)
        capturePreferences.controls.topLeft = .upload
        capturePreferences.controls.bottomRight = .save
        capturePreferences.controls.buttonSize = 38
        capturePreferences.window.background = .solid
        capturePreferences.window.colorHex = "123456"
        let loadedPreferences = CapturePreferences(defaults: preferences)
        try expect(loadedPreferences.controls.topLeft == .upload && loadedPreferences.controls.bottomRight == .save && loadedPreferences.controls.buttonSize == 38, "Custom corner actions and button size survive restart")
        try expect(loadedPreferences.window.background == .solid && loadedPreferences.window.colorHex == "123456", "Window background customization survives restart")
        let upload = try queue.add(source, title: "File chooser helper")
        try expect(queue.prepareUpload(upload), "Upload helper accepts an existing screenshot")
        try expect(clipboard.string(forType: .string) == queue.disk.url(upload).path && clipboard.string(forType: .fileURL) == queue.disk.url(upload).absoluteString, "Upload helper copies a chooser-ready path and file URL")
        try expect(queue.captures.first(where: { $0.id == upload.id })!.onShelf, "Preparing an upload keeps it queued until the user chooses the file")
        try expect(!queue.prepareUpload(missing), "Upload helper refuses a missing file")
        let exported = queueRoot.appendingPathComponent("exported.png")
        try queue.savePNG(upload, to: exported)
        try expect(FileManager.default.fileExists(atPath: exported.path) && !queue.captures.first(where: { $0.id == upload.id })!.onShelf, "Saving a PNG consumes the queue entry after writing its image")
        let failedExport = try queue.add(source, title: "Failed save")
        do { try queue.savePNG(failedExport, to: queueRoot.appendingPathComponent("missing/fail.png")); throw Failure(description: "Missing directory unexpectedly accepted a save") }
        catch is Failure { throw Failure(description: "Failed-save test did not fail") } catch {}
        try expect(queue.captures.first(where: { $0.id == failedExport.id })!.onShelf, "A failed save cannot consume a waiting screenshot")
        checks += try WorkflowSelfTest.run()
        checks += try ReleaseReadinessSelfTest.run()
        print("SELF-TEST PASSED: \(checks) checks")
    }
}
