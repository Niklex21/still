import XCTest
import AppKit
@testable import SnapShelfCore

final class BrowserScrollTests: XCTestCase {
    private func viewport(_ number: Int) throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "viewport-\(number)",withExtension: "png",subdirectory: "Fixtures/Bootstrap"))
        return try Imaging.load(url)
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0,count: image.width*image.height*4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        }
        return data
    }
    func testRealChromePageChoosesTextAlignmentInsteadOfAnEmptyWhiteOverlap() throws {
        let first = try viewport(1), second = try viewport(2)
        // Independent full-resolution body comparison: exactly 138 pixels of
        // movement, zero differing body pixels at this offset (not a DOM estimate).
        let a = pixels(first), b = pixels(second), width = first.width, height = first.height
        var mismatches = 0, ink = 0
        for y in 150..<height-338 { for x in width/5..<width*2/5 {
            let i = ((y+138)*width+x)*4, j = (y*width+x)*4
            for channel in 0..<3 { if a[i+channel] != b[j+channel] { mismatches += 1 } }
            if min(a[i],a[i+1],a[i+2]) < 180 { ink += 1 }
        } }
        XCTAssertEqual(mismatches,0); XCTAssertGreaterThan(ink,1_000)
        let stitcher = ScrollStitcher(first: first)
        XCTAssertTrue(try stitcher.append(second))
        XCTAssertEqual(stitcher.lastShift,138,"A blank overlap must never beat the actual matching text")
        XCTAssertEqual(stitcher.result.height,height+138)
        XCTAssertFalse(try stitcher.append(second),"A paused webpage must not extend the image")
    }
    func testRealChromeFloatingThemeButtonAppearsOnlyAtTheBottom() throws {
        let first = try viewport(1), second = try viewport(2), stitcher = ScrollStitcher(first: first)
        XCTAssertTrue(try stitcher.append(second))
        let image = stitcher.result, rgba = pixels(image), width = image.width
        var rows: [Int] = []
        for y in 0..<image.height {
            var purple = 0
            for x in width-160..<width-10 {
                let i = (y*width+x)*4
                if rgba[i] > 70 && rgba[i] < 160 && rgba[i+1] < 90 && rgba[i+2] > 210 { purple += 1 }
            }
            if purple > 40 { rows.append(y) }
        }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(rows.first),image.height-125)
        XCTAssertLessThan(rows.count,100,"The floating button must not stretch into a trail")
    }
    func testInitialRealChromeViewportAndNativeSelectionCropUseTheActualOffset() throws {
        for crop in [false,true] {
            let rect = CGRect(x: 4,y: 2,width: 3014,height: 1710)
            let first = try viewport(0), second = try viewport(1)
            let a = try XCTUnwrap(crop ? first.cropping(to: rect) : first)
            let b = try XCTUnwrap(crop ? second.cropping(to: rect) : second)
            let stitcher = ScrollStitcher(first: a)
            XCTAssertTrue(try stitcher.append(b))
            XCTAssertEqual(stitcher.lastShift,138,"The initial white-heavy viewport must not create a false large jump; cropped: \(crop)")
            XCTAssertEqual(stitcher.result.height,a.height+138)
        }
    }
    func testFractionalBrowserRasterizationCannotPreferAnEmptyWhiteOverlap() throws {
        let first = try viewport(0), second = try viewport(1)
        let rgba = pixels(second), width = second.width, height = second.height
        // Resting Chrome frames align exactly. During smooth scrolling, glyphs
        // can land between physical rows. Blend adjacent rows to exercise three
        // raster phases without replacing the real page with a synthetic pattern.
        for phase in 1...3 {
            var fractional = rgba
            for y in 0..<height-1 { for x in 0..<width { for channel in 0..<3 {
                let i = (y*width+x)*4+channel
                fractional[i] = UInt8((Int(rgba[i])*(4-phase)+Int(rgba[i+width*4])*phase)/4)
            } } }
            let shifted = try XCTUnwrap(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(fractional) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
            let stitcher = ScrollStitcher(first: first)
            XCTAssertTrue(try stitcher.append(shifted))
            XCTAssertLessThanOrEqual(abs(stitcher.lastShift-138),1,"Subpixel text must not lose to a distant blank region; phase \(phase)")
        }
    }
    func testEmptyWhiteOverlapCannotBeatMatchingTextWithSmallRenderingChanges() throws {
        let width = 240, height = 600
        func sparsePage(scroll: Int,ink: UInt8) -> CGImage {
            var rgba = [UInt8](repeating: 255,count: width*height*4)
            for (top,end) in [(180,150),(220,200),(260,115)] {
                for y in top-scroll..<top-scroll+8 { for x in 30..<end {
                    let i = (y*width+x)*4
                    rgba[i] = ink; rgba[i+1] = ink; rgba[i+2] = ink
                } }
            }
            return CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(rgba) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        }
        let stitcher = ScrollStitcher(first: sparsePage(scroll: 0,ink: 20))
        XCTAssertTrue(try stitcher.append(sparsePage(scroll: 30,ink: 21)))
        XCTAssertEqual(stitcher.lastShift,30,"Empty overlap is not evidence of a large scroll, even if matching glyphs differ slightly")
        XCTAssertEqual(stitcher.result.height,630)
        let stationary = ScrollStitcher(first: sparsePage(scroll: 0,ink: 20))
        XCTAssertFalse(try stationary.append(sparsePage(scroll: 0,ink: 21)),"A small stationary rendering change must not invent a scroll")
        XCTAssertEqual(stationary.result.height,height)
    }
}
