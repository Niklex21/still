import XCTest
import AppKit
@testable import SnapShelfCore

final class ImagingTests: XCTestCase {
    func testWindowFrameCentersCaptureWithoutScaling() throws {
        let original = fixture(width: 200, height: 100)
        let framed = try Imaging.frameWindow(original)
        XCTAssertEqual(framed.width, 296)
        XCTAssertEqual(framed.height, 196)
        let center = try XCTUnwrap(framed.cropping(to: CGRect(x: 48, y: 48, width: 200, height: 100)))
        XCTAssertLessThan(difference(original, center), 0.01)
        let bitmap = NSBitmapImageRep(cgImage: framed)
        let top = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 291, y: 191)?.usingColorSpace(.sRGB))
        XCTAssertEqual(top.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(abs(top.blueComponent - bottom.blueComponent), 0.05)
    }
    func fixture(width: Int = 360, height: Int = 1800, seed: UInt64 = 42) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1
                let value = UInt8((state >> 33) % 170 + 25)
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = UInt8((y * 17 + x / 12) % 230); bytes[i + 2] = UInt8((y / 7 + x * 3) % 220)
            }
        }
        let data = Data(bytes)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func frame(_ image: CGImage, y: Int, height: Int = 600) -> CGImage { image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))! }
    func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b)
        var sum = 0.0, count = 0
        for y in stride(from: 0, to: a.height, by: 13) {
            for x in stride(from: 0, to: a.width, by: 17) {
                let ca = ra.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!, cb = rb.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                sum += abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent) + abs(ca.blueComponent - cb.blueComponent); count += 3
            }
        }
        return sum / Double(count)
    }
    func testStitchProducesExactFullImageWithoutRepeatingOverlap() throws {
        let image = fixture(), stitch = ScrollStitcher(first: frame(image, y: 0))
        XCTAssertFalse(try stitch.append(frame(image, y: 0)))
        XCTAssertTrue(try stitch.append(frame(image, y: 220)))
        XCTAssertEqual(stitch.lastShift, 220)
        XCTAssertTrue(try stitch.append(frame(image, y: 480)))
        XCTAssertEqual(stitch.lastShift, 260)
        XCTAssertEqual(stitch.result.height, 1080)
        XCTAssertEqual(stitch.frameCount, 3)
        XCTAssertLessThan(difference(stitch.result, frame(image, y: 0, height: 1080)), 0.01)
    }
    func testRejectsUnrelatedFramesAndPreservesResult() throws {
        let image = fixture(), stitch = ScrollStitcher(first: frame(image, y: 0))
        XCTAssertThrowsError(try stitch.append(frame(fixture(seed: 912), y: 900)))
        XCTAssertEqual(stitch.result.height, 600)
        XCTAssertEqual(stitch.frameCount, 1)
        XCTAssertThrowsError(try stitch.append(fixture(width: 480, height: 600)))
    }
    func testStitchesSparsePageWithRepeatedWhitespaceAndTextRows() throws {
        let width = 360, height = 1500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let section = y / 250, line = y % 250
            for x in 0..<width {
                let i = (y * width + x) * 4
                let background = UInt8(244 - section * 3)
                bytes[i] = background; bytes[i + 1] = 250; bytes[i + 2] = 252
                // Different line lengths and positions mimic text in a real page.
                if ((line >= 35 && line < 44 && x > 30 && x < 110 + section * 21) ||
                    (line >= 90 && line < 96 && x > 30 && x < 285 - section * 7) ||
                    (line >= 125 && line < 131 && x > 30 && x < 180 + section * 14)) {
                    bytes[i] = 25; bytes[i + 1] = 30; bytes[i + 2] = 32
                }
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let stitch = ScrollStitcher(first: frame(image, y: 0))
        XCTAssertTrue(try stitch.append(frame(image, y: 187)))
        XCTAssertEqual(stitch.lastShift, 187)
        XCTAssertTrue(try stitch.append(frame(image, y: 420)))
        XCTAssertEqual(stitch.lastShift, 233)
        XCTAssertEqual(stitch.result.height, 1020)
        XCTAssertLessThan(difference(stitch.result, frame(image, y: 0, height: 1020)), 0.01)
    }
    func testPNGEncodingRoundTripAndInvalidInput() throws {
        let image = fixture(width: 64, height: 128)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Imaging.png(image).write(to: url)
        let result = try Imaging.load(url)
        XCTAssertEqual(result.width, 64); XCTAssertEqual(result.height, 128)
        XCTAssertLessThan(difference(image, result), 0.01)
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try Imaging.load(url))
    }

    func testDragProviderMakesAReadableImageFileAvailable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Imaging.png(fixture(width: 64, height: 128)).write(to: url)
        let provider = Imaging.dragProvider(for: url)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.png"))
        let loaded = expectation(description: "Drag item resolves to an image file")
        provider.loadFileRepresentation(forTypeIdentifier: "public.png") { file, error in
            XCTAssertNil(error)
            if let file {
                let image = try? Imaging.load(file)
                XCTAssertEqual(image?.width, 64)
                XCTAssertEqual(image?.height, 128)
            } else {
                XCTFail("The drag item did not provide a file")
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        let loadedData = expectation(description: "Drag item resolves to PNG bytes")
        provider.loadDataRepresentation(forTypeIdentifier: "public.png") { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(Array((data ?? Data()).prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            loadedData.fulfill()
        }
        wait(for: [loadedData], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Supplying a drag must not remove the original")
    }
}
