import Foundation

public struct VisualIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var revision: Int
    public var summary: String
    public var keywords: [String]

    public init(summary: String, keywords: [String], revision: Int) {
        version = Self.currentVersion
        self.revision = revision
        self.summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        var seen = Set<String>()
        self.keywords = keywords.compactMap { keyword in
            let value = String(keyword.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(16).map { $0 }
    }
}
