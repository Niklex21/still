import Foundation

public struct Annotation: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var tool: String
    public var points: [CGPoint]
    public var color: [Double]
    public var width: Double
    public var text: String
    public var number: Int
    public init(id: UUID = UUID(), tool: String, points: [CGPoint], color: [Double], width: Double, text: String = "", number: Int = 0) {
        self.id = id; self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text; self.number = number
    }
}
public struct EditDocument: Codable, Equatable {
    public var version = 1
    public var baseFilename: String
    public var annotations: [Annotation]
    public var crop: CGRect?
    public init(baseFilename: String, annotations: [Annotation], crop: CGRect? = nil) { self.baseFilename = baseFilename; self.annotations = annotations; self.crop = crop }
}
public enum EditGeometry {
    public static func endpoint(from start: CGPoint, to end: CGPoint, square: Bool, bounds: CGSize) -> CGPoint {
        var dx = end.x - start.x, dy = end.y - start.y
        if square {
            let xLimit = dx < 0 ? start.x : bounds.width - start.x
            let yLimit = dy < 0 ? start.y : bounds.height - start.y
            let side = min(max(abs(dx), abs(dy)), xLimit, yLimit)
            dx = (dx < 0 ? -1 : 1) * side; dy = (dy < 0 ? -1 : 1) * side
        }
        return CGPoint(x: max(0, min(bounds.width, start.x + dx)), y: max(0, min(bounds.height, start.y + dy)))
    }
}
public struct TextRegion: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    /// Pixel coordinates, origin at the top left.
    public var rect: CGRect
    public init(text: String, rect: CGRect) { id = UUID(); self.text = text; self.rect = rect }
}
public struct CaptureMetadata: Codable, Equatable {
    public var application: String?
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var sourceURL: String?
    public var kind: String?
    public var notes: String
    public var tags: [String]
    public init(application: String? = nil, bundleIdentifier: String? = nil, windowTitle: String? = nil, sourceURL: String? = nil, kind: String? = nil, notes: String = "", tags: [String] = []) {
        self.application = application; self.bundleIdentifier = bundleIdentifier; self.windowTitle = windowTitle; self.sourceURL = sourceURL; self.kind = kind; self.notes = notes; self.tags = tags
    }
    public var searchText: String { [application, windowTitle, sourceURL, kind, notes, tags.joined(separator: " ")].compactMap { $0 }.joined(separator: " ") }
}
public enum SensitiveText {
    public static func contains(_ text: String) -> Bool {
        let patterns = [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"\b\d{3}[- ]\d{2}[- ]\d{4}\b"#, #"\b(?:\d[ -]*?){13,19}\b"#, #"\b(?:sk-|ghp_|github_pat_|AKIA)[A-Z0-9_-]{12,}\b"#, #"\b(?:password|secret|api[ _-]?key|access[ _-]?token)\s*[:=]\s*\S+"#]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
