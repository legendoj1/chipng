// Renders AppIcon.icns: the chipng 血 mark on a red squircle.
// Usage: swift Scripts/make-icon.swift Mac/Resources
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowBlurRadius = s * 0.02
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1), NSColor(red: 0.78, green: 0.06, blue: 0.16, alpha: 1)])!
        .draw(in: shape, angle: -90)

    let font = NSFont(name: "Hiragino Sans W8", size: s * 0.5) ?? NSFont.systemFont(ofSize: s * 0.5, weight: .black)
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(red: 0.45, green: 0, blue: 0.05, alpha: 0.45)
    glyphShadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    glyphShadow.shadowBlurRadius = s * 0.02
    let text = NSAttributedString(string: "血", attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: glyphShadow])
    let size = text.size()
    text.draw(at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.01))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
