import AppKit
import SwiftUI
import Carbon
import SnapShelfCore

private typealias CaptureShortcut = SnapShelfCore.KeyboardShortcut

final class GlobalShortcutManager: ObservableObject {
    private static let settingsKey = "customShortcuts.v1"
    @Published private(set) var bindings: ShortcutBindings
    @Published private(set) var errors: [ShortcutAction: String] = [:]
    @Published private(set) var recording: ShortcutAction?
    private let defaults: UserDefaults
    private var registered: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var hoveredTargetActive = false
    var onAction: ((ShortcutAction) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey), var saved = try? JSONDecoder().decode(ShortcutBindings.self, from: data) {
            let previous = saved
            if (saved.version ?? 1) < 4 {
                if (saved.version ?? 1) < 3 {
                    if (saved.version ?? 1) < 2 { saved.addHoverDefaults() }
                    else { saved.addUploadDefault() }
                }
                saved.addDescriptionDefault()
            }
            if (saved.version ?? 1) < 5 { saved.addSharingCopyDefault() }
            if (saved.version ?? 1) < 6 { saved.addTrashDefault() }
            if saved != previous, let migrated = try? JSONEncoder().encode(saved) { defaults.set(migrated, forKey: Self.settingsKey) }
            bindings = saved
        } else { bindings = .defaults(legacyPreset: defaults.string(forKey: "hotkeyPreset") ?? "optionShift") }
    }
    deinit {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    func start() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x5354494C,
                  let action = ShortcutAction.allCases.first(where: { $0.eventID == id.id }) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak manager] in if manager?.recording == nil { manager?.onAction?(action) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if result != noErr { errors[.region] = "Could not start global shortcuts (\(result))."; return }
        registerMissing()
    }
    private func register(_ shortcut: CaptureShortcut, for action: ShortcutAction) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x5354494C, id: action.eventID), GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }
    private func registerMissing() {
        guard eventHandler != nil else { return }
        for action in ShortcutAction.allCases where registered[action] == nil {
            guard !action.isHoverAction || hoveredTargetActive else { continue }
            guard let shortcut = bindings[action] else { continue }
            if let message = shortcut.validationMessage { errors[action] = message; continue }
            if let ref = register(shortcut, for: action) { registered[action] = ref; errors[action] = nil }
            else { errors[action] = "Shortcut unavailable. It may be used by macOS or another app." }
        }
    }
    func setHoveredTargetActive(_ active: Bool) {
        guard active != hoveredTargetActive else { return }
        hoveredTargetActive = active
        if active && recording == nil { registerMissing() }
        else if !active {
            for action in ShortcutAction.allCases where action.isHoverAction {
                if let ref = registered.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
            }
        }
    }
    func beginRecording(_ action: ShortcutAction) {
        // Prevent existing capture shortcuts from firing while recording their replacements.
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        recording = action
        errors[action] = nil
    }
    func cancelRecording() {
        recording = nil
        registerMissing()
    }
    @discardableResult func assign(_ shortcut: SnapShelfCore.KeyboardShortcut?, to action: ShortcutAction) -> Bool {
        if let shortcut {
            if let message = shortcut.validationMessage { errors[action] = message; return false }
            if let conflict = bindings.conflict(for: shortcut, excluding: action) { errors[action] = "Already assigned to \(conflict.title)."; return false }
        }
        if let previous = registered.removeValue(forKey: action) { UnregisterEventHotKey(previous) }
        if let shortcut, eventHandler != nil, !action.isHoverAction || hoveredTargetActive {
            guard let ref = register(shortcut, for: action) else {
                errors[action] = "Shortcut unavailable. Try another key combination."
                if recording == nil { registerMissing() }
                return false
            }
            registered[action] = ref
        }
        bindings[action] = shortcut
        errors[action] = nil
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.settingsKey) }
        recording = nil
        registerMissing()
        return true
    }
    func restoreDefaults() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        recording = nil; errors = [:]; bindings = .defaults()
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.settingsKey) }
        registerMissing()
    }
}

extension SnapShelfCore.KeyboardShortcut {
    init(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
    var displayName: String {
        var result = ""
        for (mask, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] where modifiers & UInt32(mask) != 0 { result += symbol }
        let names: [UInt32: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "Clear", 76: "⌤", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = names[keyCode] { return result + name }
        let functionCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if let index = functionCodes.firstIndex(of: keyCode) { return result + "F\(index + 1)" }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0, length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, buffer.count, &length, &buffer) == noErr, length > 0 {
                return result + String(utf16CodeUnits: buffer, count: length).uppercased()
            }
        }
        return result + "Key \(keyCode)"
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var manager: GlobalShortcutManager
    let action: ShortcutAction
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.manager = manager; button.shortcutAction = action
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(RecorderButton.record)
        button.setAccessibilityLabel("Shortcut for \(action.title)")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = manager.recording == action ? "Press shortcut…" : (manager.bindings[action]?.displayName ?? "Record Shortcut")
        button.toolTip = manager.recording == action ? "Escape to cancel · Delete to clear" : "Click to record a shortcut"
        if manager.recording != action { button.removeMonitor() }
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.cancel() }

    final class RecorderButton: NSButton {
        weak var manager: GlobalShortcutManager?
        var shortcutAction: ShortcutAction = .region
        var monitor: Any?
        var windowObserver: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }
        @objc func record() {
            guard let manager else { return }
            manager.beginRecording(shortcutAction)
            window?.makeFirstResponder(self)
            removeMonitor()
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.cancel() }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let manager = self.manager, manager.recording == self.shortcutAction else { return event }
                let shortcut = CaptureShortcut(event: event)
                if shortcut.modifiers == 0 && event.keyCode == 53 { self.cancel(); return nil }
                if shortcut.modifiers == 0 && event.keyCode == 48 { self.cancel(); return event }
                if shortcut.modifiers == 0 && (event.keyCode == 51 || event.keyCode == 117) {
                    if manager.assign(nil, to: self.shortcutAction) { self.removeMonitor() }
                } else if manager.assign(shortcut, to: self.shortcutAction) { self.removeMonitor() }
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
        }
        func cancel() {
            removeMonitor()
            if manager?.recording == shortcutAction { manager?.cancelRecording() }
        }
        override func resignFirstResponder() -> Bool { cancel(); return super.resignFirstResponder() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { cancel() } }
        deinit { removeMonitor() }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var manager: GlobalShortcutManager
    var body: some View {
        Form {
            ForEach([false, true], id: \.self) { hoverActions in
                Section {
                ForEach(ShortcutAction.allCases.filter { $0.isHoverAction == hoverActions }) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(manager: manager, action: action).frame(width: 150, height: 28)
                            Button { manager.cancelRecording(); _ = manager.assign(nil, to: action) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).disabled(manager.bindings[action] == nil)
                                .help("Clear shortcut").accessibilityLabel("Clear shortcut for \(action.title)")
                        }
                        if let error = manager.errors[action] { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
                } header: { Text(hoverActions ? "While hovering a screenshot" : "Global shortcuts") }
                footer: { Text(hoverActions ? "Active only while the pointer is over a screenshot or pinned image." : "Click a shortcut and press your keys. Escape cancels; Delete clears.") }
            }
            Button("Restore Defaults") { manager.restoreDefaults() }
        }.formStyle(.grouped).onDisappear { manager.cancelRecording() }
    }
}
