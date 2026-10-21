import Foundation
import CoreGraphics
import CoreText

struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 1, g: 1, b: 1)
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
}

/// A Bézier anchor with its two handles (absolute positions; a handle equal to the anchor means a corner).
struct Node: Codable, Equatable {
    var p: CGPoint
    var i: CGPoint
    var o: CGPoint

    init(_ p: CGPoint) { self.p = p; i = p; o = p }
    init(p: CGPoint, i: CGPoint, o: CGPoint) { self.p = p; self.i = i; self.o = o }

    var isCorner: Bool { i == p && o == p }

    func applying(_ t: CGAffineTransform) -> Node { Node(p: p.applying(t), i: i.applying(t), o: o.applying(t)) }
}

/// One subpath. A compound path (letters, shapes with holes) has several.
struct Contour: Codable, Equatable {
    var nodes: [Node]
    var closed: Bool
}

struct Affine: Codable, Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    static let identity = Affine()
    init() {}
    init(_ t: CGAffineTransform) { a = t.a; b = t.b; c = t.c; d = t.d; tx = t.tx; ty = t.ty }
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    /// Rotation in degrees, for display.
    var rotation: Double { atan2(b, a) * 180 / .pi }
}

struct FillGradient: Codable, Equatable {
    var from: RGBA
    var to: RGBA
    var angle: Double = 0     // degrees, 0 = left → right
    var radial = false
}

struct TextSpec: Codable, Equatable {
    var string: String
    var font = "HelveticaNeue-Bold"
    var size: Double = 64
    var tracking: Double = 0
    var leading: Double = 1.2
    var alignment = 0          // 0 left, 1 center, 2 right
}

enum ItemKind: Codable, Equatable {
    case path([Contour])
    case text(TextSpec)
    case image(UUID, CGSize)
}

enum LineCap: String, Codable, CaseIterable, Identifiable {
    case butt = "Butt", round = "Round", square = "Square"
    var id: String { rawValue }
    var cg: CGLineCap { self == .butt ? .butt : (self == .round ? .round : .square) }
}

enum LineJoin: String, Codable, CaseIterable, Identifiable {
    case miter = "Miter", round = "Round", bevel = "Bevel"
    var id: String { rawValue }
    var cg: CGLineJoin { self == .miter ? .miter : (self == .round ? .round : .bevel) }
}

/// Anything on the artboard. Geometry is in the item's own space; `transform` places it.
struct Item: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var kind: ItemKind
    var transform = Affine.identity
    var fill: RGBA? = RGBA(r: 1, g: 0.8, b: 0.2)
    var gradient: FillGradient?
    var stroke: RGBA? = .black
    var strokeWidth: Double = 2
    var cap: LineCap = .butt
    var join: LineJoin = .miter
    var dashed = false
    var opacity: Double = 1
    var evenOdd = false
    /// Items sharing a group id select and move together.
    var group: UUID?

    var contours: [Contour]? { if case .path(let c) = kind { return c } else { return nil } }
    var isText: Bool { if case .text = kind { return true } else { return false } }
}

struct ArtLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var visible = true
    var locked = false
    var colorIndex = 0
    /// Bottom to top.
    var items: [Item] = []
}

struct ImageAsset: Codable, Equatable, Identifiable {
    var id = UUID()
    var url: URL
    var size: CGSize
}

struct ArtDocument: Codable, Equatable {
    var version = 1
    var width: Double = 1200
    var height: Double = 800
    /// nil = transparent.
    var background: RGBA? = .white
    var layers: [ArtLayer] = [ArtLayer(name: "Layer 1")]
    var images: [ImageAsset] = []

    var size: CGSize { CGSize(width: width, height: height) }

    func image(_ id: UUID) -> ImageAsset? { images.first { $0.id == id } }

    var allItems: [Item] { layers.flatMap(\.items) }

    static let presets: [(String, Double, Double)] = [
        ("Web 1200×800", 1200, 800), ("HD 1920×1080", 1920, 1080), ("Square 1080", 1080, 1080),
        ("Icon 1024", 1024, 1024), ("Letter", 612, 792), ("A4", 595, 842), ("Poster 18×24", 1296, 1728),
    ]
}

// MARK: - Geometry

