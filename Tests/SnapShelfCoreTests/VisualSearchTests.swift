import XCTest
@testable import SnapShelfCore

final class VisualSearchTests: XCTestCase {
    func testVisualWordsCombineWithOCRAndTitleAndPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var image = Capture(title: "Café planning", width: 400, height: 300)
        image.text = "Quarterly revenue"
        image.visualIndex = VisualIndex(summary: "Blue bars in a chart", keywords: ["bar graph", "dashboard"], revision: 0)
        XCTAssertTrue(image.matches("CAFE blue revenue"))
        XCTAssertTrue(image.matches("dashboard graph"))
        XCTAssertFalse(image.matches("red chart"))
        try disk.save([image])
        XCTAssertTrue(try XCTUnwrap(disk.load().first).matches("blue chart"))
        image.revision += 1
        XCTAssertFalse(image.hasVisualIndex)
        XCTAssertFalse(image.matches("blue chart"), "Old descriptions must not reveal content removed by editing or redaction")
        XCTAssertTrue(image.matches("revenue"))
    }
    func testOldLibrariesLoadWithoutVisualMetadataAndNewerVersionsAreIgnored() throws {
        var image = Capture(title: "Legacy", width: 400, height: 300)
        let data = try JSONEncoder().encode(image)
        XCTAssertFalse(try JSONDecoder().decode(Capture.self, from: data).hasVisualIndex)
        image.visualIndex = VisualIndex(summary: "A red circle", keywords: ["round"], revision: 0)
        image.visualIndex!.version += 1
        XCTAssertFalse(image.matches("red circle"))
        XCTAssertFalse(image.hasVisualIndex)
    }
    func testModelMetadataIsBoundedAndKeywordsAreCleaned() {
        let result = VisualIndex(summary: "  " + String(repeating: "x", count: 900), keywords: [" Blue ", "blue", "", "Chart"] + (0..<30).map { "tag \($0)" }, revision: 3)
        XCTAssertEqual(result.summary.count, 600)
        XCTAssertEqual(result.keywords.count, 16)
        XCTAssertEqual(Array(result.keywords.prefix(2)), ["Blue", "Chart"])
        XCTAssertEqual(result.revision, 3)
    }
}
