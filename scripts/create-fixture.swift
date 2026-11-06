import AppKit
let size = NSSize(width: 900, height: 5000)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
for i in 0..<12 {
    let y = 5000 - CGFloat(i + 1) * 410
    NSColor(calibratedRed: 0.88 - Double(i % 3) * 0.04, green: 0.94, blue: 0.97 - Double(i % 4) * 0.03, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 45, y: y + 20, width: 810, height: 365), xRadius: 18, yRadius: 18).fill()
    let text = String(format: "SECTION %02d", i + 1)
    (text as NSString).draw(at: NSPoint(x: 85, y: y + 280), withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.black])
    ("Scrolling capture test.\nUnique content for section \(i + 1).\nEvery section should appear exactly once." as NSString).draw(at: NSPoint(x: 85, y: y + 125), withAttributes: [.font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.darkGray])
    NSColor.systemBlue.withAlphaComponent(0.4).setFill(); NSRect(x: 85, y: y + 75, width: CGFloat(200 + 45 * i), height: 16).fill()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
