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
    var completed = false
    init(completion: @escaping (CGRect?) -> Void) { self.completion = completion }
    func start() {
        Task { @MainActor in
            let screens = NSScreen.screens
            var backgrounds: [CGDirectDisplayID: CGImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                for display in content.displays {
                    let scale = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.backingScaleFactor ?? 1
                    let config = SCStreamConfiguration(); config.width = Int(CGFloat(display.width) * scale); config.height = Int(CGFloat(display.height) * scale); config.showsCursor = false
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { backgrounds[display.displayID] = image }
                }
            }
            self.present(screens: screens, backgrounds: backgrounds)
        }
    }
    func present(screens: [NSScreen], backgrounds: [CGDirectDisplayID: CGImage]) {
        for screen in screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.onCancel = { [weak self] in self?.finish(nil) }
            panel.level = .screenSaver; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, let background = backgrounds[id.uint32Value] {
                view.backgroundImage = NSImage(cgImage: background, size: screen.frame.size)
            }
            view.selection = { [weak self] local in
                guard let self else { return }
                if let local {
                    let global = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
                    self.finish(CGRect(x: global.minX, y: mainTop - global.maxY, width: global.width, height: global.height))
                } else { self.finish(nil) }
            }
            panel.contentView = view; panels.append(panel); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
        }
        NSCursor.crosshair.push(); NSApp.activate(ignoringOtherApps: true)
    }
    func finish(_ rect: CGRect?) {
        guard !completed else { return }; completed = true
        for panel in panels { panel.orderOut(nil) }; panels.removeAll(); NSCursor.pop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.completion(rect) }
    }
}

final class SelectionView: NSView {
    var backgroundImage: NSImage?
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
        let title = "Select the scrolling content · Drag a region · Esc to cancel"
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
        if rect.width >= 120 && rect.height >= 120 { selection?(rect) } else { NSSound.beep(); self.start = nil; self.end = nil; needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { selection?(nil) } else { super.keyDown(with: event) } }
}

final class ScrollProgress: ObservableObject {
    @Published var frames = 0
    @Published var height = 0
    @Published var message = "Scroll slowly downward"
    @Published var busy = true
    var finish: (() -> Void)?
    var cancel: (() -> Void)?
}

struct ScrollProgressView: View {
    @ObservedObject var progress: ScrollProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "arrow.down.viewfinder").foregroundStyle(accent); Text("Scrolling capture").font(.system(size: 14, weight: .semibold)); Spacer(); if progress.busy { ProgressView().controlSize(.small) } }
            Text(progress.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Text("\(progress.frames) frames · \(progress.height) px tall").font(.system(size: 10, design: .monospaced)).foregroundStyle(accent); Spacer(); Button("Cancel") { progress.cancel?() }; Button("Finish") { progress.finish?() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).disabled(progress.frames == 0) }
        }.padding(18).frame(width: 420).background(.regularMaterial)
    }
}

final class ScrollCapture {
    let rect: CGRect
    let store: CaptureStore
    let done: () -> Void
    let metadata: CaptureMetadata?
    var panel: NSPanel?
    var timer: Timer?
    var process: Process?
    var stitcher: ScrollStitcher?
    var inFlight = false
    var stopped = false
    var finishPending = false
    var progress = ScrollProgress()
    let worker = DispatchQueue(label: "Still.Stitching", qos: .userInitiated)
    init(rect: CGRect, store: CaptureStore, metadata: CaptureMetadata? = nil, done: @escaping () -> Void) { self.rect = rect; self.store = store; self.metadata = metadata; self.done = done }
    func start() {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let appRect = CGRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(appRect) }) ?? NSScreen.main!
        let frame = screen.visibleFrame
        // Place the controls beyond the selected region whenever space allows.
        let y = appRect.minY - 160 > frame.minY ? appRect.minY - 156 : min(frame.maxY - 150, appRect.maxY + 10)
        let panel = ShelfPanel(contentRect: NSRect(x: min(frame.maxX - 460, max(frame.minX + 10, appRect.minX)), y: y, width: 456, height: 140), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScrollProgressView(progress: progress)); self.panel = panel
        progress.finish = { [weak self] in self?.finish() }; progress.cancel = { [weak self] in self?.cancel() }
        // If controls must overlap the region, hide them while taking each frame.
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func tick() {
        guard !inFlight, !stopped else { return }; inFlight = true
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let appRect = CGRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
        let hide = panel?.frame.intersects(appRect) ?? false
        if hide { panel?.orderOut(nil) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-scroll-\(UUID()).png")
        DispatchQueue.main.asyncAfter(deadline: .now() + (hide ? 0.12 : 0.02)) {
            guard !self.stopped else { self.inFlight = false; return }
            let task = Process(); self.process = task; task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-R\(Int(self.rect.minX)),\(Int(self.rect.minY)),\(Int(self.rect.width)),\(Int(self.rect.height))", url.path]
            task.terminationHandler = { _ in
                self.worker.async {
                    let outcome = Result { () -> (Int, Int, Bool) in
                        let image = try Imaging.load(url)
                        let added: Bool
                        if let stitcher = self.stitcher { added = try stitcher.append(image) } else { self.stitcher = ScrollStitcher(first: image); added = true }
                        return (self.stitcher!.frameCount, self.stitcher!.result.height, added)
                    }
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        self.inFlight = false; self.process = nil
                        guard !self.stopped else { return }
                        if hide { self.panel?.orderFrontRegardless() }
                        switch outcome {
                        case .success(let info): self.progress.frames = info.0; self.progress.height = info.1; self.progress.busy = false; self.progress.message = info.2 ? "Scroll slowly downward" : "Ready for more content"
                        case .failure(let error): self.progress.message = error.localizedDescription; self.progress.busy = false
                        }
                        if self.finishPending { self.finish() }
                    }
                }
            }
            do { try task.run() } catch { self.inFlight = false; self.progress.message = error.localizedDescription; self.panel?.orderFrontRegardless() }
        }
    }
    func finish() {
        timer?.invalidate(); timer = nil
        if inFlight { finishPending = true; return }
        guard let image = stitcher?.result else { cancel(); return }
        stopped = true; panel?.orderOut(nil)
        do { try store.add(image, title: "Scrolling capture \(Date().formatted(date: .abbreviated, time: .shortened))", metadata: metadata) } catch { store.error = error.localizedDescription; AppDelegate.shared.showLibrary() }
        done()
    }
    func cancel() { stopped = true; timer?.invalidate(); timer = nil; process?.terminate(); panel?.orderOut(nil); done() }
}
