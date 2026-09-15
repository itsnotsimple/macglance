// Draws the app icon (a chip with a bar chart) and writes Resources/AppIcon.icns.
// Run from the project root: swift scripts/make-icon.swift
import AppKit

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Draws the icon on a 1024×1024 canvas scaled to `size` pixels.
func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    // Body: Apple's icon grid, an 824 px rounded square with radius 185 and a 100 px margin.
    // macOS 26+ checks this exact shape; anything else gets boxed in a gray frame.
    let body = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: hex(0x2A3142), ending: hex(0x0D1017))!.draw(in: body, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(starting: hex(0xFFFFFF, 0.10), ending: hex(0xFFFFFF, 0))!   // soft top light
        .draw(in: CGRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Chip outline with 4 pins per side.
    let chip = CGRect(x: 272, y: 272, width: 480, height: 480)
    let line = hex(0xC9D2E3)
    line.setStroke()
    let outline = NSBezierPath(roundedRect: chip, xRadius: 72, yRadius: 72)
    outline.lineWidth = 24
    outline.stroke()
    let pins = NSBezierPath()
    pins.lineWidth = 24
    pins.lineCapStyle = .round
    for i in 0..<4 {
        let p = chip.minX + 120 + CGFloat(i) * 80
        pins.move(to: NSPoint(x: p, y: chip.maxY + 14)); pins.line(to: NSPoint(x: p, y: chip.maxY + 62))
        pins.move(to: NSPoint(x: p, y: chip.minY - 14)); pins.line(to: NSPoint(x: p, y: chip.minY - 62))
        pins.move(to: NSPoint(x: chip.minX - 14, y: p)); pins.line(to: NSPoint(x: chip.minX - 62, y: p))
        pins.move(to: NSPoint(x: chip.maxX + 14, y: p)); pins.line(to: NSPoint(x: chip.maxX + 62, y: p))
    }
    pins.stroke()

    // Bar chart inside the chip: green, amber, cyan.
    let bars: [(height: CGFloat, top: UInt32, bottom: UInt32)] = [
        (150, 0x6EE7A8, 0x10B981),
        (270, 0xFCD34D, 0xF59E0B),
        (200, 0x7DD3FC, 0x0EA5E9),
    ]
    let barWidth: CGFloat = 80, gap: CGFloat = 36, floor: CGFloat = 377
    var x = chip.midX - (3 * barWidth + 2 * gap) / 2
    for bar in bars {
        let shape = NSBezierPath(roundedRect: CGRect(x: x, y: floor, width: barWidth, height: bar.height),
                                 xRadius: 18, yRadius: 18)
        NSGradient(starting: hex(bar.top), ending: hex(bar.bottom))!.draw(in: shape, angle: -90)
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every size is drawn from vectors, so the small ones stay sharp instead of being downscaled.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))   // preview

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
