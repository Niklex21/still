import AppKit
import SwiftUI
import SnapShelfCore
import ScreenCaptureKit
import OSLog

final class SelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }
}

final class RegionSelector {
    var panels: [NSPanel] = []
    let completion: (CGRect?) -> Void
    let instructions: String
    private var freezeTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "local.alex.Still", category: "RegionSelector")
    private var previousCursor: NSCursor?
    var completed = false
    var selectedImage: CGImage?
    var selectedProcessID: Int32?
    var selectedWindowID: CGWindowID?
    let minimumSize: CGFloat
    init(instructions: String = "Select scrolling content · Drag a region · Esc to cancel", minimumSize: CGFloat = 2, completion: @escaping (CGRect?) -> Void) { self.instructions = instructions; self.minimumSize = minimumSize; self.completion = completion }
    func start() {
        freezeTask = Task { @MainActor in
            let screens = NSScreen.screens
            var backgrounds: [CGDirectDisplayID: CGImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                for display in content.displays {
                    guard !Task.isCancelled else { return }
                    let scale = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.backingScaleFactor ?? 1
                    let config = SCStreamConfiguration(); config.width = Int(CGFloat(display.width) * scale); config.height = Int(CGFloat(display.height) * scale); config.showsCursor = false
                    let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { backgrounds[display.displayID] = image }
                }
            }
            self.logger.debug("Region freeze returned for \(screens.count) displays, with \(backgrounds.count) images.")
            self.present(screens: screens, backgrounds: backgrounds)
        }
    }
    func present(screens: [NSScreen], backgrounds: [CGDirectDisplayID: CGImage]) {
        guard !completed, !screens.isEmpty else { finish(nil); return }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info -> ScrollCaptureLayout.WindowTarget? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return .init(processID: pid,frame: frame,layer: layer,windowID: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
        previousCursor = NSCursor.currentSystem ?? NSCursor.current
        for screen in screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.onCancel = { [weak self] in self?.finish(nil) }
            panel.isReleasedWhenClosed = false; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.animationBehavior = .none; panel.isFloatingPanel = true; panel.level = .screenSaver; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, let background = backgrounds[id.uint32Value] {
                view.backgroundImage = NSImage(cgImage: background, size: screen.frame.size)
            }
            view.instructions = instructions; view.minimumSize = minimumSize
            view.selection = { [weak self] local in
                guard let self else { return }
                if let local {
                    if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, let frozen = backgrounds[id.uint32Value] {
                        let crop = CaptureRegion.frozenCrop(local,screen: screen.frame.size,pixels: CGSize(width: frozen.width,height: frozen.height))
                        self.selectedImage = frozen.cropping(to: crop)
                    }
                    let global = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
                    let rect = CGRect(x: global.minX, y: mainTop - global.maxY, width: global.width, height: global.height)
                    let target = ScrollCaptureLayout.targetWindow(region: rect,windows: windows,ownProcess: ProcessInfo.processInfo.processIdentifier)
                    self.selectedProcessID = target?.processID
                    if let target, target.windowID != 0, target.frame.contains(rect) { self.selectedWindowID = target.windowID }
                    self.finish(rect)
                } else { self.finish(nil) }
            }
            panel.acceptsMouseMovedEvents = true
            panel.contentView = view; panels.append(panel)
            panel.orderFrontRegardless()
            logger.info("Ordered region selector \(panel.windowNumber) at level \(panel.level.rawValue); visible: \(panel.isVisible), active Space: \(panel.isOnActiveSpace).")
            if screen.frame.contains(NSEvent.mouseLocation) { panel.makeKey() }; panel.makeFirstResponder(view)
        }
        PanelCursor.set(.crosshair)
    }
    func finish(_ rect: CGRect?) {
        guard !completed else { return }; completed = true
        logger.debug("Ending region selection, accepted: \(rect != nil).")
        freezeTask?.cancel(); freezeTask = nil
        if let previousCursor { PanelCursor.set(previousCursor); self.previousCursor = nil }
        for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }; panels.removeAll()
        completion(rect)
    }
}

final class SelectionView: NSView {
    var backgroundImage: NSImage?
    var minimumSize: CGFloat = 2
    var instructions = "Select scrolling content · Drag a region · Esc to cancel"
    var selection: ((CGRect?) -> Void)?
    var start: CGPoint?
    var end: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var cursorTracking: NSTrackingArea?
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard cursorTracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        cursorTracking = area
    }
    private func showCrosshair() {
        guard window?.isVisible == true else { return }
        PanelCursor.set(.crosshair)
    }
    override func cursorUpdate(with event: NSEvent) { showCrosshair() }
    override func mouseEntered(with event: NSEvent) { showCrosshair() }
    override func mouseMoved(with event: NSEvent) { showCrosshair() }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage?.draw(in: bounds)
        let shade = NSBezierPath(rect: bounds); shade.windingRule = .evenOdd
        if let start, let end {
            shade.appendRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
        }
        NSColor.black.withAlphaComponent(0.18).setFill(); shade.fill()
        if start == nil && !instructions.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let title = instructions as NSString
            let size = title.size(withAttributes: attributes)
            let badge = NSRect(x: bounds.midX - size.width / 2 - 8, y: bounds.maxY - 63, width: size.width + 16, height: size.height + 8)
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
            title.draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: attributes)
        }
        if let start, let end {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            let pixel = 1 / (window?.backingScaleFactor ?? 1)
            NSColor.black.withAlphaComponent(0.65).setStroke()
            let outer = NSBezierPath(rect: rect.insetBy(dx: -pixel, dy: -pixel))
            outer.lineWidth = pixel
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(rect: rect)
            inner.lineWidth = pixel
            inner.stroke()
            let scale = window?.backingScaleFactor ?? 1
            let label = "\(Int(rect.integral.width * scale)) × \(Int(rect.integral.height * scale))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let badge = CGRect(x: min(max(3,end.x + 12),bounds.maxX - size.width - 15), y: min(max(3,end.y - size.height - 14),bounds.maxY - size.height - 8), width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            label.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attributes)
        }
    }
    override func mouseDown(with event: NSEvent) { showCrosshair(); start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { showCrosshair(); end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }; let end = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).integral
        if rect.width >= minimumSize && rect.height >= minimumSize { selection?(rect) } else { NSSound.beep(); self.start = nil; self.end = nil; needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { selection?(nil) } else { super.keyDown(with: event) } }
}
