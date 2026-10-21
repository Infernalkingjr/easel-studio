import AppKit
import SwiftUI
import Observation

extension Notification.Name {
    static let toneFitTimeline = Notification.Name("ToneFitTimeline")
}

struct TracksView: NSViewRepresentable {
    let studio: ToneStudio
    func makeNSView(context: Context) -> TracksNSView { TracksNSView(studio: studio) }
    func updateNSView(_ nsView: TracksNSView, context: Context) {}
}

/// The multitrack editor: headers on the left, regions on a scrolling timeline.
final class TracksNSView: NSView {
    private let studio: ToneStudio
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var isTracking = false
    private var draft: Session?
    private let playhead = CALayer()

    static let header: CGFloat = 196
    static let ruler: CGFloat = 26
    static let rowHeight: CGFloat = 104
    static let rowGap: CGFloat = 2

    private enum Drag {
        case scrub
        case range(track: UUID, anchor: Double)
        case move(track: UUID, region: UUID, original: Region, grab: Double, startPoint: CGPoint, moved: Bool)
        case trim(track: UUID, region: UUID, original: Region, left: Bool)
        case fade(track: UUID, region: UUID, original: Region, fadeIn: Bool)
    }

    private var drag: Drag?

    private let bg = NSColor(srgbRed: 0.1, green: 0.105, blue: 0.12, alpha: 1)
    private let laneBG = NSColor(srgbRed: 0.135, green: 0.14, blue: 0.16, alpha: 1)
    private let headerBG = NSColor(srgbRed: 0.16, green: 0.165, blue: 0.19, alpha: 1)

    init(studio: ToneStudio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playhead.backgroundColor = NSColor.white.cgColor
        playhead.zPosition = 10
        layer?.addSublayer(playhead)
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(forName: .toneFitTimeline, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.fitTimeline() }
        }
        trackTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.studio.transport.isPlaying else { return }
                // Only the header meters need refreshing while playing.
                self.setNeedsDisplay(CGRect(x: 0, y: Self.ruler, width: Self.header, height: self.bounds.height))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var session: Session { draft ?? studio.session }
    private var zoom: CGFloat { CGFloat(studio.zoom) }

    func x(_ t: Double) -> CGFloat { Self.header + CGFloat(t) * zoom - scrollX }
    func time(_ x: CGFloat) -> Double { max(0, Double((x - Self.header + scrollX) / zoom)) }

    func rowRect(_ i: Int) -> CGRect {
        CGRect(x: 0, y: Self.ruler + CGFloat(i) * (Self.rowHeight + Self.rowGap) - scrollY, width: bounds.width, height: Self.rowHeight)
    }

    private func row(at y: CGFloat) -> Int? {
        guard y > Self.ruler else { return nil }
        let i = Int((y - Self.ruler + scrollY) / (Self.rowHeight + Self.rowGap))
        return session.tracks.indices.contains(i) ? i : nil
    }

    private func regionRect(_ r: Region, row: Int) -> CGRect {
        let rr = rowRect(row)
        return CGRect(x: x(r.start), y: rr.minY + 4, width: max(3, CGFloat(r.duration) * zoom), height: rr.height - 8)
    }

    private func clampScroll() {
        let contentW = CGFloat(max(session.duration, 30)) * zoom + 400
        scrollX = min(max(0, scrollX), max(0, contentW - (bounds.width - Self.header)))
        let contentH = CGFloat(session.tracks.count) * (Self.rowHeight + Self.rowGap) + 60
        scrollY = min(max(0, scrollY), max(0, contentH - (bounds.height - Self.ruler)))
    }

    // MARK: Playhead

