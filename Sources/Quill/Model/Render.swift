import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import EaselKit

/// Decoded placed images, shared by the canvas and exports.
final class ImageStore: @unchecked Sendable {
    private var cache: [UUID: CGImage] = [:]
    private let lock = NSLock()

    func image(_ asset: ImageAsset) -> CGImage? {
        lock.withLock {
            if let hit = cache[asset.id] { return hit }
            let img = Bitmap.load(url: asset.url)
            cache[asset.id] = img
            return img
        }
    }
}

enum QuillRenderer {
    /// Draws the artwork into a y-down context in artboard units.
    static func draw(_ doc: ArtDocument, in ctx: CGContext, images: ImageStore, background: Bool = true, skipping: Set<UUID> = []) {
        if background, let bg = doc.background {
            ctx.setFillColor(bg.cg)
            ctx.fill(CGRect(origin: .zero, size: doc.size))
        }
        for layer in doc.layers where layer.visible {
            for item in layer.items where !skipping.contains(item.id) { drawItem(item, doc: doc, in: ctx, images: images) }
        }
    }

    static func drawItem(_ item: Item, doc: ArtDocument, in ctx: CGContext, images: ImageStore) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let layered = item.opacity < 1
        if layered { ctx.setAlpha(item.opacity); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer { if layered { ctx.endTransparencyLayer() } }

        switch item.kind {
        case .path:
            let path = item.worldPath
            if let g = item.gradient {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip(using: item.evenOdd ? .evenOdd : .winding)
                drawGradient(g, in: path.boundingBoxOfPath, ctx: ctx)
                ctx.restoreGState()
            } else if let fill = item.fill {
                ctx.addPath(path)
                ctx.setFillColor(fill.cg)
                ctx.fillPath(using: item.evenOdd ? .evenOdd : .winding)
            }
            if let stroke = item.stroke, item.strokeWidth > 0 {
                ctx.addPath(path)
                applyStroke(item, color: stroke, ctx: ctx)
                ctx.strokePath()
            }
        case .text(let spec):
            ctx.concatenate(item.transform.cg)
            if let g = item.gradient {
                let outline = TextLayout.outlines(spec)
                ctx.saveGState()
                ctx.addPath(outline)
                ctx.clip()
                drawGradient(g, in: outline.boundingBoxOfPath, ctx: ctx)
                ctx.restoreGState()
            } else if let fill = item.fill {
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                for (line, origin) in TextLayout.lines(spec, color: fill.cg) {
                    ctx.textPosition = origin
                    CTLineDraw(line, ctx)
                }
            }
            if let stroke = item.stroke, item.strokeWidth > 0 {
                ctx.addPath(TextLayout.outlines(spec))
                applyStroke(item, color: stroke, ctx: ctx)
                ctx.strokePath()
            }
        case .image(let id, let size):
            guard let asset = doc.image(id), let img = images.image(asset) else { return }
            ctx.concatenate(item.transform.cg)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
        }
    }

    private static func applyStroke(_ item: Item, color: RGBA, ctx: CGContext) {
        ctx.setStrokeColor(color.cg)
        ctx.setLineWidth(item.strokeWidth)
        ctx.setLineCap(item.cap.cg)
        ctx.setLineJoin(item.join.cg)
        if item.dashed { ctx.setLineDash(phase: 0, lengths: [item.strokeWidth * 3, item.strokeWidth * 2]) }
    }

    /// End points of a linear gradient running at `angle` across `r`.
    static func gradientLine(_ g: FillGradient, in r: CGRect) -> (CGPoint, CGPoint) {
        let a = g.angle * .pi / 180, dx = cos(a), dy = sin(a)
        let half = (abs(r.width * dx) + abs(r.height * dy)) / 2
        return (CGPoint(x: r.midX - dx * half, y: r.midY - dy * half), CGPoint(x: r.midX + dx * half, y: r.midY + dy * half))
    }

