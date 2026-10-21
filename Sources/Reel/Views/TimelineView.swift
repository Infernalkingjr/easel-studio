import AppKit
import SwiftUI
import Observation
import EaselKit

struct TimelineView: NSViewRepresentable {
    let studio: Studio
    func makeNSView(context: Context) -> TimelineNSView { TimelineNSView(studio: studio) }
    func updateNSView(_ nsView: TimelineNSView, context: Context) {}
}

/// Custom-drawn timeline. Drags edit a draft copy of the project that is committed on mouse-up,
/// so the player is rebuilt once per edit, not on every mouse move.
final class TimelineNSView: NSView {
    private let studio: Studio
    private var draft: Project?
    private var scrollX: CGFloat = 0
    private var isTracking = false
    private let playheadLayer = CALayer()
    private let playheadKnob = CAShapeLayer()

    // Layout (flipped: y grows downward).
    static let header: CGFloat = 36
    static let ruler: CGFloat = 26
    static let laneHeights: [TimelineLane: CGFloat] = [.titles: 28, .graphics: 30, .video: 78, .music: 46]
    static let gap: CGFloat = 6

    private enum Drag {
        case scrub
        case trimClip(id: UUID, leftEdge: Bool, original: Clip)
        case moveClip(id: UUID, from: Int, start: CGPoint, active: Bool, target: Int)
        case item(kind: TimelineLane, id: UUID, mode: ItemMode, startX: CGFloat, original: (start: Double, duration: Double, source: Double))
    }

    private enum ItemMode { case move, left, right }

    private var drag: Drag?

