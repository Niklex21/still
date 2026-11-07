import AppKit
import SwiftUI
import SnapShelfCore

final class ScrollProgress: ObservableObject {
    enum Phase { case preparing, recording, finishing, failed, finished, cancelled }
    @Published var frames = 0
    @Published var width = 0
    @Published var height = 0
    @Published var preview: NSImage?
    @Published var phase = Phase.preparing
    @Published var message = "Preparing capture…"
    @Published var warning = false
    var finishShortcut: String?
    var finish: (() -> Void)?
    var cancel: (() -> Void)?
    var canFinish: Bool { frames > 0 && (phase == .recording || phase == .failed) }
}

struct ScrollProgressView: View {
    @ObservedObject var progress: ScrollProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { progress.cancel?() } label: { Image(systemName: "xmark").font(.system(size: 11,weight: .semibold)).frame(width: 22,height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel capture").accessibilityLabel("Cancel scrolling capture")
                ZStack {
                    ShelfMoveHandle()
                    Text("Scrolling capture").font(.system(size: 11,weight: .semibold)).allowsHitTesting(false)
                }.frame(maxWidth: .infinity).frame(height: 26).help("Drag to move")
                Button { progress.finish?() } label: { Image(systemName: "checkmark").font(.system(size: 12,weight: .semibold)).frame(width: 24,height: 22) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(!progress.canFinish)
                    .help(progress.finishShortcut.map { "Finish · \($0)" } ?? "Finish capture").accessibilityLabel("Finish scrolling capture")
            }
            GeometryReader { geometry in
                if let preview = progress.preview {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                Image(nsImage: preview).resizable().interpolation(.medium).scaledToFit().frame(width: geometry.size.width)
                                Color.clear.frame(height: 1).id("end")
                            }
                        }.scrollIndicators(.hidden)
                            .onChange(of: progress.height) { _, _ in
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo("end",anchor: .bottom) }
                            }
                    }
                } else {
                    VStack(spacing: 12) {
                        if progress.phase == .preparing { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.down.viewfinder").font(.system(size: 28,weight: .ultraLight)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity,maxHeight: .infinity)
                }
            }.background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                Circle().fill(progress.warning ? Color.orange : Color.accentColor).frame(width: 5,height: 5)
                Text(progress.message).font(.system(size: 10)).foregroundStyle(progress.warning ? .primary : .secondary).lineLimit(2).help(progress.message)
                Spacer(minLength: 2)
                if progress.height > 0 { Text("\(progress.height) px").font(.system(size: 10,design: .monospaced)).foregroundStyle(.secondary).contentTransition(.numericText()) }
            }.frame(minHeight: 24)
        }.padding(12)
            .background { ShelfBlur().clipShape(RoundedRectangle(cornerRadius: 17)) }
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.12),lineWidth: 0.5).allowsHitTesting(false) }
    }
}

final class ScrollRegionOutline: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3,dy: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setStroke()
        let halo = NSBezierPath(roundedRect: rect, xRadius: 5,yRadius: 5); halo.lineWidth = 6; halo.stroke()
        NSColor.controlAccentColor.setStroke()
        let line = NSBezierPath(roundedRect: rect,xRadius: 5,yRadius: 5); line.lineWidth = 2; line.stroke()
        for point in [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.minX,y: rect.maxY),CGPoint(x: rect.maxX,y: rect.maxY)] {
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: CGRect(x: point.x-3,y: point.y-3,width: 6,height: 6)).fill()
        }
    }
}
