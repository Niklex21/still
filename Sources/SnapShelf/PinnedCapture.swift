import AppKit
import SwiftUI
import SnapShelfCore

final class PinnedCaptureController: NSWindowController, NSWindowDelegate {
    private let interaction = ShelfInteraction()
    private var placing = true
    var onMove: ((CGRect) -> Void)?
    init(item: Capture, store: CaptureStore, offset: Int, onHover: @escaping (UUID?) -> Void) {
        interaction.onHoverChanged = onHover
        let anchor = PanelPlacement.savedPoint("pinAnchor.v2")
        let screen = PanelPlacement.screen(containing: anchor)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(1, 500 / CGFloat(max(1, item.width)), 360 / CGFloat(max(1, item.height)))
        let size = NSSize(width: max(180, CGFloat(item.width) * scale), height: max(120, CGFloat(item.height) * scale))
        let frame = PanelPlacement.pinFrame(size: size, screen: screen, anchor: anchor, depth: offset)
        let panel = ShelfPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "Pinned · \(item.title)"
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = false; panel.minSize = NSSize(width: 180, height: 120)
        panel.contentAspectRatio = size
        panel.isReleasedWhenClosed = false
        panel.onDismiss = { [weak store] in if store?.captures.first(where: { $0.id == item.id })?.isPinned == true { store?.togglePin(item.id) } }
        let host = NSHostingView(rootView: PinnedCaptureView(store: store, id: item.id, interaction: interaction))
        host.sizingOptions = []; panel.contentView = host
        super.init(window: panel)
        panel.delegate = self; placing = false
    }
    func place(anchor: CGPoint?, depth: Int) {
        guard let window else { return }
        let screen = PanelPlacement.screen(containing: anchor)?.visibleFrame ?? window.frame
        placing = true
        window.setFrame(PanelPlacement.pinFrame(size: window.frame.size, screen: screen, anchor: anchor, depth: depth), display: true)
        placing = false
    }
    func windowDidMove(_ notification: Notification) { if !placing, let window, window.isVisible { onMove?(window.frame) } }
    override func close() { interaction.dismiss(); super.close() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct PinnedCaptureView: View {
    @ObservedObject var store: CaptureStore
    let id: UUID
    @ObservedObject var interaction: ShelfInteraction
    var body: some View {
        if let item = store.captures.first(where: { $0.id == id }) {
            ShelfThumbnail(store: store, item: item, expanded: true, interaction: interaction, pinned: true)
                .help("Drag to move · Option-drag to copy the image · Drag a corner to resize")
        }
    }
}