    static func drawGradient(_ g: FillGradient, in r: CGRect, ctx: CGContext) {
        guard let gradient = CGGradient(colorsSpace: Bitmap.colorSpace, colors: [g.from.cg, g.to.cg] as CFArray, locations: [0, 1]) else { return }
        if g.radial {
            let c = CGPoint(x: r.midX, y: r.midY)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: hypot(r.width, r.height) / 2,
                                   options: [.drawsAfterEndLocation])
        } else {
            let (a, b) = gradientLine(g, in: r)
            ctx.drawLinearGradient(gradient, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: Raster & PDF

    static func image(_ doc: ArtDocument, images: ImageStore, scale: CGFloat = 1, background: Bool = true) -> CGImage {
        Bitmap.render(CGSize(width: doc.width * scale, height: doc.height * scale)) { ctx in
            ctx.translateBy(x: 0, y: doc.height * scale)
            ctx.scaleBy(x: scale, y: -scale)
            draw(doc, in: ctx, images: images, background: background)
        }
    }

    static func pdf(_ doc: ArtDocument, images: ImageStore) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: doc.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: doc.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(doc, in: ctx, images: images)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func encode(_ img: CGImage, type: UTType, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: SVG

    static func svg(_ doc: ArtDocument, images: ImageStore) -> String {
        func n(_ v: Double) -> String {
            let s = String(format: "%.2f", v)
            return s.hasSuffix(".00") ? String(s.dropLast(3)) : s
        }
        func pt(_ p: CGPoint) -> String { "\(n(p.x)) \(n(p.y))" }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func pathData(_ contours: [Contour]) -> String {
            var d = ""
            for c in contours where !c.nodes.isEmpty {
                d += "M\(pt(c.nodes[0].p))"
                var pairs = Array(zip(c.nodes, c.nodes.dropFirst()))
                if c.closed && c.nodes.count > 1 { pairs.append((c.nodes[c.nodes.count - 1], c.nodes[0])) }
                for (a, b) in pairs {
                    d += (a.o == a.p && b.i == b.p) ? "L\(pt(b.p))" : "C\(pt(a.o)) \(pt(b.i)) \(pt(b.p))"
                }
                if c.closed { d += "Z" }
            }
            return d
        }
        func matrix(_ t: Affine) -> String { "matrix(\(n(t.a)) \(n(t.b)) \(n(t.c)) \(n(t.d)) \(n(t.tx)) \(n(t.ty)))" }

        var defs: [String] = []
        var body: [String] = []
        func paint(_ item: Item, box: CGRect, local: Bool) -> String {
            var a = ""
            if let g = item.gradient {
                let gid = "g\(defs.count + 1)"
                let stops = "<stop offset=\"0\" stop-color=\"\(g.from.hex)\" stop-opacity=\"\(n(g.from.a))\"/><stop offset=\"1\" stop-color=\"\(g.to.hex)\" stop-opacity=\"\(n(g.to.a))\"/>"
                if g.radial {
                    let radius = Double(hypot(box.width, box.height)) / 2
                    defs.append("<radialGradient id=\"\(gid)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(n(box.midX))\" cy=\"\(n(box.midY))\" r=\"\(n(radius))\">\(stops)</radialGradient>")
                } else {
                    let (p, q) = gradientLine(g, in: box)
                    defs.append("<linearGradient id=\"\(gid)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(p.x))\" y1=\"\(n(p.y))\" x2=\"\(n(q.x))\" y2=\"\(n(q.y))\">\(stops)</linearGradient>")
                }
                a += " fill=\"url(#\(gid))\""
            } else if let f = item.fill {
                a += " fill=\"\(f.hex)\"" + (f.a < 1 ? " fill-opacity=\"\(n(f.a))\"" : "")
            } else {
                a += " fill=\"none\""
            }
            if item.evenOdd { a += " fill-rule=\"evenodd\"" }
            if let s = item.stroke, item.strokeWidth > 0 {
                a += " stroke=\"\(s.hex)\" stroke-width=\"\(n(item.strokeWidth))\""
                if s.a < 1 { a += " stroke-opacity=\"\(n(s.a))\"" }
                if item.cap != .butt { a += " stroke-linecap=\"\(item.cap.rawValue.lowercased())\"" }
                if item.join != .miter { a += " stroke-linejoin=\"\(item.join.rawValue.lowercased())\"" }
                if item.dashed { a += " stroke-dasharray=\"\(n(item.strokeWidth * 3)) \(n(item.strokeWidth * 2))\"" }
            }
            if item.opacity < 1 { a += " opacity=\"\(n(item.opacity))\"" }
            return a
        }

        for layer in doc.layers where layer.visible {
            body.append("<g id=\"\(esc(layer.name))\">")
            for item in layer.items {
                switch item.kind {
                case .path(let c):
                    let world = c.map { Contour(nodes: $0.nodes.map { $0.applying(item.transform.cg) }, closed: $0.closed) }
                    body.append("<path d=\"\(pathData(world))\"\(paint(item, box: item.geometryBounds, local: false))/>")
                case .text(let spec):
                    let font = TextLayout.font(spec)
                    let family = CTFontCopyFamilyName(font) as String
                    let traits = CTFontGetSymbolicTraits(font)
                    var attrs = " font-family=\"\(esc(family))\" font-size=\"\(n(spec.size))\""
                    if traits.contains(.traitBold) { attrs += " font-weight=\"bold\"" }
                    if traits.contains(.traitItalic) { attrs += " font-style=\"italic\"" }
                    if spec.tracking != 0 { attrs += " letter-spacing=\"\(n(spec.tracking))\"" }
                    let spans = zip(spec.string.components(separatedBy: "\n"), TextLayout.lines(spec)).map { text, l in
                        "<tspan x=\"\(n(l.origin.x))\" y=\"\(n(l.origin.y))\">\(esc(text))</tspan>"
                    }.joined()
                    body.append("<text transform=\"\(matrix(item.transform))\"\(attrs)\(paint(item, box: item.localBounds, local: true))>\(spans)</text>")
                case .image(let id, let size):
                    guard let asset = doc.image(id), let img = images.image(asset), let png = Bitmap.png(img) else { continue }
                    body.append("<image transform=\"\(matrix(item.transform))\" width=\"\(n(size.width))\" height=\"\(n(size.height))\" href=\"data:image/png;base64,\(png.base64EncodedString())\"\(item.opacity < 1 ? " opacity=\"\(n(item.opacity))\"" : "")/>")
                }
            }
            body.append("</g>")
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(doc.width))\" height=\"\(n(doc.height))\" viewBox=\"0 0 \(n(doc.width)) \(n(doc.height))\">\n"
        if !defs.isEmpty { out += "<defs>\(defs.joined())</defs>\n" }
        if let bg = doc.background { out += "<rect width=\"100%\" height=\"100%\" fill=\"\(bg.hex)\"/>\n" }
        out += body.joined(separator: "\n") + "\n</svg>\n"
        return out
    }
}
