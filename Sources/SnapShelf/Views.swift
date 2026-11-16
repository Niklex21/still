import Carbon
import SwiftUI
import SnapShelfCore

let accent = Color.accentColor

func makeShelfSurface(store: CaptureStore, interaction: ShelfInteraction) -> NSView {
    let host = ShelfHostingView(store: store, interaction: interaction)
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: ShelfLayout.minimizedSize(recentCount: store.compactShelf.recent.count, hasOlder: !store.compactShelf.older.isEmpty))
    host.autoresizingMask = [.width, .height]
    return host
}

/// A single boundary tracker survives SwiftUI's compact/expanded subtree changes.
private final class ShelfHostingView: NSHostingView<ShelfView> {
    let interaction: ShelfInteraction
    private var boundary: NSTrackingArea?
    init(store: CaptureStore, interaction: ShelfInteraction) {
        self.interaction = interaction
        super.init(rootView: ShelfView(store: store, interaction: interaction))
    }
    required init(rootView: ShelfView) { fatalError("Use init(store:interaction:)") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard boundary == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area); boundary = area
    }
    override func mouseEntered(with event: NSEvent) { interaction.pointerInside(true) }
    override func mouseExited(with event: NSEvent) { interaction.pointerInside(false) }
}

private struct ShelfGlass: ViewModifier {
    let expanded: Bool
    func body(content: Content) -> some View {
        content.background {
            ShelfBlur().overlay(Color.white.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .opacity(expanded ? 1 : 0).allowsHitTesting(false)
        }
    }
}

struct ShelfBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow
        view.state = .active; view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.state = .active; view.isEmphasized = false }
}

struct CopyConfirmation: View {
    var message = "Copied"
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 4) {
        Label(message, systemImage: "checkmark.circle.fill")
        if let detail { Text(detail).font(.system(size: 10)).multilineTextAlignment(.center) }
        }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel(message)
    }
}

struct CaptureCard: View {
    @ObservedObject var store: CaptureStore
    let item: Capture
    var compact = false
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035))
                if let image = store.thumbnail(item) {
                    ScreenshotDragView(image: image, url: store.disk.url(item),
                        onClick: { count in if count == 2 { AppDelegate.shared?.edit(item) } },
                        onBegin: {
                            store.beginShelfDrag(item.id)
                            AppDelegate.shared?.updateHoverTarget(nil, source: "library:\(item.id)")
                            AppDelegate.shared?.shelfInteraction.beginDragging()
                        }, onEnd: { success in
                            store.finishShelfDrag(item.id, succeeded: success)
                            AppDelegate.shared?.shelfInteraction.endDragging()
                        }).padding(8)
                }
                ScreenshotActionOverlay(store: store, item: item, hover: hover, interaction: nil, pinned: false, inHistory: true)
                if item.favorite { Image(systemName: "star.fill").foregroundStyle(accent).padding(9).frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false) }
            }.frame(height: compact ? 108 : 155)
            .overlay { if store.copiedID == item.id { CopyConfirmation(message: store.feedbackMessage, detail: store.feedbackDetail).transition(.opacity) } }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.isPrivate ? "Private capture" : item.title).font(.system(size: compact ? 11 : 12, weight: .medium)).lineLimit(1)
                    Text("\(item.width) × \(item.height)  ·  \(item.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if store.indexing.contains(item.id) { ProgressView().controlSize(.mini).help("Recognizing text locally") }
            }.padding(compact ? 8 : 12)
        }
        .background(Color.primary.opacity(hover ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(hover ? 0.16 : 0.07)))
        .onHover { inside in
            hover = inside
            AppDelegate.shared?.updateHoverTarget(inside ? item.id : nil, source: "library:\(item.id)")
        }
        .onDisappear { AppDelegate.shared?.updateHoverTarget(nil, source: "library:\(item.id)") }
        .onTapGesture(count: 2) { AppDelegate.shared?.edit(item) }
        .contextMenu {
            Button("Annotate…") { AppDelegate.shared?.edit(item) }
            Button(item.isPinned ? "Unpin from Screen" : "Pin to Screen") { store.togglePin(item.id) }
            Button("Copy Image") { store.copy(item) }
            Button("Copy for Sharing") { store.copyForSharing(item) }
            Button(actionLabel(.upload, item: item)) { store.prepareUpload(item) }
            Button("Select Text…") { AppDelegate.shared?.selectText(item) }
            Button("Copy Recognized Text") { store.copyText(item) }.disabled(item.text.isEmpty)
            Button(actionLabel(.description, item: item)) { AppDelegate.shared?.showDescription(item.id) }
            Button(item.onShelf ? "Remove from Shelf" : "Add to Shelf") { store.update(item.id) { $0.onShelf.toggle() }; if !item.onShelf { AppDelegate.shared?.showShelf() } }
            Button(item.favorite ? "Unfavorite" : "Favorite") { store.update(item.id) { $0.favorite.toggle() } }
            Button("Rename…") { AppDelegate.shared?.rename(item) }
            Button("Export / Resize…") { store.export(item) }
            Button("Show in Finder") { store.showInFinder(item) }
            Divider()
            Button("Move to Trash…", role: .destructive) { store.delete(item) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(item.title)
    }
    func mini(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 25) }
            .buttonStyle(.plain).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 6)).help(help).accessibilityLabel(help)
    }
}

