import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import EaselKit

enum FlipTool: String, CaseIterable, Identifiable {
    case select, brush, eraser, line, rect, ellipse, fill, eyedropper, hand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Move & Transform"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Oval"
        case .fill: return "Paint Bucket"
        case .eyedropper: return "Color Picker"
        case .hand: return "Hand"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "arrow.up.and.down.and.arrow.left.and.right"
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .hand: return "hand.raised.fill"
        }
    }

    var key: Character {
        switch self {
        case .select: return "v"
        case .brush: return "b"
        case .eraser: return "e"
        case .line: return "n"
        case .rect: return "r"
        case .ellipse: return "o"
        case .fill: return "k"
        case .eyedropper: return "i"
        case .hand: return "h"
        }
    }

    var hint: String {
        switch self {
        case .select: return "Drag to move, corners to scale, the round handle to rotate. On a new frame this makes a motion tween."
        case .brush: return "Draw. Pen pressure changes thickness. ⇧ draws a straight line."
        case .eraser: return "Erase parts of strokes."
        case .line: return "Drag to draw a line. ⇧ snaps to 45°."
        case .rect: return "Drag a rectangle. ⇧ makes a square."
        case .ellipse: return "Drag an oval. ⇧ makes a circle."
        case .fill: return "Click inside a closed shape to fill it."
        case .eyedropper: return "Click to pick a color."
        case .hand: return "Drag to pan. Pinch to zoom."
        }
    }
}

extension UTType {
    static let flipProject = UTType(exportedAs: "app.easel.flip.project", conformingTo: .json)
}

@Observable @MainActor
final class FlipStudio {
    var doc = FlipDocument() {
        didSet { if doc != oldValue { isDirty = true } }
    }
    var frame = 0
    var layerID: UUID
    var tool: FlipTool = .brush
    var color = RGBA.black
    var fillColor = RGBA(r: 1, g: 0.75, b: 0.2)
    var shapeFill = false
    var brushSize: Double = 6
    var eraserSize: Double = 24
    var smoothing: Double = 0.5
    var onion = true
    var isPlaying = false
    var loop = true
    var documentURL: URL?
    var documentName = "Untitled"
    var isDirty = false
    var busyMessage: String?
    var toast: String?
    var showExport = false
    var showNewDocument = false
    var exportProgress: Double?
    var recentColors: [RGBA] = []
    var fitRequest = 0

    @ObservationIgnored let images = ImageStore()
    @ObservationIgnored private var timer: Timer?
    private(set) var undoStack: [FlipDocument] = []
    private(set) var redoStack: [FlipDocument] = []

    static let layerColors: [NSColor] = [.systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple, .systemTeal]

