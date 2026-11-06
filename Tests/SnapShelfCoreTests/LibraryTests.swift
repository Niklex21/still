import XCTest
@testable import SnapShelfCore

final class LibraryTests: XCTestCase {
    func testReviewStateSurvivesReloadAndOldIndexesRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var item = Capture(title: "New screenshot", width: 400, height: 300)
        XCTAssertTrue(item.needsAttention)
        // An index from before attention tracking must still load without data loss.
        try disk.save([item])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: disk.indexURL)) as? [String: Any])
        var captures = try XCTUnwrap(json["captures"] as? [[String: Any]])
        captures[0].removeValue(forKey: "reviewedAt")
        json["captures"] = captures
        try JSONSerialization.data(withJSONObject: json).write(to: disk.indexURL)
        XCTAssertEqual(try disk.load(), [item])
        item.reviewedAt = Date(timeIntervalSince1970: 123456)
        try disk.save([item])
        let reloaded = try XCTUnwrap(disk.load().first)
        XCTAssertFalse(reloaded.needsAttention)
        XCTAssertEqual(reloaded.reviewedAt, item.reviewedAt)
        item.reviewedAt = nil; item.onShelf = false
        XCTAssertFalse(item.needsAttention)
    }
    func testCompactShelfShowsLatestThreeThenOlderStack() {
        var captures = (0..<7).map { Capture(title: "Capture \($0)", width: 400, height: 300) }
        captures[1].onShelf = false
        captures[2].reviewedAt = Date()
        for i in 4..<captures.count { captures[i].inPreview = false }
        let contents = CompactShelfContents(captures: captures)
        XCTAssertEqual(contents.recent.map(\.id), [captures[0].id, captures[2].id, captures[3].id])
        XCTAssertEqual(contents.older.map(\.id), Array(captures[4...].map(\.id)))
        XCTAssertEqual(contents.columnCount, 4)
        XCTAssertTrue(Set(contents.recent.map(\.id)).isDisjoint(with: Set(contents.older.map(\.id))))
        XCTAssertEqual(CompactShelfContents(captures: Array(captures.prefix(2))).columnCount, 1)
        XCTAssertEqual(CompactShelfContents(captures: []).columnCount, 0)
    }
    func testRemovingCurrentPreviewsNeverPromotesOlderCaptures() {
        var items = (0..<6).map { Capture(title: "Capture \($0)", width: 400, height: 300) }
        for i in 3..<6 { items[i].inPreview = false }
        items[0].onShelf = false
        XCTAssertEqual(CompactShelfContents(captures: items).recent.map(\.id), [items[1].id, items[2].id])
        items[1].onShelf = false; items[2].onShelf = false
        let contents = CompactShelfContents(captures: items)
        XCTAssertTrue(contents.recent.isEmpty)
        XCTAssertEqual(contents.older.map(\.id), Array(items[3...].map(\.id)))
        XCTAssertEqual(contents.columnCount, 1)
    }
    func testPinsSurviveReloadIndependentlyOfShelfAndAttention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var item = Capture(title: "Pinned", width: 300, height: 400)
        XCTAssertFalse(item.isPinned)
        item.pinnedAt = Date(timeIntervalSince1970: 123456)
        item.onShelf = false; item.reviewedAt = item.pinnedAt
        try disk.save([item])
        XCTAssertEqual(try disk.load(), [item])
        XCTAssertTrue(try XCTUnwrap(disk.load().first).isPinned)
        XCTAssertFalse(item.needsAttention)
    }
    func testSearchCombinesTitleAndOCRWithCaseAndAccents() {
        var capture = Capture(title: "Café design", width: 100, height: 200)
        capture.text = "Release Checklist\nQuarterly Planning"
        XCTAssertTrue(capture.matches("CAFE checklist"))
        XCTAssertTrue(capture.matches("  release   design "))
        XCTAssertTrue(capture.matches(""))
        XCTAssertFalse(capture.matches("checklist invoice"))
    }
    func testLibraryRoundTripKeepsShelfFavoritesAndEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        XCTAssertEqual(try disk.load(), [])
        var item = Capture(title: "Important", width: 1234, height: 5678)
        item.onShelf = false; item.favorite = true; item.revision = 3; item.text = "OCR text"
        try disk.save([item])
        XCTAssertEqual(try LibraryDisk(root: root).load(), [item])
        XCTAssertEqual(disk.url(item).lastPathComponent, "\(item.id).png")
        XCTAssertNotEqual(disk.url(item), disk.url(item, original: true))
    }
    func testCorruptLibraryIsReportedAndNotReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        let data = Data("broken index".utf8); try data.write(to: disk.indexURL)
        XCTAssertThrowsError(try disk.load())
        XCTAssertEqual(try Data(contentsOf: disk.indexURL), data)
    }
}
