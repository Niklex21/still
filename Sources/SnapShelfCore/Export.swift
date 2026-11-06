import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Identifiable {
    case png = "PNG", jpeg = "JPEG", heic = "HEIC"
    public var id: String { rawValue }
    public var type: UTType { switch self { case .png: return .png; case .jpeg: return .jpeg; case .heic: return .heic } }
    public var fileExtension: String { type.preferredFilenameExtension ?? "png" }
}
public struct ExportOptions {
    public var format = ExportFormat.png
    public var scale = 1.0
    public var maxWidth = 0
    public var quality = 0.85
    public init() {}
    public func dimensions(width: Int, height: Int) throws -> (Int, Int) {
        guard width > 0, height > 0, scale.isFinite, scale > 0, maxWidth >= 0 else { throw Imaging.ImageError.invalid }
        let factor = min(scale, maxWidth > 0 ? Double(maxWidth) / Double(width) : scale)
        let w = (Double(width) * factor).rounded(), h = (Double(height) * factor).rounded()
        guard w <= 30_000, h <= 30_000, w * h <= 150_000_000 else { throw Imaging.ImageError.tooLarge }
        return (max(1, Int(w)), max(1, Int(h)))
    }
    public func image(_ source: CGImage) throws -> CGImage {
        let (w, h) = try dimensions(width: source.width, height: source.height)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Imaging.ImageError.invalid }
        if format == .jpeg { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        context.interpolationQuality = .high; context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw Imaging.ImageError.invalid }; return result
    }
    public func encode(_ source: CGImage) throws -> Data {
        let result = try image(source), data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { throw Imaging.ImageError.invalid }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: max(0.1, min(1, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Imaging.ImageError.invalid }; return data as Data
    }
}
