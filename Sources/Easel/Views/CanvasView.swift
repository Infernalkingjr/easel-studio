import EaselKit
import AppKit
import SwiftUI
import Observation

struct CanvasView: NSViewRepresentable {
    let editor: Editor
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(editor: editor) }
    func updateNSView(_ nsView: CanvasNSView, context: Context) {}
}

/// The drawing surface. Layers are drawn straight from their `CGImage`s; an in-progress tool
/// gesture swaps in a `LayerRenderer` for the active layer so strokes preview with the layer's
/// real opacity and blend mode, and committing reuses the exact same drawing code.
final class CanvasNSView: NSView {
    private let editor: Editor
    private var viewport: Viewport { editor.viewport }

    private enum Gesture {
        case none
        case stroke(erase: Bool)
        case pan(start: CGPoint, offset: CGPoint)
        case move(start: CGPoint, offset: CGPoint)
        case scale(handle: Int, bounds: CGRect, transform: CGAffineTransform)
        case rotate(bounds: CGRect, startAngle: CGFloat, angle: CGFloat)
        case select(start: CGPoint)
        case crop(start: CGPoint)
        case cropMove(start: CGPoint, rect: CGRect)
        case shape(start: CGPoint, end: CGPoint)
        case gradient(start: CGPoint, end: CGPoint)
        case pick
    }

    private var gesture: Gesture = .none
    private var activeRenderer: LayerRenderer?
    private var strokePath = CGMutablePath()
    private var strokePoints: [CGPoint] = []
    private var lastMid: CGPoint = .zero
    private var lastStrokeEnd: CGPoint?

    // Dab ("stamp") engine for soft-edged and pressure-sensitive strokes. New dabs are rendered into
    // small batch images each event, so a frame never re-stamps the whole stroke.
    private var useDabs = false
    private var strokeUsesPressure = false
    private var dabBatches: [(image: CGImage, rect: CGRect)] = []
    private var dabImage: CGImage?
    private var lastDab: (point: CGPoint, pressure: CGFloat) = (.zero, 1)
    private var dabCarry: CGFloat = 0
    private var spaceDown = false
    private var isTracking = false
    private var keyMonitor: Any?
    private var cursorKey = ""
    private var currentCursor: NSCursor = .crosshair
    private var hadSize = false

    private lazy var checker: CGImage = {
        let ctx = Bitmap.context(CGSize(width: 16, height: 16))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        return ctx.makeImage()!
    }()

    init(editor: Editor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if keyMonitor == nil, window != nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
                guard let self else { return e }
                return self.handleKey(e) ? nil : e
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewport.viewSize = newSize
        if !hadSize, newSize.width > 0, editor.hasDocument {
            hadSize = true
            editor.zoomToFit()
        }
    }

    // MARK: Coordinates

    private var origin: CGPoint {
        let z = viewport.zoom
        let scale = window?.backingScaleFactor ?? 2
        let x = (bounds.width - editor.canvasSize.width * z) / 2 + viewport.offset.x
        let y = (bounds.height - editor.canvasSize.height * z) / 2 + viewport.offset.y
        return CGPoint(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale)
    }

    private func toCanvas(_ p: CGPoint) -> CGPoint {
        let o = origin, z = viewport.zoom
        return CGPoint(x: (p.x - o.x) / z, y: (p.y - o.y) / z)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = origin, z = viewport.zoom
        return CGRect(x: o.x + r.minX * z, y: o.y + r.minY * z, width: r.width * z, height: r.height * z)
    }

