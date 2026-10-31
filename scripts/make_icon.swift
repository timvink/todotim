// Draws the TodoTim app icon as a 1024px PNG: a completed checkbox in Catppuccin peach, with the
// faint ring of its completion burst, on a Mocha squircle.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let surface0 = color(0x313244), base = color(0x1E1E2E), crust = color(0x11111B), peach = color(0xFAB387)

// macOS icon grid: 824px body centered in the 1024px canvas, with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
base.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: surface0, ending: base)!.draw(in: squircle, angle: -90)

let center = NSPoint(x: 512, y: 512)
func circle(_ diameter: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
}

// The burst: two fading rings.
peach.withAlphaComponent(0.18).setStroke()
let outer = circle(650)
outer.lineWidth = 12
outer.stroke()
peach.withAlphaComponent(0.35).setStroke()
let inner = circle(560)
inner.lineWidth = 16
inner.stroke()

// The checked box.
peach.setFill()
circle(440).fill()
crust.setStroke()
let check = NSBezierPath()
check.move(to: NSPoint(x: 410, y: 520))
check.line(to: NSPoint(x: 485, y: 440))
check.line(to: NSPoint(x: 625, y: 595))
check.lineWidth = 50
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
