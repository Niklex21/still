import Foundation

public struct Capture: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var filename: String
    public var originalFilename: String
    public var text: String
    public var width: Int
    public var height: Int
    public var onShelf: Bool
    public var favorite: Bool
    public var revision: Int
    public var indexed: Bool?
    public var reviewedAt: Date?
    public var pinnedAt: Date?
    public var inPreview: Bool?
    public var visualIndex: VisualIndex?
    public var editDocument: EditDocument?
    public var metadata: CaptureMetadata?
    public var textRegions: [TextRegion]?
    public var privateCapture: Bool?
    public var isPrivate: Bool { privateCapture == true }
    public var searchText: String { "\(title) \(text) \(visualSearchText) \(metadata?.searchText ?? "")" }
    public var hasVisualIndex: Bool { visualIndex?.version == VisualIndex.currentVersion && visualIndex?.revision == revision }
    public var visualSearchText: String { hasVisualIndex ? "\(visualIndex!.summary) \(visualIndex!.keywords.joined(separator: " "))" : "" }
    public var isCurrentPreview: Bool { onShelf && inPreview == true }
    public var isPinned: Bool { pinnedAt != nil }
    public var needsAttention: Bool { onShelf && reviewedAt == nil }

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), width: Int, height: Int) {
        self.id = id; self.title = title; self.createdAt = createdAt
        filename = "\(id.uuidString).png"; originalFilename = "\(id.uuidString)-original.png"
        text = ""; self.width = width; self.height = height
        onShelf = true; inPreview = true; favorite = false; revision = 0; indexed = false
    }

    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        let content = searchText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return words.allSatisfy { content.contains($0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) }
    }
}

public struct CompactShelfContents {
    public let recent: [Capture]
    public let older: [Capture]
    public init(captures: [Capture]) {
        let shelf = captures.filter(\.onShelf)
        recent = Array(shelf.filter(\.isCurrentPreview).prefix(3))
        let recentIDs = Set(recent.map(\.id))
        older = shelf.filter { !recentIDs.contains($0.id) }
    }
    public var columnCount: Int { recent.count + (older.isEmpty ? 0 : 1) }
}

public struct LibraryIndex: Codable {
    public var version: Int = 1
    public var captures: [Capture]
    public init(captures: [Capture] = []) { self.captures = captures }
}

public final class LibraryDisk {
    public let root: URL
    public var images: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public var privateImages: URL { root.appendingPathComponent("Private", isDirectory: true) }
    public var indexURL: URL { root.appendingPathComponent("library.json") }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    }

    public func load() throws -> [Capture] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: indexURL))
        guard index.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        guard Set(index.captures.map(\.id)).count == index.captures.count else { throw CocoaError(.fileReadCorruptFile) }
        return index.captures.filter { !$0.isPrivate }
    }

    public func save(_ captures: [Capture]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(LibraryIndex(captures: captures.filter { !$0.isPrivate })).write(to: indexURL, options: .atomic)
    }

    public func baseURL(_ capture: Capture, filename: String) -> URL {
        let safe = URL(fileURLWithPath: filename).lastPathComponent
        return (capture.isPrivate ? privateImages : images).appendingPathComponent(["", ".", ".."].contains(safe) ? "\(capture.id)-base.png" : safe)
    }
    public func url(_ capture: Capture, original: Bool = false) -> URL {
        let filename = original ? capture.originalFilename : capture.filename
        let safe = URL(fileURLWithPath: filename).lastPathComponent
        let fallback = original ? "\(capture.id)-original.png" : "\(capture.id).png"
        return (capture.isPrivate ? privateImages : images).appendingPathComponent(["", ".", ".."].contains(safe) ? fallback : safe)
    }
}
