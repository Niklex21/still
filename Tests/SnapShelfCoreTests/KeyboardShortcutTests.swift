import XCTest
import Carbon
@testable import SnapShelfCore

final class KeyboardShortcutTests: XCTestCase {
    func testLegacyPresetsRetainTheirAssignments() {
        let optionShift = ShortcutBindings.defaults()
        XCTAssertEqual(optionShift[.region], KeyboardShortcut(keyCode: 18, modifiers: UInt32(optionKey | shiftKey)))
        XCTAssertEqual(optionShift[.shelf]?.keyCode, 29)
        XCTAssertNil(optionShift[.library])
        let controlOption = ShortcutBindings.defaults(legacyPreset: "controlOption")
        XCTAssertEqual(controlOption[.window]?.modifiers, UInt32(controlKey | optionKey))
        XCTAssertTrue(ShortcutBindings.defaults(legacyPreset: "off").shortcuts.isEmpty)
    }
    func testIndependentCustomBindingsAndDisabledActionsSurviveEncoding() throws {
        var settings = ShortcutBindings.defaults()
        let custom = KeyboardShortcut(keyCode: 15, modifiers: UInt32(cmdKey | controlKey | shiftKey))
        settings[.region] = custom
        settings[.window] = nil
        settings[.library] = KeyboardShortcut(keyCode: 37, modifiers: UInt32(optionKey | cmdKey))
        let reloaded = try JSONDecoder().decode(ShortcutBindings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(reloaded[.region], custom)
        XCTAssertNil(reloaded[.window])
        XCTAssertNotNil(reloaded[.library])
        XCTAssertEqual(reloaded[.scrolling], ShortcutBindings.defaults()[.scrolling])
    }
    func testHoverDefaultsAndMigrationPreserveCustomCaptureKeys() throws {
        let data = Data(#"{"shortcuts":{"region":{"keyCode":1,"modifiers":768}}}"#.utf8)
        var old = try JSONDecoder().decode(ShortcutBindings.self, from: data)
        XCTAssertNil(old.version)
        let region = old[.region]
        old.addHoverDefaults()
        XCTAssertEqual(old[.region], region)
        XCTAssertEqual(old[.copyHovered], KeyboardShortcut(keyCode: 8, modifiers: UInt32(cmdKey | optionKey)))
        XCTAssertEqual(old[.pinHovered], KeyboardShortcut(keyCode: 35, modifiers: UInt32(cmdKey)))
        XCTAssertTrue(ShortcutAction.pinHovered.isHoverAction)
        XCTAssertFalse(ShortcutAction.shelf.isHoverAction)
        old[.copyHovered] = nil
        let saved = try JSONDecoder().decode(ShortcutBindings.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(saved.version, 6)
        XCTAssertNil(saved[.copyHovered])
        XCTAssertEqual(ShortcutAction.library.eventID, 6)
    }
    func testTrashShortcutPreservesExistingBindingsAndDisabledPresets() {
        let shortcut = KeyboardShortcut(keyCode: 51, modifiers: UInt32(cmdKey | optionKey))
        XCTAssertEqual(ShortcutBindings.defaults()[.trashHovered], shortcut)
        var custom = ShortcutBindings(shortcuts: [ShortcutAction.editHovered.rawValue: shortcut])
        custom.addTrashDefault()
        XCTAssertNil(custom[.trashHovered])
        var off = ShortcutBindings()
        off.addTrashDefault()
        XCTAssertTrue(off.shortcuts.isEmpty)
    }
    func testDuplicatesExcludeTheActionBeingEdited() throws {
        let settings = ShortcutBindings.defaults()
        let region = try XCTUnwrap(settings[.region])
        XCTAssertEqual(settings.conflict(for: region, excluding: .window), .region)
        XCTAssertNil(settings.conflict(for: region, excluding: .region))
    }
    func testDescriptionShortcutMigrationKeepsCustomBindingsAndDisabledPresets() throws {
        var settings = ShortcutBindings.defaults()
        XCTAssertEqual(settings[.descriptionHovered], KeyboardShortcut(keyCode: 34, modifiers: UInt32(cmdKey)))
        settings.version = 3
        settings[.descriptionHovered] = nil
        let customRegion = KeyboardShortcut(keyCode: 1, modifiers: UInt32(cmdKey | shiftKey))
        settings[.region] = customRegion
        settings.addDescriptionDefault()
        XCTAssertEqual(settings.version, 4)
        XCTAssertEqual(settings[.region], customRegion)
        XCTAssertNotNil(settings[.descriptionHovered])
        settings[.descriptionHovered] = nil
        settings[.editHovered] = KeyboardShortcut(keyCode: 34, modifiers: UInt32(cmdKey))
        settings.addDescriptionDefault()
        XCTAssertNil(settings[.descriptionHovered], "A new hover action cannot take an existing custom shortcut")
        var disabled = ShortcutBindings.defaults(legacyPreset: "off")
        disabled.version = 3; disabled.addDescriptionDefault()
        XCTAssertTrue(disabled.shortcuts.isEmpty)
        XCTAssertEqual(ShortcutAction.uploadHovered.eventID, 15)
        XCTAssertEqual(ShortcutAction.descriptionHovered.eventID, 16)
    }
    func testOrdinaryTypingAndModifierOnlyKeysAreNotGlobalShortcuts() {
        XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: 0).validationMessage)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: UInt32(shiftKey)).validationMessage)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 55, modifiers: UInt32(cmdKey)).validationMessage)
        XCTAssertNil(KeyboardShortcut(keyCode: 0, modifiers: UInt32(cmdKey | shiftKey)).validationMessage)
        XCTAssertNil(KeyboardShortcut(keyCode: 122, modifiers: 0).validationMessage)
        XCTAssertNil(KeyboardShortcut(keyCode: 123, modifiers: UInt32(controlKey | optionKey)).validationMessage)
    }
}
