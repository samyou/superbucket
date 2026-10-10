// Renders a simple app icon (gradient square + SF Symbol) to AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()
    let inset = CGFloat(px) * 0.08
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.65, alpha: 1))!
        .draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "arrow.up.doc.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let origin = NSPoint(x: (CGFloat(px) - tinted.size.width) / 2, y: (CGFloat(px) - tinted.size.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    rep.size = size
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print("wrote \(outDir)/AppIcon.icns")
