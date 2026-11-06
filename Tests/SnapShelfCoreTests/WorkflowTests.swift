import XCTest
@testable import SnapShelfCore

final class WorkflowTests: XCTestCase {
    func testEditableDocumentAndLegacyLibraryRoundTrip() throws {
        var capture = Capture(title: "Example", width: 400, height: 200)
        let legacy = try JSONDecoder().decode(Capture.self, from: JSONEncoder().encode(capture))
        XCTAssertNil(legacy.editDocument); XCTAssertNil(legacy.metadata)
        let mark = Annotation(tool: "pin", points: [CGPoint(x: 23, y: 35)], color: [1, 0, 0, 1], width: 4, text: "Click here", number: 3)
        capture.editDocument = EditDocument(baseFilename: "base.png", annotations: [mark], crop: CGRect(x: 10, y: 20, width: 100, height: 80))
        capture.metadata = CaptureMetadata(application: "Safari", kind: "Window", notes: "Checkout flow", tags: ["Payments"])
        let restored = try JSONDecoder().decode(Capture.self, from: JSONEncoder().encode(capture))
        XCTAssertEqual(capture, restored); XCTAssertEqual(restored.editDocument?.annotations.first?.id, mark.id)
        XCTAssertTrue(restored.matches("safari payments checkout"))
    }
    func testShiftSquareAcrossQuadrantsAndImageEdges() {
        for end in [CGPoint(x: 90, y: 60), CGPoint(x: 10, y: 70), CGPoint(x: 60, y: 5), CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 400)] {
            let start = CGPoint(x: 30, y: 40), result = EditGeometry.endpoint(from: start, to: end, square: true, bounds: CGSize(width: 100, height: 80))
            XCTAssertEqual(abs(result.x - start.x), abs(result.y - start.y), accuracy: 0.001)
            XCTAssertTrue((0...100).contains(result.x)); XCTAssertTrue((0...80).contains(result.y))
        }
        XCTAssertEqual(EditGeometry.endpoint(from: .zero, to: CGPoint(x: 80, y: 40), square: false, bounds: CGSize(width: 100, height: 100)), CGPoint(x: 80, y: 40))
    }
    func testExportDimensionsKeepAspectAndRejectOversizedAllocation() throws {
        var options = ExportOptions(); options.scale = 0.5
        let half = try options.dimensions(width: 2400, height: 1600); XCTAssertEqual(half.0, 1200); XCTAssertEqual(half.1, 800)
        options.maxWidth = 600
        let limited = try options.dimensions(width: 2400, height: 1600); XCTAssertEqual(limited.0, 600); XCTAssertEqual(limited.1, 400)
        options.maxWidth = 0; options.scale = 2
        XCTAssertThrowsError(try options.dimensions(width: 20000, height: 20000))
        options.scale = .nan; XCTAssertThrowsError(try options.dimensions(width: 2, height: 2))
    }
    func testSensitivePatternsAndOrdinaryText() {
        for value in ["hello@example.com", "SSN 123-45-6789", "4111 1111 1111 1111", "api_key: abcdefg123", "sk-abcdefghijklmnopq"] { XCTAssertTrue(SensitiveText.contains(value), value) }
        for value in ["A cat beside a window", "Revenue 1,200", "2026-10-30", "Step 3 of 5"] { XCTAssertFalse(SensitiveText.contains(value), value) }
    }
    func testHistoryFiltersCanCombineSourceDateTextAndTag() {
        var capture = Capture(title: "Example", createdAt: Date(timeIntervalSince1970: 1000000), width: 20, height: 30)
        capture.metadata = CaptureMetadata(application: "Safari", kind: "Window", tags: ["Payments"]); capture.text = "Receipt"
        var filters = HistoryFilters(); filters.application = "Safari"; filters.kind = "Window"; filters.tag = "pay"; filters.days = 7; filters.hasText = true
        XCTAssertTrue(filters.includes(capture, now: capture.createdAt.addingTimeInterval(100)))
        XCTAssertFalse(filters.includes(capture, now: capture.createdAt.addingTimeInterval(8 * 86400)))
        filters.application = "Finder"; XCTAssertFalse(filters.includes(capture, now: capture.createdAt))
    }
    func testWalkthroughOrderAndLayout() throws {
        let first = WalkthroughStep(id: UUID(), title: "First", caption: "Click"), second = WalkthroughStep(id: UUID(), title: "Second")
        var project = Walkthrough(steps: [first, second]); project.layout = "compare"; project.comparison = 0.7; project.move(second.id, by: -1)
        XCTAssertEqual(project.steps.first, second); XCTAssertTrue(project.markdown.contains("## 1. Second")); XCTAssertTrue(project.markdown.contains("\(first.id.uuidString).png"))
        XCTAssertEqual(try JSONDecoder().decode(Walkthrough.self, from: JSONEncoder().encode(project)), project)
        let sizes = [CGSize(width: 100, height: 200), CGSize(width: 200, height: 100)]
        let vertical = try BatchLayout(images: sizes, horizontal: false, width: 100)
        XCTAssertGreaterThan(vertical.frames[1].minY, vertical.frames[0].maxY)
        let horizontal = try BatchLayout(images: sizes, horizontal: true, width: 100)
        XCTAssertGreaterThan(horizontal.frames[1].minX, horizontal.frames[0].maxX)
        XCTAssertThrowsError(try BatchLayout(images: [CGSize(width: 1, height: 40000)], horizontal: false))
        let full = try BatchLayout(images: sizes, horizontal: false, width: 1000)
        let preview = try BatchLayout(images: sizes, horizontal: false, width: 300)
        XCTAssertEqual(preview.size.width / full.size.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(preview.size.height / full.size.height, 0.3, accuracy: 0.001)
    }
    func testSemanticRetrievalFindsRelatedMeaningWithoutLiteralWords() throws {
        let engine = SemanticSearch()
        guard engine.available else { throw XCTSkip("System sentence model unavailable") }
        var car = Capture(title: "Photo 1", width: 20, height: 20)
        car.visualIndex = VisualIndex(summary: "An automobile driving along a highway.", keywords: ["vehicle"], revision: 0)
        var food = Capture(title: "Photo 2", width: 20, height: 20)
        food.visualIndex = VisualIndex(summary: "A bowl of fresh salad with vegetables.", keywords: ["food"], revision: 0)
        XCTAssertFalse(car.matches("car on a road"))
        let results = engine.rank([food, car], query: "car on a road")
        XCTAssertEqual(results.first?.id, car.id, "Related visual meaning must outrank unrelated food")
        XCTAssertTrue(engine.rank([car, food], query: "car on a road", semantic: false).isEmpty)
        car.visualIndex = VisualIndex(summary: "A bowl of fresh salad.", keywords: [], revision: 0)
        let after = engine.rank([car, food], query: "car on a road")
        XCTAssertFalse(after.contains { $0.id == car.id }, "Changed metadata must invalidate cached vectors")
    }
}
