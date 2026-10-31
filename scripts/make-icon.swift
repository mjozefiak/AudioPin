import AppKit
// Renders the 1024×1024 AudioPin app icon from the "Needle Wave" brand mark
// (docs/assets/brand/): a violet gradient squircle (#7D6BFF → #4B2FD6) on Apple's
// macOS icon grid (100 px margin, ~185 px continuous corners, soft drop shadow)
// with the white mark centered on it. The mark is drawn from the brand SVG path
// data below — no SF Symbols (their license forbids use in app icons).
//
// Usage: swift scripts/make-icon.swift <out.png> [--small]
//   --small  uses the simplified 32-grid mark (logo-mark-small.svg), drawn larger,
//            for the 16 px and 32 px icon sizes where the full mark gets muddy.

// logo-mark-white.svg (256 grid)
let fullMark = "M17 140A15 15 0 0 1 47 140V164A15 15 0 0 1 17 164ZM65 116A15 15 0 0 1 95 116V188A15 15 0 0 1 65 188ZM161 116A15 15 0 0 1 191 116V188A15 15 0 0 1 161 188ZM209 140A15 15 0 0 1 239 140V164A15 15 0 0 1 209 164ZM128 25A39 39 0 1 1 128 103A39 39 0 1 1 128 25ZM113 96H143L132.5 232Q128 241 123.5 232Z"
// logo-mark-small.svg (32 grid)
let smallMark = "M5 15A2 2 0 0 1 9 15V21A2 2 0 0 1 5 21ZM23 15A2 2 0 0 1 27 15V21A2 2 0 0 1 23 21ZM16 5A5 5 0 1 1 16 15A5 5 0 1 1 16 5ZM14 13H18L17 26.5Q16 28.5 15 26.5Z"

/// Minimal SVG path parser for absolute M/L/H/V/Q/A/Z commands (all the brand marks use).
func svgPath(_ d: String) -> CGMutablePath {
    var tokens: [String] = []
    var cur = ""
    for ch in d {
        if ch.isLetter { if !cur.isEmpty { tokens.append(cur); cur = "" }; tokens.append(String(ch)) }
        else if ch == " " || ch == "," { if !cur.isEmpty { tokens.append(cur); cur = "" } }
        else if ch == "-" && !cur.isEmpty && cur.last != "e" { tokens.append(cur); cur = "-" }
        else { cur.append(ch) }
    }
    if !cur.isEmpty { tokens.append(cur) }

    let path = CGMutablePath()
    var i = 0, cmd = "", p = CGPoint.zero
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    while i < tokens.count {
        if tokens[i].first!.isLetter { cmd = tokens[i]; i += 1 }
        switch cmd {
        case "M": p = CGPoint(x: num(), y: num()); path.move(to: p); cmd = "L"
        case "L": p = CGPoint(x: num(), y: num()); path.addLine(to: p)
        case "H": p.x = num(); path.addLine(to: p)
        case "V": p.y = num(); path.addLine(to: p)
        case "Q": let c = CGPoint(x: num(), y: num()); p = CGPoint(x: num(), y: num()); path.addQuadCurve(to: p, control: c)
        case "A":
            let rx = num(), ry = num(), rot = num(), large = num() != 0, sweep = num() != 0
            let end = CGPoint(x: num(), y: num())
            addArc(path, from: p, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
            p = end
        case "Z": path.closeSubpath()
        default: fatalError("unsupported path command \(cmd)")
        }
    }
    return path
}

/// SVG endpoint arc → cubic Béziers (SVG spec, appendix B.2.4).
func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
            rotation: CGFloat, large: Bool, sweep: Bool) {
    var rx = abs(rx0), ry = abs(ry0)
    let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var coef = sqrt(max(0, num / den))
    if large == sweep { coef = -coef }
    let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
    var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
    if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
    let segments = Int(ceil(abs(dt) / (.pi / 2)))
    let step = dt / CGFloat(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func pt(_ t: CGFloat) -> (CGPoint, CGPoint) {  // point and derivative direction
        let ex = rx * cos(t), ey = ry * sin(t), dxe = -rx * sin(t), dye = ry * cos(t)
        return (CGPoint(x: cx + cosP * ex - sinP * ey, y: cy + sinP * ex + cosP * ey),
                CGPoint(x: cosP * dxe - sinP * dye, y: sinP * dxe + cosP * dye))
    }
    var t = t1
    for s in 0..<segments {
        let (a, da) = pt(t), (b, db) = pt(t + step)
        let end = s == segments - 1 ? p1 : b
        path.addCurve(to: end, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                      control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
        t += step
    }
}

let args = CommandLine.arguments.dropFirst()
guard let outPath = args.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <out.png> [--small]\n".data(using: .utf8)!)
    exit(2)
}
let small = args.contains("--small")

let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).cgPath

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Tile with drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(color(0x4B2FD6)); ctx.fillPath()
ctx.restoreGState()

// Gradient #7D6BFF (top-left) → #4B2FD6 (bottom-right), clipped to the tile
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let gradient = CGGradient(colorsSpace: rgb, colors: [color(0x7D6BFF), color(0x4B2FD6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Subtle top highlight
let shine = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// White mark, centered on its bounding box. SVG is y-down, so flip while scaling.
let mark = svgPath(small ? smallMark : fullMark)
let box = mark.boundingBoxOfPath
let grid: CGFloat = small ? 32 : 256
let fraction: CGFloat = small ? 0.70 : 0.62   // share of the tile the mark's grid occupies
let scale = tile.width * fraction / grid
var transform = CGAffineTransform(translationX: tile.midX, y: tile.midY)
    .scaledBy(x: scale, y: -scale)
    .translatedBy(x: -box.midX, y: -box.midY)
ctx.addPath(mark.copy(using: &transform)!)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
