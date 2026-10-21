import AppKit
import SwiftUI
import Observation

struct StageView: NSViewRepresentable {
    let studio: FlipStudio
    func makeNSView(context: Context) -> StageNSView { StageNSView(studio: studio) }
    func updateNSView(_ nsView: StageNSView, context: Context) {}
}

/// The drawing surface. Document coordinates are y-down, like the view (flipped).
final class StageNSView: NSView {
    private let studio: FlipStudio
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var isTracking = false
    private var lastFit = -1
    private var hadSize = false

    private enum Gesture {
        case none
        case pan(start: CGPoint, offset: CGPoint)
        case draw(Stroke)
        case shape(kind: StrokeKind, start: CGPoint, end: CGPoint)
        case erase([CGPoint])
        case move(start: CGPoint, original: Placement, began: Bool)
        case scale(pivot: CGPoint, startDistance: CGFloat, original: Placement, began: Bool)
        case rotate(pivot: CGPoint, startAngle: CGFloat, original: Placement, began: Bool)
    }

    private var gesture: Gesture = .none
    private var spaceDown = false
    private var keyMonitor: Any?
    private var smoothed: CGPoint?

    init(studio: FlipStudio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard keyMonitor == nil, window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self, e.keyCode == 49, e.window === self.window, !(self.window?.firstResponder is NSText),
                  self.studio.tool != .hand, e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            // Space pans while held (and plays on a quick tap, handled by the key catcher on key-up).
            if e.type == .keyDown, !e.isARepeat { self.spaceDown = true; NSCursor.openHand.set() }
            if e.type == .keyUp { self.spaceDown = false; NSCursor.crosshair.set() }
            return e
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !hadSize, newSize.width > 0 { hadSize = true; fit() }
    }

    func fit() {
        let doc = studio.doc
        guard bounds.width > 0 else { return }
        zoom = min((bounds.width - 60) / doc.width, (bounds.height - 60) / doc.height, 4)
        offset = .zero
        needsDisplay = true
    }

