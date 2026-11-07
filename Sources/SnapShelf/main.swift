import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import QuartzCore
import SnapShelfCore

enum CaptureMode: String, CaseIterable {
    case region, window, screen, scrolling
    var title: String { switch self { case .region: return "Capture Region"; case .window: return "Capture Window"; case .screen: return "Capture Full Screen"; case .scrolling: return "Capture Scrolling Region" } }
}

final class ShelfPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { if let onDismiss { onDismiss() } else { orderOut(sender) } }
    override func performClose(_ sender: Any?) { if let onDismiss { onDismiss() } else { orderOut(sender) } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    static var shared: AppDelegate!
    var store: CaptureStore!
    var status: NSStatusItem!
    var shelfPanel: NSPanel?
    let shelfInteraction = ShelfInteraction()
    var shelfExpandsLeft = false
    let shelfPositionMemory = ShelfPositionMemory()
    private var shelfResizeGeneration = 0
    var libraryWindow: NSWindow?
    var settingsWindow: NSWindow?
    var librarySearchField: NSSearchField?
    var editors: [UUID: EditorController] = [:]
    var descriptionWindows: [UUID: DescriptionController] = [:]
    var pinnedWindows: [UUID: PinnedCaptureController] = [:]
    var hoveredCaptureID: UUID?
    private var hoverSource = ""
    let shortcuts = GlobalShortcutManager()
    private let capturePreparation = DispatchQueue(label: "Still.PrepareCapture", qos: .userInitiated)
    var capturing = false
    var scrollSession: ScrollCapture?
    var selection: RegionSelector?
    var countdown: CaptureCountdown?
    var captureProcess: Process?
    var demo = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        demo = ProcessInfo.processInfo.arguments.contains("--demo")
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        let testRoot = ProcessInfo.processInfo.environment["STILL_DATA_DIR"]
        let root = testRoot.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still")
        do { store = try CaptureStore(root: root) }
        catch {
            let alert = NSAlert(); alert.messageText = "Still could not open your library"
            alert.informativeText = "Your files have been left untouched.\n\n\(error.localizedDescription)\n\nLibrary: \(root.path)"
            alert.addButton(withTitle: "Show Library Folder"); alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(root) }
            NSApp.terminate(nil); return
        }
        store.onImport = { [weak self] in if UserDefaults.standard.object(forKey: "autoShelf") as? Bool ?? true { self?.showShelf(manuallyOpened: false) } }
        shelfInteraction.onExpansion = { [weak self] in self?.expandShelf($0) }
        shelfInteraction.onViewed = { [weak self] in self?.store.markReviewed($0) }
        shelfInteraction.onHoverChanged = { [weak self] id in self?.updateHoverTarget(id, source: "shelf") }
        store.onPinsChanged = { [weak self] in self?.syncPinnedWindows() }
        configureMenu()
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .repeatRegion: self.capture(.region, repeatLast: true)
            case .delayedRegion: self.capture(.region, delay: self.store.preferences.captureDelay)
            case .privateRegion: self.capture(.region, privateCapture: true)
            case .region: self.capture(.region)
            case .window: self.capture(.window)
            case .screen: self.capture(.screen)
            case .scrolling: if let session = self.scrollSession { session.finish() } else { self.capture(.scrolling) }
            case .shelf: self.toggleShelf()
            case .library: self.searchAction()
            default: self.performHoveredAction(action)
            }
        }
        shortcuts.start()
        syncPinnedWindows()
        if !demo && testRoot == nil && (UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true) {
            do {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(true, forKey: "launchAtLogin")
            } catch {
                store.error = "Could not enable launch at login: \(error.localizedDescription). You can try again in Settings."
            }
        }
        if demo { seedDemo() }
        if demo { showLibrary(); showShelf(manuallyOpened: false) }
        else if !loginLaunch && !ProcessInfo.processInfo.arguments.contains("--background") && store.shelf.count > 0 { showShelf(manuallyOpened: false) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        scrollSession?.cancel()
        countdown?.finish(canceled: true)
        if captureProcess?.isRunning == true { captureProcess?.terminate() }
        store?.clearPrivateCaptures()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "still" else { store.importURLs([url]); continue }
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let params = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            switch url.host {
            case "text": if let id = params["id"].flatMap(UUID.init(uuidString:)), let item = store.captures.first(where: { $0.id == id }) { selectText(item) }
            case "export": if let id = params["id"].flatMap(UUID.init(uuidString:)), let item = store.captures.first(where: { $0.id == id }) { store.export(item) }
            case "capture": capture(CaptureMode(rawValue: params["mode"] ?? "region") ?? .region)
            case "search": store.query = params["q"] ?? ""; store.filter = "all"; showLibrary()
            case "edit": if let id = UUID(uuidString: params["id"] ?? ""), let item = store.captures.first(where: { $0.id == id }) { edit(item) }
            case "describe": if let id = UUID(uuidString: params["id"] ?? "") { showDescription(id) }
            case "consume": if let id = UUID(uuidString: params["id"] ?? "") { store.consume(id) }
            case "upload": if let id = UUID(uuidString: params["id"] ?? ""), let item = store.captures.first(where: { $0.id == id }) { store.prepareUpload(item); showShelf() }
            case "review": if let id = UUID(uuidString: params["id"] ?? "") { store.markReviewed(id) }
            case "shelf": if let id = UUID(uuidString: params["id"] ?? "") { store.update(id) { $0.onShelf = true } }; showShelf()
            default: showLibrary()
            }
        }
    }
    func configureMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); let app = NSMenu()
        app.addItem(withTitle: "About Still", action: #selector(about), keyEquivalent: "")
        app.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Close Still Windows", action: #selector(closeWindowsAction), keyEquivalent: "q")
        app.addItem(withTitle: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = app; main.addItem(appItem)
        let file = NSMenuItem(); file.title = "File"; let fileMenu = NSMenu(title: "File")
        for (index, mode) in CaptureMode.allCases.enumerated() { let item = NSMenuItem(title: mode.title, action: #selector(captureMenu(_:)), keyEquivalent: ""); item.tag = index; fileMenu.addItem(item) }
        addExtraCaptureItems(to: fileMenu)
        fileMenu.addItem(.separator()); fileMenu.addItem(withTitle: "Import Images…", action: #selector(importAction), keyEquivalent: "o")
        file.submenu = fileMenu; main.addItem(file)
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(pasteAction), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; main.addItem(edit)
        let window = NSMenuItem(); window.title = "Window"; let wm = NSMenu(title: "Window")
        wm.addItem(withTitle: "Library", action: #selector(libraryAction), keyEquivalent: "l")
        wm.addItem(withTitle: "Shelf", action: #selector(shelfAction), keyEquivalent: "")
        wm.addItem(withTitle: "Search", action: #selector(searchAction), keyEquivalent: "f")
        wm.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.submenu = wm; main.addItem(window); NSApp.mainMenu = main
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Still")
        let menu = NSMenu()
        for (index, mode) in CaptureMode.allCases.enumerated() { let item = NSMenuItem(title: mode.title, action: #selector(captureMenu(_:)), keyEquivalent: ""); item.tag = index; menu.addItem(item) }
        addExtraCaptureItems(to: menu)
        menu.addItem(.separator()); menu.addItem(withTitle: "Show Shelf", action: #selector(shelfAction), keyEquivalent: "")
        menu.addItem(withTitle: "Search Library…", action: #selector(searchAction), keyEquivalent: "")
        menu.addItem(withTitle: "Paste Image", action: #selector(pasteAction), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu
    }
    func addExtraCaptureItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(withTitle: "Repeat Last Region", action: #selector(repeatRegionAction), keyEquivalent: "")
        menu.addItem(withTitle: "Delayed Region…", action: #selector(delayedRegionAction), keyEquivalent: "")
        menu.addItem(withTitle: "Private Region…", action: #selector(privateRegionAction), keyEquivalent: "")
    }
    @objc func repeatRegionAction() { capture(.region, repeatLast: true) }
    @objc func delayedRegionAction() { capture(.region, delay: store.preferences.captureDelay) }
    @objc func privateRegionAction() { capture(.region, privateCapture: true) }
    @objc func captureMenu(_ sender: NSMenuItem) { capture(CaptureMode.allCases[sender.tag]) }
    @objc func importAction() { store.chooseImages() }
    @objc func pasteAction() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.paste(nil) } else { store.paste() }
    }
    @objc func closeWindowsAction() {
        dismissShelf()
        libraryWindow?.orderOut(nil); settingsWindow?.orderOut(nil)
        Array(editors.values).forEach { $0.window?.performClose(nil) }
        descriptionWindows.values.forEach { $0.window?.orderOut(nil) }
        Array(ExportController.windows).forEach { $0.window?.performClose(nil) }
        Array(WalkthroughController.windows).forEach { $0.window?.performClose(nil) }
    }
    @objc func shelfAction() { showShelf() }
    @objc func libraryAction() { showLibrary() }
    @objc func searchAction() { showLibrary(); libraryWindow?.makeFirstResponder(librarySearchField); librarySearchField?.selectText(nil) }
    @objc func settingsAction() { showSettings() }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = "Still \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1")"; alert.informativeText = "Capture. Keep. Make your point.\n\nA local screenshot workspace for your Mac.\nOpen source. No account or subscription."; alert.runModal()
    }
    var compactShelfSize: CGSize {
        let contents = store.compactShelf
        if store.copiedID != nil && store.shelf.isEmpty && store.feedbackImage != nil { return ShelfLayout.minimizedSize(recentCount: 1,hasOlder: false) }
        return ShelfLayout.minimizedSize(recentCount: contents.recent.count, hasOlder: !contents.older.isEmpty)
    }
    func clearHoverTarget() {
        hoveredCaptureID = nil; hoverSource = ""; shortcuts.setHoveredTargetActive(false)
    }
    func updateHoverTarget(_ id: UUID?, source: String) {
        guard id != nil || hoverSource == source else { return }
        hoveredCaptureID = id; hoverSource = id == nil ? "" : source
        shortcuts.setHoveredTargetActive(id != nil)
    }
    func performHoveredAction(_ action: ShortcutAction) {
        guard !capturing, scrollSession == nil, let id = hoveredCaptureID,
              let item = store.captures.first(where: { $0.id == id }) else { return }
        switch action {
        case .copySharingHovered: store.copyForSharing(item)
        case .copyHovered: store.copy(item)
        case .editHovered: edit(item)
        case .pinHovered: store.togglePin(id)
        case .exportHovered: store.export(item)
        case .reviewHovered: store.markReviewed(id)
        case .removeHovered:
            if hoverSource.hasPrefix("library:") || (hoverSource == "shelf" && shelfInteraction.manuallyOpened) {
                store.delete(item)
            } else {
                store.update(id) { $0.onShelf = false }
                shelfInteraction.pointer(over: id, inside: false)
            }
        case .textHovered: store.copyText(item)
        case .revealHovered: store.showInFinder(item)
        case .uploadHovered: store.prepareUpload(item)
        case .descriptionHovered: showDescription(id)
        default: break
        }
    }
    func performScreenshotAction(_ action: ScreenshotAction, item: Capture, interaction: ShelfInteraction?, pinned: Bool, inHistory: Bool = false) {
        switch action {
        case .none: break
        case .dismiss:
            if inHistory { store.delete(item) }
            else if pinned && item.isPinned { store.togglePin(item.id) } else { store.consume(item.id) }
        case .pin: store.togglePin(item.id)
        case .edit: edit(item)
        case .copySharing: store.copyForSharing(item)
        case .copy: store.copy(item)
        case .save: store.export(item)
        case .upload: store.prepareUpload(item)
        case .copyText: store.copyText(item)
        case .reveal: store.showInFinder(item)
        case .description: showDescription(item.id)
        case .history:
            showShelf(manuallyOpened: true)
        }
    }
    func showDescription(_ id: UUID) {
        clearHoverTarget()
        guard store.captures.contains(where: { $0.id == id }) else { return }
        if descriptionWindows[id] == nil {
            let controller = DescriptionController(id: id, store: store)
            controller.onClose = { [weak self] in self?.descriptionWindows.removeValue(forKey: id) }
            descriptionWindows[id] = controller
        }
        descriptionWindows[id]?.showWindow(nil)
        descriptionWindows[id]?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func syncPinnedWindows() {
        let pinned = store.captures.filter(\.isPinned).sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        let ids = Set(pinned.map(\.id))
        for id in Array(pinnedWindows.keys) where !ids.contains(id) {
            shelfInteraction.pointer(over: id, inside: false)
            pinnedWindows.removeValue(forKey: id)?.close()
        }
        for (depth, item) in pinned.enumerated() where pinnedWindows[item.id] == nil {
            let controller = PinnedCaptureController(item: item, store: store, offset: depth, onHover: { [weak self] id in
                self?.updateHoverTarget(id, source: item.id.uuidString)
            })
            controller.onMove = { [weak self] frame in self?.pinMoved(item.id, frame: frame) }
            pinnedWindows[item.id] = controller
            controller.showWindow(nil)
        }
        let anchor = PanelPlacement.savedPoint("pinAnchor.v2")
        for (depth, item) in pinned.enumerated().reversed() {
            pinnedWindows[item.id]?.place(anchor: anchor, depth: depth)
            pinnedWindows[item.id]?.window?.orderFrontRegardless()
        }
    }
    func pinMoved(_ id: UUID, frame: CGRect) {
        let anchor = CGPoint(x: frame.maxX, y: frame.minY)
        PanelPlacement.save(anchor, key: "pinAnchor.v2")
        let others = store.captures.filter { $0.isPinned && $0.id != id }.sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        for (depth, item) in others.enumerated() { pinnedWindows[item.id]?.place(anchor: anchor, depth: depth + 1) }
    }
    func showShelf(manuallyOpened: Bool = true) {
        let wasVisible = shelfPanel?.isVisible == true
        if shelfPanel == nil {
            let origin = PanelPlacement.savedPoint("shelfOrigin.v2")
            let screen = PanelPlacement.screen(containing: origin)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let panel = ShelfPanel(contentRect: PanelPlacement.shelfFrame(size: compactShelfSize, screen: screen, origin: origin), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Still Shelf"
            panel.onDismiss = { [weak self] in self?.dismissShelf() }
            panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.contentView = makeShelfSurface(store: store, interaction: shelfInteraction)
            panel.delegate = shelfPositionMemory
            shelfPanel = panel
        }
        guard let panel = shelfPanel else { return }
        if !wasVisible {
            // Set the final state, size and backdrop before the first visible
            // frame. Ordering a compact panel front first caused the flash.
            shelfInteraction.present(expanded: manuallyOpened, manuallyOpened: manuallyOpened)
            let origin = PanelPlacement.savedPoint("shelfOrigin.v2") ?? panel.frame.origin
            let screen = PanelPlacement.screen(containing: origin)?.visibleFrame ?? panel.frame
            let size = ShelfLayout.panelSize(expanded: manuallyOpened, compact: compactShelfSize, current: compactShelfSize, shelfCount: shelfInteraction.manuallyOpened ? store.history.count : store.shelf.count, availableWidth: screen.width - 20)
            shelfPositionMemory.applyingLayout = true
            panel.hasShadow = manuallyOpened
            panel.setFrame(PanelPlacement.shelfFrame(size: size, screen: screen, origin: origin), display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            shelfPositionMemory.applyingLayout = false
            panel.orderFrontRegardless()
        } else if manuallyOpened {
            shelfInteraction.present(expanded: true, manuallyOpened: true)
        }
    }
    func dismissShelf() {
        store.dismissCurrentPreviews()
        hideShelf()
    }
    func hideShelf() {
        shelfPanel?.orderOut(nil)
        shelfInteraction.dismiss()
    }
    func hideShelfIfReviewed(afterAction: Bool = false) {
        guard store.copiedID == nil, shelfInteraction.shouldHide(queueCount: store.shelf.count, pendingCount: store.pendingCount, afterAction: afterAction) else { return }
        hideShelf()
    }
    func expandShelf(_ expanded: Bool) {
        guard let panel = shelfPanel, panel.isVisible else { return }
        if store.copiedID != nil && store.shelf.isEmpty && !shelfInteraction.manuallyOpened { return }
        if store.copiedID == nil && shelfInteraction.shouldHide(queueCount: store.shelf.count, pendingCount: store.pendingCount) {
            hideShelf()
            return
        }
        panel.hasShadow = expanded
        let old = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? old
        let size = ShelfLayout.panelSize(expanded: expanded, compact: compactShelfSize, current: old.size, shelfCount: shelfInteraction.manuallyOpened ? store.history.count : store.shelf.count, availableWidth: screen.width - 20)
        let width = size.width, height = size.height
        // Keep the panel within the current display, including when it is near the right edge.
        if expanded { shelfExpandsLeft = old.minX + width > screen.maxX }
        let desiredX = expanded && shelfExpandsLeft ? old.maxX - width : (!expanded && shelfExpandsLeft ? old.maxX - width : old.minX)
        let x = max(screen.minX, min(desiredX, screen.maxX - width))
        let y = max(screen.minY, min(old.minY, screen.maxY - height))
        let target = NSRect(x: x, y: y, width: width, height: height)
        guard target != old else { return }
        shelfResizeGeneration += 1
        let generation = shelfResizeGeneration
        shelfInteraction.beginResize()
        shelfPositionMemory.applyingLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, generation == self.shelfResizeGeneration else { return }
            self.shelfPositionMemory.applyingLayout = false
            self.shelfInteraction.finishResize(pointerInside: panel.frame.contains(NSEvent.mouseLocation))
        }
    }
    func toggleShelf() {
        if shelfPanel?.isVisible == true { dismissShelf() } else { showShelf() }
    }
    func showLibrary() {
        if libraryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Still"; window.minSize = NSSize(width: 720, height: 480)
            let toolbar = NSToolbar(identifier: "Still.Library"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
            window.toolbar = toolbar; window.toolbarStyle = .unified
            let host = NSHostingView(rootView: LibraryView(store: store)); host.sizingOptions = []; window.contentView = host; window.center()
            window.isReleasedWhenClosed = false; window.setFrameAutosaveName("Still.library"); libraryWindow = window
        }
        librarySearchField?.stringValue = store.query
        libraryWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("sidebar"), .flexibleSpace, .init("capture"), .init("import"), .init("search")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search screenshots"
            item.searchField.target = self; item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            librarySearchField = item.searchField
            return item
        }
        if id.rawValue == "capture" {
            let item = NSMenuToolbarItem(itemIdentifier: id); item.label = "Capture"; item.toolTip = "Capture screenshot"
            item.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Capture screenshot")
            let menu = NSMenu()
            for (index, mode) in CaptureMode.allCases.enumerated() { let entry = NSMenuItem(title: mode.title, action: #selector(captureMenu(_:)), keyEquivalent: ""); entry.tag = index; entry.target = self; menu.addItem(entry) }
            item.menu = menu; item.showsIndicator = true; item.isBordered = true
            return item
        }
        let item = NSToolbarItem(itemIdentifier: id); item.target = self; item.isBordered = true
        if id.rawValue == "sidebar" {
            item.label = "Sidebar"; item.toolTip = "Toggle sidebar"; item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar"); item.action = #selector(toggleSidebar)
        } else {
            item.label = "Import"; item.toolTip = "Import images"; item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import images"); item.action = #selector(importAction)
        }
        return item
    }
    @objc func searchChanged(_ sender: NSSearchField) { store.query = sender.stringValue }
    @objc func toggleSidebar() { store.sidebarVisible.toggle() }
    func selectText(_ item: Capture) {
        edit(item)
        if let editor = editors[item.id] { editor.model.tool = .extract; editor.model.canvas.scanText() }
    }
    func edit(_ item: Capture) {
        clearHoverTarget()
        if let existing = editors[item.id] { store.consume(item.id); existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        do { let editor = try EditorController(item: item, store: store); store.consume(item.id); editors[item.id] = editor; editor.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
        catch { store.error = error.localizedDescription; showLibrary() }
    }
    func rename(_ item: Capture) {
        let alert = NSAlert(); alert.messageText = "Rename screenshot"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: item.title); field.frame = NSRect(x: 0, y: 0, width: 340, height: 24); alert.accessoryView = field; alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { store.update(item.id) { $0.title = value } } }
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Still Settings"; window.contentView = NSHostingView(rootView: SettingsView(store: store, shortcuts: shortcuts, preferences: store.preferences)); window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    var captureScreens: [CGRect] {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { CGRect(x: $0.frame.minX,y: mainTop - $0.frame.maxY,width: $0.frame.width,height: $0.frame.height) }
    }
    func capture(_ mode: CaptureMode, repeatLast: Bool = false, delay: Int = 0, privateCapture: Bool = false) {
        guard !capturing, scrollSession == nil else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert(); alert.messageText = "Allow Still to capture your screen"
            alert.informativeText = "Enable Still in System Settings → Privacy & Security → Screen & System Audio Recording. macOS may ask you to reopen the app afterward."
            alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }; return
        }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let sourceWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let sourceTitle = sourceWindows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == sourceApp?.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowName as String] as? String
        var metadata = CaptureMetadata(application: privateCapture ? nil : sourceApp?.localizedName, bundleIdentifier: privateCapture ? nil : sourceApp?.bundleIdentifier, windowTitle: privateCapture ? nil : sourceTitle, kind: privateCapture ? "Private" : mode.rawValue.capitalized)
        metadata.pixelScale = Double(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        capturing = true; clearHoverTarget()
        let visible = NSApp.windows.filter { $0.isVisible && $0 != status.button?.window }
        visible.forEach { $0.orderOut(nil) }
        func restore() { self.capturing = false; visible.forEach { $0.orderFront(nil) }; sourceApp?.activate(options: []) }
        func run(region: CGRect?) {
            func execute() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-\(UUID()).png")
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                var arguments = ["-x","-t","png"]
                if let region { arguments.append(CaptureRegion.arguments(region)) }
                else if mode == .screen { arguments.append("-m") }
                else if mode == .window { arguments += ["-i","-w","-o"] }
                arguments.append(url.path); process.arguments = arguments; self.captureProcess = process
                process.terminationHandler = { [weak self] child in DispatchQueue.main.async {
                    guard let self else { try? FileManager.default.removeItem(at: url); return }
                    self.captureProcess = nil; self.capturing = false
                    self.pinnedWindows.values.forEach { $0.window?.orderFrontRegardless() }
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard child.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else { restore(); return }
                    do {
                        let image = try Imaging.load(url)
                        // Derive scale from actual output: repeat-region may run while
                        // the pointer is on a different display.
                        if let region { metadata.pixelScale = Double(image.width) / max(1,Double(region.width.rounded())) }
                        else if mode == .screen, let primary = NSScreen.screens.first { metadata.pixelScale = Double(image.width) / max(1,Double(primary.frame.width)) }
                        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                        let captured = try mode == .window ? self.store.preferences.frameWindow(image, screen: screen) : image
                        let png = try mode == .window ? nil : Data(contentsOf: url)
                        self.enqueueCapture(captured,metadata: metadata,privateCapture: privateCapture,encodedPNG: png)
                    } catch { self.store.error = error.localizedDescription; restore(); self.showLibrary() }
                } }
                do { try process.run() } catch { self.captureProcess = nil; self.store.error = error.localizedDescription; restore() }
            }
            if delay > 0 {
                self.countdown = CaptureCountdown(seconds: delay, screen: NSScreen.main) { [weak self] canceled in
                    self?.countdown = nil
                    if canceled { restore() } else { execute() }
                }
                self.countdown?.start()
            } else { execute() }
        }
        if mode == .region || mode == .scrolling {
            if repeatLast, let region = store.preferences.lastRegion, CaptureRegion.valid(region, within: captureScreens) { run(region: region); return }
            selection = RegionSelector(instructions: mode == .scrolling ? "Select scrolling content · Drag a region · Esc to cancel" : privateCapture ? "Private capture · Drag a region · Esc to cancel" : "Capture region · Drag to select · Esc to cancel", minimumSize: mode == .scrolling ? 120 : 2) { [weak self] region in
                guard let self else { return }; let frozen = self.selection?.selectedImage; self.selection = nil
                guard let region, CaptureRegion.valid(region, within: self.captureScreens) else { restore(); return }
                sourceApp?.activate(options: [])
                let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
                if let display = NSScreen.screens.first(where: { CGRect(x: $0.frame.minX,y: mainTop-$0.frame.maxY,width: $0.frame.width,height: $0.frame.height).contains(CGPoint(x: region.midX,y: region.midY)) }) { metadata.pixelScale = Double(display.backingScaleFactor) }
                if mode == .scrolling {
                    self.capturing = false
                    self.scrollSession = ScrollCapture(rect: region, store: self.store, metadata: metadata) {
                        self.scrollSession = nil; self.pinnedWindows.values.forEach { $0.window?.orderFrontRegardless() }
                    }
                    self.scrollSession?.start()
                } else {
                    if !privateCapture { self.store.preferences.lastRegion = region }
                    if delay == 0 {
                        guard let frozen else { self.store.error = "The screen could not be frozen. Try capturing the area again."; restore(); return }
                        metadata.pixelScale = Double(frozen.width) / max(1,Double(region.width))
                        self.capturing = false; self.pinnedWindows.values.forEach { $0.window?.orderFrontRegardless() }
                        self.enqueueCapture(frozen,metadata: metadata,privateCapture: privateCapture)
                    } else { run(region: region) }
                }
            }
            selection?.start()
        } else { run(region: nil) }
    }
    private func enqueueCapture(_ image: CGImage, metadata: CaptureMetadata, privateCapture: Bool, encodedPNG: Data? = nil) {
        capturePreparation.async { [weak self] in
            let prepared = Result { (try encodedPNG ?? Imaging.png(image), try Imaging.thumbnail(image)) }
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    let (png,thumbnail) = try prepared.get()
                    try self.store.add(image,metadata: metadata,privateCapture: privateCapture,encodedPNG: png,thumbnail: thumbnail)
                } catch { self.store.error = error.localizedDescription; self.showLibrary() }
            }
        }
    }
    func seedDemo() {
        guard store.captures.isEmpty else { return }
        for (title, text, color) in [("Project notes", "LAUNCH CHECKLIST\nCapture the little things.\nMake room for your next idea.", NSColor.systemMint), ("Design exploration", "LESS FRICTION.\nMORE FLOW.\nA workspace for everything you see.", NSColor.systemIndigo), ("A useful detail", "Your screenshots, together.\nDrag. Annotate. Find again.", NSColor.systemOrange)] {
            let image = NSImage(size: NSSize(width: 1000, height: 640)); image.lockFocus()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1000, height: 640).fill()
            color.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 880, height: 520), xRadius: 30, yRadius: 30).fill()
            (text as NSString).draw(in: NSRect(x: 110, y: 150, width: 790, height: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 45, weight: .semibold), .foregroundColor: NSColor.white])
            image.unlockFocus(); if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { _ = try? store.add(cg, title: title) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var shortcuts: GlobalShortcutManager
    @ObservedObject var preferences: CapturePreferences
    @AppStorage("autoShelf") var autoShelf = true
    @State var login = SMAppService.mainApp.status == .enabled
    @State var message = ""
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            HoverControlsSettings(preferences: preferences).tabItem { Label("Controls", systemImage: "cursorarrow.click") }
            WindowAppearanceSettings(preferences: preferences, root: store.disk.root).tabItem { Label("Background", systemImage: "photo") }
            PrivacySettings(store: store, preferences: preferences).tabItem { Label("Privacy", systemImage: "lock") }
            VisualSearchSettings(store: store, preferences: preferences).tabItem { Label("Search", systemImage: "sparkle.magnifyingglass") }
            ShortcutSettingsView(manager: shortcuts).tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }.padding(8).frame(width: 620, height: 560)
    }
    var general: some View {
        Form {
            Section("Your workflow") {
                Toggle("Show shelf after every capture", isOn: $autoShelf)
                Picker("Capture countdown", selection: $preferences.captureDelay) { Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10) }
                Text("Still runs in the menu bar when its windows are closed.").font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $login).onChange(of: login) { _, enabled in UserDefaults.standard.set(enabled, forKey: "launchAtLogin"); do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { message = error.localizedDescription; login = SMAppService.mainApp.status == .enabled } }
            }
            Section("Raycast") {
                Text("Search “Search Screenshots” in Raycast.").font(.callout).foregroundStyle(.secondary)
                Button("Open Raycast Extension Folder") { if let url = Bundle.main.resourceURL?.appendingPathComponent("Raycast") { NSWorkspace.shared.open(url) } }
            }
            Section("Local library") {
                Button("Open Library Folder") { NSWorkspace.shared.open(store.disk.root) }
                Text("All screenshots and recognized text stay on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).foregroundStyle(.orange) }
        }.formStyle(.grouped)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--search-json"), CommandLine.arguments.indices.contains(index + 1) {
    do {
        let root = ProcessInfo.processInfo.environment["STILL_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Still")
        let items = try LibraryDisk(root: root).load()
        let results = SemanticSearch().rank(items, query: CommandLine.arguments[index + 1])
        let data = try JSONEncoder().encode(results.map { $0.id.uuidString })
        FileHandle.standardOutput.write(data); exit(0)
    } catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
}
let application = NSApplication.shared
if ProcessInfo.processInfo.arguments.contains("--visual-search-self-test") || ProcessInfo.processInfo.arguments.contains("--visual-model-test") {
    Task { @MainActor in
        do {
            if ProcessInfo.processInfo.arguments.contains("--visual-model-test") { try await VisualSearchSelfTest.runModel() }
            else { try await VisualSearchSelfTest.run() }
            exit(0)
        } catch { print("VISUAL SELF-TEST FAILED: \(error)"); exit(1) }
    }
    application.run()
    exit(0)
}
if ProcessInfo.processInfo.arguments.contains("--self-test") {
    do { try SelfTest.run(); exit(0) } catch { print("SELF-TEST FAILED: \(error)"); exit(1) }
}
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