struct ShelfMoveHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandle { DragHandle() }
    func updateNSView(_ view: DragHandle, context: Context) {}

    final class DragHandle: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var tracking: NSTrackingArea?
        private var grabOffset: CGPoint?
        private var moveCursor: NSCursor { grabOffset == nil ? .openHand : .closedHand }
        override var mouseDownCanMoveWindow: Bool { false }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard tracking == nil else { return }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
        }
        private func setCursor(_ cursor: NSCursor) {
            PanelCursor.set(cursor)
        }
        override func cursorUpdate(with event: NSEvent) { setCursor(moveCursor) }
        override func mouseMoved(with event: NSEvent) { setCursor(moveCursor) }
        override func mouseEntered(with event: NSEvent) { setCursor(moveCursor) }
        override func mouseExited(with event: NSEvent) {
            if grabOffset == nil && NSCursor.current == .openHand { setCursor(.arrow) }
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            grabOffset = CGPoint(x: pointer.x - window.frame.minX, y: pointer.y - window.frame.minY)
            window.invalidateCursorRects(for: self)
            setCursor(.closedHand)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let grabOffset else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let origin = CGPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen
            let frame = CGRect(origin: origin, size: window.frame.size)
            window.setFrameOrigin(screen.map { PanelPlacement.clamped(frame, to: $0.visibleFrame).origin } ?? origin)
            setCursor(.closedHand)
        }
        override func mouseUp(with event: NSEvent) {
            grabOffset = nil
            window?.invalidateCursorRects(for: self)
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            setCursor(inside ? .openHand : .arrow)
        }
        override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: moveCursor) }
    }
}

