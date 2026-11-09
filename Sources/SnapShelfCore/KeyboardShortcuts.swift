import Foundation
import Carbon

public enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case region, window, screen, scrolling, shelf, library
    case copyHovered, editHovered, pinHovered, exportHovered, reviewHovered, removeHovered, textHovered, revealHovered, uploadHovered, descriptionHovered
    case repeatRegion, delayedRegion, privateRegion, copySharingHovered, trashHovered
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .repeatRegion: return "Repeat Last Region"
        case .delayedRegion: return "Delayed Region Capture"
        case .privateRegion: return "Private Region Capture"
        case .copySharingHovered: return "Copy for Sharing"
        case .region: return "Capture Region"
        case .window: return "Capture Window"
        case .screen: return "Capture Full Screen"
        case .scrolling: return "Capture Scrolling Region"
        case .shelf: return "Toggle Shelf"
        case .library: return "Search Library"
        case .copyHovered: return "Copy Image"
        case .editHovered: return "Annotate"
        case .pinHovered: return "Pin / Unpin to Screen"
        case .exportHovered: return "Export / Resize…"
        case .reviewHovered: return "Mark as Viewed"
        case .removeHovered: return "Dismiss Preview / Delete in History"
        case .trashHovered: return "Move Screenshot to Trash…"
        case .textHovered: return "Copy Recognized Text"
        case .revealHovered: return "Show in Finder"
        case .uploadHovered: return "Prepare for Upload"
        case .descriptionHovered: return "Show Description"
        }
    }
    public var eventID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    public var isHoverAction: Bool { eventID > 6 && ![.repeatRegion, .delayedRegion, .privateRegion].contains(self) }
}

public struct KeyboardShortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    public var validationMessage: String? {
        guard keyCode <= 127, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) else { return "Choose a key with your modifiers." }
        let supported = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        guard modifiers & ~supported == 0 else { return "That modifier is not supported." }
        let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 || functionKeys.contains(keyCode) else { return "Include ⌘, ⌃, or ⌥, or use a function key." }
        return nil
    }
}

public struct ShortcutBindings: Codable, Equatable {
    public var version: Int? = 6
    public var shortcuts: [String: KeyboardShortcut]
    public init(shortcuts: [String: KeyboardShortcut] = [:]) { self.shortcuts = shortcuts }
    public subscript(_ action: ShortcutAction) -> KeyboardShortcut? {
        get { shortcuts[action.rawValue] }
        set { shortcuts[action.rawValue] = newValue }
    }
    public static func defaults(legacyPreset: String = "optionShift") -> Self {
        guard legacyPreset != "off" else { return Self() }
        var result = Self()
        let modifiers = legacyPreset == "controlOption" ? UInt32(controlKey | optionKey) : UInt32(optionKey | shiftKey)
        for (action, key) in zip(ShortcutAction.allCases, [18, 19, 20, 21, 29]) {
            result[action] = KeyboardShortcut(keyCode: UInt32(key), modifiers: modifiers)
        }
        result.addHoverDefaults()
        return result
    }
    public mutating func addHoverDefaults() {
        for (action, key, modifiers) in [
            (ShortcutAction.copyHovered, 8, cmdKey | optionKey), (.editHovered, 14, cmdKey),
            (.pinHovered, 35, cmdKey), (.exportHovered, 1, cmdKey),
            (.reviewHovered, 40, cmdKey), (.removeHovered, 51, cmdKey),
            (.textHovered, 8, cmdKey | shiftKey), (.revealHovered, 15, cmdKey)
        ] { self[action] = KeyboardShortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers)) }
        addUploadDefault()
        addDescriptionDefault()
        addSharingCopyDefault()
        addTrashDefault()
    }
    public mutating func addUploadDefault() {
        let shortcut = KeyboardShortcut(keyCode: 32, modifiers: UInt32(cmdKey))
        if conflict(for: shortcut, excluding: .uploadHovered) == nil { self[.uploadHovered] = shortcut }
        version = max(version ?? 1, 3)
    }
    public mutating func addDescriptionDefault() {
        let shortcut = KeyboardShortcut(keyCode: 34, modifiers: UInt32(cmdKey))
        if !shortcuts.isEmpty, conflict(for: shortcut, excluding: .descriptionHovered) == nil { self[.descriptionHovered] = shortcut }
        version = 4
    }
    public mutating func addSharingCopyDefault() {
        defer { version = max(version ?? 1, 5) }
        guard !shortcuts.isEmpty, self[.copySharingHovered] == nil else { return }
        let copy = KeyboardShortcut(keyCode: 8, modifiers: UInt32(cmdKey))
        let original = KeyboardShortcut(keyCode: 8, modifiers: UInt32(cmdKey | optionKey))
        if self[.copyHovered] == copy {
            guard conflict(for: original, excluding: .copyHovered) == nil else { return }
            self[.copyHovered] = original
        }
        if conflict(for: copy, excluding: .copySharingHovered) == nil { self[.copySharingHovered] = copy }
    }
    public mutating func addTrashDefault() {
        defer { version = max(version ?? 1, 6) }
        let shortcut = KeyboardShortcut(keyCode: 51, modifiers: UInt32(cmdKey | optionKey))
        if !shortcuts.isEmpty, self[.trashHovered] == nil, conflict(for: shortcut, excluding: .trashHovered) == nil {
            self[.trashHovered] = shortcut
        }
    }
    public func conflict(for shortcut: KeyboardShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self[$0] == shortcut }
    }
}
