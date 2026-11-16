import AppKit
import SwiftUI

/// The drag stays alive until AppKit reports a completed drop or cancellation.
/// In particular, beginning a drag never consumes the last unread screenshot.
struct ScreenshotDragView: NSViewRepresentable {
    let image: NSImage
    let url: URL
    var fill = false
    var moveWindowOnDrag = false
    var onClick: (Int) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onEnd: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> ImageDragView { ImageDragView() }
    func updateNSView(_ view: ImageDragView, context: Context) {
        view.image = image; view.url = url; view.fill = fill; view.moveWindowOnDrag = moveWindowOnDrag
        view.onClick = onClick; view.onBegin = onBegin; view.onEnd = onEnd
        view.needsDisplay = true
    }
    final class ImageDragView: NSView, NSDraggingSource {
        var image: NSImage?
        var url: URL?
        var fill = false
        var moveWindowOnDrag = false
        var onClick: (Int) -> Void = { _ in }
        var onBegin: () -> Void = {}
        var onEnd: (Bool) -> Void = { _ in }
        private var transfer: URL?
        private var down: NSEvent?
        private var isDragging = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            guard let image, image.size.width > 0, image.size.height > 0 else { return }
            let scale = fill ? max(bounds.width / image.size.width, bounds.height / image.size.height) : min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState(); bounds.clip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        override func mouseDown(with event: NSEvent) { down = event }
        override func mouseUp(with event: NSEvent) {
            if down != nil && !isDragging { onClick(event.clickCount) }
            down = nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let down, let url, let image,
                  hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 3 else { return }
            if moveWindowOnDrag && !event.modifierFlags.contains(.option) {
                self.down = nil
                window?.performDrag(with: down)
                return
            }
            do {
                transfer = try ScreenshotTransferFiles.shared.prepare(url)
            } catch {
                self.down = nil
                AppDelegate.shared?.store.error = "Could not prepare the screenshot for dragging. " + error.localizedDescription
                NSSound.beep()
                return
            }
            guard let transfer else { return }
            let item = Self.fileDragItem(for: transfer)
            item.setDraggingFrame(bounds, contents: image)
            isDragging = true; onBegin()
            beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            completeDrag(success: !operation.isEmpty)
        }
        func completeDrag(success: Bool) {
            if let transfer {
                ScreenshotTransferFiles.shared.finish(transfer, succeeded: success)
                self.transfer = nil
            }
            isDragging = false; down = nil; onEnd(success)
        }
        static func fileDragItem(for url: URL) -> NSDraggingItem {
            // Let AppKit publish the same file representation that upload fields expect.
            NSDraggingItem(pasteboardWriter: url as NSURL)
        }
    }
}


// A web uploader can finish reading after AppKit has reported a successful drop.
final class ScreenshotTransferFiles {
    static let shared = ScreenshotTransferFiles()
    private let root: URL
    private let lease: TimeInterval
    private var owned = Set<URL>()

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Still-Drag-Exports", isDirectory: true),
         lease: TimeInterval = 60) {
        self.root = root
        self.lease = lease
    }

    func prepare(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: file)
            owned.insert(directory)
            return file
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    func finish(_ file: URL, succeeded: Bool) {
        let dir = file.deletingLastPathComponent()
        if succeeded {
            DispatchQueue.main.asyncAfter(deadline: .now() + lease) { [self] in remove(dir) }
        } else { remove(dir) }
    }

    private func remove(_ dir: URL) {
        guard owned.remove(dir) != nil else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    func cleanOnQuit() { for dir in Array(owned) { remove(dir) } }

    func removeAbandoned() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        for dir in dirs where UUID(uuidString: dir.lastPathComponent) != nil && !owned.contains(dir) {
            if let date = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > lease {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
