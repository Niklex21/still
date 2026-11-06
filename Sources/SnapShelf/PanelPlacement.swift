import AppKit

/// Stores an edge anchor, independent of screenshot size and screen resolution.
enum PanelPlacement {
    static func shelfFrame(size: CGSize, screen: CGRect, origin: CGPoint?) -> CGRect {
        clamped(CGRect(origin: origin ?? CGPoint(x: screen.minX + 20, y: screen.minY + 20), size: size), to: screen)
    }
    static func pinFrame(size: CGSize, screen: CGRect, anchor: CGPoint?, depth: Int) -> CGRect {
        let anchor = anchor ?? CGPoint(x: screen.maxX - 24, y: screen.minY + 24)
        let shift = CGFloat(min(8, max(0, depth))) * 16
        return clamped(CGRect(x: anchor.x - size.width - shift, y: anchor.y + shift, width: size.width, height: size.height), to: screen)
    }
    static func clamped(_ frame: CGRect, to screen: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return CGRect(x: max(screen.minX, min(frame.minX, screen.maxX - size.width)), y: max(screen.minY, min(frame.minY, screen.maxY - size.height)), width: size.width, height: size.height)
    }
    static func savedPoint(_ key: String, defaults: UserDefaults = .standard) -> CGPoint? {
        guard let values = defaults.array(forKey: key) as? [Double], values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
    static func save(_ point: CGPoint, key: String, defaults: UserDefaults = .standard) { defaults.set([point.x, point.y], forKey: key) }
    static func screen(containing point: CGPoint?) -> NSScreen? {
        point.flatMap { point in NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) } } ?? NSScreen.main
    }
}

final class ShelfPositionMemory: NSObject, NSWindowDelegate {
    var applyingLayout = false
    func windowDidMove(_ notification: Notification) {
        guard !applyingLayout, let window = notification.object as? NSWindow, window.isVisible else { return }
        PanelPlacement.save(window.frame.origin, key: "shelfOrigin.v2")
    }
}