/// Floating panels must track hover even when another application is active.
struct ShelfHoverArea: NSViewRepresentable {
    let onHover: (Bool) -> Void
    var onScroll: (() -> Void)? = nil
    var collapsedCapsuleSize: CGSize?
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        view.onScroll = onScroll
        view.collapsedCapsuleSize = collapsedCapsuleSize
        return view
    }
    func updateNSView(_ view: TrackingView, context: Context) { view.onHover = onHover; view.onScroll = onScroll }
    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        var onScroll: (() -> Void)?
        var collapsedCapsuleSize: CGSize?
        private var area: NSTrackingArea?
        private var scrollMonitor: Any?
        private var inside = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // inVisibleRect follows layout and scrolling itself. Replacing the
            // tracking area here generates false exit/enter pairs during layout.
            guard area == nil else { return }
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag]
            if collapsedCapsuleSize != nil { options.insert(.mouseMoved) }
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }
        private func setInside(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            onHover?(value)
        }
        private func containsPointer(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard let collapsedCapsuleSize else { return bounds.contains(point) }
            let size = inside ? bounds.size : collapsedCapsuleSize
            let bottomAlignedY = isFlipped ? bounds.maxY - size.height : bounds.minY
            let capsule = CGRect(x: bounds.midX - size.width / 2, y: bottomAlignedY,
                                 width: size.width, height: size.height)
            return NSBezierPath(roundedRect: capsule, xRadius: size.height / 2, yRadius: size.height / 2).contains(point)
        }
        override func mouseEntered(with event: NSEvent) { setInside(collapsedCapsuleSize == nil || containsPointer(event)) }
        override func mouseMoved(with event: NSEvent) { if collapsedCapsuleSize != nil { setInside(containsPointer(event)) } }
        override func mouseExited(with event: NSEvent) { setInside(false) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
            guard window != nil, onScroll != nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onScroll?() }
                return event
            }
        }
        deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }
    }
}

private struct ShelfIconButton: View {
    let symbol: String
    let hint: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(hovered ? 0.20 : 0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(ShelfHoverArea { hovered = $0 })
        .help(hint)
        .accessibilityLabel(hint)
    }
}

