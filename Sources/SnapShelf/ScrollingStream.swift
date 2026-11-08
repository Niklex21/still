import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import OSLog
import SnapShelfCore

protocol ScrollFrameSource: AnyObject {
    @MainActor func start(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void) async throws
    @MainActor func stop() async
}

/// Shared only for dropping late frames; stitching itself stays on one queue.
final class ScrollFrameGate {
    private let lock = NSLock()
    private var enabled = false
    func set(_ enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}

final class ScrollFrameDecoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let software = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    func decode(_ buffer: CVPixelBuffer) throws -> CGImage {
        let image = CIImage(cvPixelBuffer: buffer), space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) ?? software.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { throw Imaging.ImageError.invalid }
        return result
    }
}

/// Continuous pixels, with all of Still excluded at the compositor. The border
/// and preview can remain on-screen, including when they overlap the region.
final class ScreenRegionStream: NSObject, ScrollFrameSource, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "local.alex.Still",category: "ScrollingCapture")
    private var loggedFirstSample = false
    private var stream: SCStream?
    private let windowID: CGWindowID?
    private var windowCrop: (region: CGRect, window: CGRect)?
    init(windowID: CGWindowID? = nil) { self.windowID = windowID; super.init() }
    private let queue = DispatchQueue(label: "Still.ScrollFrames", qos: .userInitiated)
    private let decoder = ScrollFrameDecoder()
    private let lock = NSLock()
    private var callbacks: (((CGImage) -> Void), ((Error) -> Void))?
    @MainActor func start(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: windowID == nil)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.frame.contains(region) }) else { throw StreamError.displayUnavailable }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApplications.isEmpty else { throw StreamError.exclusionUnavailable }
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        if let windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }), window.frame.contains(region) else { throw StreamError.windowUnavailable }
            // A window-bound stream keeps the selected page, even if a preview
            // or another application comes in front. Crop its pixels ourselves
            // so shadow framing cannot offset the selected region.
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            windowCrop = (region,window.frame)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            configuration.sourceRect = ScrollCaptureLayout.sourceRect(region: region, display: display.frame)
        }
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let size = windowCrop?.window.size ?? region.size
        configuration.width = Int((size.width * scale).rounded()); configuration.height = Int((size.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 8); configuration.queueDepth = 3
        let next = SCStream(filter: filter, configuration: configuration, delegate: self)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        setCallbacks((frame,failure)); stream = next
        do { try await next.startCapture(); logger.info("Continuous stream started"); try Task.checkCancellation() }
        catch {
            // stop() may already have detached a stream while startCapture was
            // still pending. Stop this exact instance after the start resolves.
            setCallbacks(nil)
            if stream === next { stream = nil }
            try? await next.stopCapture()
            throw error
        }
    }
    @MainActor func stop() async {
        setCallbacks(nil)
        let previous = stream; stream = nil
        if let previous { try? await previous.stopCapture() }
    }
    private func setCallbacks(_ value: (((CGImage) -> Void), ((Error) -> Void))?) { lock.lock(); callbacks = value; lock.unlock() }
    private func currentCallbacks() -> (((CGImage) -> Void), ((Error) -> Void))? { lock.lock(); defer { lock.unlock() }; return callbacks }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if !loggedFirstSample { logger.info("Received first stream sample"); loggedFirstSample = true }
        guard type == .screen, sampleBuffer.isValid, let callbacks = currentCallbacks(),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .started,
              let pixels = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            do {
                var image = try decoder.decode(pixels)
                if let crop = windowCrop {
                    let rect = ScrollCaptureLayout.windowCrop(region: crop.region,window: crop.window,pixels: CGSize(width: image.width,height: image.height))
                    guard let cropped = image.cropping(to: rect) else { throw Imaging.ImageError.invalid }
                    image = cropped
                }
                callbacks.0(image)
            } catch { callbacks.1(error) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { logger.error("Stream stopped: \(error.localizedDescription,privacy: .public)"); currentCallbacks()?.1(error) }
    enum StreamError: LocalizedError {
        case displayUnavailable, exclusionUnavailable, windowUnavailable
        var errorDescription: String? {
            switch self {
            case .displayUnavailable: return "The selected display is no longer available. Select the area again."
            case .exclusionUnavailable: return "Still could not prepare a clean capture. Reopen Still and try again."
            case .windowUnavailable: return "The selected window changed or closed. Select the area again."
            }
        }
    }
}