    init() {
        layerID = FlipDocument().layers[0].id
        layerID = doc.layers[0].id
    }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(doc)
        if undoStack.count > 150 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let d = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = d
        fixSelection()
    }

    func redo() {
        guard let d = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = d
        fixSelection()
    }

    private func fixSelection() {
        if !doc.layers.contains(where: { $0.id == layerID }) { layerID = doc.layers[0].id }
        frame = min(frame, doc.usedFrames - 1)
    }

    // MARK: Layers

    var layerIndex: Int { doc.layers.firstIndex { $0.id == layerID } ?? 0 }
    var layer: AnimLayer { doc.layers[layerIndex] }

    func addLayer(name: String? = nil) {
        checkpoint()
        let l = AnimLayer(name: name ?? "Layer \(doc.layers.count + 1)", colorIndex: doc.layers.count % Self.layerColors.count,
                          keyframes: [Keyframe(frame: 0)])
        doc.layers.insert(l, at: layerIndex)
        layerID = l.id
    }

    func deleteLayer() {
        guard doc.layers.count > 1 else { return flash("A scene needs at least one layer") }
        checkpoint()
        let i = layerIndex
        doc.layers.remove(at: i)
        layerID = doc.layers[min(i, doc.layers.count - 1)].id
    }

    func moveLayer(up: Bool) {
        let i = layerIndex, j = up ? i - 1 : i + 1
        guard doc.layers.indices.contains(j) else { return }
        checkpoint()
        doc.layers.swapAt(i, j)
    }

    func updateLayer(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout AnimLayer) -> Void) {
        guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&doc.layers[i])
    }

    // MARK: Keyframes

    func isKey(_ layer: AnimLayer, _ frame: Int) -> Bool { layer.keyframes.contains { $0.frame == frame } }

    /// F6: a keyframe here that starts as a copy of what is showing. F7: an empty one.
    func insertKeyframe(blank: Bool = false) {
        let l = layer
        guard !isKey(l, frame) else { return flash("There’s already a keyframe here") }
        checkpoint()
        var key = Keyframe(frame: frame)
        if !blank, let pose = l.pose(at: frame) {
            key.drawing = pose.drawing
            key.placement = pose.placement
        }
        updateLayer(l.id) {
            $0.keyframes.append(key)
            $0.sortKeys()
        }
        doc.frameCount = max(doc.frameCount, frame + 1)
    }

    func clearKeyframe() {
        let l = layer
        guard let i = l.keyframes.firstIndex(where: { $0.frame == frame }) else { return }
        guard l.keyframes.count > 1 else { return flash("A layer needs at least one keyframe") }
        checkpoint()
        updateLayer(l.id) { $0.keyframes.remove(at: i) }
    }

    /// The keyframe whose span contains the current frame.
    var activeKey: Keyframe? { layer.keyIndex(at: frame).map { layer.keyframes[$0] } }

    func setTween(_ on: Bool) {
        guard let i = layer.keyIndex(at: frame) else { return }
        checkpoint()
        updateLayer(layerID) { $0.keyframes[i].tween = on }
        if on, i + 1 >= layer.keyframes.count {
            flash("Add another keyframe later on, then move the object there")
        }
    }

    func setEase(_ ease: Ease) {
        guard let i = layer.keyIndex(at: frame) else { return }
        checkpoint()
        updateLayer(layerID) { $0.keyframes[i].ease = ease }
    }

    /// F5: pushes later keyframes on this layer back a frame.
    func insertFrame() {
        checkpoint()
        updateLayer(layerID) { l in
            for i in l.keyframes.indices where l.keyframes[i].frame > frame { l.keyframes[i].frame += 1 }
        }
        doc.frameCount += 1
    }

    /// ⇧F5: removes a frame, pulling later keyframes earlier.
    func removeFrame() {
        guard doc.frameCount > 1 else { return }
        checkpoint()
        updateLayer(layerID) { l in
            l.keyframes.removeAll { $0.frame == frame && $0.frame != 0 }
            for i in l.keyframes.indices where l.keyframes[i].frame > frame { l.keyframes[i].frame -= 1 }
        }
        doc.frameCount -= 1
        frame = min(frame, doc.frameCount - 1)
    }

    func moveKeyframe(layer: UUID, from: Int, to: Int) {
        guard from != to, to >= 0 else { return }
        guard let l = doc.layers.first(where: { $0.id == layer }), !isKey(l, to) else { return }
        checkpoint()
        updateLayer(layer) { l in
            if let i = l.keyframes.firstIndex(where: { $0.frame == from }) { l.keyframes[i].frame = to }
            l.sortKeys()
        }
        doc.frameCount = max(doc.frameCount, to + 1)
    }

    // MARK: Drawing

    private var canEdit: Bool {
        if layer.locked { flash("This layer is locked"); return false }
        if !layer.visible { flash("This layer is hidden"); return false }
        return true
    }

    /// Changes keyframe `i`'s drawing. Tween partners that were identical copies get the same change,
    /// so adding a detail to a moving object doesn't make it "pop" at the end of the tween.
    private func editDrawing(at i: Int, _ change: (inout Drawing) -> Void) {
        let keys = layer.keyframes
        let before = keys[i].drawing
        var after = before
        change(&after)
        var partners: [Int] = []
        if keys[i].tween, i + 1 < keys.count, keys[i + 1].drawing == before { partners.append(i + 1) }
        if i > 0, keys[i - 1].tween, keys[i - 1].drawing == before { partners.append(i - 1) }
        updateLayer(layerID) { l in
            l.keyframes[i].drawing = after
            for j in partners { l.keyframes[j].drawing = after }
        }
    }

    /// Converts document-space points into the active keyframe's own space (undoing its placement).
    func toLocal(_ points: [CGPoint]) -> (points: [CGPoint], scale: Double) {
        guard let pose = layer.pose(at: frame) else { return (points, 1) }
        let t = pose.placement.transform(pivot: pose.drawing.pivot(in: doc.size)).inverted()
        return (points.map { $0.applying(t) }, pose.placement.scale)
    }

    /// Adds a stroke drawn on screen (document coordinates) to whatever is showing on this layer.
    func addStroke(_ stroke: Stroke) {
        guard canEdit else { return }
        checkpoint()
        if layer.keyIndex(at: frame) == nil {
            updateLayer(layerID) { $0.keyframes.append(Keyframe(frame: frame)); $0.sortKeys() }
        }
        let local = toLocal(stroke.points)
        var s = stroke
        s.points = local.points
        s.width = stroke.width / max(0.01, local.scale)
        let i = layer.keyIndex(at: frame)!
        editDrawing(at: i) { $0.strokes.append(s) }
        if stroke.kind != .image { rememberColor(stroke.color) }
    }

    /// Cuts strokes where the eraser passed. Brush strokes split into pieces; shapes are removed whole.
    func erase(along path: [CGPoint], radius: Double) {
        guard canEdit, let i = layer.keyIndex(at: frame) else { return }
        let local = toLocal(path)
        let r = radius / max(0.01, local.scale)
        let eraser = local.points
        /// Distance from p to the eraser's path (all of it, not just the sampled points).
        func distance(_ p: CGPoint) -> CGFloat {
            guard eraser.count > 1 else { return eraser.first.map { hypot($0.x - p.x, $0.y - p.y) } ?? .greatestFiniteMagnitude }
            var best = CGFloat.greatestFiniteMagnitude
            for (a, b) in zip(eraser, eraser.dropFirst()) {
                let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
                let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
            }
            return best
        }
        var strokeWidth: CGFloat = 0
        func hit(_ p: CGPoint) -> Bool { distance(p) <= r + strokeWidth / 2 }
        var strokes: [Stroke] = []
        var changed = false
        for s in layer.keyframes[i].drawing.strokes {
            strokeWidth = s.width
            switch s.kind {
            case .brush:
                var piece = Stroke(kind: .brush, points: [], color: s.color, width: s.width)
                var pieces: [Stroke] = []
                for (k, p) in s.points.enumerated() {
                    if hit(p) {
                        changed = true
                        if piece.points.count > 1 { pieces.append(piece) }
                        piece = Stroke(kind: .brush, points: [], color: s.color, width: s.width)
                    } else {
                        piece.points.append(p)
                        if k < s.pressures.count { piece.pressures.append(s.pressures[k]) }
                    }
                }
                if piece.points.count > 1 { pieces.append(piece) }
                // An untouched stroke keeps its id and fill.
                if pieces.count == 1 && pieces[0].points.count == s.points.count { strokes.append(s) } else { strokes += pieces }
            case .line, .rect, .ellipse, .image:
                let hitShape = s.kind == .image ? eraser.contains { s.bounds.contains($0) } : sampled(s).contains(where: hit)
                if hitShape { changed = true } else { strokes.append(s) }
            }
        }
        guard changed else { return }
        checkpoint()
        editDrawing(at: i) { $0.strokes = strokes }
    }

    /// Points along a shape's outline, for hit testing.
    private func sampled(_ s: Stroke) -> [CGPoint] {
        guard s.points.count >= 2 else { return s.points }
        let a = s.points[0], b = s.points[s.points.count - 1]
        switch s.kind {
        case .line:
            return (0...40).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / 40, y: a.y + (b.y - a.y) * CGFloat($0) / 40) }
        case .rect:
            let corners = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
            var out: [CGPoint] = []
            for (p, q) in zip(corners, corners.dropFirst()) {
                for k in 0..<20 {
                    let t = CGFloat(k) / 20
                    out.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
                }
            }
            return out
        case .ellipse:
            let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            return (0..<80).map { CGPoint(x: c.x + rx * cos(CGFloat($0) / 80 * 2 * .pi), y: c.y + ry * sin(CGFloat($0) / 80 * 2 * .pi)) }
        default:
            return s.points
        }
    }

    /// Paint bucket: fills the topmost closed shape under the point.
    func fill(at point: CGPoint) {
        guard canEdit, let i = layer.keyIndex(at: frame) else { return }
        let p = toLocal([point]).points[0]
        let strokes = layer.keyframes[i].drawing.strokes
        guard let k = strokes.lastIndex(where: { s in
            guard s.isClosed, s.points.count >= 2 else { return false }
            switch s.kind {
            case .rect: return Geometry.rect(s.points[0], s.points[1]).contains(p)
            case .ellipse: return CGPath(ellipseIn: Geometry.rect(s.points[0], s.points[1]), transform: nil).contains(p)
            default: return FlipRenderer.smoothPath(s.points, closed: true).contains(p)
            }
        }) else { return flash("Click inside a closed shape") }
        checkpoint()
        let color = fillColor
        editDrawing(at: i) { $0.strokes[k].fill = color }
    }

    func pickColor(at point: CGPoint) {
        let img = FlipRenderer.image(doc, frame: frame, images: images)
        let p = CGPoint(x: point.x, y: doc.height - point.y)
        guard let c = ImageOps.color(in: img, at: p) else { return }
        color = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        rememberColor(color)
    }

    private func rememberColor(_ c: RGBA) {
        recentColors.removeAll { $0 == c }
        recentColors.insert(c, at: 0)
        if recentColors.count > 10 { recentColors.removeLast() }
    }

    /// Moves/scales/rotates what's on this layer. On a frame without a keyframe, makes one here and
    /// turns on a motion tween from the previous keyframe — Animate's "just move it" workflow.
    func setPlacement(_ p: Placement, checkpoint shouldCheckpoint: Bool = true) {
        guard canEdit else { return }
        if shouldCheckpoint { checkpoint() }
        if let i = layer.keyframes.firstIndex(where: { $0.frame == frame }) {
            updateLayer(layerID) { $0.keyframes[i].placement = p }
        } else if let pose = layer.pose(at: frame), let prev = layer.keyIndex(at: frame) {
            var key = Keyframe(frame: frame, drawing: pose.drawing, placement: p)
            key.ease = layer.keyframes[prev].ease
            updateLayer(layerID) {
                $0.keyframes[prev].tween = true
                $0.keyframes.append(key)
                $0.sortKeys()
            }
            flash("Motion tween created")
        }
    }

    var currentPlacement: Placement { layer.pose(at: frame)?.placement ?? Placement() }

    func clearFrame() {
        guard canEdit, let i = layer.keyIndex(at: frame) else { return }
        checkpoint()
        updateLayer(layerID) { $0.keyframes[i].drawing = Drawing() }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if frame >= doc.usedFrames - 1 { frame = 0 }
        isPlaying = true
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / Double(doc.fps), repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func advance() {
        if frame + 1 >= doc.usedFrames {
            if loop { frame = 0 } else { pause() }
        } else {
            frame += 1
        }
    }

    func go(to f: Int) { frame = max(0, min(f, doc.usedFrames + 200)) }
    func step(_ d: Int) {
        pause()
        let f = frame + d
        if f >= doc.usedFrames { doc.frameCount = f + 1 }
        go(to: f)
    }

    // MARK: Images

    static var mediaFolder: URL {
        let dir = AppLink.folder("Flip").appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Each image lands on its own new layer, centered and fitted.
    func importImages(_ urls: [URL]) {
        var added = 0
        for url in urls {
            guard let cg = Bitmap.load(url: url), let png = Bitmap.png(cg) else { continue }
            let copy = Self.mediaFolder.appendingPathComponent(UUID().uuidString + ".png")
            guard (try? png.write(to: copy)) != nil else { continue }
            let asset = ImageAsset(url: copy, size: CGSize(width: cg.width, height: cg.height))
            if added == 0 { checkpoint() }
            doc.images.append(asset)
            let fit = min(1, doc.width * 0.6 / asset.size.width, doc.height * 0.6 / asset.size.height)
            let w = asset.size.width * fit, h = asset.size.height * fit
            let origin = CGPoint(x: (doc.width - w) / 2, y: (doc.height - h) / 2)
            let stroke = Stroke(kind: .image, points: [origin, CGPoint(x: origin.x + w, y: origin.y + h)], imageID: asset.id)
            let l = AnimLayer(name: url.deletingPathExtension().lastPathComponent.prefix(20).description,
                              colorIndex: doc.layers.count % Self.layerColors.count,
                              keyframes: [Keyframe(frame: frame, drawing: Drawing(strokes: [stroke]))])
            doc.layers.insert(l, at: layerIndex)
            layerID = l.id
            added += 1
        }
        if added > 0 {
            tool = .select
            flash(urls.contains(where: { AppLink.isInInbox($0, of: .flip) }) ? "Added from Easel" : "Imported \(added) image\(added == 1 ? "" : "s")")
        } else {
            flash("Couldn’t import those files")
        }
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .flipProject]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "flip" }) { return openProject(project) }
        importImages(urls)
    }

    // MARK: Files

    func newDocument(width: Double, height: Double, fps: Int, transparent: Bool) {
        guard confirmDiscard() else { return }
        pause()
        var d = FlipDocument()
        d.width = width
        d.height = height
        d.fps = fps
        d.background = transparent ? nil : .white
        doc = d
        layerID = d.layers[0].id
        frame = 0
        undoStack.removeAll()
        redoStack.removeAll()
        documentURL = nil
        documentName = "Untitled"
        isDirty = false
        fitRequest += 1
    }

    func save(as saveAs: Bool = false) {
        var url = documentURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.flipProject]
            panel.nameFieldStringValue = documentName
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        guard let url else { return }
        do {
            try JSONEncoder().encode(doc).write(to: url, options: .atomic)
            documentURL = url
            documentName = url.deletingPathExtension().lastPathComponent
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            flash("Saved")
        } catch {
            flash("Couldn’t save: \(error.localizedDescription)")
        }
    }

    func openProject(_ url: URL) {
        guard confirmDiscard() else { return }
        do {
            let d = try JSONDecoder().decode(FlipDocument.self, from: Data(contentsOf: url))
            pause()
            doc = d
            layerID = d.layers[0].id
            frame = 0
            undoStack.removeAll()
            redoStack.removeAll()
            documentURL = url
            documentName = url.deletingPathExtension().lastPathComponent
            isDirty = false
            fitRequest += 1
        } catch {
            flash("Couldn’t open that animation")
        }
    }

    func confirmDiscard() -> Bool {
        guard isDirty, doc.layers.contains(where: { $0.keyframes.contains { !$0.drawing.strokes.isEmpty } }) else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentName)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !isDirty
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: Export

    func export(_ format: FlipExporter.Format) {
        pause()
        let doc = self.doc
        if format == .pngSequence {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            run(format, doc: doc, to: dir.appendingPathComponent(documentName, isDirectory: true)) { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).\(format.ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(format, doc: doc, to: url) { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func run(_ format: FlipExporter.Format, doc: FlipDocument, to url: URL, then done: @escaping @MainActor (URL) -> Void) {
        exportProgress = 0
        let images = self.images
        Task.detached(priority: .userInitiated) {
            do {
                try await FlipExporter.export(doc, images: images, format: format, to: url) { p in
                    Task { @MainActor in self.exportProgress = p }
                }
                await MainActor.run {
                    self.exportProgress = nil
                    self.flash("Exported \(url.lastPathComponent)")
                    done(url)
                }
            } catch {
                await MainActor.run {
                    self.exportProgress = nil
                    self.flash("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Renders the animation and adds it to Reel (keeping transparency when the background is clear).
    func sendToReel() {
        pause()
        let format: FlipExporter.Format = doc.background == nil ? .movAlpha : .mp4
        let url = AppLink.newInboxURL(for: .reel, named: documentName, ext: format.ext)
        run(format, doc: doc, to: url) { [weak self] url in
            if AppLink.open(url, in: .reel) { self?.flash("Sent to Reel") } else { self?.flash("Couldn’t find Reel. Build it with Scripts/build_app.sh") }
        }
    }

    // MARK: Messages

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}

enum Geometry {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

enum FlipExporter {
    enum Format: String, CaseIterable, Identifiable {
        case mp4 = "MP4 Video", movAlpha = "Transparent Video (HEVC)", gif = "Animated GIF", pngSequence = "PNG Sequence"
        var id: String { rawValue }
        var ext: String {
            switch self {
            case .mp4: return "mp4"
            case .movAlpha: return "mov"
            case .gif: return "gif"
            case .pngSequence: return ""
            }
        }
        var note: String {
            switch self {
            case .mp4: return "Plays everywhere. Transparent areas become white."
            case .movAlpha: return "Keeps transparency — drop it over other video in Reel or Final Cut."
            case .gif: return "Loops in chats and on the web."
            case .pngSequence: return "One transparent PNG per frame, for other apps."
            }
        }
    }

    static func export(_ doc: FlipDocument, images: ImageStore, format: Format, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let frames = doc.usedFrames
        switch format {
        case .pngSequence:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for f in 0..<frames {
                let img = FlipRenderer.image(doc, frame: f, images: images, background: doc.background != nil)
                try Bitmap.png(img)?.write(to: url.appendingPathComponent(String(format: "frame_%04d.png", f + 1)))
                progress(Double(f + 1) / Double(frames))
            }
        case .gif:
            try? FileManager.default.removeItem(at: url)
            let scale = min(1, 640 / max(doc.width, doc.height))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for f in 0..<frames {
                let img = FlipRenderer.image(doc, frame: f, images: images, scale: scale)
                CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(doc.fps)]] as CFDictionary)
                progress(Double(f + 1) / Double(frames))
            }
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        case .mp4, .movAlpha:
            try? FileManager.default.removeItem(at: url)
            let alpha = format == .movAlpha
            // Encoders want even dimensions.
            let w = Int(doc.width / 2) * 2, h = Int(doc.height / 2) * 2
            let writer = try AVAssetWriter(outputURL: url, fileType: alpha ? .mov : .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
                AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * doc.fps / 4],
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            var opaque = doc
            if !alpha && opaque.background == nil { opaque.background = .white }
            for f in 0..<frames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard let pool = adaptor.pixelBufferPool else { break }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { continue }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.translateBy(x: 0, y: CGFloat(h))
                    ctx.scaleBy(x: CGFloat(w) / doc.width, y: -CGFloat(h) / doc.height)
                    FlipRenderer.draw(opaque, frame: f, in: ctx, images: images)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(doc.fps)))
                progress(Double(f + 1) / Double(frames))
            }
            input.markAsFinished()
            await writer.finishWriting()
            if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
    }
}