    private var origin: CGPoint {
        let doc = studio.doc
        let x = (bounds.width - doc.width * zoom) / 2 + offset.x
        let y = (bounds.height - doc.height * zoom) / 2 + offset.y
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func toDoc(_ p: CGPoint) -> CGPoint {
        let o = origin
        return CGPoint(x: (p.x - o.x) / zoom, y: (p.y - o.y) / zoom)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let o = origin
        return CGPoint(x: o.x + p.x * zoom, y: o.y + p.y * zoom)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isTracking {
            render()
        } else {
            isTracking = true
            withObservationTracking { render() } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.isTracking = false
                    self?.needsDisplay = true
                }
            }
        }
    }

    private func render() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if studio.fitRequest != lastFit { lastFit = studio.fitRequest; fit() }
        let doc = studio.doc
        NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1).setFill()
        bounds.fill()

        let o = origin
        let canvas = CGRect(x: o.x, y: o.y, width: doc.width * zoom, height: doc.height * zoom)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 18, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(.white)
        ctx.fill(canvas)
        ctx.restoreGState()
        if doc.background == nil {
            // Checkerboard for transparency.
            let s: CGFloat = 10
            ctx.saveGState()
            ctx.clip(to: canvas)
            ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
            var y = canvas.minY
            var row = 0
            while y < canvas.maxY {
                var x = canvas.minX + (row % 2 == 0 ? 0 : s)
                while x < canvas.maxX { ctx.fill(CGRect(x: x, y: y, width: s, height: s)); x += 2 * s }
                y += s
                row += 1
            }
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.clip(to: canvas)
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: zoom, y: zoom)
        let onion = studio.onion && !studio.isPlaying ? FlipRenderer.Onion() : nil
        FlipRenderer.draw(doc, frame: studio.frame, in: ctx, images: studio.images, onion: onion)

        // In-progress marks.
        switch gesture {
        case .draw(let s):
            FlipRenderer.drawStroke(s, doc: doc, ctx: ctx, images: studio.images)
        case .shape(let kind, let a, let b):
            var s = Stroke(kind: kind, points: [a, b], color: studio.color, width: studio.brushSize)
            if studio.shapeFill && kind != .line { s.fill = studio.fillColor }
            FlipRenderer.drawStroke(s, doc: doc, ctx: ctx, images: studio.images)
        case .erase(let path):
            ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.35))
            ctx.setLineWidth(studio.eraserSize)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: path)
            ctx.strokePath()
        default:
            break
        }
        ctx.restoreGState()

        if studio.tool == .select && !studio.isPlaying { drawTransformBox(ctx) }
    }

    /// Corners of the current layer's drawing, as placed on this frame (document space).
    private func poseQuad() -> (corners: [CGPoint], pivot: CGPoint, rotateKnob: CGPoint)? {
        let layer = studio.layer
        guard let pose = layer.pose(at: studio.frame), !pose.drawing.strokes.isEmpty else { return nil }
        let b = pose.drawing.bounds
        let pivot = pose.drawing.pivot(in: studio.doc.size)
        let t = pose.placement.transform(pivot: pivot)
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            .map { $0.applying(t) }
        let topMid = CGPoint(x: b.midX, y: b.minY).applying(t)
        let center = pivot.applying(t)
        // Knob sits outside the top edge, along the box's own "up" direction.
        let dx = topMid.x - center.x, dy = topMid.y - center.y, len = max(1, hypot(dx, dy))
        let knob = CGPoint(x: topMid.x + dx / len * 28 / zoom, y: topMid.y + dy / len * 28 / zoom)
        return (corners, center, knob)
    }

    private func drawTransformBox(_ ctx: CGContext) {
        guard let q = poseQuad() else { return }
        let pts = q.corners.map(toView)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addLines(between: pts + [pts[0]])
        ctx.strokePath()
        let knob = toView(q.rotateKnob)
        let topMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        ctx.strokeLineSegments(between: [topMid, knob])
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        ctx.strokeEllipse(in: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        for p in pts {
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.fill(r)
            ctx.stroke(r)
        }
        let c = toView(q.pivot)
        ctx.strokeEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        ctx.restoreGState()
    }

    // MARK: Mouse

    private func pressure(_ e: NSEvent) -> Float {
        e.subtype == .tabletPoint ? max(0.05, e.pressure) : 1
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let v = convert(e.locationInWindow, from: nil)
        let p = toDoc(v)
        if spaceDown || studio.tool == .hand {
            if e.clickCount == 2 { fit(); return }
            gesture = .pan(start: v, offset: offset)
            NSCursor.closedHand.set()
            return
        }
        studio.pause()
        switch studio.tool {
        case .brush:
            smoothed = p
            gesture = .draw(Stroke(kind: .brush, points: [p], pressures: [pressure(e)], color: studio.color, width: studio.brushSize))
        case .line: gesture = .shape(kind: .line, start: p, end: p)
        case .rect: gesture = .shape(kind: .rect, start: p, end: p)
        case .ellipse: gesture = .shape(kind: .ellipse, start: p, end: p)
        case .eraser: gesture = .erase([p])
        case .fill: studio.fill(at: p)
        case .eyedropper: studio.pickColor(at: p)
        case .select:
            guard let q = poseQuad() else { return }
            let original = studio.currentPlacement
            let knob = toView(q.rotateKnob)
            if hypot(knob.x - v.x, knob.y - v.y) < 10 {
                gesture = .rotate(pivot: q.pivot, startAngle: atan2(p.y - q.pivot.y, p.x - q.pivot.x), original: original, began: false)
            } else if q.corners.map(toView).contains(where: { hypot($0.x - v.x, $0.y - v.y) < 9 }) {
                gesture = .scale(pivot: q.pivot, startDistance: max(1, hypot(p.x - q.pivot.x, p.y - q.pivot.y)), original: original, began: false)
            } else {
                gesture = .move(start: p, original: original, began: false)
            }
        case .hand:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil)
        var p = toDoc(v)
        let shift = e.modifierFlags.contains(.shift)
        switch gesture {
        case .none:
            return
        case .pan(let start, let o):
            offset = CGPoint(x: o.x + v.x - start.x, y: o.y + v.y - start.y)
        case .draw(var s):
            if shift, let first = s.points.first {
                s.points = [first, p]
                s.pressures = [s.pressures.first ?? 1, pressure(e)]
            } else {
                // Smoothing: each point eases toward the pointer, ironing out hand jitter.
                let k = CGFloat(1 - studio.smoothing * 0.85)
                let prev = smoothed ?? p
                let q = CGPoint(x: prev.x + (p.x - prev.x) * k, y: prev.y + (p.y - prev.y) * k)
                smoothed = q
                if let last = s.points.last, hypot(q.x - last.x, q.y - last.y) * zoom < 1.5 { return }
                s.points.append(q)
                s.pressures.append(pressure(e))
            }
            gesture = .draw(s)
        case .shape(let kind, let a, _):
            if shift {
                if kind == .line {
                    let ang = (atan2(p.y - a.y, p.x - a.x) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(p.x - a.x, p.y - a.y)
                    p = CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
                } else {
                    let d = max(abs(p.x - a.x), abs(p.y - a.y))
                    p = CGPoint(x: a.x + (p.x < a.x ? -d : d), y: a.y + (p.y < a.y ? -d : d))
                }
            }
            gesture = .shape(kind: kind, start: a, end: p)
        case .erase(var path):
            path.append(p)
            gesture = .erase(path)
        case .move(let start, let original, let began):
            var pl = original
            pl.x += p.x - start.x
            pl.y += p.y - start.y
            if shift { if abs(p.x - start.x) > abs(p.y - start.y) { pl.y = original.y } else { pl.x = original.x } }
            studio.setPlacement(pl, checkpoint: !began)
            gesture = .move(start: start, original: original, began: true)
        case .scale(let pivot, let d0, let original, let began):
            var pl = original
            pl.scale = max(0.02, original.scale * hypot(p.x - pivot.x, p.y - pivot.y) / d0)
            studio.setPlacement(pl, checkpoint: !began)
            gesture = .scale(pivot: pivot, startDistance: d0, original: original, began: true)
        case .rotate(let pivot, let a0, let original, let began):
            var pl = original
            var deg = original.rotation + (atan2(p.y - pivot.y, p.x - pivot.x) - a0) * 180 / .pi
            if shift { deg = (deg / 15).rounded() * 15 }
            pl.rotation = deg
            studio.setPlacement(pl, checkpoint: !began)
            gesture = .rotate(pivot: pivot, startAngle: a0, original: original, began: true)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { gesture = .none; smoothed = nil; needsDisplay = true }
        switch gesture {
        case .draw(let s):
            studio.addStroke(s)
        case .shape(let kind, let a, let b):
            guard hypot(b.x - a.x, b.y - a.y) > 2 else { return }
            var s = Stroke(kind: kind, points: [a, b], color: studio.color, width: studio.brushSize)
            if studio.shapeFill && kind != .line { s.fill = studio.fillColor }
            studio.addStroke(s)
        case .erase(let path):
            studio.erase(along: path, radius: studio.eraserSize / 2)
        case .pan:
            NSCursor.crosshair.set()
        default:
            break
        }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || !e.hasPreciseScrollingDeltas {
            zoom(by: exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08)), around: convert(e.locationInWindow, from: nil))
        } else {
            offset.x += e.scrollingDeltaX
            offset.y += e.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, around: convert(e.locationInWindow, from: nil))
    }

    private func zoom(by f: CGFloat, around v: CGPoint) {
        let p = toDoc(v)
        zoom = min(16, max(0.05, zoom * f))
        let doc = studio.doc
        offset = CGPoint(x: v.x - p.x * zoom - (bounds.width - doc.width * zoom) / 2,
                         y: v.y - p.y * zoom - (bounds.height - doc.height * zoom) / 2)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: studio.tool == .hand ? .openHand : (studio.tool == .select ? .arrow : .crosshair))
    }

    // MARK: Drop

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        studio.open(urls)
        return true
    }
}
