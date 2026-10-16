// Draws the AnyScroll app icon (the auto-scroll anchor with four arrows on a
// macOS-style tile) at every size the asset catalog needs.
//
// Usage: swift scripts/make_icon.swift   (run from the repository root)

import Cocoa

let appIconSet = "AnyScroll/Assets.xcassets/AppIcon.appiconset"
let readmeIcon = "img/anyscroll-icon.png"

func drawIcon(in canvas: CGFloat) {
    let unit = canvas / 1024
    // Apple's icon grid: an 824 pt tile centred on a 1024 pt canvas
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.shadowBlurRadius = 24 * unit
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.30, blue: 0.75, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.26, green: 0.58, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.25, blue: 0.68, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    let mid = NSPoint(x: canvas / 2, y: canvas / 2)
    NSColor.white.set()

    let radius = 300 * unit
    let ring = NSBezierPath(ovalIn: NSRect(x: mid.x - radius, y: mid.y - radius, width: radius * 2, height: radius * 2))
    ring.lineWidth = max(1, 42 * unit)
    ring.stroke()

    let dot = 34 * unit
    NSBezierPath(ovalIn: NSRect(x: mid.x - dot, y: mid.y - dot, width: dot * 2, height: dot * 2)).fill()

    // Arrows spaced like the menu bar icon so their corners do not touch
    let tip = 228 * unit, base = 122 * unit, halfWidth = 74 * unit
    for (dx, dy) in [(0, 1), (0, -1), (-1, 0), (1, 0)] as [(CGFloat, CGFloat)] {
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: mid.x + dx * tip, y: mid.y + dy * tip))
        arrow.line(to: NSPoint(x: mid.x + dx * base - dy * halfWidth, y: mid.y + dy * base - dx * halfWidth))
        arrow.line(to: NSPoint(x: mid.x + dx * base + dy * halfWidth, y: mid.y + dy * base + dx * halfWidth))
        arrow.close()
        arrow.fill()
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Replace the old images with one file per size/scale
let fm = FileManager.default
for file in try fm.contentsOfDirectory(atPath: appIconSet) where file.hasSuffix(".png") {
    try fm.removeItem(atPath: "\(appIconSet)/\(file)")
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try png(pixels: size * scale).write(to: URL(fileURLWithPath: "\(appIconSet)/\(name)"))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(appIconSet)/Contents.json"))
try png(pixels: 1024).write(to: URL(fileURLWithPath: readmeIcon))
print("Wrote \(images.count) icon images to \(appIconSet) and \(readmeIcon)")