    private func trackTime() {
        withObservationTracking {
            _ = studio.transport.time
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updatePlayhead()
                self?.trackTime()
            }
        }
        updatePlayhead()
    }

    private func updatePlayhead() {
        var px = x(studio.transport.time)
        if studio.transport.isPlaying, drag == nil, px > bounds.width - 40 {
            scrollX += px - Self.header - 60
            clampScroll()
            needsDisplay = true
            px = x(studio.transport.time)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playhead.backgroundColor = (studio.transport.isRecording ? NSColor.systemRed : NSColor.white).cgColor
        playhead.frame = CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height)
        playhead.isHidden = px < Self.header
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
            withObservationTracking { render(dirtyRect) } onChange: { [weak self] in
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
        _ = studio.zoom
        _ = studio.spectral
        let session = self.session
        bg.setFill()
        dirty.fill()

        ctx.saveGState()
        ctx.clip(to: CGRect(x: Self.header, y: Self.ruler, width: bounds.width - Self.header, height: bounds.height - Self.ruler))
        for (i, track) in session.tracks.enumerated() {
            let rr = rowRect(i)
            guard rr.maxY > Self.ruler, rr.minY < bounds.height else { continue }
            laneBG.setFill()
            CGRect(x: Self.header, y: rr.minY, width: bounds.width - Self.header, height: rr.height).fill()
            if let r = studio.range, r.track == track.id {
                NSColor.white.withAlphaComponent(0.13).setFill()
                CGRect(x: x(r.start), y: rr.minY, width: CGFloat(r.length) * zoom, height: rr.height).fill()
                NSColor.white.withAlphaComponent(0.5).setFill()
                CGRect(x: x(r.start), y: rr.minY, width: 1, height: rr.height).fill()
                CGRect(x: x(r.end), y: rr.minY, width: 1, height: rr.height).fill()
            }
            for region in track.regions {
                let rect = regionRect(region, row: i)
                guard rect.maxX > Self.header, rect.minX < bounds.width else { continue }
                drawRegion(region, track: track, rect: rect, ctx: ctx)
            }
        }
        ctx.restoreGState()

        drawRuler()
        drawHeaders(session)

        if session.duration == 0 {
            let text = NSAttributedString(string: "Drop audio here, press ⌘I to import, or hit R to record", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ])
            text.draw(at: CGPoint(x: Self.header + 24, y: rowRect(0).midY - 9))
        }
    }

    private func drawRuler() {
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.ruler).fill()
        let steps: [Double] = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * Double(zoom) >= 70 } ?? 300
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        NSColor.white.withAlphaComponent(0.2).setFill()
        var t = floor(time(Self.header) / step) * step
        while x(t) < bounds.width {
            let px = x(t)
            if px >= Self.header {
                CGRect(x: px, y: Self.ruler - 8, width: 1, height: 8).fill()
                NSAttributedString(string: Self.timecode(t, fine: step < 1), attributes: attrs).draw(at: CGPoint(x: px + 3, y: 5))
            }
            t += step
        }
    }

    static func timecode(_ t: Double, fine: Bool = true) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return fine ? String(format: "%d:%02d.%03d", m, s, Int((t - floor(t)) * 1000)) : String(format: "%d:%02d", m, s)
    }

    private func headerButtons(_ rr: CGRect) -> (mute: CGRect, solo: CGRect, arm: CGRect) {
        let y = rr.minY + 38, w: CGFloat = 26, h: CGFloat = 20
        return (CGRect(x: 14, y: y, width: w, height: h), CGRect(x: 44, y: y, width: w, height: h), CGRect(x: 74, y: y, width: w, height: h))
    }

    private func drawHeaders(_ session: Session) {
        let meters = studio.levels
        for (i, track) in session.tracks.enumerated() {
            let rr = rowRect(i)
            guard rr.maxY > Self.ruler, rr.minY < bounds.height else { continue }
            let hr = CGRect(x: 0, y: max(rr.minY, Self.ruler), width: Self.header - 1, height: rr.maxY - max(rr.minY, Self.ruler))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: hr).addClip()
            let selected = studio.selectedTrack?.id == track.id
            (selected ? headerBG.blended(withFraction: 0.25, of: .white)! : headerBG).setFill()
            CGRect(x: 0, y: rr.minY, width: Self.header - 1, height: rr.height).fill()
            ToneStudio.colors[track.colorIndex % ToneStudio.colors.count].setFill()
            CGRect(x: 0, y: rr.minY, width: 5, height: rr.height).fill()
            NSAttributedString(string: track.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
            ]).draw(with: CGRect(x: 14, y: rr.minY + 12, width: Self.header - 30, height: 18), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

            let b = headerButtons(rr)
            for (rect, label, on, color) in [(b.mute, "M", track.muted, NSColor.systemOrange), (b.solo, "S", track.solo, NSColor.systemYellow),
                                             (b.arm, "R", track.armed, NSColor.systemRed)] {
                (on ? color : NSColor.white.withAlphaComponent(0.1)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                let a = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                                       .foregroundColor: on ? NSColor.black : NSColor.white.withAlphaComponent(0.75)])
                a.draw(at: CGPoint(x: rect.midX - a.size().width / 2, y: rect.midY - a.size().height / 2))
            }
            let vol = NSAttributedString(string: String(format: "%+.1f dB   %@", track.volumeDB, track.pan == 0 ? "C" : (track.pan < 0 ? "L\(Int(-track.pan * 100))" : "R\(Int(track.pan * 100))")),
                                         attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                      .foregroundColor: NSColor.white.withAlphaComponent(0.5)])
            vol.draw(at: CGPoint(x: 112, y: rr.minY + 41))

            // Level meter
            let level = CGFloat(min(1, meters[track.id] ?? 0))
            let meter = CGRect(x: 14, y: rr.minY + 72, width: Self.header - 30, height: 6)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: meter, xRadius: 3, yRadius: 3).fill()
            let db = max(-60, 20 * log10(max(level, 1e-6)))
            let fill = meter.width * CGFloat((db + 60) / 60)
            (level > 0.98 ? NSColor.systemRed : (db > -9 ? NSColor.systemYellow : NSColor.systemGreen)).setFill()
            NSBezierPath(roundedRect: CGRect(x: meter.minX, y: meter.minY, width: max(0, fill), height: meter.height), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.black.withAlphaComponent(0.5).setFill()
        CGRect(x: Self.header - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    private func drawRegion(_ region: Region, track: Track, rect: CGRect, ctx: CGContext) {
        let color = ToneStudio.colors[track.colorIndex % ToneStudio.colors.count]
        let selected: Bool = {
            if case .region(_, let id)? = studio.selection { return id == region.id }
            return false
        }()
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        color.withAlphaComponent(region.muted ? 0.12 : 0.28).setFill()
        rect.fill()

        let body = CGRect(x: rect.minX, y: rect.minY + 16, width: rect.width, height: rect.height - 16)
        if studio.spectral {
            if let image = studio.spectrum(for: region, width: Int(rect.width), height: 128) {
                ctx.saveGState()
                ctx.translateBy(x: body.minX, y: body.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: body.width, height: body.height))
                ctx.restoreGState()
            }
        } else if let asset = studio.session.asset(region.assetID), let peaks = studio.peaks(for: asset) {
            drawWave(peaks, region: region, in: body, color: color.blended(withFraction: 0.35, of: .white) ?? color)
        }

        // Fades
        for (fade, leading) in [(region.fadeIn, true), (region.fadeOut, false)] where fade > 0 {
            let w = CGFloat(fade) * zoom
            let path = NSBezierPath()
            let x0 = leading ? rect.minX : rect.maxX, dir: CGFloat = leading ? 1 : -1
            path.move(to: CGPoint(x: x0, y: rect.minY))
            for k in 0...20 {
                let p = CGFloat(k) / 20
                path.line(to: CGPoint(x: x0 + dir * w * p, y: rect.maxY - (rect.height) * sin(p * .pi / 2)))
            }
            path.line(to: CGPoint(x: x0 + dir * w, y: rect.minY))
            path.close()
            NSColor.black.withAlphaComponent(0.35).setFill()
            path.fill()
        }

        NSColor.black.withAlphaComponent(0.35).setFill()
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 16).fill()
        var label = studio.session.asset(region.assetID)?.name ?? "Audio"
        if region.gainDB != 0 { label += String(format: "  %+.1f dB", region.gainDB) }
        if region.muted { label += "  (muted)" }
        NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white])
            .draw(with: CGRect(x: max(rect.minX, Self.header) + 6, y: rect.minY + 1.5, width: max(0, rect.width - 12), height: 14),
                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()

        (selected ? NSColor.white : color.withAlphaComponent(0.8)).setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
        if selected {
            // Fade handles
            NSColor.white.setFill()
            for hx in [rect.minX + CGFloat(region.fadeIn) * zoom, rect.maxX - CGFloat(region.fadeOut) * zoom] {
                NSBezierPath(ovalIn: CGRect(x: hx - 5, y: rect.minY + 3, width: 10, height: 10)).fill()
            }
        }
    }

    private func drawWave(_ peaks: [Float], region: Region, in r: CGRect, color: NSColor) {
        let rate = 200.0
        let gain = Double(pow(10, region.gainDB / 20))
        let path = NSBezierPath()
        let x0 = max(r.minX, Self.header), x1 = min(r.maxX, bounds.width)
        guard x1 > x0 else { return }
        var px = x0
        let perPixel = max(1, Int(rate / Double(zoom)))
        while px < x1 {
            let t = region.offset + Double((px - r.minX) / zoom)
            let i = Int(t * rate)
            var peak: Float = 0
            if i >= 0 && i < peaks.count {
                for k in i..<min(peaks.count, i + perPixel) { peak = max(peak, peaks[k]) }
            }
            let h = max(0.5, CGFloat(min(1, Double(peak) * gain)) * (r.height / 2 - 2))
            path.appendRect(CGRect(x: px, y: r.midY - h, width: 1, height: h * 2))
            px += 1
        }
        color.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.15).setFill()
        CGRect(x: r.minX, y: r.midY, width: r.width, height: 0.5).fill()
    }

    // MARK: Mouse

    private func snapped(_ t: Double, excluding id: UUID?) -> Double {
        var points = [studio.transport.time, 0]
        for track in session.tracks { for r in track.regions where r.id != id { points += [r.start, r.end] } }
        let threshold = Double(8 / zoom)
        return points.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) < threshold ? $0 : nil } ?? t
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if p.y < Self.ruler {
            drag = .scrub
            studio.seek(to: time(p.x))
            return
        }
        guard let i = row(at: p.y) else { studio.selection = nil; studio.range = nil; return }
        let track = session.tracks[i]

        if p.x < Self.header {
            let b = headerButtons(rowRect(i))
            if b.mute.contains(p) { studio.updateTrack(track.id, checkpoint: true) { $0.muted.toggle() } }
            else if b.solo.contains(p) { studio.updateTrack(track.id, checkpoint: true) { $0.solo.toggle() } }
            else if b.arm.contains(p) {
                // Only one armed track at a time keeps recording simple.
                studio.checkpoint()
                let arm = !track.armed
                for t in studio.session.tracks { studio.updateTrack(t.id) { $0.armed = arm && $0.id == track.id } }
            }
            studio.selection = .track(track.id)
            return
        }

        // ⌥-drag selects a range even on top of a clip.
        if !e.modifierFlags.contains(.option),
           let region = track.regions.last(where: { regionRect($0, row: i).insetBy(dx: -2, dy: 0).contains(p) }) {
            let rect = regionRect(region, row: i)
            studio.selection = .region(track: track.id, region: region.id)
            draft = studio.session
            let fadeInX = rect.minX + CGFloat(region.fadeIn) * zoom, fadeOutX = rect.maxX - CGFloat(region.fadeOut) * zoom
            if p.y < rect.minY + 16 && abs(p.x - fadeInX) < 8 {
                drag = .fade(track: track.id, region: region.id, original: region, fadeIn: true)
            } else if p.y < rect.minY + 16 && abs(p.x - fadeOutX) < 8 {
                drag = .fade(track: track.id, region: region.id, original: region, fadeIn: false)
            } else if p.x - rect.minX < 6 {
                drag = .trim(track: track.id, region: region.id, original: region, left: true)
            } else if rect.maxX - p.x < 6 {
                drag = .trim(track: track.id, region: region.id, original: region, left: false)
            } else {
                drag = .move(track: track.id, region: region.id, original: region, grab: time(p.x) - region.start, startPoint: p, moved: false)
            }
            if e.clickCount == 2 { studio.seek(to: region.start) }
            return
        }

        studio.selection = .track(track.id)
        studio.range = nil
        drag = .range(track: track.id, anchor: time(p.x))
        studio.seek(to: snapped(time(p.x), excluding: nil))
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.x > bounds.width - 30 { scrollX += 10; clampScroll() } else if p.x < Self.header + 10 && scrollX > 0 { scrollX -= 10; clampScroll() }
        guard let drag else { return }
        switch drag {
        case .scrub:
            studio.seek(to: time(p.x))
        case .range(let track, let anchor):
            let t = snapped(time(p.x), excluding: nil)
            studio.range = abs(t - anchor) > 0.01 ? TimeRange(track: track, start: min(anchor, t), end: max(anchor, t)) : nil
            needsDisplay = true
        case .move(let trackID, let regionID, let original, let grab, let start, var moved):
            if !moved && hypot(p.x - start.x, p.y - start.y) < 3 { return }
            moved = true
            self.drag = .move(track: trackID, region: regionID, original: original, grab: grab, startPoint: start, moved: true)
            guard var d = studio.session as Session? else { return }
            var newStart = max(0, time(p.x) - grab)
            let s1 = snapped(newStart, excluding: regionID), s2 = snapped(newStart + original.duration, excluding: regionID)
            if s1 != newStart { newStart = s1 } else if s2 != newStart + original.duration { newStart = s2 - original.duration }
            var moving = original
            moving.start = newStart
            let target = row(at: p.y) ?? d.tracks.firstIndex { $0.id == trackID } ?? 0
            for i in d.tracks.indices { d.tracks[i].regions.removeAll { $0.id == regionID } }
            d.tracks[target].regions.append(moving)
            draft = d
            needsDisplay = true
        case .trim(let trackID, let regionID, let original, let left):
            guard var d = draft, let ti = d.tracks.firstIndex(where: { $0.id == trackID }),
                  let ri = d.tracks[ti].regions.firstIndex(where: { $0.id == regionID }),
                  let asset = d.asset(original.assetID) else { return }
            var r = original
            if left {
                let newStart = min(original.end - 0.02, max(original.start - original.offset, snapped(time(p.x), excluding: regionID)))
                r.offset = original.offset + (newStart - original.start)
                r.start = newStart
                r.duration = original.end - newStart
            } else {
                let newEnd = max(original.start + 0.02, min(original.start + asset.duration - original.offset, snapped(time(p.x), excluding: regionID)))
                r.duration = newEnd - original.start
            }
            r.fadeIn = min(r.fadeIn, r.duration / 2)
            r.fadeOut = min(r.fadeOut, r.duration / 2)
            d.tracks[ti].regions[ri] = r
            draft = d
            needsDisplay = true
        case .fade(let trackID, let regionID, let original, let fadeIn):
            guard var d = draft, let ti = d.tracks.firstIndex(where: { $0.id == trackID }),
                  let ri = d.tracks[ti].regions.firstIndex(where: { $0.id == regionID }) else { return }
            let t = time(p.x)
            if fadeIn {
                d.tracks[ti].regions[ri].fadeIn = min(original.duration - original.fadeOut, max(0, t - original.start))
            } else {
                d.tracks[ti].regions[ri].fadeOut = min(original.duration - original.fadeIn, max(0, original.end - t))
            }
            draft = d
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil; draft = nil; needsDisplay = true }
        guard let drag else { return }
        switch drag {
        case .move(_, let regionID, _, _, _, let moved):
            guard moved, let draft else { return }
            studio.checkpoint()
            studio.session = draft
            if let t = draft.tracks.first(where: { $0.regions.contains { $0.id == regionID } }) {
                studio.selection = .region(track: t.id, region: regionID)
            }
        case .trim, .fade:
            if let draft, draft != studio.session {
                studio.checkpoint()
                studio.session = draft
            }
        case .range:
            studio.selectClipUnderRange()
        default:
            break
        }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            zoom(by: exp((e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 4) * 0.01), around: convert(e.locationInWindow, from: nil).x)
            return
        }
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 8
        if e.modifierFlags.contains(.shift) {
            scrollX -= e.scrollingDeltaY * k
        } else {
            scrollX -= e.scrollingDeltaX * k
            scrollY -= e.scrollingDeltaY * k
        }
        clampScroll()
        needsDisplay = true
        updatePlayhead()
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, around: convert(e.locationInWindow, from: nil).x)
    }

    /// Zooms so the whole session fits the visible width.
    private func fitTimeline() {
        studio.zoom = Double(min(4000, max(2, (bounds.width - Self.header - 40) / CGFloat(max(1, session.duration)))))
        scrollX = 0
        needsDisplay = true
        updatePlayhead()
    }

    private func zoom(by factor: CGFloat, around px: CGFloat) {
        let t = time(px)
        studio.zoom = Double(min(4000, max(2, zoom * factor)))
        scrollX = Self.header + CGFloat(t) * zoom - px
        clampScroll()
        needsDisplay = true
        updatePlayhead()
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let track = row(at: p.y).map { session.tracks[$0].id }
        let t = p.x > Self.header ? time(p.x) : 0
        Task { await studio.importFiles(urls, track: track, at: t) }
        return true
    }
}
