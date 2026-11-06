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
    final class ImageDragView: NSView, NSDraggingSource, NSPasteboardItemDataProvider {
        var image: NSImage?
        var url: URL?
        var fill = false
        var moveWindowOnDrag = false
        var onClick: (Int) -> Void = { _ in }
        var onBegin: () -> Void = {}
        var onEnd: (Bool) -> Void = { _ in }
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
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
            pasteboardItem.setDataProvider(self, forTypes: [.png])
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
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
            isDragging = false; down = nil; onEnd(success)
        }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            if type == .png, let url, let data = try? Data(contentsOf: url) { item.setData(data, forType: .png) }
        }
    }
}
