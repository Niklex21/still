import Foundation
import NaturalLanguage

public struct HistoryFilters: Equatable {
    public var application = ""
    public var kind = ""
    public var tag = ""
    public var days = 0
    public var hasText = false
    public init() {}
    public func includes(_ item: Capture, now: Date = Date()) -> Bool {
        (application.isEmpty || item.metadata?.application == application) &&
        (kind.isEmpty || item.metadata?.kind == kind) &&
        (tag.isEmpty || (item.metadata?.tags ?? []).contains { $0.localizedCaseInsensitiveContains(tag) }) &&
        (days == 0 || item.createdAt >= now.addingTimeInterval(-Double(days) * 86400)) &&
        (!hasText || !item.text.isEmpty)
    }
    public var active: Bool { self != HistoryFilters() }
}

/// Apple's sentence vectors run locally. Cache keys include all searchable content,
/// so edits, OCR backfill and metadata changes cannot reuse stale vectors.
public final class SemanticSearch {
    private let lock = NSLock()
    private var embedding: NLEmbedding?
    private var attempted = false
    private var cache: [UUID: (String, [[Double]])] = [:]
    public init() {}
    public var available: Bool {
        lock.lock(); defer { lock.unlock() }; loadModel(); return embedding != nil
    }
    private func loadModel() { if !attempted { embedding = NLEmbedding.sentenceEmbedding(for: .english); attempted = true } }
    public func rank(_ captures: [Capture], query: String, semantic: Bool = true) -> [(id: UUID, score: Double)] {
        lock.lock(); defer { lock.unlock() }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return captures.map { ($0.id, 0) } }
        if semantic { loadModel() }
        let queryVector = semantic ? embedding?.vector(for: query) : nil
        if cache.count > max(500, captures.count * 2) { cache.removeAll() }
        var results: [(id: UUID, score: Double)] = []
        for item in captures {
            let exact = item.matches(query)
            var similarity = 0.0
            if let queryVector, let embedding {
                let content = item.searchText
                let vectors: [[Double]]
                if let cached = cache[item.id], cached.0 == content { vectors = cached.1 }
                else {
                    let descriptions = [item.hasVisualIndex ? item.visualIndex?.summary : nil, item.metadata?.searchText, item.title].compactMap { $0 }.filter { !$0.isEmpty }
                    // Keep OCR in short chunks; a page of unrelated words must not dilute a useful caption.
                    let lines = item.text.split(separator: "\n").map(String.init)
                    var chunks = descriptions; var current = ""
                    for line in lines.prefix(160) {
                        if current.count + line.count > 400 { if !current.isEmpty { chunks.append(current) }; current = "" }
                        current += String(line.prefix(400)) + " "
                        if chunks.count >= 32 { break }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    vectors = chunks.compactMap { embedding.vector(for: $0) }
                    cache[item.id] = (content, vectors)
                }
                similarity = vectors.map { Self.cosine(queryVector, $0) }.max() ?? 0
            }
            if exact || similarity >= 0.52 {
                // Literal matches remain dependable; related visual matches follow them.
                results.append((item.id, (exact ? 2 : 0) + similarity))
            }
        }
        return results.enumerated().sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }.map(\.element)
    }
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { dot += x * y; aa += x * x; bb += y * y }
        return aa > 0 && bb > 0 ? dot / sqrt(aa * bb) : 0
    }
}
