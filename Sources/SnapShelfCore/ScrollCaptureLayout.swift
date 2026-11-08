import Foundation
import CoreGraphics

public enum ScrollCaptureLayout {
    public struct WindowTarget {
        public let processID: Int32
        public let frame: CGRect
        public let layer: Int
        public let windowID: UInt32
        public init(processID: Int32, frame: CGRect, layer: Int = 0, windowID: UInt32 = 0) { self.processID = processID; self.frame = frame; self.layer = layer; self.windowID = windowID }
    }
    /// Input follows the compositor's front-to-back order, before selection UI.
    public static func targetProcess(region: CGRect, windows: [WindowTarget], ownProcess: Int32) -> Int32? {
        targetWindow(region: region,windows: windows,ownProcess: ownProcess)?.processID
    }
    public static func targetWindow(region: CGRect, windows: [WindowTarget], ownProcess: Int32) -> WindowTarget? {
        let point = CGPoint(x: region.midX,y: region.midY)
        return windows.first { $0.processID != ownProcess && $0.layer == 0 && $0.frame.contains(point) }
    }
    public static func windowCrop(region: CGRect, window: CGRect, pixels: CGSize) -> CGRect {
        CGRect(x: (region.minX-window.minX)*pixels.width/window.width,y: (region.minY-window.minY)*pixels.height/window.height,
               width: region.width*pixels.width/window.width,height: region.height*pixels.height/window.height).integral.intersection(CGRect(origin: .zero,size: pixels))
    }
    /// A side preview whenever room permits; otherwise a movable overlay that is
    /// excluded from the captured stream. Never resize/hide it for a frame.
    public static func previewFrame(region: CGRect, screen: CGRect) -> CGRect {
        let width = min(252, max(180, screen.width - 24))
        let height = min(560, max(300, region.height), screen.height - 24)
        let gap: CGFloat = 16
        let x: CGFloat
        if region.maxX + gap + width <= screen.maxX - 12 { x = region.maxX + gap }
        else if region.minX - gap - width >= screen.minX + 12 { x = region.minX - gap - width }
        else { x = screen.maxX - width - 12 }
        return CGRect(x: max(screen.minX + 12, x), y: max(screen.minY + 12, min(region.maxY - height, screen.maxY - height - 12)), width: width, height: height)
    }
    public static func appRect(_ quartzRect: CGRect, mainTop: CGFloat) -> CGRect {
        CGRect(x: quartzRect.minX, y: mainTop - quartzRect.maxY, width: quartzRect.width, height: quartzRect.height)
    }
    public static func sourceRect(region: CGRect, display: CGRect) -> CGRect {
        region.offsetBy(dx: -display.minX, dy: -display.minY)
    }
}
