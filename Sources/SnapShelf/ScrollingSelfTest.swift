import AppKit
import SwiftUI
import CoreMedia
import SnapShelfCore

private final class FixtureScrollSource: ScrollFrameSource {
    var output: ((CGImage) -> Void)?
    var oldOutput: ((CGImage) -> Void)?
    var failure: ((Error) -> Void)?
    var starts = 0, stops = 0
    @MainActor func start(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void) async throws {
        starts += 1; output = frame; oldOutput = frame; self.failure = failure
    }
    @MainActor func stop() async { stops += 1; output = nil }
}

enum ScrollingSelfTest {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool,_ message: String) throws {
            guard try value() else { throw SelfTest.Failure(description: message) }; checks += 1; print("PASS \(message)")
        }
        func wait(_ message: String,_ condition: () -> Bool) throws {
            let end = Date().addingTimeInterval(10)
            while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try expect(condition(),message)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Still-Scroll-\(UUID())"), suite = "Still.ScrollTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!, pasteboard = NSPasteboard.withUniqueName()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let prefs = CapturePreferences(defaults: defaults); prefs.visualSearchEnabled = false
        let store = try CaptureStore(root: root,preferences: prefs,startVisualIndexing: false,startOCRIndexing: false,pasteboard: pasteboard)
        let width = 320,height = 1500
        var pixels = [UInt8](repeating: 255,count: width*height*4)
        var seed: UInt64 = 17
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 6364136223846793005 &+ 1
            let i = (y*width+x)*4
            pixels[i] = UInt8((seed >> 33)%180+30); pixels[i+1] = UInt8((x*3+y*7)%230); pixels[i+2] = UInt8((y/5+x*7)%200)
        } }
        let sourceImage = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(pixels) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        func frame(_ y: Int) -> CGImage { sourceImage.cropping(to: CGRect(x: 0,y: y,width: width,height: 500))! }
        let source = FixtureScrollSource(); var completions = 0
        let capture = ScrollCapture(rect: CGRect(x: 0,y: 0,width: 160,height: 250),store: store,source: source) { completions += 1 }
        capture.start(showUI: false)
        try wait("Scrolling starts without displaying test windows") { source.starts == 1 }
        source.output?(frame(0))
        try wait("The first frame immediately creates a live preview") { capture.progress.frames == 1 && capture.progress.preview != nil }
        try expect(capture.progress.height == 500 && capture.progress.canFinish,"Live preview dimensions and Finish follow captured pixels")
        source.output?(frame(180))
        try wait("Scrolling extends the live image without polling a screenshot process") { capture.progress.height == 680 }
        source.output?(frame(410))
        try wait("More scroll content grows the same preview") { capture.progress.height == 910 }
        try expect(store.captures.isEmpty,"A live scrolling preview is not saved prematurely")
        let snapshotFolder = ProcessInfo.processInfo.environment["STILL_QA_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let snapshotFolder {
            try FileManager.default.createDirectory(at: snapshotFolder,withIntermediateDirectories: true)
            let host = NSHostingView(rootView: ScrollProgressView(progress: capture.progress).background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []; host.frame = CGRect(x: 0,y: 0,width: 252,height: 500)
            let window = NSWindow(contentRect: host.frame,styleMask: [.borderless],backing: .buffered,defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds,to: bitmap)
                try bitmap.representation(using: .png,properties: [:])!.write(to: snapshotFolder.appendingPathComponent("scrolling-live.png"))
            }
            window.contentView = nil; window.close()
        }
        // A failed save must leave the stitched image available for retry.
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: index,withIntermediateDirectories: true)
        capture.finish()
        try wait("Failed scrolling save keeps its preview available") { capture.progress.phase == .failed }
        try expect(capture.progress.canFinish && completions == 0,"A failed save can retry without losing stitched pixels")
        try FileManager.default.removeItem(at: index); store.error = nil
        capture.finish(); capture.finish()
        try wait("Finishing saves one stitched screenshot") { store.captures.count == 1 && completions == 1 }
        try expect(store.captures[0].height == 910 && store.captures[0].width == 320,"Saved scrolling capture contains all newly stitched content")
        try expect(store.captures[0].metadata?.pixelScale == nil,"Missing metadata stays optional")
        source.oldOutput?(frame(650))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(store.captures.count == 1 && completions == 1,"Late stream frames cannot create a second capture")
        let cancelledSource = FixtureScrollSource(); var cancelled = 0
        let cancelledCapture = ScrollCapture(rect: CGRect(x: 0,y: 0,width: 160,height: 250),store: store,source: cancelledSource) { cancelled += 1 }
        cancelledCapture.start(showUI: false)
        try wait("A second scrolling session starts independently") { cancelledSource.starts == 1 }
        cancelledSource.output?(frame(0))
        try wait("Second session has a preview before canceling") { cancelledCapture.progress.frames == 1 }
        cancelledCapture.cancel(); cancelledCapture.cancel(); cancelledSource.oldOutput?(frame(180))
        try wait("Cancel stops the source and completes once") { cancelled == 1 && cancelledSource.stops > 0 }
        try expect(store.captures.count == 1 && cancelledCapture.progress.phase == .cancelled,"Cancel does not leak a partial screenshot into History")
        // The prepared PNG path avoids re-encoding an already captured file.
        let png = try Imaging.png(frame(0)), thumb = try Imaging.thumbnail(frame(0))
        let ready = try store.add(frame(0),title: "Prepared",encodedPNG: png,thumbnail: thumb)
        try expect(try Data(contentsOf: store.disk.url(ready)) == png,"Prepared screenshots preserve their validated PNG bytes")
        var invalidRejected = false
        do { _ = try store.add(frame(0),encodedPNG: Data("invalid".utf8)) } catch { invalidRejected = true }
        try expect(invalidRejected && store.captures.count == 2,"Invalid prepared pixels cannot create a queue entry")
        store.consume(store.captures[1].id)
        try expect(store.copy(ready),"Copy succeeds before its empty-queue transition")
        try expect(store.shelf.isEmpty && store.feedbackImage != nil,"Copy keeps the actual thumbnail during feedback instead of an empty stack glyph")
        try wait("Copy confirmation clears its retained thumbnail promptly") { store.copiedID == nil && store.feedbackImage == nil }
        // Verify that raw screen-buffer rows do not become vertically inverted.
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,16,8,kCVPixelFormatType_32BGRA,nil,&buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer,[])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<8 { for x in 0..<16 { let i = y*stride+x*4; base[i] = y < 4 ? 0 : 255; base[i+1] = 0; base[i+2] = y < 4 ? 255 : 0; base[i+3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pixelBuffer,[])
        let decoded = try ScrollFrameDecoder().decode(pixelBuffer), bitmap = NSBitmapImageRep(cgImage: decoded)
        let top = bitmap.colorAt(x: 2,y: 0)!.usingColorSpace(.sRGB)!, bottom = bitmap.colorAt(x: 2,y: 7)!.usingColorSpace(.sRGB)!
        try expect(top.redComponent > 0.95 && bottom.blueComponent > 0.95,"Live stream decoding preserves screen orientation and colors")
        return checks
    }
}
