import AppKit
import SwiftUI
import SnapShelfCore

final class ScrollCapture {
    let rect: CGRect
    let store: CaptureStore
    let done: () -> Void
    private var metadata: CaptureMetadata?
    private(set) var panel: NSPanel?
    private(set) var outline: NSPanel?
    let progress = ScrollProgress()
    private let source: any ScrollFrameSource
    private let gate = ScrollFrameGate()
    private let worker = DispatchQueue(label: "Still.Stitching",qos: .userInitiated)
    private var startTask: Task<Void,Never>?
    private var firstFrameTimeout: Timer?
    // Only accessed on worker.
    private var stitcher: ScrollStitcher?
    private let frameLock = NSLock()
    private var latestFrame: CGImage?
    private var processing = false
    private var mismatches = 0
    // Only accessed on main.
    private var completed = false
    private var started = false
    init(rect: CGRect, store: CaptureStore, metadata: CaptureMetadata? = nil, source: (any ScrollFrameSource)? = nil, done: @escaping () -> Void) {
        self.rect = rect; self.store = store; self.metadata = metadata; self.source = source ?? ScreenRegionStream(); self.done = done
        progress.finish = { [weak self] in self?.finish() }; progress.cancel = { [weak self] in self?.cancel() }
    }
    func start(showUI: Bool = true) {
        guard !started else { return }; started = true; gate.set(true)
        if showUI { showWindows() }
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.source.start(region: self.rect, frame: { [weak self] image in self?.receive(image) }, failure: { [weak self] error in DispatchQueue.main.async { self?.failed(error) } })
                guard self.gate.isOpen else { await self.source.stop(); return }
                if self.progress.phase == .preparing { self.progress.phase = .recording; self.progress.message = "Scroll down to build" }
            } catch { if !Task.isCancelled { self.failed(error) } }
        }
        firstFrameTimeout = Timer.scheduledTimer(withTimeInterval: 8,repeats: false) { [weak self] _ in
            guard let self, self.progress.frames == 0, self.gate.isOpen else { return }
            self.failed(CaptureError.noFrames)
        }
    }
    private func showWindows() {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let appRect = ScrollCaptureLayout.appRect(rect,mainTop: mainTop)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: appRect.midX,y: appRect.midY)) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? appRect.insetBy(dx: -300,dy: -100)
        let outline = NSPanel(contentRect: appRect.insetBy(dx: -4,dy: -4), styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        outline.title = "Still Capture Area"; outline.isOpaque = false; outline.backgroundColor = .clear; outline.hasShadow = false
        outline.ignoresMouseEvents = true; outline.level = .floating; outline.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        outline.isReleasedWhenClosed = false; outline.contentView = ScrollRegionOutline(); outline.orderFrontRegardless(); self.outline = outline
        let panel = ShelfPanel(contentRect: ScrollCaptureLayout.previewFrame(region: appRect,screen: frame),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.title = "Still Scrolling Capture"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.onDismiss = { [weak self] in self?.cancel() }
        progress.finishShortcut = AppDelegate.shared?.shortcuts.bindings[.scrolling]?.displayName
        let host = NSHostingView(rootView: ScrollProgressView(progress: progress)); host.sizingOptions = []; panel.contentView = host
        panel.orderFrontRegardless(); self.panel = panel
    }
    func showPreview() {
        panel?.makeKeyAndOrderFront(nil)
    }
    private func receive(_ image: CGImage) {
        guard gate.isOpen else { return }
        frameLock.lock(); latestFrame = image
        if processing { frameLock.unlock(); return }
        processing = true; frameLock.unlock()
        worker.async { [weak self] in self?.drainFrames() }
    }
    private func drainFrames() {
        while gate.isOpen {
            frameLock.lock()
            guard let image = latestFrame else { processing = false; frameLock.unlock(); return }
            latestFrame = nil; frameLock.unlock()
            processFrame(image)
        }
        frameLock.lock(); latestFrame = nil; processing = false; frameLock.unlock()
    }
    private func processFrame(_ image: CGImage) {
        autoreleasepool {
            do {
                let added: Bool
                if let stitcher = self.stitcher { added = try stitcher.append(image) }
                else { self.stitcher = ScrollStitcher(first: image); added = true }
                let wasMismatched = self.mismatches > 0; self.mismatches = 0
                guard added || wasMismatched else { return }
                let result = self.stitcher!.result, frames = self.stitcher!.frameCount
                let preview = added ? self.thumbnail(result) : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.gate.isOpen else { return }
                    self.firstFrameTimeout?.invalidate(); self.firstFrameTimeout = nil
                    self.progress.frames = frames; self.progress.width = result.width; self.progress.height = result.height
                    if let preview { self.progress.preview = NSImage(cgImage: preview,size: .zero) }
                    self.metadata?.pixelScale = Double(image.width) / max(1,Double(self.rect.width))
                    self.progress.phase = .recording; self.progress.warning = false; self.progress.message = "Scroll down to build"
                }
            } catch Imaging.ImageError.noOverlap {
                self.mismatches += 1
                if self.mismatches == 3 { DispatchQueue.main.async { [weak self] in
                    guard let self, self.gate.isOpen else { return }
                    self.progress.warning = true; self.progress.message = "Scroll back a little, then slowly down"
                } }
            } catch { DispatchQueue.main.async { [weak self] in self?.failed(error) } }
            }
    }
    private func thumbnail(_ image: CGImage) -> CGImage? {
        let scale = min(1,220 / CGFloat(image.width),8192 / CGFloat(image.height))
        let w = max(1,Int(CGFloat(image.width)*scale)), h = max(1,Int(CGFloat(image.height)*scale))
        guard let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium; context.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h)); return context.makeImage()
    }
    private func failed(_ error: Error) {
        guard gate.isOpen else { return }; gate.set(false)
        startTask?.cancel(); firstFrameTimeout?.invalidate(); firstFrameTimeout = nil
        progress.phase = .failed; progress.warning = true; progress.message = error.localizedDescription
        Task { @MainActor in await source.stop() }
    }
    func finish() {
        guard progress.canFinish, !completed else { return }
        gate.set(false); firstFrameTimeout?.invalidate(); firstFrameTimeout = nil; progress.phase = .finishing; progress.message = "Finishing…"
        startTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }; await self.source.stop()
            self.worker.async { [weak self] in
                guard let self else { return }
                let prepared = Result { () -> (CGImage,Data,CGImage) in
                    guard let image = self.stitcher?.result else { throw Imaging.ImageError.invalid }
                    return (image,try Imaging.png(image),try Imaging.thumbnail(image))
                }
                DispatchQueue.main.async {
                    guard self.progress.phase == .finishing, !self.completed else { return }
                    do {
                        let (image,png,thumbnail) = try prepared.get()
                        try self.store.add(image,title: "Scrolling capture \(Date().formatted(date: .abbreviated,time: .shortened))",metadata: self.metadata,encodedPNG: png,thumbnail: thumbnail)
                        self.progress.phase = .finished; self.closeWindows(); self.completeOnce()
                    } catch {
                        self.store.error = error.localizedDescription; self.progress.phase = .failed
                        self.progress.warning = true; self.progress.message = "Couldn’t save. Try Finish again."
                    }
                }
            }
        }
    }
    func cancel() {
        guard !completed, progress.phase != .cancelled else { return }
        gate.set(false); startTask?.cancel(); firstFrameTimeout?.invalidate(); firstFrameTimeout = nil
        progress.phase = .cancelled; closeWindows()
        Task { @MainActor [weak self] in guard let self else { return }; await self.source.stop(); self.completeOnce() }
    }
    private func closeWindows() {
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil
        outline?.orderOut(nil); outline?.contentView = nil; outline?.close(); outline = nil
    }
    private func completeOnce() { guard !completed else { return }; completed = true; done() }
    enum CaptureError: LocalizedError {
        case noFrames
        var errorDescription: String? { "No screen pixels arrived. Reopen Still or check Screen Recording access." }
    }
}
