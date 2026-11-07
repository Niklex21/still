import XCTest
import AppKit
@testable import SnapShelfCore

final class ScrollingOverlayTests: XCTestCase {
    private let width = 240, viewport = 600

    /// Scrolling content with a stationary header, composer, and floating button
    /// above the composer's edge, like a chat application's jump-to-latest UI.
    private func page(height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255,count: width*height*4)
        var seed: UInt64 = 871
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 6364136223846793005 &+ 1
            let i = (y*width+x)*4
            pixels[i] = UInt8((seed >> 33)%170+25)
            pixels[i+1] = UInt8((y*17+x/12)%230)
            pixels[i+2] = UInt8((y/7+x*3)%220)
        } }
        return pixels
    }
    private func image(_ pixels: [UInt8],height: Int) -> CGImage {
        CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(pixels) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }
    private func fill(_ pixels: inout [UInt8],x: Range<Int>,y: Range<Int>,color: [UInt8]) {
        for row in y { for column in x {
            let i = (row*width+column)*4
            pixels.replaceSubrange(i..<i+4,with: color)
        } }
    }
    private func header(_ pixels: inout [UInt8]) {
        fill(&pixels,x: 0..<width,y: 0..<24,color: [225,228,232,255])
        fill(&pixels,x: 18..<130,y: 8..<15,color: [30,35,40,255])
    }
    private func footer(_ pixels: inout [UInt8],offset: Int,buttonTop: Int) {
        fill(&pixels,x: 0..<width,y: offset+565..<offset+viewport,color: [246,247,249,255])
        fill(&pixels,x: 92..<190,y: offset+buttonTop..<offset+buttonTop+32,color: [20,105,175,255])
        // A rounded button's upper edge is especially visible in the reported trails.
        fill(&pixels,x: 98..<184,y: offset+buttonTop-3..<offset+buttonTop,color: [20,105,175,255])
    }
    private func frame(_ page: [UInt8],at offset: Int,buttonTop: Int) -> CGImage {
        var pixels = Array(page[offset*width*4..<(offset+viewport)*width*4])
        header(&pixels); footer(&pixels,offset: 0,buttonTop: buttonTop)
        return image(pixels,height: viewport)
    }
    private func rgba(_ image: CGImage) -> Data {
        var pixels = [UInt8](repeating: 0,count: image.width*image.height*4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy); context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        }
        return Data(pixels)
    }
    private func verify(shifts: [Int],buttonTop: Int) throws {
        let page = page(height: viewport+shifts.reduce(0,+))
        let stitcher = ScrollStitcher(first: frame(page,at: 0,buttonTop: buttonTop))
        var offset = 0
        for shift in shifts {
            offset += shift
            XCTAssertTrue(try stitcher.append(frame(page,at: offset,buttonTop: buttonTop)))
            XCTAssertEqual(stitcher.lastShift,shift)
            XCTAssertEqual(stitcher.result.height,offset+viewport)
            var expected = Array(page.prefix((offset+viewport)*width*4))
            header(&expected); footer(&expected,offset: offset,buttonTop: buttonTop)
            let actual = rgba(stitcher.result), reference = rgba(image(expected,height: offset+viewport))
            XCTAssertTrue(actual == reference,"Only the last viewport should retain its floating button/footer; every other pixel must match the unobstructed page, after shift \(shift)")
        }
    }
    func testFloatingChatButtonDoesNotLeaveTrailsDuringSlowScrolling() throws {
        try verify(shifts: Array(repeating: 7,count: 28),buttonTop: 480)
    }
    func testFloatingFooterDoesNotDuplicateOrHideContentWithMixedScrollSteps() throws {
        try verify(shifts: [31,83,160,3,220,17,101],buttonTop: 480)
    }
    func testLargeScrollStepPreservesHeaderAndOnlyOneBottomButton() throws {
        try verify(shifts: [430,449],buttonTop: 540)
    }
}