struct ShelfView: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var interaction: ShelfInteraction
    @State private var pillHovered = false
    @State private var gripHovered = false
    @State private var cardFrames: [UUID: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var previews: some View {
        VStack(spacing: 0) {
            if interaction.expanded {
                HStack(spacing: 10) {
                    ZStack {
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).frame(width: 28)
                            Text(interaction.manuallyOpened ? "History" : "\(store.pendingCount)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.allowsHitTesting(false)
                        ShelfMoveHandle()
                    }.frame(maxWidth: .infinity).frame(height: 30).help("Drag to move")
                    minimizeButton.frame(width: 32, height: 28)
                    Button { AppDelegate.shared?.showLibrary() } label: { Image(systemName: "magnifyingglass") }.help("Search library")
                    Menu {
                        Button("Capture Region") { AppDelegate.shared?.capture(.region) }
                        Button("Import Images…") { store.chooseImages() }
                        Button("Paste Image") { store.paste() }
                        Button("Mark All as Viewed") { store.markReviewed(Set(store.shelf.map(\.id))) }
                        Button("Dismiss All Previews") { store.dismissCurrentPreviews(); AppDelegate.shared?.hideShelf() }
                        Button("Settings…") { AppDelegate.shared?.showSettings() }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                    Button { AppDelegate.shared?.dismissShelf() } label: { Image(systemName: "xmark") }.help("Dismiss all queued previews; keep in History").accessibilityLabel("Close shelf")
                }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 38).transition(.opacity)
            }
            if !interaction.manuallyOpened, store.shelf.isEmpty, store.copiedID != nil, let image = store.feedbackImage {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 152,height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 9)).shadow(color: .black.opacity(0.16),radius: 8,y: 4)
                    .frame(maxWidth: .infinity,maxHeight: .infinity).allowsHitTesting(false)
            } else if store.captures.isEmpty || (!interaction.expanded && store.shelf.isEmpty) {
                if interaction.manuallyOpened {
                    Image(systemName: "rectangle.stack").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Color.clear.frame(maxWidth: .infinity,maxHeight: .infinity) }
            } else if interaction.expanded {
                GeometryReader { viewport in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(interaction.manuallyOpened ? store.history : store.shelf) { item in
                                ShelfThumbnail(store: store, item: item, expanded: true, interaction: interaction).frame(width: 150, height: 108)
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: ShelfCardFrames.self, value: [item.id: geometry.frame(in: .named("Still.ShelfViewport"))])
                                    })
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 8)
                    }
                    .coordinateSpace(name: "Still.ShelfViewport")
                    .scrollIndicators(.hidden)
                    .onPreferenceChange(ShelfCardFrames.self) { frames in
                        cardFrames = frames
                        updateVisibleItems(frames, size: viewport.size)
                    }
                    .onChange(of: viewport.size) { _, size in updateVisibleItems(cardFrames, size: size) }
                }
            } else {
                CompactShelfRow(store: store, interaction: interaction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ShelfGlass(expanded: interaction.expanded))
        .opacity(!interaction.manuallyOpened && store.shelf.isEmpty && store.copiedID == nil ? 0 : 1)
        .overlay(alignment: .top) {
            if !interaction.expanded && !store.shelf.isEmpty { actionBar }
        }
        .overlay(alignment: .bottom) {
            if store.copiedID != nil { CopyConfirmation(message: store.feedbackMessage, detail: store.feedbackDetail).padding(.bottom, 5).allowsHitTesting(false) }
        }
        .background(ShelfHoverArea(onHover: { _ in }, onScroll: { interaction.scrolled() }))
    }

    private var actionBar: some View {
        let restingSize = CGSize(width: 54, height: 7)
        let openSize = CGSize(width: 164, height: 34)
        let buttonDiameter: CGFloat = 28
        let spacing: CGFloat = 4
        let inset = (openSize.height - buttonDiameter) / 2
        let gripWidth = openSize.width - 2 * (inset + buttonDiameter + spacing)
        let open = pillHovered && !interaction.dragging
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.14)

        return HStack(spacing: 0) {
            ShelfMoveHandle()
            ZStack(alignment: .bottom) {
                Capsule().fill(.regularMaterial)
                    .overlay { Capsule().fill(Color.primary.opacity(open ? 0 : 0.25)) }
                    .frame(width: open ? openSize.width : restingSize.width,
                           height: open ? openSize.height : restingSize.height)
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                    .allowsHitTesting(false)
                    .animation(animation, value: open)
                HStack(spacing: spacing) {
                    minimizeButton.frame(width: buttonDiameter, height: buttonDiameter)
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .frame(width: gripWidth, height: buttonDiameter)
                        .background(Color.primary.opacity(gripHovered ? 0.19 : 0.08), in: Capsule())
                        .allowsHitTesting(false)
                    ShelfIconButton(symbol: "clock.arrow.circlepath", hint: "Open screenshot history") {
                        AppDelegate.shared?.showShelf(manuallyOpened: true)
                    }.frame(width: buttonDiameter, height: buttonDiameter)
                }
                .padding(inset)
                .opacity(open ? 1 : 0)
                .animation(animation, value: open)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)

                ShelfMoveHandle()
                    .frame(width: open ? gripWidth : restingSize.width,
                           height: open ? buttonDiameter : restingSize.height)
                    .background(ShelfHoverArea { gripHovered = $0 })
                    .padding(.bottom, open ? inset : 0)
                    .help("Drag to move the shelf")
            }
            .frame(width: openSize.width, height: openSize.height, alignment: .bottom)
            ShelfMoveHandle()
        }
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity)
        .frame(height: 38, alignment: .bottom)
        .overlay(alignment: .bottom) {
            // The stationary tracker includes the approach from the gap below the bar.
            ShelfHoverArea(onHover: { pillHovered = $0 },
                           collapsedCapsuleSize: CGSize(width: restingSize.width + 24, height: restingSize.height + 12))
                .frame(width: openSize.width + 8, height: openSize.height + 8)
                .offset(y: 6)
        }
        .onDisappear { pillHovered = false }
    }

    private var minimizeButton: some View {
        ShelfIconButton(symbol: "chevron.down", hint: "Collapse shelf") {
            AppDelegate.shared?.setShelfTucked(true)
        }
    }

    private var tuckedHandle: some View {
        HStack(spacing: 0) {
            ZStack {
                Capsule().fill(Color.primary.opacity(gripHovered ? 0.10 : 0)).padding(.vertical, 3).allowsHitTesting(false)
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).allowsHitTesting(false)
                ShelfMoveHandle()
            }.frame(width: 23).help("Drag to move the shelf")
                .background(ShelfHoverArea { gripHovered = $0 })
            Button { AppDelegate.shared?.setShelfTucked(false) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.stack")
                    if store.pendingCount > 0 { Text("\(store.pendingCount)").monospacedDigit() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Restore shelf").accessibilityLabel("Restore shelf")
        }
        .padding(.horizontal, 3)
        .font(.system(size: 11, weight: .medium))
        .background(.regularMaterial, in: Capsule())
    }

    var body: some View {
        Group {
            if interaction.tucked { tuckedHandle } else { previews }
        }
        .onChange(of: store.compactShelf.columnCount) { _, _ in
            if !interaction.expanded { AppDelegate.shared?.expandShelf(false) }
        }
        .onChange(of: store.shelf.count) { _, _ in AppDelegate.shared?.hideShelfIfReviewed(afterAction: true) }
        .onChange(of: store.pendingCount) { _, _ in AppDelegate.shared?.hideShelfIfReviewed() }
        .onChange(of: store.copiedID) { _, id in if id == nil { AppDelegate.shared?.hideShelfIfReviewed(afterAction: true) } }
        .onDrop(of: [.fileURL], isTargeted: nil) { importDrop($0, store: store) }
    }
    private func updateVisibleItems(_ frames: [UUID: CGRect], size: CGSize) {
        interaction.visibleItems(ShelfInteraction.visibleItems(frames: frames, size: size))
    }
}

