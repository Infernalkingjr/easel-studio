import AppKit
import SwiftUI
import Observation

struct CanvasView: NSViewRepresentable {
    let studio: QuillStudio
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(studio: studio) }
    func updateNSView(_ nsView: CanvasNSView, context: Context) {}
}

/// The artboard. Artboard coordinates are y-down, like the view (flipped).
final class CanvasNSView: NSView {
    private let studio: QuillStudio
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var isTracking = false
    private var lastFit = -1
    private var hadSize = false
    private var hover: CGPoint?
    private var guides: [(vertical: Bool, at: CGFloat)] = []
    private var spaceDown = false
    private var keyMonitor: Any?
    private var textEditor: InlineTextView?

    private enum Gesture {
        case none
        case pan(start: CGPoint, offset: CGPoint)
        case marquee(start: CGPoint, end: CGPoint, extend: Bool)
        case move(base: ArtDocument, start: CGPoint, ids: Set<UUID>, moved: Bool)
        case scale(base: ArtDocument, anchor: CGPoint, handle: CGPoint, xAxis: Bool, yAxis: Bool, moved: Bool)
        case rotate(base: ArtDocument, center: CGPoint, startAngle: CGFloat, moved: Bool)
        case shape(QuillTool, start: CGPoint, end: CGPoint, shift: Bool, alt: Bool)
        case pencil([CGPoint])
        case penHandle(index: Int)
        case nodes(base: ArtDocument, start: CGPoint, moved: Bool)
        case handle(base: ArtDocument, ref: NodeRef, outgoing: Bool, smooth: Bool)
    }

    private var gesture: Gesture = .none

