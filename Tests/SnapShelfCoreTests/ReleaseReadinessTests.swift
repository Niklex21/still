import XCTest
import ImageIO
@testable import SnapShelfCore

final class ReleaseReadinessTests: XCTestCase {
    func testViewportAnchorsZoomAndMatchesRetinaPixels() {
        var viewport = EditorViewport()
        let image = CGSize(width: 2000, height: 1000), bounds = CGSize(width: 800, height: 600), anchor = CGPoint(x: 280,y: 220)
        let old = viewport.rect(image: image, bounds: bounds)
        let fraction = CGPoint(x: (anchor.x-old.minX)/old.width,y: (anchor.y-old.minY)/old.height)
        viewport.setZoom(2, around: anchor, image: image, bounds: bounds)
        let zoomed = viewport.rect(image: image, bounds: bounds)
        XCTAssertEqual(zoomed.minX + fraction.x*zoomed.width, anchor.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.minY + fraction.y*zoomed.height, anchor.y, accuracy: 0.001)
        viewport.actualPixels(image: image, bounds: bounds, backingScale: 2)
        XCTAssertEqual(viewport.rect(image: image, bounds: bounds).width*2, image.width, accuracy: 0.001)
    }
    func testRetentionProtectsEveryKindOfActiveCapture() {
        let now = Date(), old = now.addingTimeInterval(-40*86400)
        let eligible = Capture(title: "Old", createdAt: old, width: 10, height: 10)
        var samples = (0..<7).map { _ in eligible }; for i in samples.indices { samples[i].id = UUID(); samples[i].onShelf = false }
        samples[1].favorite = true; samples[2].pinnedAt = now; samples[3].onShelf = true; samples[4].privateCapture = true; samples[5].createdAt = now
        let ids = Set(RetentionPolicy.candidates(samples, days: 30, protectedIDs: [samples[6].id], now: now).map(\.id))
        XCTAssertEqual(ids, [samples[0].id]); XCTAssertTrue(RetentionPolicy.candidates(samples, days: 0, protectedIDs: []).isEmpty)
    }
    func testPrivateNeverEntersDiskIndexAndDuplicateIDsFailSafely() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try LibraryDisk(root: folder)
        let normal = Capture(title: "Public", width: 1, height: 1); var secret = Capture(title: "Secret", width: 1, height: 1); secret.privateCapture = true
        try disk.save([normal, secret]); XCTAssertEqual(try disk.load(), [normal])
        XCTAssertFalse(try String(contentsOf: disk.indexURL).contains("Secret"))
        try JSONEncoder().encode(LibraryIndex(captures: [normal,normal])).write(to: disk.indexURL)
        XCTAssertThrowsError(try disk.load())
        var escape = normal; escape.filename = "../../outside.png"
        XCTAssertEqual(disk.url(escape).deletingLastPathComponent(), disk.images)
    }
    func testRepeatRegionRejectsAbsentDisplaysAndInvalidGeometry() {
        let screens = [CGRect(x: 0,y: 0,width: 1440,height: 900),CGRect(x: -1200,y: 0,width: 1200,height: 800)]
        XCTAssertTrue(CaptureRegion.valid(CGRect(x: -900,y: 20,width: 500,height: 300), within: screens))
        XCTAssertFalse(CaptureRegion.valid(CGRect(x: -900,y: 850,width: 500,height: 300), within: screens))
        XCTAssertFalse(CaptureRegion.valid(CGRect(x: Double.nan,y: 0,width: 100,height: 100), within: screens))
        XCTAssertEqual(CaptureRegion.arguments(CGRect(x: -900,y: 20,width: 500,height: 300)), "-R-900,20,500,300")
    }
    private func fixture(dx: Int = 0, dy: Int = 0, changed: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: 180, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 180,height: 120))
        for y in 0..<10 { for x in 0..<15 {
            ctx.setFillColor(CGColor(gray: CGFloat((x*17+y*29)%101)/100,alpha: 1));ctx.fill(CGRect(x: x*12+dx,y: y*12+dy,width: 9,height: 9))
        } }
        if changed { ctx.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1)); ctx.fill(CGRect(x: 40,y: 80,width: 12,height: 12)) }
        return ctx.makeImage()!
    }
    func testDifferencesAlignTranslationAndRespectIgnoredRegions() throws {
        let first = fixture()
        let same = try ImageDifference.compare(first, first)
        XCTAssertEqual(same.changedPixels,0); XCTAssertEqual(same.comparedPixels,180*120)
        // Registration must recover positive and negative translations, not just one direction.
        for shift in [-5,3] {
            let aligned = try ImageDifference.compare(first,fixture(dx: shift,dy: -2))
            XCTAssertEqual(aligned.changedPixels,0); XCTAssertEqual(abs(aligned.offset.x),CGFloat(abs(shift))); XCTAssertEqual(abs(aligned.offset.y),2)
        }
        var options = DifferenceOptions(); options.align = false
        let changed = try ImageDifference.compare(first,fixture(changed: true),options: options)
        XCTAssertGreaterThan(changed.changedPixels,100)
        // Pixel data and ignored rectangles must share top-left orientation.
        options.ignored = [CGRect(x: 39.0/180,y: 27.0/120,width: 14.0/180,height: 14.0/120)]
        let ignored = try ImageDifference.compare(first,fixture(changed: true),options: options)
        XCTAssertEqual(ignored.changedPixels,0)
    }
    func testSharingPresetsEncodeWithoutUpscalingAndRespectBudget() throws {
        let source = fixture()
        let retina = try SharingImage.prepare(source,preset: .screenSize,pixelScale: 2)
        XCTAssertEqual(retina.width,90); XCTAssertEqual(retina.height,60)
        let chat = try SharingImage.prepare(source,preset: .chat,pixelScale: nil)
        XCTAssertEqual(chat.width,180)
        let limited = try SharingImage.prepare(source,preset: .underTwoMB,pixelScale: nil)
        XCTAssertLessThanOrEqual(limited.data.count,2_000_000); XCTAssertEqual(limited.format,.jpeg)
        let decoded = CGImageSourceCreateWithData(limited.data as CFData,nil)!
        XCTAssertEqual(CGImageSourceGetType(decoded) as String?,"public.jpeg")
    }
    func testNewGlobalShortcutsAreNotMisclassifiedAsHoverActions() {
        for action in [ShortcutAction.repeatRegion,.delayedRegion,.privateRegion] { XCTAssertFalse(action.isHoverAction) }
        XCTAssertTrue(ShortcutAction.copySharingHovered.isHoverAction)
    }
}
