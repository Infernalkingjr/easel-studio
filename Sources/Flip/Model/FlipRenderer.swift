import AppKit
import CoreGraphics
import EaselKit

/// Decoded images used by image strokes.
final class ImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [UUID: CGImage] = [:]

    func image(_ asset: ImageAsset) -> CGImage? {
        lock.withLock {
            if let hit = images[asset.id] { return hit }
            let img = Bitmap.load(url: asset.url)
            images[asset.id] = img
            return img
        }
    }

    func reset(_ id: UUID) { lock.withLock { images[id] = nil } }
}

enum FlipRenderer {
    struct Onion {
        var before = 2
        var after = 2
    }

    /// Draws `frame` in document coordinates (y down). The context must already map document space.
    static func draw(_ doc: FlipDocument, frame: Int, in ctx: CGContext, images: ImageStore,
                     onion: Onion? = nil, background: Bool = true) {
        let rect = CGRect(origin: .zero, size: doc.size)
        if background, let bg = doc.background {
            ctx.setFillColor(bg.cg)
            ctx.fill(rect)
        }
        // Bottom layer first: the timeline lists layers top-down.
        for layer in doc.layers.reversed() where layer.visible {
            if let onion {
                for k in stride(from: onion.before, through: 1, by: -1) where frame - k >= 0 {
                    drawLayer(layer, frame: frame - k, doc: doc, ctx: ctx, images: images,
                              tint: CGColor(srgbRed: 0.95, green: 0.2, blue: 0.25, alpha: 1), alpha: 0.32 / Double(k))
                }
                for k in stride(from: onion.after, through: 1, by: -1) where frame + k < doc.usedFrames {
                    drawLayer(layer, frame: frame + k, doc: doc, ctx: ctx, images: images,
                              tint: CGColor(srgbRed: 0.15, green: 0.75, blue: 0.35, alpha: 1), alpha: 0.32 / Double(k))
                }
            }
            drawLayer(layer, frame: frame, doc: doc, ctx: ctx, images: images)
        }
    }

    static func drawLayer(_ layer: AnimLayer, frame: Int, doc: FlipDocument, ctx: CGContext, images: ImageStore,
                          tint: CGColor? = nil, alpha: Double = 1) {
        guard let pose = layer.pose(at: frame), !pose.drawing.strokes.isEmpty else { return }
        // Onion skins only show frames that look different from the current one.
        ctx.saveGState()
        ctx.setAlpha(alpha * pose.placement.opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.concatenate(pose.placement.transform(pivot: pose.drawing.pivot(in: doc.size)))
        for stroke in pose.drawing.strokes { drawStroke(stroke, doc: doc, ctx: ctx, images: images) }
        if let tint {
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(tint)
            ctx.fill(CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func smoothPath(_ points: [CGPoint], closed: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { path.addLine(to: p) }
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
        } else {
            for i in 1..<points.count - 1 {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        if closed { path.closeSubpath() }
        return path
    }

    static func drawStroke(_ s: Stroke, doc: FlipDocument, ctx: CGContext, images: ImageStore) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(s.color.cg)
        ctx.setLineWidth(s.width)
        switch s.kind {
        case .image:
            guard s.points.count >= 2, let id = s.imageID, let asset = doc.images.first(where: { $0.id == id }),
                  let img = images.image(asset) else { return }
            let r = CGRect(x: min(s.points[0].x, s.points[1].x), y: min(s.points[0].y, s.points[1].y),
                           width: abs(s.points[1].x - s.points[0].x), height: abs(s.points[1].y - s.points[0].y))
            // Document space is y-down; flip locally so the image is upright.
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        case .line:
            guard s.points.count >= 2 else { return }
            ctx.strokeLineSegments(between: [s.points[0], s.points[s.points.count - 1]])
        case .rect, .ellipse:
            guard s.points.count >= 2 else { return }
            let r = CGRect(x: min(s.points[0].x, s.points[1].x), y: min(s.points[0].y, s.points[1].y),
                           width: abs(s.points[1].x - s.points[0].x), height: abs(s.points[1].y - s.points[0].y))
            let path = s.kind == .rect ? CGPath(rect: r, transform: nil) : CGPath(ellipseIn: r, transform: nil)
            if let fill = s.fill {
                ctx.addPath(path)
                ctx.setFillColor(fill.cg)
                ctx.fillPath()
            }
            if s.width > 0 {
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .brush:
            if let fill = s.fill, s.isClosed {
                ctx.addPath(smoothPath(s.points, closed: true))
                ctx.setFillColor(fill.cg)
                ctx.fillPath()
            }
            let varying = s.pressures.count == s.points.count && Set(s.pressures.map { Int($0 * 20) }).count > 1
            if !varying || s.points.count < 2 {
                ctx.addPath(smoothPath(s.points))
                ctx.strokePath()
            } else {
                // Pressure: draw segment by segment, grouped so overlaps don't darken translucent ink.
                ctx.setAlpha(s.color.a)
                ctx.setStrokeColor(s.color.cg.copy(alpha: 1) ?? s.color.cg)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                for i in 1..<s.points.count {
                    let p = Double(s.pressures[i - 1] + s.pressures[i]) / 2
                    ctx.setLineWidth(max(0.5, s.width * (0.15 + 0.85 * p)))
                    ctx.strokeLineSegments(between: [s.points[i - 1], s.points[i]])
                }
                ctx.endTransparencyLayer()
            }
        }
    }

    /// Renders a frame to an image (for export and thumbnails).
    static func image(_ doc: FlipDocument, frame: Int, images: ImageStore, scale: CGFloat = 1, background: Bool = true) -> CGImage {
        let size = CGSize(width: (doc.width * scale).rounded(), height: (doc.height * scale).rounded())
        return Bitmap.render(size) { ctx in
            // Bitmap contexts are y-up; documents are y-down.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: scale, y: -scale)
            draw(doc, frame: frame, in: ctx, images: images, background: background)
        }
    }
}
