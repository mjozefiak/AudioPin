import AppKit
// Renders the DMG window background: a soft gradient with an arrow pointing from the app to Applications.
// Usage: swift scripts/make-dmg-background.swift <out.png> <scale>   (scale 1 → 640×400, 2 → 1280×800)
let args = CommandLine.arguments
let scale = CGFloat(Double(args.count > 2 ? args[2] : "1") ?? 1)
let w: CGFloat = 640, h: CGFloat = 400

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h) // 72 dpi at 1x, 144 dpi at 2x
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(colors: [NSColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 1), NSColor(red: 0.90, green: 0.91, blue: 0.98, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// Arrow between the two icons (icon centers at x=160 and x=480, y=190 from top).
let accent = NSColor(red: 0.45, green: 0.36, blue: 0.97, alpha: 0.85)
accent.setStroke(); accent.setFill()
let y = h - 190
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 255, y: y)); shaft.line(to: NSPoint(x: 370, y: y))
shaft.lineWidth = 6; shaft.lineCapStyle = .round; shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 392, y: y)); head.line(to: NSPoint(x: 364, y: y + 17)); head.line(to: NSPoint(x: 364, y: y - 17)); head.close()
head.fill()

let text = "Drag AudioPin to Applications to install"
let style = NSMutableParagraphStyle(); style.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor(white: 0.25, alpha: 1), .paragraphStyle: style,
]
text.draw(in: NSRect(x: 0, y: 62, width: w, height: 22), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
