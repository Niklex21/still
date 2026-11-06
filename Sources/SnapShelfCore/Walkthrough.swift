import Foundation

public struct WalkthroughStep: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var caption: String
    public init(id: UUID, title: String, caption: String = "") { self.id = id; self.title = title; self.caption = caption }
}
public struct Walkthrough: Codable, Identifiable, Equatable {
    public var version = 1
    public var id = UUID()
    public var title = "Walkthrough"
    public var layout: String?
    public var comparison: Double?
    public var steps: [WalkthroughStep]
    public init(steps: [WalkthroughStep]) { self.steps = steps }
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let from = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(from + offset) else { return }
        steps.swapAt(from, from + offset)
    }
    public var markdown: String {
        func escaped(_ value: String) -> String { value.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]") }
        return "# \(escaped(title))\n\n" + steps.enumerated().map { i, step in
            "## \(i + 1). \(escaped(step.title))\n\n\(escaped(step.caption))\n\n![Step \(i + 1)](\(step.id.uuidString).png)\n"
        }.joined(separator: "\n")
    }
}
public struct BatchLayout {
    public var size: CGSize
    public var frames: [CGRect]
    public init(images: [CGSize], horizontal: Bool, width: CGFloat = 1000, captions: Bool = true, captionHeights: [CGFloat]? = nil) throws {
        guard !images.isEmpty, images.count <= 50, images.allSatisfy({ $0.width > 0 && $0.height > 0 }), width > 0, width <= 4000 else { throw Imaging.ImageError.invalid }
        let factor = width / 1000
        let margin: CGFloat = 32 * factor, gap: CGFloat = 32 * factor
        if let captionHeights, captionHeights.count != images.count { throw Imaging.ImageError.invalid }
        var frames: [CGRect] = [], x = margin, y = margin, maxHeight: CGFloat = 0
        for (index, image) in images.enumerated() {
            let caption: CGFloat = captions ? max(96 * factor, captionHeights?[index] ?? 96 * factor) : 0
            guard caption.isFinite, caption >= 0 else { throw Imaging.ImageError.invalid }
            let h = (image.height / image.width * width).rounded()
            frames.append(CGRect(x: x, y: y + caption, width: width, height: h))
            if horizontal { x += width + gap; maxHeight = max(maxHeight, h + caption) }
            else { y += h + caption + gap }
        }
        size = horizontal ? CGSize(width: x - gap + margin, height: maxHeight + margin * 2) : CGSize(width: width + margin * 2, height: y - gap + margin)
        guard size.width <= 30_000, size.height <= 30_000, size.width * size.height <= 150_000_000 else { throw Imaging.ImageError.tooLarge }
        self.frames = frames
    }
}