enum Geo {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func path(_ contours: [Contour], transform t: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        for c in contours where !c.nodes.isEmpty {
            let n = c.nodes.map { $0.applying(t) }
            path.move(to: n[0].p)
            var pairs = Array(zip(n, n.dropFirst()))
            if c.closed && n.count > 1 { pairs.append((n[n.count - 1], n[0])) }
            for (a, b) in pairs {
                if a.o == a.p && b.i == b.p { path.addLine(to: b.p) } else { path.addCurve(to: b.p, control1: a.o, control2: b.i) }
            }
            if c.closed { path.closeSubpath() }
        }
        return path
    }

    /// Back from a CGPath (e.g. a boolean result or a glyph outline) to editable contours.
    static func contours(_ path: CGPath) -> [Contour] {
        var out: [Contour] = []
        var current: Contour?
        func finish() { if let c = current, !c.nodes.isEmpty { out.append(c) }; current = nil }
        path.applyWithBlock { el in
            let e = el.pointee, pts = e.points
            switch e.type {
            case .moveToPoint:
                finish()
                current = Contour(nodes: [Node(pts[0])], closed: false)
            case .addLineToPoint:
                current?.nodes.append(Node(pts[0]))
            case .addQuadCurveToPoint:
                guard let last = current?.nodes.last?.p else { return }
                let c = pts[0], p = pts[1]
                let c1 = CGPoint(x: last.x + 2 / 3 * (c.x - last.x), y: last.y + 2 / 3 * (c.y - last.y))
                let c2 = CGPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y))
                if var c = current, !c.nodes.isEmpty {
                    c.nodes[c.nodes.count - 1].o = c1
                    c.nodes.append(Node(p: p, i: c2, o: p))
                    current = c
                }
            case .addCurveToPoint:
                guard var c = current, !c.nodes.isEmpty else { return }
                c.nodes[c.nodes.count - 1].o = pts[0]
                c.nodes.append(Node(p: pts[2], i: pts[1], o: pts[2]))
                current = c
            case .closeSubpath:
                guard var c = current else { return }
                c.closed = true
                // A closing segment that lands back on the start merges into the first node.
                if c.nodes.count > 1, let first = c.nodes.first, let last = c.nodes.last,
                   hypot(first.p.x - last.p.x, first.p.y - last.p.y) < 0.001 {
                    c.nodes[0].i = last.i
                    c.nodes.removeLast()
                }
                current = c
                finish()
            @unknown default:
                break
            }
        }
        finish()
        return out
    }

    static func rectContour(_ r: CGRect) -> Contour {
        Contour(nodes: [Node(CGPoint(x: r.minX, y: r.minY)), Node(CGPoint(x: r.maxX, y: r.minY)),
                        Node(CGPoint(x: r.maxX, y: r.maxY)), Node(CGPoint(x: r.minX, y: r.maxY))], closed: true)
    }

    static func ellipseContour(_ r: CGRect) -> Contour {
        contours(CGPath(ellipseIn: r, transform: nil)).first ?? rectContour(r)
    }

    /// Regular polygon, or a star when `inner` is given (inner radius as a fraction of the outer).
    static func polygonContour(center c: CGPoint, radius: CGFloat, sides: Int, inner: CGFloat? = nil, rotation: CGFloat = -.pi / 2) -> Contour {
        let count = inner == nil ? max(3, sides) : max(3, sides) * 2
        let nodes = (0..<count).map { k -> Node in
            let r = (inner != nil && k % 2 == 1) ? radius * inner! : radius
            let a = rotation + CGFloat(k) / CGFloat(count) * 2 * .pi
            return Node(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        return Contour(nodes: nodes, closed: true)
    }

    /// Fits smooth Béziers through freehand points: simplify, then Catmull-Rom → cubic.
    static func smoothContour(_ raw: [CGPoint], tolerance: CGFloat, closed: Bool) -> Contour {
        let pts = simplify(raw, tolerance: tolerance)
        guard pts.count > 2 else { return Contour(nodes: pts.map(Node.init), closed: closed) }
        var nodes: [Node] = []
        let n = pts.count
        for k in 0..<n {
            let prev = closed ? pts[(k - 1 + n) % n] : pts[max(0, k - 1)]
            let next = closed ? pts[(k + 1) % n] : pts[min(n - 1, k + 1)]
            let tangent = CGPoint(x: (next.x - prev.x) / 6, y: (next.y - prev.y) / 6)
            let p = pts[k]
            var node = Node(p: p, i: CGPoint(x: p.x - tangent.x, y: p.y - tangent.y), o: CGPoint(x: p.x + tangent.x, y: p.y + tangent.y))
            if !closed && k == 0 { node.i = p }
            if !closed && k == n - 1 { node.o = p }
            nodes.append(node)
        }
        return Contour(nodes: nodes, closed: closed)
    }

    /// Ramer–Douglas–Peucker.
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        func dist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            return len == 0 ? hypot(p.x - a.x, p.y - a.y) : abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
        }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var best = s, bestD: CGFloat = 0
            for k in (s + 1)..<e {
                let d = dist(pts[k], pts[s], pts[e])
                if d > bestD { bestD = d; best = k }
            }
            if bestD > tolerance { keep[best] = true; stack += [(s, best), (best, e)] }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}

