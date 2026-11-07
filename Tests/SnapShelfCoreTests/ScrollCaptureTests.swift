import XCTest
import Carbon
@testable import SnapShelfCore

final class ScrollCaptureTests: XCTestCase {
    func testSidePreviewFitsOutsideSelectedAreaOnEitherSide() {
        let screen = CGRect(x: -1440,y: 0,width: 1440,height: 900)
        for region in [CGRect(x: -1380,y: 100,width: 700,height: 600),CGRect(x: -820,y: 100,width: 700,height: 600)] {
            let panel = ScrollCaptureLayout.previewFrame(region: region,screen: screen)
            XCTAssertTrue(screen.contains(panel)); XCTAssertFalse(panel.intersects(region))
        }
        let full = ScrollCaptureLayout.previewFrame(region: screen,screen: screen)
        XCTAssertTrue(screen.contains(full)); XCTAssertGreaterThan(full.height,200)
    }
    func testDisplayAndAppCoordinatesPreserveNegativeScreenOrigins() {
        let display = CGRect(x: -1440,y: -200,width: 1440,height: 900), region = CGRect(x: -1300,y: -100,width: 500,height: 600)
        XCTAssertEqual(ScrollCaptureLayout.sourceRect(region: region,display: display),CGRect(x: 140,y: 100,width: 500,height: 600))
        XCTAssertEqual(ScrollCaptureLayout.appRect(region,mainTop: 900),CGRect(x: -1300,y: 400,width: 500,height: 600))
    }
    func testFrozenCropUsesSelectedSnapshotAndRetinaPixelCoordinates() {
        let local = CGRect(x: 10,y: 200,width: 120,height: 100)
        let crop = CaptureRegion.frozenCrop(local,screen: CGSize(width: 400,height: 300),pixels: CGSize(width: 800,height: 600))
        XCTAssertEqual(crop,CGRect(x: 20,y: 0,width: 240,height: 200))
        let edge = CaptureRegion.frozenCrop(CGRect(x: -10,y: -10,width: 30,height: 30),screen: CGSize(width: 100,height: 100),pixels: CGSize(width: 200,height: 200))
        XCTAssertEqual(edge,CGRect(x: 0,y: 160,width: 40,height: 40))
    }
    func testSharingMigrationMovesOnlyTheOrdinaryCopyDefault() {
        var old = ShortcutBindings(); old.version = 4
        old[.copyHovered] = KeyboardShortcut(keyCode: 8,modifiers: UInt32(cmdKey))
        let area = KeyboardShortcut(keyCode: 1,modifiers: UInt32(cmdKey | shiftKey)); old[.region] = area
        old.addSharingCopyDefault()
        XCTAssertEqual(old[.copySharingHovered],KeyboardShortcut(keyCode: 8,modifiers: UInt32(cmdKey)))
        XCTAssertEqual(old[.copyHovered],KeyboardShortcut(keyCode: 8,modifiers: UInt32(cmdKey | optionKey)))
        XCTAssertEqual(old[.region],area); XCTAssertEqual(old.version,5)
        var off = ShortcutBindings.defaults(legacyPreset: "off"); off.addSharingCopyDefault(); XCTAssertTrue(off.shortcuts.isEmpty)
        var custom = old; custom[.copySharingHovered] = KeyboardShortcut(keyCode: 15,modifiers: UInt32(cmdKey)); custom.addSharingCopyDefault()
        XCTAssertEqual(custom[.copySharingHovered]?.keyCode,15)
        var conflict = ShortcutBindings(); conflict[.pinHovered] = KeyboardShortcut(keyCode: 8,modifiers: UInt32(cmdKey)); conflict.addSharingCopyDefault()
        XCTAssertNil(conflict[.copySharingHovered]); XCTAssertNotNil(conflict[.pinHovered])
    }
}