    init(studio: QuillStudio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL, .png, .tiff])
        NotificationCenter.default.addObserver(forName: .quillZoom, object: nil, queue: .main) { [weak self] n in
            let f = n.object as? Double ?? 1
            DispatchQueue.main.async { if f == 0 { self?.actualSize() } else { self?.zoom(by: f) } }
        }
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
                  e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            // Space pans while held, whatever the tool.
            if e.type == .keyDown, !e.isARepeat { self.spaceDown = true; NSCursor.openHand.set() }
            if e.type == .keyUp { self.spaceDown = false; self.window?.invalidateCursorRects(for: self) }
            return nil
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !hadSize, newSize.width > 0 { hadSize = true; fit() }
    }

    func fit() {
        guard bounds.width > 0 else { return }
        zoom = min((bounds.width - 80) / studio.doc.width, (bounds.height - 80) / studio.doc.height, 8)
        offset = .zero
        needsDisplay = true
    }

    func actualSize() {
        zoom = 1
        offset = .zero
        needsDisplay = true
    }

    private var origin: CGPoint {
        CGPoint(x: ((bounds.width - studio.doc.width * zoom) / 2 + offset.x).rounded(),
                y: ((bounds.height - studio.doc.height * zoom) / 2 + offset.y).rounded())
    }

    private func toDoc(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom) }
    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
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
        NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).setFill()
        bounds.fill()

        let board = toView(CGRect(origin: .zero, size: doc.size))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 16, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(.white)
        ctx.fill(board)
        ctx.restoreGState()
        if doc.background == nil { drawChecker(ctx, board) }

        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: zoom, y: zoom)
        QuillRenderer.draw(doc, in: ctx, images: studio.images, skipping: studio.editingTextID.map { [$0] } ?? [])
        drawPreview(ctx)
        ctx.restoreGState()

        drawOverlays(ctx)
    }

    private func drawChecker(_ ctx: CGContext, _ r: CGRect) {
        let s: CGFloat = 10
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        var y = r.minY, row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : s)
            while x < r.maxX { ctx.fill(CGRect(x: x, y: y, width: s, height: s)); x += 2 * s }
            y += s; row += 1
        }
        ctx.restoreGState()
    }

    /// In-progress shapes, drawn in artboard space.
    private func drawPreview(_ ctx: CGContext) {
        switch gesture {
        case .shape(let tool, let a, let b, let shift, let alt):
            if let c = shapeContour(tool, a, b, shift: shift, alt: alt) {
                var item = studio.styled(Item(name: "", kind: .path([c])))
                if tool == .line { item.fill = nil; if item.stroke == nil { item.stroke = .black } }
                QuillRenderer.drawItem(item, doc: studio.doc, in: ctx, images: studio.images)
            }
        case .pencil(let pts):
            ctx.setStrokeColor((studio.stroke ?? .black).cg)
            ctx.setLineWidth(max(1, studio.strokeWidth))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: pts)
            ctx.strokePath()
        default:
            break
        }
    }

    private func drawOverlays(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.setLineWidth(1)

        // Outline every selected path so it reads even when unfilled.
        for item in studio.selectedItems {
            var t = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: zoom, y: zoom)
            ctx.addPath(item.worldPath.copy(using: &t) ?? item.worldPath)
            ctx.setStrokeColor(accent)
            ctx.strokePath()
        }

        if studio.tool == .direct { drawPoints(ctx) }
        else if studio.tool == .select, case .none = gesture, let b = studio.selectionBounds { drawBox(ctx, toView(b)) }
        else if studio.tool == .select, let b = studio.selectionBounds { ctx.setStrokeColor(accent); ctx.stroke(toView(b)) }

        if !studio.penNodes.isEmpty { drawPen(ctx) }

        if case .marquee(let a, let b, _) = gesture {
            let r = Geo.rect(a, b)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(accent)
            ctx.stroke(r)
        }

        if !guides.isEmpty {
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            for g in guides {
                let v = toView(CGPoint(x: g.at, y: g.at))
                ctx.strokeLineSegments(between: g.vertical ? [CGPoint(x: v.x, y: 0), CGPoint(x: v.x, y: bounds.height)]
                                                         : [CGPoint(x: 0, y: v.y), CGPoint(x: bounds.width, y: v.y)])
            }
        }
    }

    private func handlePoints(_ r: CGRect) -> [(CGPoint, xAxis: Bool, yAxis: Bool)] {
        [(CGPoint(x: r.minX, y: r.minY), true, true), (CGPoint(x: r.midX, y: r.minY), false, true), (CGPoint(x: r.maxX, y: r.minY), true, true),
         (CGPoint(x: r.maxX, y: r.midY), true, false), (CGPoint(x: r.maxX, y: r.maxY), true, true), (CGPoint(x: r.midX, y: r.maxY), false, true),
         (CGPoint(x: r.minX, y: r.maxY), true, true), (CGPoint(x: r.minX, y: r.midY), true, false)]
    }

    private func drawBox(_ ctx: CGContext, _ r: CGRect) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.stroke(r)
        ctx.setFillColor(.white)
        for (p, _, _) in handlePoints(r) {
            let h = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            ctx.fill(h)
            ctx.stroke(h)
        }
    }

    private func drawPoints(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        for item in studio.selectedItems {
            guard let contours = item.contours else { continue }
            for (ci, c) in contours.enumerated() {
                for (ni, n) in c.nodes.enumerated() {
                    let ref = NodeRef(item: item.id, contour: ci, node: ni)
                    let selected = studio.nodeSelection.contains(ref)
                    let p = toView(n.p)
                    if selected {
                        ctx.setStrokeColor(accent)
                        for h in [n.i, n.o] where h != n.p {
                            let hv = toView(h)
                            ctx.strokeLineSegments(between: [p, hv])
                            ctx.setFillColor(accent)
                            ctx.fillEllipse(in: CGRect(x: hv.x - 3, y: hv.y - 3, width: 6, height: 6))
                        }
                    }
                    let r = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                    ctx.setFillColor(selected ? accent : .white)
                    ctx.fill(r)
                    ctx.setStrokeColor(accent)
                    ctx.stroke(r)
                }
            }
        }
    }

    private func drawPen(_ ctx: CGContext) {
        let nodes = studio.penNodes
        let accent = NSColor.controlAccentColor.cgColor
        var t = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: zoom, y: zoom)
        let path = Geo.path([Contour(nodes: nodes, closed: false)])
        ctx.addPath(path.copy(using: &t) ?? path)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.setLineWidth(1)
        // Rubber band to the pointer.
        if case .none = gesture, let hover, let last = nodes.last {
            let band = CGMutablePath()
            band.move(to: last.p)
            band.addCurve(to: hover, control1: last.o, control2: hover)
            ctx.addPath(band.copy(using: &t) ?? band)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
            ctx.strokePath()
        }
        for (k, n) in nodes.enumerated() {
            let p = toView(n.p)
            if k == nodes.count - 1 {
                ctx.setStrokeColor(accent)
                for h in [n.i, n.o] where h != n.p {
                    let hv = toView(h)
                    ctx.strokeLineSegments(between: [p, hv])
                    ctx.fillEllipse(in: CGRect(x: hv.x - 3, y: hv.y - 3, width: 6, height: 6))
                }
            }
            let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(k == 0 && nodes.count > 1 ? NSColor.systemYellow.cgColor : .white)
            ctx.fill(r)
            ctx.setStrokeColor(accent)
            ctx.stroke(r)
        }
    }

    // MARK: Hit testing

    /// Topmost editable item under a view point.
    private func hitItem(_ v: CGPoint) -> Item? {
        let p = toDoc(v)
        let tolerance = max(4, 6 / zoom)
        for layer in studio.doc.layers.reversed() where layer.visible && !layer.locked {
            for item in layer.items.reversed() {
                switch item.kind {
                case .path:
                    let path = item.worldPath
                    if (item.fill != nil || item.gradient != nil) && path.contains(p, using: item.evenOdd ? .evenOdd : .winding) { return item }
                    let hit = path.copy(strokingWithWidth: max(item.strokeWidth, tolerance * 2), lineCap: .round, lineJoin: .round, miterLimit: 4)
                    if hit.contains(p) { return item }
                case .text, .image:
                    if item.localBounds.insetBy(dx: -2, dy: -2).contains(p.applying(item.transform.cg.inverted())) { return item }
                }
            }
        }
        return nil
    }

    private func hitNode(_ v: CGPoint) -> NodeRef? {
        for item in studio.selectedItems.reversed() {
            guard let contours = item.contours else { continue }
            for (ci, c) in contours.enumerated() {
                for (ni, n) in c.nodes.enumerated() {
                    let p = toView(n.p)
                    if abs(p.x - v.x) < 6 && abs(p.y - v.y) < 6 { return NodeRef(item: item.id, contour: ci, node: ni) }
                }
            }
        }
        return nil
    }

    private func hitHandle(_ v: CGPoint) -> (NodeRef, outgoing: Bool)? {
        for ref in studio.nodeSelection {
            guard let n = studio.node(ref) else { continue }
            for (h, out) in [(n.o, true), (n.i, false)] where h != n.p {
                let hv = toView(h)
                if hypot(hv.x - v.x, hv.y - v.y) < 6 { return (ref, out) }
            }
        }
        return nil
    }

    // MARK: Shapes

    private func shapeContour(_ tool: QuillTool, _ a: CGPoint, _ b0: CGPoint, shift: Bool, alt: Bool) -> Contour? {
        var b = b0
        switch tool {
        case .rect, .ellipse:
            if shift {
                let d = max(abs(b.x - a.x), abs(b.y - a.y))
                b = CGPoint(x: a.x + (b.x < a.x ? -d : d), y: a.y + (b.y < a.y ? -d : d))
            }
            let r = alt ? Geo.rect(CGPoint(x: 2 * a.x - b.x, y: 2 * a.y - b.y), b) : Geo.rect(a, b)
            guard r.width > 0.5 || r.height > 0.5 else { return nil }
            return tool == .rect ? Geo.rectContour(r) : Geo.ellipseContour(r)
        case .polygon, .star:
            let radius = hypot(b.x - a.x, b.y - a.y)
            guard radius > 0.5 else { return nil }
            let rot = shift ? -CGFloat.pi / 2 : atan2(b.y - a.y, b.x - a.x)
            return tool == .polygon
                ? Geo.polygonContour(center: a, radius: radius, sides: studio.sides, rotation: rot)
                : Geo.polygonContour(center: a, radius: radius, sides: studio.starPoints, inner: studio.starInner, rotation: rot)
        case .line:
            if shift {
                let ang = (atan2(b.y - a.y, b.x - a.x) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(b.x - a.x, b.y - a.y)
                b = CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
            }
            guard hypot(b.x - a.x, b.y - a.y) > 0.5 else { return nil }
            return Contour(nodes: [Node(a), Node(b)], closed: false)
        default:
            return nil
        }
    }

    // MARK: Snapping

    /// Snaps a move so the selection's edges or center line up with the artboard or other objects.
    private func snap(_ d: CGPoint, moving b: CGRect, excluding ids: Set<UUID>) -> CGPoint {
        let doc = studio.doc
        var xs: [CGFloat] = [0, doc.width / 2, doc.width], ys: [CGFloat] = [0, doc.height / 2, doc.height]
        for layer in doc.layers where layer.visible {
            for item in layer.items where !ids.contains(item.id) {
                let r = item.geometryBounds
                xs += [r.minX, r.midX, r.maxX]
                ys += [r.minY, r.midY, r.maxY]
            }
        }
        let threshold = 6 / zoom
        func best(_ edges: [CGFloat], _ lines: [CGFloat]) -> (CGFloat, CGFloat)? {
            var out: (CGFloat, CGFloat)?
            for e in edges { for l in lines where abs(l - e) < threshold && abs(l - e) < abs(out?.0 ?? .infinity) { out = (l - e, l) } }
            return out
        }
        var r = d
        guides = []
        if let (dx, at) = best([b.minX + d.x, b.midX + d.x, b.maxX + d.x], xs) { r.x += dx; guides.append((true, at)) }
        if let (dy, at) = best([b.minY + d.y, b.midY + d.y, b.maxY + d.y], ys) { r.y += dy; guides.append((false, at)) }
        return r
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let v = convert(e.locationInWindow, from: nil)
        let p = toDoc(v)
        let shift = e.modifierFlags.contains(.shift), alt = e.modifierFlags.contains(.option)
        if spaceDown || studio.tool == .hand {
            if e.clickCount == 2 { fit(); return }
            gesture = .pan(start: v, offset: offset)
            NSCursor.closedHand.set()
            return
        }
        switch studio.tool {
        case .select:
            if e.clickCount == 2, let item = hitItem(v) {
                if item.isText { return beginEditing(item.id) }
                if item.contours != nil { studio.tool = .direct; studio.selection = [item.id]; return }
            }
            if let b = studio.selectionBounds {
                let r = toView(b)
                for (h, xAxis, yAxis) in handlePoints(r) where abs(h.x - v.x) < 6 && abs(h.y - v.y) < 6 {
                    let opposite = CGPoint(x: r.midX * 2 - h.x, y: r.midY * 2 - h.y)
                    let anchor = alt ? toDoc(CGPoint(x: r.midX, y: r.midY)) : toDoc(opposite)
                    gesture = .scale(base: studio.doc, anchor: anchor, handle: toDoc(h), xAxis: xAxis, yAxis: yAxis, moved: false)
                    return
                }
                let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                if !r.insetBy(dx: -2, dy: -2).contains(v), corners.contains(where: { hypot($0.x - v.x, $0.y - v.y) < 22 }) {
                    let c = CGPoint(x: b.midX, y: b.midY)
                    gesture = .rotate(base: studio.doc, center: c, startAngle: atan2(p.y - c.y, p.x - c.x), moved: false)
                    return
                }
            }
            if let item = hitItem(v) {
                if shift { studio.select([item.id], extend: true); return }
                if !studio.selection.contains(item.id) { studio.select([item.id]) }
                if alt { studio.duplicateSelection(offset: .zero) }
                gesture = .move(base: studio.doc, start: p, ids: studio.selection, moved: alt)
            } else {
                if !shift { studio.deselect() }
                gesture = .marquee(start: v, end: v, extend: shift)
            }
        case .direct:
            if let (ref, out) = hitHandle(v), let n = studio.node(ref) {
                // Handles stay opposite each other unless ⌥ breaks the point.
                let other = out ? n.i : n.o
                let collinear = other != n.p && abs((n.o.x - n.p.x) * (n.i.y - n.p.y) - (n.o.y - n.p.y) * (n.i.x - n.p.x)) < 1
                gesture = .handle(base: studio.doc, ref: ref, outgoing: out, smooth: !alt && (collinear || other == n.p))
                return
            }
            if let ref = hitNode(v) {
                if shift { studio.nodeSelection.formSymmetricDifference([ref]) }
                else if !studio.nodeSelection.contains(ref) { studio.nodeSelection = [ref] }
                gesture = .nodes(base: studio.doc, start: p, moved: false)
                return
            }
            if let item = hitItem(v) {
                if shift { studio.selection.insert(item.id) } else if !studio.selection.contains(item.id) { studio.selection = [item.id] }
                studio.nodeSelection = []
                gesture = .move(base: studio.doc, start: p, ids: studio.selection, moved: false)
            } else {
                if !shift { studio.deselect() }
                gesture = .marquee(start: v, end: v, extend: shift)
            }
        case .pen:
            let nodes = studio.penNodes
            if nodes.count >= 2, hypot(toView(nodes[0].p).x - v.x, toView(nodes[0].p).y - v.y) < 8 {
                studio.finishPen(close: true)
                return
            }
            studio.penNodes.append(Node(p))
            gesture = .penHandle(index: studio.penNodes.count - 1)
        case .pencil:
            gesture = .pencil([p])
        case .rect, .ellipse, .polygon, .star, .line:
            gesture = .shape(studio.tool, start: p, end: p, shift: shift, alt: alt)
        case .text:
            if let item = hitItem(v), item.isText { return beginEditing(item.id) }
            if let id = studio.addText(at: p) { beginEditing(id) }
        case .eyedropper:
            if let item = hitItem(v) { studio.pickStyle(from: item.id) }
        case .hand:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil)
        let p = toDoc(v)
        let shift = e.modifierFlags.contains(.shift), alt = e.modifierFlags.contains(.option)
        hover = p
        switch gesture {
        case .none:
            return
        case .pan(let start, let o):
            offset = CGPoint(x: o.x + v.x - start.x, y: o.y + v.y - start.y)
        case .marquee(let a, _, let extend):
            gesture = .marquee(start: a, end: v, extend: extend)
        case .move(let base, let start, let ids, let moved):
            if !moved { studio.checkpoint() }
            var d = CGPoint(x: p.x - start.x, y: p.y - start.y)
            if shift { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            let b = base.allItems.filter { ids.contains($0.id) }.reduce(CGRect.null) { $0.union($1.geometryBounds) }
            if !e.modifierFlags.contains(.command) { d = snap(d, moving: b, excluding: ids) }
            studio.doc = base
            studio.transformSelection(CGAffineTransform(translationX: d.x, y: d.y), ids: ids)
            gesture = .move(base: base, start: start, ids: ids, moved: true)
        case .scale(let base, let anchor, let handle, let xAxis, let yAxis, let moved):
            if !moved { studio.checkpoint() }
            var sx = xAxis && handle.x != anchor.x ? (p.x - anchor.x) / (handle.x - anchor.x) : 1
            var sy = yAxis && handle.y != anchor.y ? (p.y - anchor.y) / (handle.y - anchor.y) : 1
            if shift {
                let s = xAxis && yAxis ? max(abs(sx), abs(sy)) : (xAxis ? sx : sy)
                sx = (sx < 0 ? -1 : 1) * abs(s); sy = (sy < 0 ? -1 : 1) * abs(s)
                if !xAxis { sx = abs(s) }
                if !yAxis { sy = abs(s) }
            }
            if abs(sx) < 0.001 { sx = 0.001 }
            if abs(sy) < 0.001 { sy = 0.001 }
            studio.doc = base
            studio.transformSelection(CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
            gesture = .scale(base: base, anchor: anchor, handle: handle, xAxis: xAxis, yAxis: yAxis, moved: true)
        case .rotate(let base, let c, let a0, let moved):
            if !moved { studio.checkpoint() }
            var a = atan2(p.y - c.y, p.x - c.x) - a0
            if shift { a = (a / (.pi / 12)).rounded() * (.pi / 12) }
            studio.doc = base
            studio.transformSelection(CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: a))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            gesture = .rotate(base: base, center: c, startAngle: a0, moved: true)
        case .shape(let tool, let a, _, _, _):
            gesture = .shape(tool, start: a, end: p, shift: shift, alt: alt)
        case .pencil(var pts):
            if let last = pts.last, hypot(p.x - last.x, p.y - last.y) * zoom < 2 { return }
            pts.append(p)
            gesture = .pencil(pts)
        case .penHandle(let k):
            guard studio.penNodes.indices.contains(k) else { return }
            var n = studio.penNodes[k]
            n.o = p
            n.i = CGPoint(x: 2 * n.p.x - p.x, y: 2 * n.p.y - p.y)
            studio.penNodes[k] = n
        case .nodes(let base, let start, let moved):
            if !moved { studio.checkpoint() }
            var d = CGPoint(x: p.x - start.x, y: p.y - start.y)
            if shift { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            studio.doc = base
            studio.moveNodes(studio.nodeSelection, by: d)
            gesture = .nodes(base: base, start: start, moved: true)
        case .handle(let base, let ref, let outgoing, let smooth):
            if studio.doc == base { studio.checkpoint() }
            guard var n = base.allItems.first(where: { $0.id == ref.item })?.contours?[ref.contour].nodes[ref.node] else { return }
            if outgoing { n.o = p } else { n.i = p }
            if smooth {
                // Keep the opposite handle's length, mirror its direction.
                let other = outgoing ? n.i : n.o
                var len = hypot(other.x - n.p.x, other.y - n.p.y)
                if len < 0.01 { len = hypot(p.x - n.p.x, p.y - n.p.y) }
                let dx = p.x - n.p.x, dy = p.y - n.p.y, l = max(0.001, hypot(dx, dy))
                let mirrored = CGPoint(x: n.p.x - dx / l * len, y: n.p.y - dy / l * len)
                if outgoing { n.i = mirrored } else { n.o = mirrored }
            }
            studio.setNode(ref, n)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { gesture = .none; guides = []; needsDisplay = true }
        switch gesture {
        case .marquee(let a, let b, let extend):
            let r = Geo.rect(toDoc(a), toDoc(b))
            guard r.width > 1 || r.height > 1 else { return }
            if studio.tool == .direct {
                var refs: Set<NodeRef> = extend ? studio.nodeSelection : []
                var owners: Set<UUID> = extend ? studio.selection : []
                for layer in studio.doc.layers where layer.visible && !layer.locked {
                    for item in layer.items {
                        guard let contours = item.contours else { continue }
                        for (ci, c) in contours.enumerated() {
                            for (ni, n) in c.nodes.enumerated() where r.contains(n.p) {
                                refs.insert(NodeRef(item: item.id, contour: ci, node: ni))
                                owners.insert(item.id)
                            }
                        }
                    }
                }
                studio.selection = owners
                studio.nodeSelection = refs
            } else {
                let hits = studio.doc.layers.filter { $0.visible && !$0.locked }.flatMap(\.items).filter { $0.geometryBounds.intersects(r) }.map(\.id)
                studio.select(Set(hits), extend: extend)
            }
        case .shape(let tool, let a, let b, let shift, let alt):
            guard hypot(b.x - a.x, b.y - a.y) * zoom > 3, let c = shapeContour(tool, a, b, shift: shift, alt: alt) else { return }
            studio.addPath([c], name: tool.title, open: tool == .line)
        case .pencil(let pts):
            guard pts.count > 2 else { return }
            let closed = pts.count > 8 && hypot(pts[0].x - pts.last!.x, pts[0].y - pts.last!.y) * zoom < 12
            studio.addPath([Geo.smoothContour(pts, tolerance: max(0.5, 2 / zoom), closed: closed)], name: "Path", open: !closed)
        case .pan:
            window?.invalidateCursorRects(for: self)
        default:
            break
        }
    }

    override func mouseMoved(with e: NSEvent) {
        hover = toDoc(convert(e.locationInWindow, from: nil))
        if !studio.penNodes.isEmpty { needsDisplay = true }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || !e.hasPreciseScrollingDeltas {
            zoom(by: exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08)), around: convert(e.locationInWindow, from: nil))
        } else {
            offset.x += e.scrollingDeltaX
            offset.y += e.scrollingDeltaY
            needsDisplay = true
        }
        endEditingText()
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, around: convert(e.locationInWindow, from: nil))
        endEditingText()
    }

    func zoom(by f: CGFloat, around v: CGPoint? = nil) {
        let v = v ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let p = toDoc(v)
        zoom = min(64, max(0.02, zoom * f))
        offset = CGPoint(x: v.x - p.x * zoom - (bounds.width - studio.doc.width * zoom) / 2,
                         y: v.y - p.y * zoom - (bounds.height - studio.doc.height * zoom) / 2)
        needsDisplay = true
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch studio.tool {
        case .hand: cursor = .openHand
        case .select, .direct: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Text editing

    func beginEditing(_ id: UUID) {
        endEditingText()
        guard let item = studio.item(id), case .text(let spec) = item.kind else { return }
        studio.select([id])
        studio.editingTextID = id
        let t = item.transform.cg
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let font = NSFont(name: spec.font, size: spec.size * scale * zoom) ?? .systemFont(ofSize: spec.size * scale * zoom)
        let b = toView(item.geometryBounds)
        let editor = InlineTextView(frame: CGRect(x: b.minX - 2, y: b.minY, width: max(60, b.width + 20), height: max(font.pointSize * 1.4, b.height)))
        editor.font = font
        editor.textColor = NSColor(cgColor: (item.fill ?? .black).cg) ?? .black
        editor.alignment = spec.alignment == 1 ? .center : (spec.alignment == 2 ? .right : .left)
        editor.string = spec.string
        editor.selectAll(nil)
        editor.onEnd = { [weak self, weak editor] text in
            self?.studio.commitText(id, text)
            editor?.removeFromSuperview()
            if self?.textEditor === editor { self?.textEditor = nil }
            self?.needsDisplay = true
        }
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
    }

    func endEditingText() {
        if let editor = textEditor { editor.finish() }
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let at = toDoc(convert(sender.draggingLocation, from: nil))
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            if urls.contains(where: { $0.pathExtension.lowercased() == "quill" }) { studio.open(urls) } else { studio.placeImages(urls, at: at) }
            return true
        }
        return false
    }
}

/// In-place typing for text objects. Esc or clicking away commits.
final class InlineTextView: NSTextView {
    var onEnd: ((String) -> Void)?
    private var finished = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        maxSize = NSSize(width: 100_000, height: 100_000)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        textContainer?.lineFragmentPadding = 2
        focusRingType = .none
        insertionPointColor = .controlAccentColor
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError() }

    func finish() {
        guard !finished else { return }
        finished = true
        onEnd?(string)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { self.finish() } }
        return ok
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(superview)
    }
}
