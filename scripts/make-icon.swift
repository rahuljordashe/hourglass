// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle body (macOS icon grid: ~80% of canvas).
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Notch silhouette at the top.
    let notchW = body.width * 0.42, notchH = body.height * 0.11
    let notch = CGRect(x: body.midX - notchW / 2, y: body.maxY - notchH, width: notchW, height: notchH)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(CGPath(roundedRect: notch.insetBy(dx: 0, dy: -notchH), cornerWidth: notchH * 0.8, cornerHeight: notchH * 0.8, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Usage ring.
    let center = CGPoint(x: body.midX, y: body.midY - body.height * 0.04)
    let r = body.width * 0.27
    let lw = body.width * 0.075
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
    ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor(white: 0.94, alpha: 1).cgColor)
    ctx.addArc(center: center, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * 0.68, clockwise: true)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
