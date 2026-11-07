import Foundation
import CoreGraphics

public struct DifferenceOptions {
    public var align = true
    public var tolerance: UInt8 = 24
    /// Rectangles use normalized, top-left image coordinates.
    public var ignored: [CGRect] = []
    public init() {}
}
public struct ImageDifference {
    public let before: CGImage
    public let after: CGImage
    public let overlay: CGImage
    public let offset: CGPoint
    public let changedPixels: Int
    public let comparedPixels: Int
    public var changedFraction: Double { comparedPixels == 0 ? 0 : Double(changedPixels) / Double(comparedPixels) }

    public static func compare(_ first: CGImage, _ second: CGImage, options: DifferenceOptions = DifferenceOptions()) throws -> ImageDifference {
        // Bound both memory and registration work, including for tall captures.
        let factor = min(1, 2000 / CGFloat(max(first.width, first.height)))
        let width = max(1, Int(CGFloat(first.width) * factor)), height = max(1, Int(CGFloat(first.height) * factor))
        let a = try pixels(first, width: width, height: height)
        let b = try pixels(second, width: width, height: height)
        let delta = options.align ? registration(a, b, width: width, height: height) : (0, 0)
        var aligned = [UInt8](repeating: 255, count: a.count), output = aligned
        var changed = 0, compared = 0
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4, bx = x - delta.0, by = y - delta.1
            let ignored = options.ignored.contains { $0.contains(CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))) }
            let overlap = bx >= 0 && bx < width && by >= 0 && by < height
            if overlap { let j = (by * width + bx) * 4; for c in 0..<3 { aligned[i+c] = b[j+c] } }
            let different = overlap && !ignored && (0..<3).contains { abs(Int(a[i+$0]) - Int(aligned[i+$0])) > Int(options.tolerance) }
            if overlap && !ignored { compared += 1 }
            if different { changed += 1; output[i] = 245; output[i+1] = 64; output[i+2] = 92 }
            else { for c in 0..<3 { output[i+c] = UInt8((Int(a[i+c]) + 3 * 255) / 4) } }
            output[i+3] = 255
        } }
        return ImageDifference(before: try image(a, width: width, height: height), after: try image(aligned, width: width, height: height), overlay: try image(output, width: width, height: height), offset: CGPoint(x: CGFloat(delta.0) / factor, y: CGFloat(delta.1) / factor), changedPixels: changed, comparedPixels: compared)
    }
    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Imaging.ImageError.invalid }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            let scale = min(CGFloat(width)/CGFloat(image.width), CGFloat(height)/CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width)*scale,height: CGFloat(image.height)*scale)
            ctx.draw(image, in: CGRect(x: (CGFloat(width)-size.width)/2,y: (CGFloat(height)-size.height)/2,width: size.width,height: size.height))
        }
        return data
    }
    private static func image(_ data: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(data) as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Imaging.ImageError.invalid }; return image
    }
    private static func registration(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (Int, Int) {
        guard width > 8, height > 8 else { return (0,0) }
        let limitX = min(100, width / 10), limitY = min(100, height / 10)
        let coarse = max(1, max(width,height) / 160), sample = max(1, max(width,height) / 80)
        func score(_ dx: Int, _ dy: Int) -> Double {
            var error = 0.0, count = 0
            for y in stride(from: limitY, to: height-limitY, by: sample) {
                for x in stride(from: limitX, to: width-limitX, by: sample) {
                    let bx = x-dx, by = y-dy
                    guard bx >= 0, bx < width, by >= 0, by < height else { continue }
                    let i = (y*width+x)*4, j = (by*width+bx)*4
                    // Clipping each sample prevents a few changing widgets dominating alignment.
                    error += Double(min(180, (0..<3).reduce(0) { $0 + abs(Int(a[i+$1])-Int(b[j+$1])) })); count += 1
                }
            }
            return count == 0 ? .infinity : error / Double(count) + Double(abs(dx)+abs(dy)) * 0.0001
        }
        var best = (0,0), bestScore = score(0,0)
        for dy in stride(from: -limitY, through: limitY, by: coarse) { for dx in stride(from: -limitX, through: limitX, by: coarse) {
            let value = score(dx,dy); if value < bestScore { best = (dx,dy); bestScore = value }
        } }
        let center = best
        for dy in max(-limitY,center.1-coarse)...min(limitY,center.1+coarse) { for dx in max(-limitX,center.0-coarse)...min(limitX,center.0+coarse) {
            let value = score(dx,dy); if value < bestScore { best = (dx,dy); bestScore = value }
        } }
        // Avoid inventing movement for unrelated pictures or near-uniform images.
        return bestScore < score(0,0) * 0.85 ? best : (0,0)
    }
}
