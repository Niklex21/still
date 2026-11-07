import AppKit
import SwiftUI

final class CountdownModel: ObservableObject {
    @Published var remaining: Int
    init(seconds: Int) { remaining = seconds }
}

final class CaptureCountdown: NSWindowController, NSWindowDelegate {
    let model: CountdownModel
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?
    init(seconds: Int, screen: NSScreen?, completion: @escaping (Bool) -> Void) {
        model = CountdownModel(seconds: seconds); self.completion = completion
        let panel = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 250,height: 78), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Still Capture Countdown"; panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        super.init(window: panel); panel.delegate = self
        panel.contentView = NSHostingView(rootView: CountdownView(model: model, cancel: { [weak self] in self?.finish(canceled: true) }))
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0,y: 0,width: 1440,height: 900)
        panel.setFrameOrigin(CGPoint(x: frame.midX - 125,y: frame.minY + 28))
    }
    required init?(coder: NSCoder) { fatalError() }
    func start() {
        window?.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }; self.model.remaining -= 1
            if self.model.remaining <= 0 { self.finish(canceled: false) }
        }
    }
    func finish(canceled: Bool) {
        timer?.invalidate(); timer = nil; window?.orderOut(nil)
        let callback = completion; completion = nil; callback?(canceled)
    }
    func windowWillClose(_ notification: Notification) { finish(canceled: true) }
    deinit { timer?.invalidate() }
}
private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(model.remaining)").font(.system(size: 28,weight: .medium,design: .rounded)).monospacedDigit().contentTransition(.numericText())
            Text("Capturing region").font(.callout)
            Spacer(minLength: 0)
            Button(action: cancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Cancel capture").accessibilityLabel("Cancel capture")
        }.padding(18).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 16))
    }
}
