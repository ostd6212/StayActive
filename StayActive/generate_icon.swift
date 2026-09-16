import Cocoa

// Generates icon.iconset/ with all standard sizes: a thin green ring with a
// bold green dot in the center, matching the menu bar icon's design.
// Run on macOS: swift generate_icon.swift
// Then: iconutil -c icns icon.iconset

let sizes: [(Int, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx
    let cg = ctx!.cgContext

    let s = CGFloat(size)
    let green = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0).cgColor
    let background = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1.0).cgColor

    // macOS-style rounded-square backdrop so the icon has its own contrast
    // instead of relying on Finder's transparent-icon placeholder.
    let cornerRadius = s * 0.224
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    cg.addPath(bgPath)
    cg.setFillColor(background)
    cg.fillPath()

    let lineWidth = s * 0.045
    let margin = s * 0.22
    let circleRect = CGRect(
        x: margin,
        y: margin,
        width: s - margin * 2,
        height: s - margin * 2
    )
    cg.setStrokeColor(green)
    cg.setLineWidth(lineWidth)
    cg.strokeEllipse(in: circleRect)

    let dotSize = s * 0.26
    let dotRect = CGRect(x: (s - dotSize) / 2, y: (s - dotSize) / 2, width: dotSize, height: dotSize)
    cg.setFillColor(green)
    cg.fillEllipse(in: dotRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconsetPath = "icon.iconset"
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let rep = drawIcon(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("Failed to render \(name)")
        continue
    }
    let path = "\(iconsetPath)/\(name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

print("Done. Now run: iconutil -c icns icon.iconset")