    private func canvasPoint(_ e: NSEvent) -> CGPoint { toCanvas(convert(e.locationInWindow, from: nil)) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isTracking {
            render(ctx, dirtyRect)
        } else {
            // Redraw automatically whenever anything this view reads from the model changes.
            isTracking = true
            withObservationTracking {
                render(ctx, dirtyRect)
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.isTracking = false
                    self?.needsDisplay = true
                }
            }
        }
    }

    private func render(_ ctx: CGContext, _ dirty: CGRect) {
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(dirty.intersection(bounds))

        let layers = editor.layers
        let activeID = editor.activeLayerID
        let selection = editor.selection
        let crop = editor.cropRect
        let z = viewport.zoom
        _ = viewport.offset
        updateCursor()
        guard editor.hasDocument else { return }

        let o = origin
        let canvasRect = editor.canvasRect
        let canvasInView = toView(canvasRect)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(.white)
        ctx.fill(canvasInView)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: canvasInView)
        ctx.draw(checker, in: CGRect(x: o.x, y: o.y, width: 16, height: 16), byTiling: true)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: z, y: z)
        ctx.clip(to: canvasRect)
        ctx.interpolationQuality = z >= 2 ? .none : (z < 1 ? .medium : .low)

        for layer in layers where layer.isVisible {
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.setBlendMode(layer.blendMode.cg)
            let image = editor.preview(for: layer) ?? layer.image
            if layer.id == activeID, let renderer = activeRenderer {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setAlpha(1)
                ctx.setBlendMode(.normal)
                renderer(ctx, image, canvasRect)
                ctx.endTransparencyLayer()
            } else {
                ctx.draw(image, in: canvasRect)
            }
            ctx.restoreGState()
        }
        ctx.resetClip()

        let hair = 1 / z
        if case .gradient(let a, let b) = gesture {
            ctx.setLineWidth(hair * 2)
            ctx.setStrokeColor(.white)
            ctx.strokeLineSegments(between: [a, b])
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
            ctx.setLineWidth(hair)
            ctx.strokeLineSegments(between: [a, b])
        }

        if let crop {
            ctx.saveGState()
            ctx.addRect(canvasRect.insetBy(dx: -10000, dy: -10000))
            ctx.addRect(crop)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
            ctx.setLineWidth(hair)
            for i in 1...2 {
                let fx = crop.minX + crop.width * CGFloat(i) / 3
                let fy = crop.minY + crop.height * CGFloat(i) / 3
                ctx.strokeLineSegments(between: [CGPoint(x: fx, y: crop.minY), CGPoint(x: fx, y: crop.maxY),
                                                 CGPoint(x: crop.minX, y: fy), CGPoint(x: crop.maxX, y: fy)])
            }
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(hair * 2)
            ctx.stroke(crop)
            ctx.restoreGState()
        }

        if let selection {
            ctx.setLineWidth(hair)
            ctx.setStrokeColor(.white)
            ctx.stroke(selection)
            ctx.setLineDash(phase: 0, lengths: [4 * hair, 4 * hair])
            ctx.setStrokeColor(.black)
            ctx.stroke(selection)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()
        drawTransformBox(ctx)
    }

    // MARK: Transform handles

    /// The active layer's box while using the Move tool, following any in-progress drag.
    private var transformBox: CGRect? {
        guard editor.tool == .move, !spaceDown, editor.selection == nil,
              let layer = editor.activeLayer, layer.isVisible, let b = editor.contentBounds(layer) else { return nil }
        switch gesture {
        case .scale(_, let bounds, let t): return bounds.applying(t)
        case .move(_, let d): return b.offsetBy(dx: d.x, dy: d.y)
        case .none: return b
        default: return nil
        }
    }

    /// Corners 0–3 (BL, BR, TR, TL) then edges 4–7 (bottom, right, top, left).
    private static func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private static func opposite(_ h: Int) -> Int { h < 4 ? (h + 2) % 4 : 4 + (h - 4 + 2) % 4 }

    /// Handle index 8 means "rotate" (the round handle, or just outside a corner).
    private static let rotateHandle = 8
    private static let rotateHandleOffset: CGFloat = 26

    private func handleHit(_ view: CGPoint) -> Int? {
        guard let box = transformBox else { return nil }
        let r = toView(box)
        // Hide edge handles when the box is too small to grab them separately.
        let count = min(r.width, r.height) < 30 ? 4 : 8
        if let h = Self.handlePoints(r).prefix(count).firstIndex(where: { hypot($0.x - view.x, $0.y - view.y) <= 7 }) {
            return h
        }
        if hypot(view.x - r.midX, view.y - (r.maxY + Self.rotateHandleOffset)) <= 9 { return Self.rotateHandle }
        // Just outside a corner rotates, like Photoshop.
        let nearCorner = Self.handlePoints(r).prefix(4).contains { hypot($0.x - view.x, $0.y - view.y) <= 24 }
        if nearCorner && !r.insetBy(dx: -2, dy: -2).contains(view) { return Self.rotateHandle }
        return nil
    }

    private func drawTransformBox(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(accent)

        // While rotating, show the turning box and the angle.
        if case .rotate(let b, _, let angle) = gesture {
            let t = Editor.rotation(angle, around: CGPoint(x: b.midX, y: b.midY))
            let quad = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
                .map { toView(CGRect(origin: $0.applying(t), size: .zero)).origin }
            ctx.addLines(between: quad)
            ctx.closePath()
            ctx.strokePath()
            var degrees = (-angle * 180 / .pi).rounded()
            if degrees <= -180 { degrees += 360 }
            if degrees > 180 { degrees -= 360 }
            let label = NSAttributedString(string: " \(Int(degrees))° ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.controlAccentColor,
            ])
            let at = dragPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            label.draw(at: CGPoint(x: at.x + 16, y: at.y - 24))
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        guard let box = transformBox else { return }
        let r = toView(box).insetBy(dx: -0.5, dy: -0.5)
        ctx.stroke(r)
        // Rotate handle above the top edge.
        let knob = CGPoint(x: r.midX, y: r.maxY + Self.rotateHandleOffset)
        ctx.strokeLineSegments(between: [CGPoint(x: r.midX, y: r.maxY), CGPoint(x: knob.x, y: knob.y - 5)])
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        ctx.strokeEllipse(in: CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        let count = min(r.width, r.height) < 30 ? 4 : 8
        for p in Self.handlePoints(r).prefix(count) {
            let h = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.fill(h)
            ctx.stroke(h)
        }
    }

    private static let rotateCursor: NSCursor = {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            func symbol(_ color: NSColor, weight: NSFont.Weight) -> NSImage? {
                NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rotate")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: weight)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
            }
            // A heavy white arrow underneath keeps the black one visible on dark images.
            symbol(.white, weight: .black)?.draw(in: rect.insetBy(dx: 2, dy: 2))
            symbol(.black, weight: .semibold)?.draw(in: rect.insetBy(dx: 3.5, dy: 3.5))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
    }()

    private func resizeCursor(_ h: Int) -> NSCursor {
        if h == Self.rotateHandle { return Self.rotateCursor }
        if #available(macOS 15.0, *) {
            let positions: [NSCursor.FrameResizePosition] = [.bottomLeft, .bottomRight, .topRight, .topLeft, .bottom, .right, .top, .left]
            return NSCursor.frameResize(position: positions[h], directions: .all)
        }
        return h == 5 || h == 7 ? .resizeLeftRight : (h == 4 || h == 6 ? .resizeUpDown : .crosshair)
    }

    /// Scale transform for dragging handle `h` of `b` to `p`. Corners keep proportions unless ⇧;
    /// ⌥ scales around the center.
    private func scaleTransform(handle h: Int, bounds b: CGRect, to p: CGPoint, flags: NSEvent.ModifierFlags) -> CGAffineTransform {
        let points = Self.handlePoints(b)
        let hp = points[h]
        let a = flags.contains(.option) ? CGPoint(x: b.midX, y: b.midY) : points[Self.opposite(h)]
        var sx: CGFloat = 1, sy: CGFloat = 1
        if h != 4 && h != 6, hp.x != a.x { sx = (p.x - a.x) / (hp.x - a.x) }
        if h != 5 && h != 7, hp.y != a.y { sy = (p.y - a.y) / (hp.y - a.y) }
        if h < 4 && !flags.contains(.shift) {
            let m = max(abs(sx), abs(sy))
            sx = sx < 0 ? -m : m
            sy = sy < 0 ? -m : m
        }
        // Never collapse below one pixel.
        let minX = 1 / b.width, minY = 1 / b.height
        if abs(sx) < minX { sx = sx < 0 ? -minX : minX }
        if abs(sy) < minY { sy = sy < 0 ? -minY : minY }
        return Editor.scale(sx: sx, sy: sy, around: a)
    }

    // MARK: Cursor

    private func updateCursor() {
        let tool = spaceDown ? .hand : editor.tool
        let size = tool == .eraser ? editor.eraserSize : editor.brushSize
        let z = viewport.zoom
        let key = "\(tool)-\(size)-\(z)"
        guard key != cursorKey else { return }
        cursorKey = key
        switch tool {
        case .brush, .eraser:
            currentCursor = Self.circleCursor(diameter: size * z)
        case .hand: currentCursor = .openHand
        case .text: currentCursor = .iBeam
        case .move: currentCursor = .arrow
        default: currentCursor = .crosshair
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    private static func circleCursor(diameter: CGFloat) -> NSCursor {
        let d = min(max(diameter, 3), 400)
        let side = d + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let r = NSRect(x: 2, y: 2, width: d, height: d)
            NSColor.black.withAlphaComponent(0.8).setStroke()
            let outer = NSBezierPath(ovalIn: r)
            outer.lineWidth = 1.5
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            inner.lineWidth = 0.75
            inner.stroke()
            if d > 10 {
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSRect(x: side / 2 - 0.5, y: side / 2 - 0.5, width: 1, height: 1).fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    // MARK: Mouse

    private var overHandle = false
    /// Latest pointer position during a drag, in view coordinates.
    private var dragPoint: CGPoint?

    override func mouseMoved(with e: NSEvent) {
        viewport.cursor = editor.hasDocument ? canvasPoint(e) : nil
        if editor.hasDocument, let h = handleHit(convert(e.locationInWindow, from: nil)) {
            resizeCursor(h).set()
            overHandle = true
        } else if overHandle {
            overHandle = false
            currentCursor.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        viewport.cursor = nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard editor.hasDocument else { return }
        let view = convert(e.locationInWindow, from: nil)
        let p = toCanvas(view)

        if spaceDown || editor.tool == .hand || e.buttonNumber == 2 {
            if e.clickCount == 2 { editor.zoomToFit(); return }
            gesture = .pan(start: view, offset: viewport.offset)
            NSCursor.closedHand.set()
            return
        }

        let shift = e.modifierFlags.contains(.shift)
        switch editor.tool {
        case .eyedropper:
            editor.pickColor(at: p)
            gesture = .pick
        case .brush where e.modifierFlags.contains(.option):
            editor.pickColor(at: p)
            gesture = .pick
        case .brush, .eraser:
            guard editor.activeLayer != nil else { return }
            let erase = editor.tool == .eraser
            gesture = .stroke(erase: erase)
            strokeUsesPressure = editor.usePressure && e.subtype == .tabletPoint
            if shift, let last = lastStrokeEnd {
                beginStroke(at: last, pressure: pressure(e))
                addStrokePoint(p, pressure: pressure(e))
            } else {
                beginStroke(at: p, pressure: pressure(e))
            }
        case .fill:
            editor.floodFill(at: p)
        case .text:
            editor.textClick(at: p)
        case .move:
            if let h = handleHit(view), let layer = editor.activeLayer, let b = editor.contentBounds(layer) {
                if h == Self.rotateHandle {
                    gesture = .rotate(bounds: b, startAngle: atan2(p.y - b.midY, p.x - b.midX), angle: 0)
                } else {
                    gesture = .scale(handle: h, bounds: b, transform: .identity)
                }
            } else {
                gesture = .move(start: p, offset: .zero)
            }
        case .select:
            gesture = .select(start: p)
        case .crop:
            if let rect = editor.cropRect, rect.contains(p) {
                if e.clickCount == 2 { editor.applyCrop(); return }
                gesture = .cropMove(start: p, rect: rect)
            } else {
                gesture = .crop(start: p)
            }
        case .shape:
            gesture = .shape(start: p, end: p)
        case .gradient:
            gesture = .gradient(start: p, end: p)
        case .hand:
            break
        }
    }

    override func otherMouseDown(with e: NSEvent) { mouseDown(with: e) }
    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func mouseDragged(with e: NSEvent) {
        let view = convert(e.locationInWindow, from: nil)
        dragPoint = view
        var p = toCanvas(view)
        viewport.cursor = p
        let shift = e.modifierFlags.contains(.shift)

        switch gesture {
        case .none:
            break
        case .pick:
            editor.pickColor(at: p)
        case .pan(let start, let offset):
            viewport.offset = CGPoint(x: offset.x + view.x - start.x, y: offset.y + view.y - start.y)
        case .stroke:
            addStrokePoint(p, pressure: pressure(e))
        case .move(let start, _):
            var d = CGPoint(x: (p.x - start.x).rounded(), y: (p.y - start.y).rounded())
            if shift { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            gesture = .move(start: start, offset: d)
            activeRenderer = moveRenderer(d)
            needsDisplay = true
        case .scale(let h, let b, _):
            let t = scaleTransform(handle: h, bounds: b, to: p, flags: e.modifierFlags)
            gesture = .scale(handle: h, bounds: b, transform: t)
            activeRenderer = { ctx, img, rect in
                ctx.concatenate(t)
                ctx.draw(img, in: rect)
            }
            needsDisplay = true
        case .rotate(let b, let startAngle, _):
            var angle = atan2(p.y - b.midY, p.x - b.midX) - startAngle
            angle = atan2(sin(angle), cos(angle))
            if shift {
                let step = CGFloat.pi / 12  // 15°
                angle = (angle / step).rounded() * step
            }
            gesture = .rotate(bounds: b, startAngle: startAngle, angle: angle)
            let t = Editor.rotation(angle, around: CGPoint(x: b.midX, y: b.midY))
            activeRenderer = { ctx, img, rect in
                ctx.concatenate(t)
                ctx.draw(img, in: rect)
            }
            Self.rotateCursor.set()
            needsDisplay = true
        case .select(let start):
            if shift { p = Geometry.constrain(start, p, ratio: 1) }
            editor.selection = Geometry.rect(start, p).intersection(editor.canvasRect).integral
        case .crop(let start):
            if let ratio = editor.cropAspect.ratio ?? (shift ? 1 : nil) { p = Geometry.constrain(start, p, ratio: ratio) }
            editor.cropRect = Geometry.rect(start, p).intersection(editor.canvasRect).integral
        case .cropMove(let start, let rect):
            var r = rect.offsetBy(dx: (p.x - start.x).rounded(), dy: (p.y - start.y).rounded())
            r.origin.x = min(max(0, r.minX), editor.canvasSize.width - r.width)
            r.origin.y = min(max(0, r.minY), editor.canvasSize.height - r.height)
            editor.cropRect = r
        case .shape(let start, _):
            if shift {
                p = [.line, .arrow].contains(editor.shapeKind) ? Geometry.snapAngle(start, p) : Geometry.constrain(start, p, ratio: 1)
            }
            gesture = .shape(start: start, end: p)
            activeRenderer = shapeRenderer(start, p)
            needsDisplay = true
        case .gradient(let start, _):
            if shift { p = Geometry.snapAngle(start, p) }
            gesture = .gradient(start: start, end: p)
            activeRenderer = gradientRenderer(start, p)
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer {
            gesture = .none
            activeRenderer = nil
        }
        switch gesture {
        case .pan:
            currentCursor.set()
        case .stroke:
            if let renderer = activeRenderer {
                editor.commitActive(renderer)
                if editor.tool == .brush { editor.rememberColor() }
            }
            lastStrokeEnd = strokePoints.last
        case .move(_, let d):
            if d != .zero, let renderer = activeRenderer {
                editor.commitActive(moving: d, renderer)
                editor.selection = editor.selection?.offsetBy(dx: d.x, dy: d.y)
            }
        case .scale(_, _, let t):
            editor.transformActive(t)
            needsDisplay = true
        case .rotate(let b, _, let angle):
            if abs(angle) > 1e-6 {
                editor.transformActive(Editor.rotation(angle, around: CGPoint(x: b.midX, y: b.midY)))
            }
            needsDisplay = true
        case .select:
            if let s = editor.selection, s.width < 2 || s.height < 2 { editor.selection = nil }
        case .crop:
            if let c = editor.cropRect, c.width < 2 || c.height < 2 { editor.cropRect = nil }
        case .shape(let a, let b):
            if hypot(b.x - a.x, b.y - a.y) > 1, let renderer = activeRenderer {
                editor.commitActive(renderer)
                editor.rememberColor()
            }
        case .gradient(let a, let b):
            if hypot(b.x - a.x, b.y - a.y) > 1, let renderer = activeRenderer {
                editor.commitActive(renderer)
            }
        default:
            break
        }
    }

    // MARK: Strokes

    private var strokeWidth: CGFloat { editor.tool == .eraser ? editor.eraserSize : editor.brushSize }

    private func pressure(_ e: NSEvent) -> CGFloat {
        guard strokeUsesPressure, e.subtype == .tabletPoint else { return 1 }
        return CGFloat(max(0.05, e.pressure))
    }

    private func beginStroke(at p: CGPoint, pressure: CGFloat) {
        strokePoints = [p]
        useDabs = editor.brushHardness < 0.99 || strokeUsesPressure
        if useDabs {
            let color = editor.tool == .eraser ? CGColor(gray: 0, alpha: 1) : (editor.primaryCG.copy(alpha: 1) ?? editor.primaryCG)
            dabImage = Self.makeDab(diameter: strokeWidth, hardness: editor.brushHardness, color: color)
            dabBatches = []
            lastDab = (p, pressure)
            dabCarry = 0
            stamp([(p, pressure)])
            return
        }
        strokePath = CGMutablePath()
        strokePath.move(to: p)
        lastMid = p
        activeRenderer = strokeRenderer()
        invalidate(canvasRect: CGRect(origin: p, size: .zero))
    }

    private func addStrokePoint(_ p: CGPoint, pressure: CGFloat) {
        guard let prev = strokePoints.last else { return }
        guard hypot(p.x - prev.x, p.y - prev.y) * viewport.zoom >= 0.75 else { return }
        strokePoints.append(p)
        if useDabs {
            let spacing = max(0.5, strokeWidth * 0.1)
            let from = lastDab.point, dist = hypot(p.x - from.x, p.y - from.y)
            var dabs: [(CGPoint, CGFloat)] = []
            var t = spacing - dabCarry
            while t <= dist {
                let f = t / dist
                dabs.append((CGPoint(x: from.x + (p.x - from.x) * f, y: from.y + (p.y - from.y) * f),
                             lastDab.pressure + (pressure - lastDab.pressure) * f))
                t += spacing
            }
            dabCarry = dist - (t - spacing)
            lastDab = (p, pressure)
            if !dabs.isEmpty { stamp(dabs) }
            return
        }
        let oldMid = lastMid
        let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
        strokePath.addQuadCurve(to: mid, control: prev)
        lastMid = mid
        activeRenderer = strokeRenderer()
        let xs = [oldMid.x, prev.x, mid.x, p.x], ys = [oldMid.y, prev.y, mid.y, p.y]
        invalidate(canvasRect: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
    }

    private func stamp(_ dabs: [(CGPoint, CGFloat)]) {
        guard let dab = dabImage else { return }
        let rects = dabs.map { c, pr -> CGRect in
            let d = max(1, strokeWidth * pr)
            return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        }
        let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.integral
        let batch = Bitmap.render(bounds.size) { ctx in
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            for r in rects { ctx.draw(dab, in: r) }
        }
        dabBatches.append((batch, bounds))
        activeRenderer = dabRenderer()
        setNeedsDisplay(toView(bounds).insetBy(dx: -2, dy: -2))
    }

    private static func makeDab(diameter: CGFloat, hardness: CGFloat, color: CGColor) -> CGImage {
        let d = max(2, ceil(diameter))
        let rect = CGRect(x: 0, y: 0, width: d, height: d)
        return Bitmap.render(rect.size) { ctx in
            if hardness >= 0.99 {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: rect)
            } else if let g = CGGradient(colorsSpace: Bitmap.colorSpace,
                                         colors: [color, color, color.copy(alpha: 0)!] as CFArray,
                                         locations: [0, max(0, hardness), 1]) {
                let c = CGPoint(x: d / 2, y: d / 2)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: d / 2, options: [])
            }
        }
    }

    private func dabRenderer() -> LayerRenderer {
        let batches = dabBatches
        let erase = editor.tool == .eraser
        let opacity = editor.brushOpacity
        let selection = editor.selection
        return { ctx, img, rect in
            ctx.draw(img, in: rect)
            ctx.saveGState()
            if let selection { ctx.clip(to: selection) }
            ctx.setAlpha(opacity)
            if erase { ctx.setBlendMode(.destinationOut) }
            // Grouping keeps overlapping dabs from stacking past the chosen opacity.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for b in batches { ctx.draw(b.image, in: b.rect) }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    private func invalidate(canvasRect r: CGRect) {
        let size = editor.tool == .eraser ? editor.eraserSize : editor.brushSize
        setNeedsDisplay(toView(r.insetBy(dx: -size / 2 - 2, dy: -size / 2 - 2)).insetBy(dx: -2, dy: -2))
    }

    private func strokeRenderer() -> LayerRenderer {
        let path = strokePath.mutableCopy()!
        if let last = strokePoints.last {
            // A lone click still needs a visible dot.
            path.addLine(to: strokePoints.count == 1 ? CGPoint(x: last.x + 0.01, y: last.y) : last)
        }
        let erase = editor.tool == .eraser
        let width = erase ? editor.eraserSize : editor.brushSize
        let opacity = editor.brushOpacity
        let color = erase ? CGColor(gray: 0, alpha: opacity) : (editor.primaryCG.copy(alpha: opacity) ?? editor.primaryCG)
        let selection = editor.selection
        return { ctx, img, rect in
            ctx.draw(img, in: rect)
            ctx.saveGState()
            if let selection { ctx.clip(to: selection) }
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(color)
            if erase { ctx.setBlendMode(.destinationOut) }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func moveRenderer(_ d: CGPoint) -> LayerRenderer {
        let selection = editor.selection
        return { ctx, img, rect in
            if let sel = selection {
                ctx.draw(img, in: rect)
                ctx.clear(sel)
                ctx.saveGState()
                ctx.clip(to: sel.offsetBy(dx: d.x, dy: d.y))
                ctx.draw(img, in: rect.offsetBy(dx: d.x, dy: d.y))
                ctx.restoreGState()
            } else {
                ctx.draw(img, in: rect.offsetBy(dx: d.x, dy: d.y))
            }
        }
    }

    private func shapeRenderer(_ a: CGPoint, _ b: CGPoint) -> LayerRenderer {
        let kind = editor.shapeKind, filled = editor.shapeFilled, width = editor.shapeLineWidth
        let color = editor.primaryCG.copy(alpha: editor.brushOpacity) ?? editor.primaryCG
        let selection = editor.selection
        return { ctx, img, rect in
            ctx.draw(img, in: rect)
            if let selection { ctx.clip(to: selection) }
            ShapeDrawer.draw(kind, from: a, to: b, filled: filled, lineWidth: width, color: color, in: ctx)
        }
    }

    private func gradientRenderer(_ a: CGPoint, _ b: CGPoint) -> LayerRenderer {
        let colors = [editor.primaryCG, editor.secondaryCG]
        let opacity = editor.brushOpacity
        let selection = editor.selection
        return { ctx, img, rect in
            ctx.draw(img, in: rect)
            ctx.saveGState()
            ctx.clip(to: selection ?? rect)
            ctx.setAlpha(opacity)
            ShapeDrawer.gradient(from: a, to: b, colors: colors, in: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: Zoom & scroll

    private func zoom(to newZoom: CGFloat, around view: CGPoint) {
        let z = min(max(newZoom, 0.02), 64)
        let c = toCanvas(view)
        viewport.zoom = z
        let ox = view.x - c.x * z, oy = view.y - c.y * z
        viewport.offset = CGPoint(x: ox - (bounds.width - editor.canvasSize.width * z) / 2,
                                  y: oy - (bounds.height - editor.canvasSize.height * z) / 2)
    }

    override func scrollWheel(with e: NSEvent) {
        guard editor.hasDocument else { return }
        let view = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) || !e.hasPreciseScrollingDeltas {
            let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            zoom(to: viewport.zoom * exp(delta), around: view)
        } else {
            viewport.offset = CGPoint(x: viewport.offset.x + e.scrollingDeltaX, y: viewport.offset.y - e.scrollingDeltaY)
        }
    }

    override func magnify(with e: NSEvent) {
        guard editor.hasDocument else { return }
        zoom(to: viewport.zoom * (1 + e.magnification), around: convert(e.locationInWindow, from: nil))
    }

    override func smartMagnify(with e: NSEvent) {
        guard editor.hasDocument else { return }
        if abs(viewport.zoom - 1) < 0.01 { editor.zoomToFit() } else { zoom(to: 1, around: convert(e.locationInWindow, from: nil)) }
    }

    // MARK: Keyboard

    /// Returns true if the key was consumed. Plain-key shortcuts only fire when the canvas window
    /// is key and no text field is being edited.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard let window, e.window === window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])

        if e.type == .keyUp {
            if e.keyCode == 49, spaceDown {
                spaceDown = false
                cursorKey = ""
                needsDisplay = true
                return true
            }
            return false
        }
        guard mods.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)

        switch e.keyCode {
        case 49: // space
            if !spaceDown {
                spaceDown = true
                cursorKey = ""
                needsDisplay = true
            }
            return true
        case 36, 76: // return
            if editor.cropRect != nil { editor.applyCrop(); return true }
            if !editor.adjustments.isIdentity { editor.applyAdjustments(); return true }
            return false
        case 53: // escape
            if editor.cropRect != nil { editor.cropRect = nil }
            else if !editor.adjustments.isIdentity { editor.cancelAdjustments() }
            else { editor.selection = nil }
            return true
        case 51, 117: // delete
            guard editor.hasDocument else { return false }
            if editor.selection != nil { editor.clearSelection() } else { editor.deleteLayer() }
            return true
        case 123, 124, 125, 126: // arrows nudge the layer with the move tool
            guard editor.tool == .move, editor.hasDocument else { return false }
            let step: CGFloat = shift ? 10 : 1
            let d: CGPoint = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0),
                              125: CGPoint(x: 0, y: -step), 126: CGPoint(x: 0, y: step)][e.keyCode]!
            editor.commitActive(moving: d, moveRenderer(d))
            editor.selection = editor.selection?.offsetBy(dx: d.x, dy: d.y)
            return true
        default:
            break
        }

        guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return false }
        if let tool = Tool.allCases.first(where: { $0.key == ch }) {
            editor.tool = tool
            return true
        }
        switch ch {
        case "[", "]":
            let up = ch == "]"
            let adjust: (Double) -> Double = { s in
                let step = max(1, (s * 0.15).rounded())
                return min(1000, max(1, up ? s + step : s - step))
            }
            if editor.tool == .eraser { editor.eraserSize = adjust(editor.eraserSize) }
            else if editor.tool == .shape { editor.shapeLineWidth = adjust(editor.shapeLineWidth) }
            else { editor.brushSize = adjust(editor.brushSize) }
            return true
        case "x":
            editor.swapColors(); return true
        case "d":
            editor.resetColors(); return true
        case "0"..."9":
            let n = Double(String(ch))!
            editor.brushOpacity = n == 0 ? 1 : n / 10
            return true
        default:
            return false
        }
    }
}
