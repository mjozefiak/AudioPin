import AppKit

/// The "Needle Wave" brand mark (docs/assets/brand/), drawn from its SVG path data
/// so the menu bar needs no image resources.
enum BrandMark {
    /// logo-mark-small.svg (32 grid) — the simplified mark that stays legible at menu bar size.
    static let smallPath = "M5 15A2 2 0 0 1 9 15V21A2 2 0 0 1 5 21ZM23 15A2 2 0 0 1 27 15V21A2 2 0 0 1 23 21ZM16 5A5 5 0 1 1 16 15A5 5 0 1 1 16 5ZM14 13H18L17 26.5Q16 28.5 15 26.5Z"

    /// Template images for the menu bar: the mark (active) and the mark with a slash cut through it (paused).
    @MainActor static let active = menuBarImage(slashed: false)
    @MainActor static let paused = menuBarImage(slashed: true)

    /// Status-item sized template image: 18 pt canvas, mark 16 pt tall, centered.
    static func menuBarImage(slashed: Bool, pathData: String = smallPath) -> NSImage {
        let mark = path(pathData)
        let box = mark.boundingBoxOfPath
        let canvas = NSSize(width: 18, height: 18)
        let image = NSImage(size: canvas, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = 16 / box.height
            // SVG is y-down: flip while scaling, centered on the mark's bounding box.
            var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: scale, y: -scale)
                .translatedBy(x: -box.midX, y: -box.midY)
            ctx.addPath(mark.copy(using: &transform) ?? mark)
            ctx.setFillColor(.black)
            ctx.fillPath()
            if slashed {
                let from = CGPoint(x: rect.minX + 2, y: rect.maxY - 1.5)
                let to = CGPoint(x: rect.maxX - 2, y: rect.minY + 1.5)
                ctx.setLineCap(.round)
                ctx.setBlendMode(.clear)       // cut a gap around the slash
                ctx.setLineWidth(3.5)
                ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
                ctx.setBlendMode(.normal)
                ctx.setStrokeColor(.black)
                ctx.setLineWidth(1.5)
                ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = slashed ? String(localized: "AudioPin (paused)") : "AudioPin"
        return image
    }

    /// Minimal SVG path parser for the absolute M/L/H/V/Q/A/Z commands the brand marks use.
    /// Stops at the first unsupported command or malformed number.
    static func path(_ d: String) -> CGPath {
        var tokens: [String] = []
        var cur = ""
        for ch in d {
            if ch.isLetter {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(String(ch))
            } else if ch == " " || ch == "," {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty && cur.last != "e" {
                tokens.append(cur); cur = "-"
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }

        let path = CGMutablePath()
        var i = 0, cmd = "", p = CGPoint.zero
        func nums(_ n: Int) -> [CGFloat]? {
            guard i + n <= tokens.count else { return nil }
            let values = tokens[i..<i + n].compactMap(Double.init).map { CGFloat($0) }
            guard values.count == n else { return nil }
            i += n
            return values
        }
        while i < tokens.count {
            if tokens[i].first?.isLetter == true { cmd = tokens[i]; i += 1 }
            switch cmd {
            case "M":
                guard let v = nums(2) else { return path }
                p = CGPoint(x: v[0], y: v[1]); path.move(to: p); cmd = "L"
            case "L":
                guard let v = nums(2) else { return path }
                p = CGPoint(x: v[0], y: v[1]); path.addLine(to: p)
            case "H":
                guard let v = nums(1) else { return path }
                p.x = v[0]; path.addLine(to: p)
            case "V":
                guard let v = nums(1) else { return path }
                p.y = v[0]; path.addLine(to: p)
            case "Q":
                guard let v = nums(4) else { return path }
                p = CGPoint(x: v[2], y: v[3]); path.addQuadCurve(to: p, control: CGPoint(x: v[0], y: v[1]))
            case "A":
                guard let v = nums(7) else { return path }
                let end = CGPoint(x: v[5], y: v[6])
                addArc(path, from: p, to: end, rx: v[0], ry: v[1], rotation: v[2], large: v[3] != 0, sweep: v[4] != 0)
                p = end
            case "Z":
                path.closeSubpath()
            default:
                return path
            }
        }
        return path
    }

    /// SVG endpoint arc → cubic Béziers (SVG spec, appendix B.2.4).
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
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
        let segments = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: CGFloat) -> (CGPoint, CGPoint) {  // point and derivative direction
            let ex = rx * cos(t), ey = ry * sin(t), dxe = -rx * sin(t), dye = ry * cos(t)
            return (CGPoint(x: cx + cosP * ex - sinP * ey, y: cy + sinP * ex + cosP * ey),
                    CGPoint(x: cosP * dxe - sinP * dye, y: sinP * dxe + cosP * dye))
        }
        var t = t1
        for s in 0..<segments {
            let (a, da) = point(t), (b, db) = point(t + step)
            let end = s == segments - 1 ? p1 : b
            path.addCurve(to: end, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }
}