    // Palette (the timeline is always dark, like pro editors).
    private let bg = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.125, alpha: 1)
    private let laneBG = NSColor(srgbRed: 0.155, green: 0.155, blue: 0.175, alpha: 1)
    private let videoColor = NSColor(srgbRed: 0.26, green: 0.42, blue: 0.95, alpha: 1)
    private let titleColor = NSColor(srgbRed: 0.62, green: 0.36, blue: 0.95, alpha: 1)
    private let graphicColor = NSColor(srgbRed: 0.1, green: 0.68, blue: 0.68, alpha: 1)
    private let musicColor = NSColor(srgbRed: 0.2, green: 0.72, blue: 0.38, alpha: 1)

    init(studio: Studio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLayer.zPosition = 10
        playheadKnob.fillColor = NSColor.systemRed.cgColor
        playheadKnob.zPosition = 11
        layer?.addSublayer(playheadLayer)
        layer?.addSublayer(playheadKnob)
        registerForDraggedTypes([.fileURL, .string])
        trackPlayhead()
        NotificationCenter.default.addObserver(forName: .reelFitTimeline, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.zoomToFit() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var project: Project { draft ?? studio.project }
    private var zoom: CGFloat { CGFloat(studio.timelineZoom) }

    // MARK: Geometry

    func x(_ t: Double) -> CGFloat { Self.header + CGFloat(t) * zoom - scrollX }
    func time(_ x: CGFloat) -> Double { max(0, Double((x - Self.header + scrollX) / zoom)) }

    func laneRect(_ lane: TimelineLane) -> CGRect {
        var y = Self.ruler + Self.gap
        for l in TimelineLane.allCases {
            let h = Self.laneHeights[l]!
            if l == lane { return CGRect(x: Self.header, y: y, width: bounds.width - Self.header, height: h) }
            y += h + Self.gap
        }
        return .zero
    }

    private func lane(at y: CGFloat) -> TimelineLane? {
        TimelineLane.allCases.first { laneRect($0).insetBy(dx: 0, dy: -Self.gap / 2).minY <= y && y < laneRect($0).insetBy(dx: 0, dy: -Self.gap / 2).maxY }
    }

    private func clipRects() -> [(Int, CGRect)] {
        let starts = project.clipStarts, lane = laneRect(.video)
        return project.clips.indices.map { i in
            (i, CGRect(x: x(starts[i]), y: lane.minY, width: CGFloat(project.clips[i].duration) * zoom, height: lane.height))
        }
    }

    private func itemRect(lane: TimelineLane, start: Double, duration: Double) -> CGRect {
        let r = laneRect(lane)
        return CGRect(x: x(start), y: r.minY + 2, width: max(4, CGFloat(duration) * zoom), height: r.height - 4)
    }

    private func clampScroll() {
        let content = CGFloat(project.duration) * zoom + 300
        scrollX = min(max(0, scrollX), max(0, content - (bounds.width - Self.header)))
    }

    // MARK: Playhead

    /// Moves the playhead layer whenever playback time changes, without redrawing the timeline.
    private func trackPlayhead() {
        withObservationTracking {
            _ = studio.playback.time
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updatePlayhead()
                self?.trackPlayhead()
            }
        }
        updatePlayhead()
    }

    private func updatePlayhead() {
        let t = studio.playback.time
        var px = x(t)
        // Keep the playhead in view while playing.
        if studio.playback.isPlaying, drag == nil, px > bounds.width - 40 || px < Self.header {
            scrollX += px - Self.header - 40
            clampScroll()
            needsDisplay = true
            px = x(t)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: px - 1, y: Self.ruler - 4, width: 2, height: bounds.height)
        let knob = CGMutablePath()
        knob.move(to: CGPoint(x: px - 6, y: 2))
        knob.addLine(to: CGPoint(x: px + 6, y: 2))
        knob.addLine(to: CGPoint(x: px + 6, y: Self.ruler - 10))
        knob.addLine(to: CGPoint(x: px, y: Self.ruler - 3))
        knob.addLine(to: CGPoint(x: px - 6, y: Self.ruler - 10))
        knob.closeSubpath()
        playheadKnob.path = knob
        playheadLayer.isHidden = px < Self.header - 1
        playheadKnob.isHidden = playheadLayer.isHidden
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updatePlayhead()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isTracking {
            render(dirtyRect)
        } else {
            isTracking = true
            withObservationTracking {
                render(dirtyRect)
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.isTracking = false
                    self?.needsDisplay = true
                    self?.updatePlayhead()
                }
            }
        }
    }

    private func render(_ dirty: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        _ = studio.mediaRevision
        _ = studio.timelineZoom
        let project = self.project
        let selection = studio.selection

        bg.setFill()
        dirty.fill()
        for lane in TimelineLane.allCases {
            laneBG.setFill()
            NSBezierPath(roundedRect: laneRect(lane).insetBy(dx: 0, dy: 0), xRadius: 6, yRadius: 6).fill()
        }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: Self.header, y: 0, width: bounds.width - Self.header, height: bounds.height))
        drawRuler(project)
        drawClips(project, selection: selection, ctx: ctx)
        drawItems(project, selection: selection)
        if case .moveClip(_, _, _, true, let target) = drag {
            let starts = project.clipStarts
            let tx = target < project.clips.count ? x(starts[target]) : x(project.mainDuration)
            NSColor.systemYellow.setFill()
            NSRect(x: tx - 2, y: laneRect(.video).minY - 4, width: 4, height: laneRect(.video).height + 8).fill()
        }
        ctx.restoreGState()
        drawHeader()

        if project.clips.isEmpty && project.titles.isEmpty {
            let text = NSAttributedString(string: "Drag videos, photos or music here — or press ⌘I to import", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ])
            let r = laneRect(.video)
            text.draw(at: CGPoint(x: r.minX + 16, y: r.midY - 8))
        }
    }

    private func drawHeader() {
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: Self.header, height: bounds.height).fill()
        let symbols: [TimelineLane: String] = [.titles: "textformat", .graphics: "photo.on.rectangle", .video: "film", .music: "music.note"]
        for lane in TimelineLane.allCases {
            let r = laneRect(lane)
            if let image = NSImage(systemSymbolName: symbols[lane]!, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.55)]))) {
                image.draw(in: CGRect(x: (Self.header - image.size.width) / 2, y: r.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height))
            }
        }
    }

    private func rulerStep() -> Double {
        let steps: [Double] = [1.0 / 30, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 * Double(zoom) >= 70 } ?? 600
    }

    static func timecode(_ t: Double, fine: Bool = false) -> String {
        let total = max(0, t)
        let m = Int(total) / 60, s = Int(total) % 60
        if fine { return String(format: "%d:%02d.%02d", m, s, Int((total - floor(total)) * 100)) }
        return String(format: "%d:%02d", m, s)
    }

    private func drawRuler(_ project: Project) {
        let step = rulerStep()
        let t0 = time(Self.header), t1 = time(bounds.width)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.5)]
        NSColor.white.withAlphaComponent(0.18).setFill()
        var t = floor(t0 / step) * step
        while t <= t1 + step {
            let px = x(t)
            NSRect(x: px, y: Self.ruler - 9, width: 1, height: 9).fill()
            let label = step < 1 ? Self.timecode(t, fine: true) : Self.timecode(t)
            NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: px + 3, y: 4))
            let minor = step / 4
            for k in 1..<4 { NSRect(x: x(t + minor * Double(k)), y: Self.ruler - 4, width: 1, height: 4).fill() }
            t += step
        }
        // Dim everything past the end of the movie.
        let end = x(project.duration)
        if end < bounds.width {
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSRect(x: max(Self.header, end), y: Self.ruler, width: bounds.width - end, height: bounds.height).fill()
        }
    }

    private func drawClips(_ project: Project, selection: Selection?, ctx: CGContext) {
        let visible = CGRect(x: Self.header, y: 0, width: bounds.width - Self.header, height: bounds.height)
        let starts = project.clipStarts
        for (i, rect) in clipRects() where rect.intersects(visible) {
            let clip = project.clips[i]
            guard let media = project.media(clip.mediaID) else { continue }
            let r = rect.insetBy(dx: 1, dy: 0)
            let shape = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            videoColor.withAlphaComponent(0.85).setFill()
            r.fill()

            // Filmstrip
            let waveH: CGFloat = media.hasAudio && !clip.muted ? 16 : 0
            let stripH = r.height - waveH
            let aspect = max(0.4, min(3, media.size.width / max(1, media.size.height)))
            let tileW = max(24, stripH * aspect)
            var tx = r.minX
            if tx < Self.header { tx += floor((Self.header - tx) / tileW) * tileW }
            while tx < min(r.maxX, bounds.width) {
                let local = Double((tx - rect.minX) / zoom) * clip.speed
                if let thumb = studio.library.thumbnail(for: media, at: clip.sourceStart + local) {
                    ctx.saveGState()
                    // The view is flipped; draw images upright.
                    ctx.translateBy(x: tx, y: r.minY + stripH)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.interpolationQuality = .medium
                    let tw = CGFloat(thumb.width), th = CGFloat(thumb.height)
                    let fill = max(tileW / tw, stripH / th)
                    ctx.clip(to: CGRect(x: 0, y: 0, width: tileW, height: stripH))
                    ctx.draw(thumb, in: CGRect(x: (tileW - tw * fill) / 2, y: (stripH - th * fill) / 2, width: tw * fill, height: th * fill))
                    ctx.restoreGState()
                }
                tx += tileW
            }

            // Waveform
            if waveH > 0 {
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSRect(x: r.minX, y: r.maxY - waveH, width: r.width, height: waveH).fill()
                if let peaks = studio.library.waveform(for: media) {
                    drawWave(peaks, in: CGRect(x: r.minX, y: r.maxY - waveH, width: r.width, height: waveH),
                             sourceStart: clip.sourceStart, speed: clip.speed, color: NSColor(srgbRed: 0.55, green: 0.8, blue: 1, alpha: 0.9),
                             gain: clip.volume)
                }
            }

            // Fades
            for (fade, leading) in [(clip.fadeIn, true), (clip.fadeOut, false)] where fade > 0 {
                let w = CGFloat(fade) * zoom
                let p = NSBezierPath()
                if leading {
                    p.move(to: CGPoint(x: r.minX, y: r.minY)); p.line(to: CGPoint(x: r.minX + w, y: r.minY)); p.line(to: CGPoint(x: r.minX, y: r.maxY))
                } else {
                    p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.line(to: CGPoint(x: r.maxX - w, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.maxY))
                }
                NSColor.black.withAlphaComponent(0.4).setFill()
                p.fill()
            }

            // Label & badges
            var badges = [media.name]
            if abs(clip.speed - 1) > 0.01 { badges.append(String(format: "%g×", clip.speed)) }
            if let look = clip.look, let e = Effect.all.first(where: { $0.id == look }) { badges.append(e.name) }
            if clip.autoEnhance { badges.append("✦ Enhanced") }
            if clip.muted && media.hasAudio { badges.append("Muted") }
            let label = NSAttributedString(string: badges.joined(separator: "  ·  "), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let lw = min(label.size().width + 10, r.width - 4)
            if lw > 16 {
                NSColor.black.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: CGRect(x: max(r.minX, Self.header) + 3, y: r.minY + 3, width: lw, height: 17), xRadius: 4, yRadius: 4).fill()
                label.draw(with: CGRect(x: max(r.minX, Self.header) + 8, y: r.minY + 5, width: lw - 8, height: 14),
                           options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            }
            NSGraphicsContext.restoreGraphicsState()

            let selected = selection == .clip(clip.id)
            (selected ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.2)).setStroke()
            shape.lineWidth = selected ? 2.5 : 1
            shape.stroke()
            if selected {
                NSColor.systemYellow.setFill()
                NSBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY + r.height / 2 - 12, width: 5, height: 24), xRadius: 2, yRadius: 2).fill()
                NSBezierPath(roundedRect: CGRect(x: r.maxX - 5, y: r.minY + r.height / 2 - 12, width: 5, height: 24), xRadius: 2, yRadius: 2).fill()
            }

            // Transition badge over the overlap.
            if let transition = clip.transition, i + 1 < project.clips.count {
                let overlap = project.overlap(after: i)
                let ox = x(starts[i + 1]), ow = CGFloat(overlap) * zoom
                let badge = CGRect(x: ox + ow / 2 - 12, y: r.midY - 10, width: 24, height: 20)
                NSColor.white.withAlphaComponent(0.22).setFill()
                NSRect(x: ox, y: r.minY, width: ow, height: r.height).fill()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                if let icon = NSImage(systemSymbolName: transition.kind.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .bold).applying(.init(paletteColors: [videoColor]))) {
                    icon.draw(in: CGRect(x: badge.midX - icon.size.width / 2, y: badge.midY - icon.size.height / 2,
                                         width: icon.size.width, height: icon.size.height))
                }
            }
        }
    }

    private func drawWave(_ peaks: [Float], in r: CGRect, sourceStart: Double, speed: Double, color: NSColor, gain: Double) {
        let path = NSBezierPath()
        let x0 = max(r.minX, Self.header), x1 = min(r.maxX, bounds.width)
        guard x1 > x0 else { return }
        var px = x0
        while px < x1 {
            let t = sourceStart + Double((px - r.minX) / zoom) * speed
            let i = Int(t * MediaLibrary.waveformRate)
            let span = max(1, Int(Double(1 / zoom) * speed * MediaLibrary.waveformRate))
            var peak: Float = 0
            if i >= 0, i < peaks.count {
                for k in i..<min(peaks.count, i + span) { peak = max(peak, peaks[k]) }
            }
            let h = max(1, CGFloat(min(1, Double(peak) * gain)) * (r.height - 2))
            path.appendRect(CGRect(x: px, y: r.midY - h / 2, width: 1, height: h))
            px += 2
        }
        color.setFill()
        path.fill()
    }

    private func drawItems(_ project: Project, selection: Selection?) {
        for title in project.titles {
            let r = itemRect(lane: .titles, start: title.start, duration: title.duration)
            drawCapsule(r, color: titleColor, text: title.text.replacingOccurrences(of: "\n", with: " "),
                        icon: "textformat", selected: selection == .title(title.id))
        }
        for g in project.graphics {
            let r = itemRect(lane: .graphics, start: g.start, duration: g.duration)
            drawCapsule(r, color: graphicColor, text: project.media(g.mediaID)?.name ?? "Graphic",
                        icon: "photo", selected: selection == .graphic(g.id))
        }
        for m in project.music {
            let r = itemRect(lane: .music, start: m.start, duration: m.duration)
            let selected = selection == .music(m.id)
            let shape = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            musicColor.withAlphaComponent(0.35).setFill()
            shape.fill()
            if let media = project.media(m.mediaID), let peaks = studio.library.waveform(for: media) {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                drawWave(peaks, in: r.insetBy(dx: 0, dy: 4), sourceStart: m.sourceStart, speed: 1,
                         color: musicColor.withAlphaComponent(0.95), gain: m.volume * 1.4)
                NSGraphicsContext.restoreGraphicsState()
            }
            let label = NSAttributedString(string: "♪ " + (project.media(m.mediaID)?.name ?? "Music"), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            label.draw(with: CGRect(x: max(r.minX, Self.header) + 6, y: r.minY + 3, width: max(0, r.width - 10), height: 14),
                       options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            (selected ? NSColor.systemYellow : musicColor).setStroke()
            shape.lineWidth = selected ? 2.5 : 1
            shape.stroke()
        }
    }

    private func drawCapsule(_ r: CGRect, color: NSColor, text: String, icon: String, selected: Bool) {
        let shape = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.85).setFill()
        shape.fill()
        (selected ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.25)).setStroke()
        shape.lineWidth = selected ? 2.5 : 1
        shape.stroke()
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        label.draw(with: CGRect(x: max(r.minX, Self.header) + 7, y: r.midY - 7, width: max(0, r.maxX - max(r.minX, Self.header) - 12), height: 14),
                   options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    // MARK: Mouse

    private func snapped(_ t: Double, excluding id: UUID?) -> Double {
        guard studio.snapping else { return t }
        var points = [studio.playback.time, 0]
        let starts = project.clipStarts
        for (i, c) in project.clips.enumerated() where c.id != id { points += [starts[i], starts[i] + c.duration] }
        for item in project.titles where item.id != id { points += [item.start, item.end] }
        for item in project.graphics where item.id != id { points += [item.start, item.end] }
        for item in project.music where item.id != id { points += [item.start, item.end] }
        let threshold = Double(8 / zoom)
        return points.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) < threshold ? $0 : nil } ?? t
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if p.y < Self.ruler || p.x < Self.header {
            drag = .scrub
            studio.pause()
            studio.seek(to: time(p.x))
            return
        }
        let edge: CGFloat = 7
        switch lane(at: p.y) {
        case .video?:
            if let (i, r) = clipRects().first(where: { $0.1.minX - 2 <= p.x && p.x <= $0.1.maxX + 2 }) {
                let clip = project.clips[i]
                studio.selection = .clip(clip.id)
                if p.x - r.minX < edge && r.width > 20 {
                    drag = .trimClip(id: clip.id, leftEdge: true, original: clip)
                } else if r.maxX - p.x < edge && r.width > 20 {
                    drag = .trimClip(id: clip.id, leftEdge: false, original: clip)
                } else {
                    drag = .moveClip(id: clip.id, from: i, start: p, active: false, target: i)
                }
                draft = studio.project
                if e.clickCount == 2 { studio.seek(to: project.clipStarts[i]) }
                return
            }
        case let l? where l != .video:
            if let hit = itemHit(l, p) {
                let r = hit.rect
                let mode: ItemMode = p.x - r.minX < edge ? .left : (r.maxX - p.x < edge ? .right : .move)
                drag = .item(kind: l, id: hit.id, mode: mode, startX: p.x, original: hit.original)
                draft = studio.project
                switch l {
                case .titles: studio.selection = .title(hit.id)
                case .graphics: studio.selection = .graphic(hit.id)
                case .music: studio.selection = .music(hit.id)
                case .video: break
                }
                return
            }
        default: break
        }
        studio.selection = nil
        drag = .scrub
        studio.pause()
        studio.seek(to: time(p.x))
    }

    private func itemHit(_ lane: TimelineLane, _ p: CGPoint) -> (id: UUID, rect: CGRect, original: (start: Double, duration: Double, source: Double))? {
        switch lane {
        case .titles:
            for t in project.titles.reversed() {
                let r = itemRect(lane: .titles, start: t.start, duration: t.duration)
                if r.insetBy(dx: -3, dy: 0).contains(p) { return (t.id, r, (t.start, t.duration, 0)) }
            }
        case .graphics:
            for g in project.graphics.reversed() {
                let r = itemRect(lane: .graphics, start: g.start, duration: g.duration)
                if r.insetBy(dx: -3, dy: 0).contains(p) { return (g.id, r, (g.start, g.duration, 0)) }
            }
        case .music:
            for m in project.music.reversed() {
                let r = itemRect(lane: .music, start: m.start, duration: m.duration)
                if r.insetBy(dx: -3, dy: 0).contains(p) { return (m.id, r, (m.start, m.duration, m.sourceStart)) }
            }
        case .video:
            break
        }
        return nil
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        autoscroll(at: p)
        guard let drag else { return }
        switch drag {
        case .scrub:
            studio.seek(to: time(p.x))
        case .trimClip(let id, let leftEdge, let original):
            guard var d = draft, let i = d.clips.firstIndex(where: { $0.id == id }), let media = d.media(original.mediaID) else { return }
            let starts = studio.project.clipStarts
            let clipStart = starts[i]
            let limit = media.kind == .image ? 3600 : media.duration
            if leftEdge {
                let newStart = snapped(time(p.x), excluding: id)
                let deltaSource = (newStart - clipStart) * original.speed
                let src = min(max(0, original.sourceStart + deltaSource), original.sourceStart + original.sourceDuration - 0.1)
                let clamped = media.kind == .image ? max(0, src) : src
                d.clips[i].sourceStart = media.kind == .image ? 0 : clamped
                d.clips[i].sourceDuration = original.sourceDuration - (clamped - original.sourceStart)
            } else {
                let end = snapped(time(p.x), excluding: id)
                let length = max(0.1, (end - clipStart) * original.speed)
                d.clips[i].sourceDuration = min(length, limit - original.sourceStart)
            }
            draft = d
            studio.seek(to: leftEdge ? clipStart : clipStart + d.clips[i].duration - 0.01)
            needsDisplay = true
        case .moveClip(let id, let from, let start, var active, _):
            if !active && hypot(p.x - start.x, p.y - start.y) > 4 { active = true }
            var target = from
            if active {
                let starts = project.clipStarts
                target = project.clips.indices.first { p.x < x(starts[$0]) + CGFloat(project.clips[$0].duration) * zoom / 2 } ?? project.clips.count
            }
            self.drag = .moveClip(id: id, from: from, start: start, active: active, target: target)
            needsDisplay = true
        case .item(let lane, let id, let mode, let startX, let original):
            guard var d = draft else { return }
            let delta = Double((p.x - startX) / zoom)
            var start = original.start, duration = original.duration, source = original.source
            switch mode {
            case .move:
                start = max(0, original.start + delta)
                let snappedStart = snapped(start, excluding: id)
                let snappedEnd = snapped(start + duration, excluding: id)
                if snappedStart != start { start = snappedStart } else if snappedEnd != start + duration { start = snappedEnd - duration }
            case .left:
                let end = original.start + original.duration
                start = min(end - 0.2, max(0, snapped(original.start + delta, excluding: id)))
                if lane == .music { source = max(0, original.source + (start - original.start)); start = original.start + (source - original.source) }
                duration = end - start
            case .right:
                duration = max(0.2, snapped(original.start + original.duration + delta, excluding: id) - original.start)
                if lane == .music, let m = d.music.first(where: { $0.id == id }), let media = d.media(m.mediaID) {
                    duration = min(duration, media.duration - source)
                }
            }
            switch lane {
            case .titles: if let i = d.titles.firstIndex(where: { $0.id == id }) { d.titles[i].start = start; d.titles[i].duration = duration }
            case .graphics: if let i = d.graphics.firstIndex(where: { $0.id == id }) { d.graphics[i].start = start; d.graphics[i].duration = duration }
            case .music:
                if let i = d.music.firstIndex(where: { $0.id == id }) { d.music[i].start = start; d.music[i].duration = duration; d.music[i].sourceStart = source }
            case .video: break
            }
            draft = d
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer {
            drag = nil
            draft = nil
            needsDisplay = true
        }
        guard let drag else { return }
        switch drag {
        case .scrub:
            break
        case .moveClip(_, let from, _, let active, let target):
            if active, target != from, target != from + 1 { studio.moveClip(from: from, to: target) }
        case .trimClip, .item:
            if let draft, draft != studio.project {
                studio.checkpoint()
                studio.project = draft
            }
        }
    }

    private func autoscroll(at p: CGPoint) {
        if p.x > bounds.width - 30 { scrollX += 12 } else if p.x < Self.header + 20 && scrollX > 0 { scrollX -= 12 }
        clampScroll()
        updatePlayhead()
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            let p = convert(e.locationInWindow, from: nil)
            zoom(by: exp((e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 4) * 0.01), around: p.x)
            return
        }
        let dx = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        scrollX -= dx * (e.hasPreciseScrollingDeltas ? 1 : 8)
        clampScroll()
        needsDisplay = true
        updatePlayhead()
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, around: convert(e.locationInWindow, from: nil).x)
    }

    private func zoom(by factor: CGFloat, around px: CGFloat) {
        let t = time(px)
        studio.timelineZoom = Double(min(600, max(4, zoom * factor)))
        scrollX = Self.header + CGFloat(t) * zoom - px
        clampScroll()
        needsDisplay = true
        updatePlayhead()
    }

    func zoomToFit() {
        let d = max(1, project.duration)
        studio.timelineZoom = Double(max(4, min(600, (bounds.width - Self.header - 60) / CGFloat(d))))
        scrollX = 0
        needsDisplay = true
        updatePlayhead()
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: Self.ruler), cursor: .pointingHand)
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        let t = time(p.x), lane = lane(at: p.y)
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Task { await studio.importAndPlace(urls, at: t, lane: lane) }
            return true
        }
        if let text = pb.string(forType: .string), let id = UUID(uuidString: text), let item = studio.project.media(id) {
            switch (item.kind, lane) {
            case (.audio, _): studio.addMusic(item, at: snapped(t, excluding: nil))
            case (.image, .graphics?): studio.addGraphic(item, at: snapped(t, excluding: nil))
            case (_, .graphics?) where item.kind == .image: studio.addGraphic(item, at: t)
            default:
                studio.checkpoint()
                let clip = Clip(mediaID: item.id, sourceDuration: item.kind == .image ? 3 : item.duration)
                studio.project.clips.insert(clip, at: studio.insertionIndex(at: t))
                studio.selection = .clip(clip.id)
            }
            return true
        }
        return false
    }
}
