import XCTest
import Carbon
import AppKit
@testable import SnapShelfCore

final class AppearanceTests: XCTestCase {
    func testOptionActionsFollowRegisteredShortcuts() {
        var keys = ShortcutBindings.defaults()
        XCTAssertEqual(ScreenshotAction.dismiss.displayed(holdingOption: false, bindings: keys), .dismiss)
        XCTAssertEqual(ScreenshotAction.dismiss.displayed(holdingOption: true, bindings: keys), .trash)
        XCTAssertEqual(ScreenshotAction.copySharing.displayed(holdingOption: true, bindings: keys), .copy)
        XCTAssertEqual(ScreenshotAction.pin.displayed(holdingOption: true, bindings: keys), .pin)
        keys[.trashHovered] = nil
        XCTAssertEqual(ScreenshotAction.dismiss.displayed(holdingOption: true, bindings: keys), .dismiss)
        keys[.revealHovered] = KeyboardShortcut(keyCode: keys[.pinHovered]!.keyCode, modifiers: UInt32(cmdKey | optionKey))
        XCTAssertEqual(ScreenshotAction.pin.displayed(holdingOption: true, bindings: keys), .reveal)
    }
    func testCornerLayoutRoundTripAndDefaults() throws {
        var controls = HoverControls()
        XCTAssertEqual(controls[.topLeft], .dismiss)
        XCTAssertEqual(controls[.topRight], .pin)
        XCTAssertEqual(controls[.bottomLeft], .edit)
        XCTAssertEqual(controls[.bottomRight], .copySharing)
        controls[.topLeft] = .upload; controls[.bottomRight] = .save
        controls.buttonSize = 38; controls.hideDate = false
        XCTAssertEqual(try JSONDecoder().decode(HoverControls.self, from: JSONEncoder().encode(controls)), controls)
        XCTAssertEqual(ScreenshotAction.upload.shortcutAction, .uploadHovered)
    }
    func testWindowBackgroundUsesImageAndPreservesCenteredPixels() throws {
        func solid(_ color: CGColor, width: Int, height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let window = solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1), width: 300, height: 200)
        let wallpaper = solid(CGColor(red: 0, green: 0.7, blue: 0.2, alpha: 1), width: 800, height: 400)
        let framed = try Imaging.frameWindow(window, background: wallpaper, style: .wallpaper, shadow: false)
        let bitmap = NSBitmapImageRep(cgImage: framed)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        let center = try XCTUnwrap(bitmap.colorAt(x: framed.width / 2, y: framed.height / 2)?.usingColorSpace(.sRGB))
        let wallpaperColor = try XCTUnwrap(NSBitmapImageRep(cgImage: wallpaper).colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        XCTAssertEqual(corner.greenComponent, wallpaperColor.greenComponent, accuracy: 0.015)
        let dimmed = try Imaging.frameWindow(window, background: wallpaper, style: .wallpaper, shadow: false, dimming: 0.4)
        XCTAssertLessThan(NSBitmapImageRep(cgImage: dimmed).colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!.greenComponent, corner.greenComponent)
        XCTAssertEqual(center.redComponent, 1, accuracy: 0.015)
        let transparent = try Imaging.frameWindow(window, style: .transparent, shadow: false)
        XCTAssertEqual(NSBitmapImageRep(cgImage: transparent).colorAt(x: 0, y: 0)!.alphaComponent, 0)
        let blue = try Imaging.frameWindow(window, style: .solid, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1), shadow: false)
        XCTAssertEqual(NSBitmapImageRep(cgImage: blue).colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!.blueComponent, 1, accuracy: 0.01)
    }
}
