import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
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
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Still.ScrollFrames", qos: .userInitiated)
    private let decoder = ScrollFrameDecoder()
    private let lock = NSLock()
    private var callbacks: (((CGImage) -> Void), ((Error) -> Void))?
    @MainActor func start(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.frame.contains(region) }) else { throw StreamError.displayUnavailable }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApplications.isEmpty else { throw StreamError.exclusionUnavailable }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = max(1, CGFloat(filter.pointPixelScale))
        configuration.sourceRect = ScrollCaptureLayout.sourceRect(region: region, display: display.frame)
        configuration.width = Int((region.width * scale).rounded()); configuration.height = Int((region.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 8); configuration.queueDepth = 3
        let next = SCStream(filter: filter, configuration: configuration, delegate: self)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        setCallbacks((frame,failure)); stream = next
        do { try await next.startCapture(); try Task.checkCancellation() }
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
        guard type == .screen, sampleBuffer.isValid, let callbacks = currentCallbacks(),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .started,
              let pixels = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            do { callbacks.0(try decoder.decode(pixels)) } catch { callbacks.1(error) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { currentCallbacks()?.1(error) }
    enum StreamError: LocalizedError {
        case displayUnavailable, exclusionUnavailable
        var errorDescription: String? {
            switch self {
            case .displayUnavailable: return "The selected display is no longer available. Select the area again."
            case .exclusionUnavailable: return "Still could not prepare a clean capture. Reopen Still and try again."
            }
        }
    }
}
