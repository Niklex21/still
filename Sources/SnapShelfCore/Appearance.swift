import Foundation
import Carbon

public enum ScreenshotAction: String, Codable, CaseIterable, Identifiable {
    case none, dismiss, pin, edit, copy, save, upload, copyText, reveal, history, description, copySharing, trash
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .dismiss: return "Remove from Queue"
        case .pin: return "Pin to Screen"
        case .edit: return "Annotate"
        case .copySharing: return "Copy for Sharing"
        case .copy: return "Copy Full-Size Image"
        case .trash: return "Move Immediately to Trash"
        case .save: return "Export / Resize…"
        case .upload: return "Prepare for Upload"
        case .copyText: return "Copy Text"
        case .reveal: return "Show in Finder"
        case .history: return "History"
        case .description: return "Show Description"
        }
    }
    public var symbol: String {
        switch self {
        case .none: return "minus"
        case .trash: return "trash.fill"
        case .dismiss: return "xmark"
        case .pin: return "pin"
        case .edit: return "pencil"
        case .copySharing: return "square.and.arrow.up"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .upload: return "arrow.up.doc"
        case .copyText: return "text.viewfinder"
        case .reveal: return "folder"
        case .history: return "clock.arrow.circlepath"
        case .description: return "info.circle"
        }
    }
    /// A corner follows the same Option-modified chord that the global shortcut manager dispatches.
    public func displayed(holdingOption: Bool, bindings: ShortcutBindings) -> ScreenshotAction {
        guard holdingOption, let shortcutAction, let base = bindings[shortcutAction],
              base.modifiers & UInt32(optionKey) == 0 else { return self }
        let alternate = KeyboardShortcut(keyCode: base.keyCode, modifiers: base.modifiers | UInt32(optionKey))
        return Self.allCases.first { candidate in
            candidate.shortcutAction.map { bindings[$0] == alternate } ?? false
        } ?? self
    }

    public var shortcutAction: ShortcutAction? {
        switch self {
        case .trash: return .trashHovered
        case .dismiss: return .removeHovered
        case .pin: return .pinHovered
        case .edit: return .editHovered
        case .copySharing: return .copySharingHovered
        case .copy: return .copyHovered
        case .save: return .exportHovered
        case .upload: return .uploadHovered
        case .copyText: return .textHovered
        case .reveal: return .revealHovered
        case .description: return .descriptionHovered
        default: return nil
        }
    }
}

public enum ActionCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

public struct HoverControls: Codable, Equatable {
    public var topLeft: ScreenshotAction = .dismiss
    public var topRight: ScreenshotAction = .pin
    public var bottomLeft: ScreenshotAction = .edit
    public var bottomRight: ScreenshotAction = .copySharing
    public var buttonSize: Double = 32
    public var dimming: Double = 0.30
    public var hideDate: Bool = true
    public init() {}
    public subscript(_ corner: ActionCorner) -> ScreenshotAction {
        get { switch corner { case .topLeft: return topLeft; case .topRight: return topRight; case .bottomLeft: return bottomLeft; case .bottomRight: return bottomRight } }
        set { switch corner { case .topLeft: topLeft = newValue; case .topRight: topRight = newValue; case .bottomLeft: bottomLeft = newValue; case .bottomRight: bottomRight = newValue } }
    }
}

public enum FrameBackground: String, Codable, CaseIterable, Identifiable {
    case wallpaper, gradient, solid, image, transparent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .wallpaper: return "Desktop Wallpaper"
        case .gradient: return "Soft Gradient"
        case .solid: return "Solid Color"
        case .image: return "Custom Image"
        case .transparent: return "Transparent"
        }
    }
}

public struct WindowAppearance: Codable, Equatable {
    public var background: FrameBackground = .wallpaper
    public var colorHex = "9BAED1"
    public var padding: Double = 0.08
    public var shadow = true
    public var dimming: Double = 0.08
    public var imagePath: String?
    public init() {}
}
