// Draws the TodoTim app icon (red rounded square with a white check) as a 1024px PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824px body centered in 1024px canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.36, blue: 0.29, alpha: 1),
           ending: NSColor(srgbRed: 0.80, green: 0.24, blue: 0.19, alpha: 1))!.draw(in: path, angle: -90)

// White ring + check, like Todoist's checkbox.
NSColor.white.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 262, y: 262, width: 500, height: 500))
ring.lineWidth = 46
ring.stroke()
let check = NSBezierPath()
check.move(to: NSPoint(x: 395, y: 515))
check.line(to: NSPoint(x: 480, y: 425))
check.line(to: NSPoint(x: 640, y: 605))
check.lineWidth = 58
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
