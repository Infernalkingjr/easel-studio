import AppKit
import SwiftUI
import Observation

struct TimelineGridView: NSViewRepresentable {
    let studio: FlipStudio
    func makeNSView(context: Context) -> TimelineGridNSView { TimelineGridNSView(studio: studio) }
    func updateNSView(_ nsView: TimelineGridNSView, context: Context) {}
}

/// Animate-style timeline: one row per layer, one column per frame.
final class TimelineGridNSView: NSView {
    private let studio: FlipStudio
    private var isTracking = false
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var cellW: CGFloat = 14

    static let header: CGFloat = 190
    static let ruler: CGFloat = 22
    static let rowH: CGFloat = 26

    private enum Drag {
        case scrub
        case key(layer: UUID, from: Int, to: Int)
    }
    private var drag: Drag?

    init(studio: FlipStudio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func x(_ frame: Int) -> CGFloat { Self.header + CGFloat(frame) * cellW - scrollX }
    private func frame(at px: CGFloat) -> Int { max(0, Int((px - Self.header + scrollX) / cellW)) }
    private func rowY(_ i: Int) -> CGFloat { Self.ruler + CGFloat(i) * Self.rowH - scrollY }
    private func row(at y: CGFloat) -> Int? {
        let i = Int((y - Self.ruler + scrollY) / Self.rowH)
        return y > Self.ruler && studio.doc.layers.indices.contains(i) ? i : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isTracking { render() } else {
            isTracking = true
            withObservationTracking { render() } onChange: { [weak self] in
                DispatchQueue.main.async { self?.isTracking = false; self?.needsDisplay = true }
            }
        }
    }

    private func render() {
        let doc = studio.doc, current = studio.frame, layerID = studio.layerID
        // Keep the playhead visible while playing.
        let px = x(current)
        if px > bounds.width - 20 || px < Self.header {
            scrollX = max(0, CGFloat(current) * cellW - (bounds.width - Self.header) / 3)
        }
        NSColor(srgbRed: 0.12, green: 0.12, blue: 0.135, alpha: 1).setFill()
        bounds.fill()
        let used = doc.usedFrames
        let lastVisible = frame(at: bounds.width) + 1

        // Ruler
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.ruler).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        for f in frame(at: Self.header)...lastVisible where (f + 1) % 5 == 0 || f == 0 {
            NSAttributedString(string: "\(f + 1)", attributes: attrs).draw(at: CGPoint(x: x(f) + 2, y: 5))
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 0, y: Self.ruler, width: bounds.width, height: bounds.height)).addClip()
        for (i, layer) in doc.layers.enumerated() {
            let y = rowY(i)
            guard y + Self.rowH > Self.ruler, y < bounds.height else { continue }
            let selected = layer.id == layerID
            // Cells
            for f in frame(at: Self.header)...lastVisible {
                let r = CGRect(x: x(f), y: y, width: cellW, height: Self.rowH)
                let shade: CGFloat = f >= used ? 0.1 : ((f + 1) % 5 == 0 ? 0.2 : 0.16)
                NSColor(white: shade + (selected ? 0.04 : 0), alpha: 1).setFill()
                r.insetBy(dx: 0.5, dy: 0.5).fill()
            }
            // Spans
            for (k, key) in layer.keyframes.enumerated() {
                let end = k + 1 < layer.keyframes.count ? layer.keyframes[k + 1].frame : used
                let span = CGRect(x: x(key.frame), y: y + 1, width: CGFloat(end - key.frame) * cellW, height: Self.rowH - 2)
                let empty = key.drawing.strokes.isEmpty
                if key.tween && k + 1 < layer.keyframes.count {
                    NSColor(srgbRed: 0.55, green: 0.42, blue: 0.95, alpha: 0.55).setFill()
                    span.fill()
                    NSColor.white.withAlphaComponent(0.7).setStroke()
                    let arrow = NSBezierPath()
                    arrow.move(to: CGPoint(x: span.minX + cellW, y: span.midY))
                    arrow.line(to: CGPoint(x: span.maxX - 4, y: span.midY))
                    arrow.move(to: CGPoint(x: span.maxX - 8, y: span.midY - 3))
                    arrow.line(to: CGPoint(x: span.maxX - 4, y: span.midY))
                    arrow.line(to: CGPoint(x: span.maxX - 8, y: span.midY + 3))
                    arrow.lineWidth = 1
                    arrow.stroke()
                } else if !empty {
                    NSColor(white: 0.36, alpha: 1).setFill()
                    span.fill()
                }
                NSColor.black.withAlphaComponent(0.6).setFill()
                CGRect(x: span.minX, y: y, width: 1, height: Self.rowH).fill()
                let dot = CGRect(x: x(key.frame) + cellW / 2 - 3.5, y: y + Self.rowH - 11, width: 7, height: 7)
                if empty {
                    NSColor.white.setStroke()
                    let c = NSBezierPath(ovalIn: dot); c.lineWidth = 1.2; c.stroke()
                } else {
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
            if case .key(let lid, let from, let to)? = drag, lid == layer.id, from != to {
                NSColor.systemYellow.setFill()
                CGRect(x: x(to), y: y + 2, width: cellW, height: Self.rowH - 4).fill()
            }
            // Header
            let header = CGRect(x: 0, y: y, width: Self.header, height: Self.rowH)
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor(white: 0.17, alpha: 1)).setFill()
            header.fill()
            FlipStudio.layerColors[layer.colorIndex % FlipStudio.layerColors.count].setFill()
            CGRect(x: 0, y: y, width: 4, height: Self.rowH).fill()
            for (k, symbol, on) in [(0, layer.visible ? "eye" : "eye.slash", layer.visible), (1, layer.locked ? "lock.fill" : "lock.open", layer.locked)] {
                if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [NSColor.white.withAlphaComponent(on || k == 0 ? 0.85 : 0.35)]))) {
                    img.draw(in: CGRect(x: 12 + CGFloat(k) * 22, y: y + (Self.rowH - img.size.height) / 2, width: img.size.width, height: img.size.height))
                }
            }
            NSAttributedString(string: layer.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
                .draw(with: CGRect(x: 60, y: y + 5, width: Self.header - 66, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            NSColor.black.withAlphaComponent(0.5).setFill()
            CGRect(x: 0, y: y + Self.rowH - 1, width: bounds.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Playhead
        let hx = x(current)
        if hx >= Self.header {
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            CGRect(x: hx, y: 0, width: cellW, height: bounds.height).fill()
            NSColor.systemRed.setFill()
            CGRect(x: hx + cellW / 2 - 0.5, y: Self.ruler, width: 1, height: bounds.height).fill()
            NSBezierPath(roundedRect: CGRect(x: hx - 1, y: 2, width: cellW + 2, height: Self.ruler - 4), xRadius: 3, yRadius: 3).fill()
        }
        NSColor.black.withAlphaComponent(0.6).setFill()
        CGRect(x: Self.header - 1, y: 0, width: 1, height: bounds.height).fill()
        NSAttributedString(string: "Layers", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
            .draw(at: CGPoint(x: 10, y: 4))
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        studio.pause()
        if p.y < Self.ruler {
            drag = .scrub
            studio.go(to: frame(at: max(p.x, Self.header)))
            return
        }
        guard let i = row(at: p.y) else { return }
        let layer = studio.doc.layers[i]
        studio.layerID = layer.id
        if p.x < Self.header {
            if p.x >= 8 && p.x < 30 { studio.updateLayer(layer.id, checkpoint: true) { $0.visible.toggle() } }
            else if p.x >= 30 && p.x < 52 { studio.updateLayer(layer.id, checkpoint: true) { $0.locked.toggle() } }
            return
        }
        let f = frame(at: p.x)
        studio.go(to: f)
        if layer.keyframes.contains(where: { $0.frame == f }) {
            drag = .key(layer: layer.id, from: f, to: f)
        } else {
            drag = .scrub
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .scrub?: studio.go(to: frame(at: max(p.x, Self.header)))
        case .key(let l, let from, _)?:
            drag = .key(layer: l, from: from, to: frame(at: max(p.x, Self.header)))
            needsDisplay = true
        case nil: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        if case .key(let l, let from, let to)? = drag, from != to {
            studio.moveKeyframe(layer: l, from: from, to: to)
            studio.go(to: to)
        }
        drag = nil
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = row(at: p.y), p.x > Self.header else { return nil }
        studio.layerID = studio.doc.layers[i].id
        studio.go(to: frame(at: p.x))
        let menu = NSMenu()
        let items: [(String, () -> Void)] = [
            ("Insert Keyframe (F6)", { self.studio.insertKeyframe() }),
            ("Insert Blank Keyframe (F7)", { self.studio.insertKeyframe(blank: true) }),
            ("Clear Keyframe", { self.studio.clearKeyframe() }),
            ("Create Motion Tween", { self.studio.setTween(true) }),
            ("Remove Tween", { self.studio.setTween(false) }),
            ("Insert Frame (F5)", { self.studio.insertFrame() }),
            ("Remove Frame (⇧F5)", { self.studio.removeFrame() }),
        ]
        for (title, action) in items {
            let item = MenuAction(title: title, action: action)
            menu.addItem(item)
        }
        return menu
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            cellW = min(40, max(5, cellW * exp(e.scrollingDeltaY * 0.01)))
        } else if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) || e.modifierFlags.contains(.shift) {
            scrollX = max(0, scrollX - (e.modifierFlags.contains(.shift) ? e.scrollingDeltaY : e.scrollingDeltaX))
        } else {
            let maxY = max(0, CGFloat(studio.doc.layers.count) * Self.rowH - (bounds.height - Self.ruler) + 20)
            scrollY = min(maxY, max(0, scrollY - e.scrollingDeltaY))
        }
        needsDisplay = true
    }
}

/// An NSMenuItem that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
