import EaselKit
import CoreGraphics

enum Geometry {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Adjusts `b` so the box from `a` has the given width/height ratio.
    static func constrain(_ a: CGPoint, _ b: CGPoint, ratio: CGFloat) -> CGPoint {
        var w = b.x - a.x, h = b.y - a.y
        let sw: CGFloat = w < 0 ? -1 : 1, sh: CGFloat = h < 0 ? -1 : 1
        if abs(w) / ratio > abs(h) { h = sh * abs(w) / ratio } else { w = sw * abs(h) * ratio }
        return CGPoint(x: a.x + w, y: a.y + h)
    }

    /// Snaps the direction from `a` to `b` to 45° increments.
    static func snapAngle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }
}

enum ShapeDrawer {
    static func draw(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint, filled: Bool,
                     lineWidth: CGFloat, color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        let box = Geometry.rect(a, b)
        // Keep strokes inside the dragged box.
        let r = filled || box.width <= lineWidth || box.height <= lineWidth ? box : box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        switch kind {
        case .rectangle:
            ctx.addRect(r)
        case .rounded:
            let radius = min(r.width, r.height) * 0.2
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case .ellipse:
            ctx.addEllipse(in: r)
        case .star:
            ctx.addPath(star(in: r))
        case .line:
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            return
        case .arrow:
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { return }
            let head = min(len, max(lineWidth * 3.5, 14))
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
            ctx.move(to: a)
            ctx.addLine(to: base)
            ctx.strokePath()
            let half = head * 0.6
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            ctx.closePath()
            ctx.fillPath()
            return
        }
        if filled { ctx.fillPath() } else { ctx.strokePath() }
    }

    private static func star(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY)
        let outerX = r.width / 2, outerY = r.height / 2
        for i in 0..<10 {
            let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let k: CGFloat = i % 2 == 0 ? 1 : 0.4
            let p = CGPoint(x: c.x + cos(angle) * outerX * k, y: c.y + sin(angle) * outerY * k)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    static func gradient(from a: CGPoint, to b: CGPoint, colors: [CGColor], in ctx: CGContext) {
        guard let g = CGGradient(colorsSpace: Bitmap.colorSpace, colors: colors as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
