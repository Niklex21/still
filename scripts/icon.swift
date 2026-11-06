import AppKit
let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let base = NSBezierPath(roundedRect: NSRect(x: 22, y: 22, width: 980, height: 980), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.16, alpha: 1).setFill(); base.fill()
let mint = NSColor(calibratedRed: 0.4, green: 0.84, blue: 0.68, alpha: 1)
for (offset, alpha) in [(CGFloat(0), CGFloat(0.25)), (CGFloat(65), CGFloat(0.5)), (CGFloat(130), CGFloat(1))] {
    let rect = NSRect(x: 205 + offset / 2, y: 210 + offset, width: 550, height: 370)
    mint.withAlphaComponent(alpha).setStroke(); let path = NSBezierPath(roundedRect: rect, xRadius: 45, yRadius: 45); path.lineWidth = 24; path.stroke()
}
mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 600, y: 545, width: 55, height: 55)).fill()
let mountain = NSBezierPath(); mountain.move(to: NSPoint(x: 320, y: 410)); mountain.line(to: NSPoint(x: 435, y: 545)); mountain.line(to: NSPoint(x: 570, y: 410)); mountain.close(); mountain.fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
