import Foundation
import CoreGraphics

public enum ScrollCaptureLayout {
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
