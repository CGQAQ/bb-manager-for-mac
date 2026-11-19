// Renders the app icon into BBManager/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BBManager/Assets.xcassets/AppIcon.appiconset")

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 185 / 1024
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.11, green: 0.20, blue: 0.42, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.85, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    // Three stacked "server" slabs.
    let slabWidth = body.width * 0.58
    let slabHeight = body.height * 0.13
    let gap = body.height * 0.055
    let totalHeight = slabHeight * 3 + gap * 2
    let x = body.midX - slabWidth / 2
    var y = body.midY - totalHeight / 2
    for index in 0..<3 {
        let rect = CGRect(x: x, y: y, width: slabWidth, height: slabHeight)
        let slab = CGPath(roundedRect: rect, cornerWidth: slabHeight * 0.28, cornerHeight: slabHeight * 0.28, transform: nil)
        ctx.addPath(slab)
        ctx.setFillColor(NSColor.white.withAlphaComponent(index == 2 ? 0.98 : 0.86 - CGFloat(index) * 0.06).cgColor)
        ctx.fillPath()
        // Status light.
        let light = CGRect(x: rect.maxX - slabHeight * 0.75, y: rect.midY - slabHeight * 0.14, width: slabHeight * 0.28, height: slabHeight * 0.28)
        ctx.setFillColor((index == 2 ? NSColor.systemGreen : NSColor(calibratedRed: 0.2, green: 0.75, blue: 0.4, alpha: 1)).cgColor)
        ctx.fillEllipse(in: light)
        // Vent lines.
        ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.55, alpha: 0.55).cgColor)
        for v in 0..<3 {
            let vent = CGRect(x: rect.minX + slabHeight * (0.45 + CGFloat(v) * 0.32), y: rect.midY - slabHeight * 0.2, width: slabHeight * 0.12, height: slabHeight * 0.4)
            ctx.fill(vent)
        }
        y += slabHeight + gap
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size: size * scale).write(to: output.appendingPathComponent(name))
    }
}
print("Wrote icons to \(output.path)")