private struct ShelfCardFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
}

struct CompactShelfRow: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var interaction: ShelfInteraction
    var body: some View {
        HStack(spacing: 12) {
            ForEach(store.compactShelf.recent) { item in
                ShelfThumbnail(store: store, item: item, expanded: false, interaction: interaction)
                    .frame(maxWidth: .infinity).frame(height: 108)
                    .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 3)
            }
            if !store.compactShelf.older.isEmpty {
                OlderScreenshotStack(store: store, items: store.compactShelf.older, interaction: interaction)
                    .frame(width: 124, height: 108)
            }
        }.padding(.horizontal, 20).padding(.top, ShelfLayout.compactCardTop).padding(.bottom, 12)
    }
}

private struct OlderScreenshotStack: View {
    @ObservedObject var store: CaptureStore
    let items: [Capture]
    @ObservedObject var interaction: ShelfInteraction
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(items.prefix(3).enumerated()).reversed(), id: \.element.id) { depth, item in
                if let image = store.thumbnail(item) {
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }.frame(width: 106, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                        .offset(x: CGFloat(depth) * 8, y: CGFloat(depth) * -8)
                        .allowsHitTesting(false)
                }
            }
            if items.contains(where: \.needsAttention) {
                Text("\(items.filter(\.needsAttention).count)")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule()).padding(5).allowsHitTesting(false)
            }
        }.frame(width: 106, height: 90).padding(.top, 18).padding(.trailing, 18)
            .contentShape(Rectangle())
            .background(ShelfHoverArea { interaction.stackHovered($0) })
            .onTapGesture { interaction.setExpanded(true) }
            .help("Older screenshots · Hover to expand")
            .accessibilityElement(children: .ignore).accessibilityLabel("Older screenshots, \(items.filter(\.needsAttention).count) awaiting attention")
            .accessibilityAddTraits(.isButton).accessibilityAction { interaction.setExpanded(true) }
    }
}

