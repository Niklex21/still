import AppKit
import SwiftUI
import SnapShelfCore
import ScreenCaptureKit

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
    var completed = false
    var selectedImage: CGImage?
    var selectedProcessID: Int32?
    var selectedWindowID: CGWindowID?
    let minimumSize: CGFloat
    init(instructions: String = "Select scrolling content · Drag a region · Esc to cancel", minimumSize: CGFloat = 2, completion: @escaping (CGRect?) -> Void) { self.instructions = instructions; self.minimumSize = minimumSize; self.completion = completion }
    func start() {
        Task { @MainActor in
            let screens = NSScreen.screens
            var backgrounds: [CGDirectDisplayID: CGImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                for display in content.displays {
                    let scale = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.backingScaleFactor ?? 1
                    let config = SCStreamConfiguration(); config.width = Int(CGFloat(display.width) * scale); config.height = Int(CGFloat(display.height) * scale); config.showsCursor = false
                    let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { backgrounds[display.displayID] = image }
                }
            }
            self.present(screens: screens, backgrounds: backgrounds)
        }
    }
    func present(screens: [NSScreen], backgrounds: [CGDirectDisplayID: CGImage]) {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info -> ScrollCaptureLayout.WindowTarget? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return .init(processID: pid,frame: frame,layer: layer,windowID: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
        for screen in screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.onCancel = { [weak self] in self?.finish(nil) }
            panel.isReleasedWhenClosed = false; panel.level = .screenSaver; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
            panel.contentView = view; panels.append(panel); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
        }
        NSCursor.crosshair.push(); NSApp.activate(ignoringOtherApps: true)
    }
    func finish(_ rect: CGRect?) {
        guard !completed else { return }; completed = true
        for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }; panels.removeAll(); NSCursor.pop()
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        backgroundImage?.draw(in: bounds)
        let shade = NSBezierPath(rect: bounds); shade.windingRule = .evenOdd
        if let start, let end {
            shade.appendRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
        }
        NSColor.black.withAlphaComponent(0.25).setFill(); shade.fill()
        let title = instructions
        (title as NSString).draw(at: NSPoint(x: bounds.midX - 260, y: bounds.maxY - 90), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
        if let start, let end {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            NSColor.systemMint.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }; let end = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).integral
        if rect.width >= minimumSize && rect.height >= minimumSize { selection?(rect) } else { NSSound.beep(); self.start = nil; self.end = nil; needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { selection?(nil) } else { super.keyDown(with: event) } }
}
