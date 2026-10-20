// Draws the 1024px app icon: a sun setting into the sea. Usage: make_icon <out.png>
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// macOS icon grid: 824px rounded square centred on the canvas.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
tile.addClip()

let horizon: CGFloat = 420
NSGradient(colors: [rgb(0xF39A4A), rgb(0xB8506A), rgb(0x2E2350)])!
    .draw(in: NSRect(x: 0, y: horizon, width: 1024, height: 1024 - horizon), angle: 90)

rgb(0xFFD58A).setFill()
NSBezierPath(ovalIn: NSRect(x: 512 - 200, y: horizon - 200, width: 400, height: 400)).fill()

NSGradient(colors: [rgb(0x231B3D), rgb(0x15102A)])!
    .draw(in: NSRect(x: 0, y: 0, width: 1024, height: horizon), angle: -90)

// Sun reflection on the water
rgb(0xFFD58A).withAlphaComponent(0.55).setFill()
for (i, w) in [300.0, 220.0, 150.0, 90.0].enumerated() {
    let y = horizon - 60 - CGFloat(i) * 70
    NSBezierPath(roundedRect: NSRect(x: 512 - w / 2, y: y, width: w, height: 18), xRadius: 9, yRadius: 9).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