struct ShelfThumbnail: View {
    @ObservedObject var store: CaptureStore
    let item: Capture
    let expanded: Bool
    @ObservedObject var interaction: ShelfInteraction
    @ObservedObject private var preferences: CapturePreferences
    var pinned = false
    @State private var loadedThumbnail: NSImage?
    @State private var loadedKey: String?
    private var thumbnailKey: String { "\(item.id)-\(item.revision)" }
    private var displayedThumbnail: NSImage? {
        if expanded {
            return store.cachedThumbnail(item) ?? (loadedKey == thumbnailKey ? loadedThumbnail : nil)
        }
        return store.thumbnail(item)
    }
    private var hover: Bool { !interaction.scrolling && !interaction.dragging && interaction.hoveredID == item.id }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(store: CaptureStore, item: Capture, expanded: Bool, interaction: ShelfInteraction, pinned: Bool = false) {
        self.store = store; self.item = item; self.expanded = expanded
        self.interaction = interaction; self.pinned = pinned; self.preferences = store.preferences
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(expanded ? 0.035 : 0))
            if let image = displayedThumbnail {
                ScreenshotDragView(image: image, url: store.disk.url(item), fill: !expanded, moveWindowOnDrag: pinned,
                    onClick: { count in if count == 2 { AppDelegate.shared?.edit(item) } },
                    onBegin: { store.beginShelfDrag(item.id); interaction.beginDragging() }, onEnd: { success in
                        store.finishShelfDrag(item.id, succeeded: success)
                        interaction.endDragging()
                    }).padding(expanded ? 3 : 0)
            }
            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 4) {
                        if item.needsAttention { Circle().fill(Color.accentColor).frame(width: 4, height: 4) }
                        Text(timestamp).font(.system(size: 10, weight: .medium))
                    }.padding(.horizontal, 6).padding(.vertical, 3).background(.thinMaterial, in: Capsule())
                    Spacer()
                }
            }.padding(6).opacity(hover && preferences.controls.hideDate ? 0 : 1).allowsHitTesting(false)
            ScreenshotActionOverlay(store: store, item: item, hover: hover, interaction: interaction, pinned: pinned, inHistory: interaction.manuallyOpened && !pinned)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
        .background(ShelfHoverArea { interaction.pointer(over: item.id, inside: $0) })
        .onDisappear { interaction.pointer(over: item.id, inside: false) }
        .task(id: expanded ? thumbnailKey : nil) {
            guard expanded, store.cachedThumbnail(item) == nil else { return }
            let image = await store.loadShelfThumbnail(item)
            guard !Task.isCancelled else { return }
            loadedThumbnail = image
            loadedKey = thumbnailKey
        }
        .contextMenu {
            ForEach(ScreenshotAction.allCases.filter { $0 != .none && $0 != .history && $0 != .trash }) { action in
                Button(actionLabel(action, item: item, inHistory: interaction.manuallyOpened && !pinned), role: action == .dismiss && interaction.manuallyOpened && !pinned ? .destructive : nil) {
                    AppDelegate.shared?.performScreenshotAction(action, item: item, interaction: interaction, pinned: pinned, inHistory: interaction.manuallyOpened && !pinned)
                }
                    .disabled(action == .copyText && item.text.isEmpty)
            }
            if !interaction.manuallyOpened && !item.isPrivate {
                Divider()
                Button("Move to Trash…", role: .destructive) { store.delete(item) }
            }
            Button("History") { AppDelegate.shared?.showShelf() }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("\(item.title), \(timestamp)")
    }
    var timestamp: String {
        if Calendar.current.isDateInToday(item.createdAt) { return item.createdAt.formatted(date: .omitted, time: .shortened) }
        return item.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

func actionLabel(_ action: ScreenshotAction, item: Capture, inHistory: Bool = false) -> String {
    let title = action == .dismiss && inHistory ? "Move to Trash…" : action == .pin && item.isPinned ? "Unpin from Screen" : action.title
    let key = action.shortcutAction.flatMap { AppDelegate.shared?.shortcuts.bindings[$0]?.displayName }
    return title + (key.map { " · " + $0 } ?? "")
}

struct ScreenshotActionOverlay: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject private var preferences: CapturePreferences
    let item: Capture
    let hover: Bool
    let interaction: ShelfInteraction?
    let pinned: Bool
    let inHistory: Bool
    @State private var optionHeld = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var bindings: ShortcutBindings { AppDelegate.shared?.shortcuts.bindings ?? .defaults() }

    init(store: CaptureStore, item: Capture, hover: Bool, interaction: ShelfInteraction?, pinned: Bool, inHistory: Bool = false) {
        self.store = store; self.preferences = store.preferences; self.item = item; self.hover = hover
        self.interaction = interaction; self.pinned = pinned; self.inHistory = inHistory
    }
    var body: some View {
        presentation(optionHeld: optionHeld)
        .task(id: hover) {
            guard hover else { optionHeld = false; return }
            // The shelf is nonactivating. Global modifier state also works over other apps
            // without an Input Monitoring permission request.
            while !Task.isCancelled {
                let held = NSEvent.modifierFlags.contains(.option)
                if held != optionHeld { optionHeld = held }
                do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            }
        }
    }
    func presentation(optionHeld: Bool) -> some View {
        ZStack {
            Color.black.opacity(hover ? preferences.controls.dimming : 0).allowsHitTesting(false)
            if hover {
                ForEach(ActionCorner.allCases) { corner in
                    let base = preferences.controls[corner]
                    if base != .none {
                        actionButton(base, size: preferences.controls.buttonSize, optionHeld: optionHeld)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner)).padding(6)
                    }
                }
            }
        }
    }
    func alignment(_ corner: ActionCorner) -> Alignment {
        switch corner { case .topLeft: return .topLeading; case .topRight: return .topTrailing; case .bottomLeft: return .bottomLeading; case .bottomRight: return .bottomTrailing }
    }
    func actionButton(_ base: ScreenshotAction, size: Double, optionHeld: Bool) -> some View {
        let action = base.displayed(holdingOption: optionHeld, bindings: bindings)
        let key = action.shortcutAction.flatMap { bindings[$0] }
        return Button(role: action == .trash || (action == .dismiss && inHistory) ? .destructive : nil) {
            let clicked = base.displayed(holdingOption: NSEvent.modifierFlags.contains(.option), bindings: bindings)
            AppDelegate.shared?.performScreenshotAction(clicked, item: item, interaction: interaction, pinned: pinned, inHistory: inHistory)
        } label: {
            VStack(spacing: 1) {
                if action == .copySharing && store.sharingJobs.contains(item.id) { ProgressView().controlSize(.small) }
                else { Image(systemName: action == .dismiss && inHistory ? "trash" : action == .pin && item.isPinned ? "pin.slash" : action.symbol) }
                if let key, !optionHeld || key.modifiers & UInt32(optionKey) != 0 {
                    Text(key.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }.font(.system(size: size < 28 ? 11 : 13, weight: .semibold))
                .foregroundStyle(action == .trash ? Color.red : Color.primary)
                .frame(width: size, height: size)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: action)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(action == .copySharing && store.sharingJobs.contains(item.id))
            .help(actionLabel(action, item: item, inHistory: inHistory)).accessibilityLabel(actionLabel(action, item: item, inHistory: inHistory))
            .onHover { inside in
                if inside { NSCursor.arrow.set() }
                if action == .history && !pinned { interaction?.stackHovered(inside, delay: 0.28) }
            }
            .onContinuousHover { phase in if case .active = phase { NSCursor.arrow.set() } }
    }
}

func importDrop(_ providers: [NSItemProvider], store: CaptureStore) -> Bool {
    // Dropping back onto Still is a cancellation, not a completed handoff.
    guard store.activeDragID == nil else { return false }
    for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url, url.deletingLastPathComponent().standardizedFileURL != store.disk.images.standardizedFileURL { DispatchQueue.main.async { store.importURLs([url]) } } }
    }
    return !providers.isEmpty
}
