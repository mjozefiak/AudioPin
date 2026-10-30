import AppKit
// Rysuje ikonę 1024×1024: gradientowy squircle z symbolem pinezki i fali dźwięku.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let inset = rect.insetBy(dx: 100, dy: 100)
    let path = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 1.0, alpha: 1), NSColor(red: 0.62, green: 0.25, blue: 0.95, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSGraphicsContext.current?.restoreGraphicsState()
    // delikatny połysk u góry
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: inset.minX, y: inset.midY, width: inset.width, height: inset.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    func symbol(_ name: String, _ pt: CGFloat, _ r: NSRect, _ alpha: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
        guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let sz = s.size; let scale = min(r.width / sz.width, r.height / sz.height)
        let w = sz.width * scale, h = sz.height * scale
        s.draw(in: NSRect(x: r.midX - w/2, y: r.midY - h/2, width: w, height: h))
    }
    symbol("waveform", 300, NSRect(x: 230, y: 250, width: 564, height: 300), 0.35)
    symbol("pin.fill", 400, NSRect(x: 362, y: 330, width: 300, height: 420), 1)
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
