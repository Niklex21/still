import AppKit
import Vision
import CoreML

public enum Imaging {
    /// Frames a window capture on a subtle backdrop, without scaling its pixels.
    public static func frameWindow(_ image: CGImage, background: CGImage? = nil, style: FrameBackground = .gradient,
                                   color: CGColor = CGColor(red: 0.6, green: 0.7, blue: 0.85, alpha: 1),
                                   padding: Double = 0.08, shadow: Bool = true, dimming: Double = 0) throws -> CGImage {
        let margin = max(48, Int(Double(max(image.width, image.height)) * min(0.20, max(0.03, padding))))
        let width = image.width + margin * 2, height = image.height + margin * 2
        guard width <= 30_000, height <= 30_000, width * height <= 150_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageError.tooLarge }
        if style == .solid {
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else if style != .transparent {
            if let background, style == .wallpaper || style == .image {
                let scale = max(CGFloat(width) / CGFloat(background.width), CGFloat(height) / CGFloat(background.height))
                let size = CGSize(width: CGFloat(background.width) * scale, height: CGFloat(background.height) * scale)
                context.draw(background, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
            } else {
                let colors = [CGColor(red: 0.72, green: 0.76, blue: 0.88, alpha: 1), CGColor(red: 0.40, green: 0.49, blue: 0.65, alpha: 1)] as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { throw ImageError.invalid }
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
            }
            context.setFillColor(CGColor(gray: 0, alpha: min(0.5, max(0, dimming))))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if shadow { context.setShadow(offset: CGSize(width: 0, height: -CGFloat(margin) * 0.13), blur: CGFloat(margin) * 0.38, color: CGColor(gray: 0, alpha: 0.30)) }
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ImageError.invalid }
        return result
    }
    public static func dragProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        // Some destinations accept file URLs, while others request PNG content.
        provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .all) { completion in
            if FileManager.default.fileExists(atPath: url.path) {
                completion(url, false, nil)
            } else {
                completion(nil, false, CocoaError(.fileNoSuchFile))
            }
            return nil
        }
        return provider
    }
    public static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageError.invalid }
        guard width <= 30_000, height <= 30_000, Int64(width)*Int64(height) <= 150_000_000 else { throw ImageError.tooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageError.invalid }
        return image
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw ImageError.invalid }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.invalid }
        return data as Data
    }

    public static func thumbnail(_ image: CGImage, maxPixelSize: Int = 700) throws -> CGImage {
        let factor = min(1,CGFloat(maxPixelSize)/CGFloat(max(image.width,image.height)))
        let w = max(1,Int(CGFloat(image.width)*factor)), h = max(1,Int(CGFloat(image.height)*factor))
        guard let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageError.invalid }
        context.interpolationQuality = .high; context.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h))
        guard let result = context.makeImage() else { throw ImageError.invalid }; return result
    }

    public static func recognize(_ image: CGImage) throws -> String { try recognizeAll(image).text }
    public static func recognizeRegions(_ image: CGImage, words: Bool = true) throws -> [TextRegion] {
        let result = try recognizeAll(image); return words ? result.words : result.lines
    }
    /// One Vision request supplies both searchable text and precise selectable words.
    public static func recognizeAll(_ image: CGImage, cpuOnly: Bool = false) throws -> (text: String, words: [TextRegion], lines: [TextRegion]) {
        func makeRequest(cpu: Bool) throws -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            if cpu {
                guard let device = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) else { throw ImageError.invalid }
                request.setComputeDevice(device, for: .main)
            }
            return request
        }
        var request = try makeRequest(cpu: cpuOnly)
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch {
            guard !cpuOnly else { throw error }
            // Virtual machines and some graphics configurations cannot run Vision's
            // preferred compute backend. Retry a fresh request on the CPU.
            request = try makeRequest(cpu: true)
            try VNImageRequestHandler(cgImage: image).perform([request])
        }
        func pixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * CGFloat(image.width), y: (1 - r.maxY) * CGFloat(image.height), width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)) }
        var words: [TextRegion] = [], lines: [TextRegion] = []
        let regex = try NSRegularExpression(pattern: #"\S+"#)
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            lines.append(TextRegion(text: text, rect: pixels(observation.boundingBox)))
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let rect = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                words.append(TextRegion(text: String(text[range]), rect: pixels(rect)))
            }
        }
        return (lines.map(\.text).joined(separator: "\n"), words, lines)
    }

    public enum ImageError: LocalizedError {
        case invalid, tooLarge, noOverlap
        public var errorDescription: String? {
            switch self {
            case .invalid: return "This image could not be read. Try a PNG, JPEG, TIFF, or HEIC image."
            case .tooLarge: return "The scrolling image reached the 30,000-pixel safety limit. Finish this capture and start another."
            case .noOverlap: return "No matching overlap. Scroll back a little, then continue more slowly."
            }
        }
    }
}

