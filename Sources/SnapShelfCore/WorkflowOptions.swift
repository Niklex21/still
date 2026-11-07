import Foundation
import CoreGraphics

public enum SharingPreset: String, Codable, CaseIterable, Identifiable {
    case original, screenSize, chat, underTwoMB
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: return "Original"
        case .screenSize: return "Screen size · 1×"
        case .chat: return "Chat-ready · 1600 px"
        case .underTwoMB: return "File under 2 MB"
        }
    }
    public func options(pixelScale: Double?) -> ExportOptions {
        var options = ExportOptions()
        switch self {
        case .original: break
        case .screenSize: options.scale = 1 / max(1, min(4, pixelScale ?? 1))
        case .chat: options.maxWidth = 1600
        case .underTwoMB: options.maxWidth = 2000; options.format = .jpeg; options.quality = 0.88
        }
        return options
    }
    public var byteLimit: Int? { self == .underTwoMB ? 2_000_000 : nil }
}

public enum RetentionPolicy {
    /// Queued, favorite, pinned, private, and walkthrough source captures are protected.
    public static func candidates(_ captures: [Capture], days: Int, protectedIDs: Set<UUID>, now: Date = Date()) -> [Capture] {
        guard [7, 30, 90].contains(days) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return captures.filter { !$0.isPrivate && !$0.favorite && !$0.isPinned && !$0.onShelf && !protectedIDs.contains($0.id) && $0.createdAt < cutoff }
    }
}

public enum CaptureRegion {
    public static func valid(_ rect: CGRect, within screens: [CGRect]) -> Bool {
        guard [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite), rect.width >= 2, rect.height >= 2,
              rect.width <= 30_000, rect.height <= 30_000 else { return false }
        // An individual region must fit a connected display; don't silently capture an absent display or a gap.
        return screens.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(rect) }
    }
    /// Crop the frozen selection using AppKit's bottom-left local coordinates.
    public static func frozenCrop(_ local: CGRect, screen: CGSize, pixels: CGSize) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        let x = pixels.width / screen.width, y = pixels.height / screen.height
        return CGRect(x: local.minX*x,y: (screen.height-local.maxY)*y,width: local.width*x,height: local.height*y).integral.intersection(CGRect(origin: .zero,size: pixels))
    }
    public static func arguments(_ rect: CGRect) -> String {
        "-R\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }
}

public struct EditorViewport {
    public var zoom: CGFloat = 1
    public var pan: CGPoint = .zero
    public init() {}
    public func rect(image: CGSize, bounds: CGSize, backingScale: CGFloat = 1) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let fit = min(bounds.width / image.width, bounds.height / image.height)
        let scale = fit * min(32, max(0.1, zoom))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2 + pan.x, y: (bounds.height - size.height) / 2 + pan.y, width: size.width, height: size.height)
    }
    public mutating func setZoom(_ value: CGFloat, around anchor: CGPoint, image: CGSize, bounds: CGSize) {
        let old = rect(image: image, bounds: bounds)
        guard old.width > 0, old.height > 0 else { return }
        let unit = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
        zoom = min(32, max(0.1, value))
        let next = rect(image: image, bounds: bounds)
        pan.x += anchor.x - (next.minX + unit.x * next.width)
        pan.y += anchor.y - (next.minY + unit.y * next.height)
    }
    public mutating func actualPixels(image: CGSize, bounds: CGSize, backingScale: CGFloat) {
        let fit = min(bounds.width / max(1,image.width), bounds.height / max(1,image.height))
        zoom = min(32, max(0.1, 1 / max(0.1,fit * backingScale))); pan = .zero
    }
}