// MARK: - Text layout

enum TextLayout {
    static func font(_ spec: TextSpec) -> CTFont { CTFontCreateWithName(spec.font as CFString, spec.size, nil) }

    /// One CTLine per paragraph, positioned by baseline in the item's own space (y down).
    static func lines(_ spec: TextSpec, color: CGColor? = nil) -> [(line: CTLine, origin: CGPoint)] {
        let font = font(spec)
        var attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                    .init(kCTKernAttributeName as String): spec.tracking]
        if let color { attrs[.init(kCTForegroundColorAttributeName as String)] = color }
        let paragraphs = spec.string.components(separatedBy: "\n")
        let lineHeight = spec.size * spec.leading
        let ascent = CTFontGetAscent(font)
        let made = paragraphs.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        let widths = made.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let maxW = widths.max() ?? 0
        return made.enumerated().map { k, line in
            let x: CGFloat = spec.alignment == 1 ? (maxW - widths[k]) / 2 : (spec.alignment == 2 ? maxW - widths[k] : 0)
            return (line, CGPoint(x: x, y: ascent + CGFloat(k) * lineHeight))
        }
    }

    static func bounds(_ spec: TextSpec) -> CGRect {
        let ls = lines(spec)
        let w = ls.map { CGFloat(CTLineGetTypographicBounds($0.line, nil, nil, nil)) + $0.origin.x }.max() ?? 0
        let font = font(spec)
        let h = CGFloat(max(0, ls.count - 1)) * spec.size * spec.leading + CTFontGetAscent(font) + CTFontGetDescent(font)
        return CGRect(x: 0, y: 0, width: max(w, 4), height: h)
    }

    /// Glyph outlines in the item's own space.
    static func outlines(_ spec: TextSpec) -> CGPath {
        let path = CGMutablePath()
        for (line, origin) in lines(spec) {
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let n = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font(spec)
                for k in 0..<n {
                    // Glyphs are y-up; flip them onto the baseline.
                    var t = CGAffineTransform(translationX: origin.x + positions[k].x, y: origin.y).scaledBy(x: 1, y: -1)
                    if let g = CTFontCreatePathForGlyph(runFont, glyphs[k], &t) { path.addPath(g) }
                }
            }
        }
        return path
    }
}

extension Item {
    /// Bounds in the item's own space.
    var localBounds: CGRect {
        switch kind {
        case .path(let c): return Geo.path(c).boundingBoxOfPath
        case .text(let spec): return TextLayout.bounds(spec)
        case .image(_, let size): return CGRect(origin: .zero, size: size)
        }
    }

    /// The outline in artboard space (for hit testing, booleans and export).
    var worldPath: CGPath {
        switch kind {
        case .path(let c): return Geo.path(c, transform: transform.cg)
        case .text(let spec):
            var t = transform.cg
            return TextLayout.outlines(spec).copy(using: &t) ?? CGPath(rect: .zero, transform: nil)
        case .image(_, let size):
            return CGPath(rect: CGRect(origin: .zero, size: size), transform: [transform.cg])
        }
    }

    /// Artboard-space bounds, including half the stroke.
    var bounds: CGRect {
        let b = geometryBounds
        guard case .path = kind, stroke != nil else { return b }
        return b.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
    }

    /// Bounds of the geometry alone (what the selection box shows).
    var geometryBounds: CGRect {
        if case .path(let c) = kind { return Geo.path(c, transform: transform.cg).boundingBoxOfPath }
        return localBounds.applying(transform.cg)
    }
}