/// Detects vertical translation using sampled luminance, then appends only new pixels.
/// Input and output use image coordinates (origin at top left).
public final class ScrollStitcher {
    public private(set) var result: CGImage
    private var previous: CGImage
    private var stickyTopInset = 0
    public private(set) var frameCount = 1
    public private(set) var lastShift = 0
    public init(first: CGImage) { result = first; previous = first }

    private func gray(_ image: CGImage) -> [UInt8] {
        // Exclude sidebars, scrollbar, and edges from overlap matching.
        let sampleWidth = 64
        var data = [UInt8](repeating: 0, count: sampleWidth * image.height)
        data.withUnsafeMutableBytes { bytes in
            let c = CGContext(data: bytes.baseAddress, width: sampleWidth, height: image.height, bitsPerComponent: 8, bytesPerRow: sampleWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            c.interpolationQuality = .low
            c.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: image.height))
        }
        return data
    }

    @discardableResult public func append(_ image: CGImage) throws -> Bool {
        guard image.width == previous.width, image.height == previous.height else { throw Imaging.ImageError.noOverlap }
        let a = gray(previous), b = gray(image), h = image.height, w = 64
        let margin = max(8, h / 12) // tolerate a small sticky header/footer
        let rowStep = max(2, h / 100)
        // Static sidebars and broad white margins are not scroll evidence.
        // Match only columns that actually changed at their screen position.
        let columns = stride(from: 4, to: 60, by: 2).filter { x in
            var error = 0, changes = 0, count = 0
            for y in stride(from: margin, to: h - margin, by: rowStep) {
                let delta = abs(Int(a[y*w+x]) - Int(b[y*w+x]))
                error += delta; changes += delta > 2 ? 1 : 0; count += 1
            }
            return changes >= 3 && Double(error) / Double(max(1,count)) > 0.3
        }
        guard !columns.isEmpty else { lastShift = 0; return false }
        // Estimate a taller stationary header before matching. Stop as soon as
        // moving content is visible; a white gap alone is not a matching feature.
        let probes = Array(stride(from: 4,to: 60,by: 2))
        var leadingStableRows = 0
        for y in 0..<h/3 {
            let stable = probes.reduce(0) { $0 + (abs(Int(a[y*w+$1])-Int(b[y*w+$1])) <= 2 ? 1 : 0) }
            guard stable*10 >= probes.count*9 else { break }
            leadingStableRows = y+1
        }
        let matchingTop = max(margin,leadingStableRows)
        func details(_ pixels: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 0,count: pixels.count)
            for y in 1..<h-1 { for x in columns {
                let index = y*w+x, center = Int(pixels[index])
                result[index] = UInt8(max(abs(center-Int(pixels[index-1])),abs(center-Int(pixels[index+1])),
                                         abs(center-Int(pixels[index-w])),abs(center-Int(pixels[index+w]))))
            } }
            return result
        }
        let detailA = details(a), detailB = details(b)
        func score(_ shift: Int, dense: Bool = false) -> Double {
            var error = 0.0, count = 0, detailedRows = 0
            let end = h - shift - margin
            guard end > matchingTop + 30 else { return .infinity }
            for y in stride(from: matchingTop, to: end, by: dense ? 1 : rowStep) {
                var detailed = false
                for x in columns {
                    let ai = (y+shift)*w+x, bi = y*w+x
                    // Empty white overlap previously scored zero and could beat
                    // the actual text alignment, duplicating most of the page.
                    guard max(detailA[ai],detailB[bi]) > 4 else { continue }
                    error += abs(Double(a[ai])-Double(b[bi])); count += 1; detailed = true
                }
                if detailed { detailedRows += 1 }
            }
            guard detailedRows >= 4, count >= max(16,columns.count*2) else { return .infinity }
            return error / Double(max(1, count))
        }
        let stationaryError = score(0)
        if stationaryError < 0.8 { lastShift = 0; return false }
        var best = (shift: 0, error: Double.infinity)
        // Evaluate every pixel offset: a coarse offset stride can skip the only
        // correct alignment on text or other high-frequency content.
        for shift in 1...max(1, h * 3 / 4) {
            let s = score(shift); if s < best.error { best = (shift, s) }
        }
        // Resolve one-pixel ambiguities hidden between sampled rows. This also
        // avoids accumulating a one-pixel seam error on every small scroll.
        if best.error.isFinite {
            let start = max(1,best.shift-rowStep), end = min(h*3/4,best.shift+rowStep)
            best.error = .infinity
            for shift in start...end {
                let s = score(shift,dense: true); if s < best.error { best = (shift,s) }
            }
        }
        // Detail-only error is stricter than a white-diluted whole-frame mean;
        // allow small antialiasing changes while still requiring motion evidence.
        guard best.error < 14.0 else { throw Imaging.ImageError.noOverlap }
        // Hover/antialiasing changes are not scrolling. Translation must explain
        // the pixels substantially better than leaving them where they are.
        guard best.error + 0.5 < stationaryError * 0.8 else { lastShift = 0; return false }
        let shift = best.shift
        guard result.height + shift <= 30_000, Int64(result.width) * Int64(result.height + shift) <= 150_000_000 else { throw Imaging.ImageError.tooLarge }
        // Join near the beginning of the overlap, below the sticky-header band.
        // Keeping almost the entire old viewport sliced floating footer buttons
        // into a trail: they often sit above the narrow bottom margin. Replace
        // the rest of that viewport with fresh pixels instead. A fixed footer
        // remains only in the newest viewport, where it can be replaced again.
        // Locate stationary chrome inside the overlap, including taller headers
        // and short pinned navigation panels. Consecutive matching pixels at the
        // same screen position, but not at the scroll offset, distinguish these
        // from scrolling body content and accidental matches in a photo.
        var runs = [Int](repeating: 0,count: w), fixedEnd = 0
        for y in 0..<max(0,min(h/2,h-shift-32)) {
            var supportedColumns = 0, longRun = false
            for x in stride(from: 4,to: 60,by: 2) {
                let p = y*w+x, aligned = (y+shift)*w+x
                if abs(Int(a[p])-Int(b[p])) <= 2 && abs(Int(a[aligned])-Int(b[p])) >= 8 { runs[x] += 1 }
                else { runs[x] = 0 }
                if runs[x] >= 3 { supportedColumns += 1 }
                if runs[x] >= 6 { longRun = true }
            }
            // Include antialiased descenders and the rest of a glyph when only
            // its taller strokes intersect the horizontally sampled columns.
            if supportedColumns >= 2 || longRun { fixedEnd = y+24 }
        }
        let incomingStart = max(margin,stickyTopInset,fixedEnd)
        guard incomingStart+shift < h-30 else { throw Imaging.ImageError.noOverlap }
        let additionHeight = h - incomingStart
        let seam = result.height - h + shift + incomingStart
        let newHeight = result.height + shift
        guard let c = CGContext(data: nil, width: result.width, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let old = result.cropping(to: CGRect(x: 0, y: 0, width: result.width, height: seam)),
              let addition = image.cropping(to: CGRect(x: 0, y: incomingStart, width: image.width, height: additionHeight)) else { throw Imaging.ImageError.invalid }
        c.draw(old, in: CGRect(x: 0, y: newHeight - seam, width: result.width, height: seam))
        c.draw(addition, in: CGRect(x: 0, y: 0, width: image.width, height: additionHeight))
        guard let merged = c.makeImage() else { throw Imaging.ImageError.invalid }
        result = merged; previous = image; stickyTopInset = incomingStart; frameCount += 1; lastShift = shift
        return true
    }
}
