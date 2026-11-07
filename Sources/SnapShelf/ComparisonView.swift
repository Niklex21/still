import AppKit
import SwiftUI
import SnapShelfCore

struct ComparisonView: View {
    @ObservedObject var model: WalkthroughModel
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("View", selection: $model.differenceMode) { Text("Wipe").tag(false); Text("Changes").tag(true) }.pickerStyle(.segmented).frame(width: 180)
                Toggle("Align", isOn: $model.alignComparison).toggleStyle(.checkbox).help("Fit images without stretching, then align small translations. Comparison uses up to 2000 pixels on the longest edge.")
                Spacer()
                if model.comparing { ProgressView().controlSize(.small) }
            }
            GeometryReader { geometry in
                if let result = model.difference {
                    let image = result.before
                    let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: model.differenceMode ? result.overlay : result.before, scale: 1).resizable().frame(width: size.width, height: size.height)
                        if !model.differenceMode {
                            Image(decorative: result.after, scale: 1).resizable().frame(width: size.width, height: size.height).mask(alignment: .leading) { Rectangle().frame(width: size.width * model.comparison) }
                            Rectangle().fill(.white).frame(width: 2, height: size.height).offset(x: size.width * model.comparison)
                        }
                        ForEach(Array(model.ignoredRegions.enumerated()), id: \.offset) { _, r in
                            Rectangle().fill(.gray.opacity(0.25)).overlay(Rectangle().stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4])))
                                .frame(width: r.width * size.width, height: r.height * size.height).offset(x: r.minX * size.width, y: r.minY * size.height).allowsHitTesting(false)
                        }
                        if let start = dragStart, let end = dragEnd {
                            Rectangle().stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [4])).frame(width: abs(end.x-start.x), height: abs(end.y-start.y)).offset(x: min(start.x,end.x), y: min(start.y,end.y)).allowsHitTesting(false)
                        }
                    }.frame(width: size.width, height: size.height).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if model.ignoringRegion { dragStart = value.startLocation; dragEnd = clamped(value.location, size: size) }
                            else { model.comparison = min(1,max(0,value.location.x / size.width)) }
                        }.onEnded { value in
                            if model.ignoringRegion {
                                let a = clamped(value.startLocation, size: size), b = clamped(value.location, size: size)
                                if abs(a.x-b.x) > 3 && abs(a.y-b.y) > 3 { model.ignoredRegions.append(CGRect(x: min(a.x,b.x)/size.width, y: min(a.y,b.y)/size.height, width: abs(a.x-b.x)/size.width, height: abs(a.y-b.y)/size.height)) }
                                dragStart = nil; dragEnd = nil; model.ignoringRegion = false
                            }
                        }).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if model.differenceMode {
                HStack {
                    Text("Tolerance").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $model.tolerance, in: 0...96, step: 8).frame(maxWidth: 140)
                    Spacer()
                    if let result = model.difference { if result.comparedPixels == 0 { Text("No comparable pixels").foregroundStyle(.secondary) } else { Text(result.changedFraction, format: .percent.precision(.fractionLength(1))).monospacedDigit(); Text("changed").foregroundStyle(.secondary) } }
                }
            } else { Slider(value: $model.comparison, in: 0...1).help("Reveal before / after") }
            HStack {
                Button { model.ignoringRegion.toggle() } label: { Label(model.ignoringRegion ? "Draw ignored area" : "Ignore Area", systemImage: "rectangle.dashed") }.tint(model.ignoringRegion ? .accentColor : nil)
                if !model.ignoredRegions.isEmpty { Button("Reset") { model.ignoredRegions = [] } }
                Spacer()
                Text("\(model.items.first?.title ?? "") → \(model.items.last?.title ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(24).onChange(of: model.alignComparison) { _, _ in model.refreshDifference() }.onChange(of: model.tolerance) { _, _ in model.refreshDifference() }.onChange(of: model.ignoredRegions) { _, _ in model.refreshDifference() }
    }
    private func clamped(_ p: CGPoint, size: CGSize) -> CGPoint { CGPoint(x: min(size.width,max(0,p.x)), y: min(size.height,max(0,p.y))) }
}
