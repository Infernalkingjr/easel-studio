import EaselKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Viewport state lives apart from the document so panning/zooming never invalidates the side panels.
@Observable @MainActor
final class Viewport {
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero
    var viewSize: CGSize = .zero
    var cursor: CGPoint?

    static let zoomLevels: [CGFloat] = [0.05, 0.1, 0.167, 0.25, 0.333, 0.5, 0.667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]
}

/// Renders the active layer while a tool is mid-gesture. Receives the context, the layer's
/// current image and the full canvas rect.
typealias LayerRenderer = (CGContext, CGImage, CGRect) -> Void

struct TextRequest: Identifiable {
    let id = UUID()
    var point: CGPoint
    var layerID: UUID?
    var string = ""
}

struct Snapshot {
    var canvasSize: CGSize
    var layers: [Layer]
    var activeLayerID: UUID?
    var selection: CGRect?
}

/// Flattened export formats, all written by ImageIO. Layered work is saved as `.easel` instead.
enum ExportFormat: String, CaseIterable, Identifiable {
    case png = "PNG", jpeg = "JPEG", heic = "HEIC", avif = "AVIF", webSafeGIF = "GIF"
    case tiff = "TIFF", psd = "PSD", pdf = "PDF", bmp = "BMP", tga = "TGA", jpeg2000 = "JPEG 2000", exr = "OpenEXR"
    case ico = "ICO", icns = "ICNS"

    var id: String { rawValue }

    var identifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .webSafeGIF: return "com.compuserve.gif"
        case .tiff: return "public.tiff"
        case .psd: return "com.adobe.photoshop-image"
        case .pdf: return "com.adobe.pdf"
        case .bmp: return "com.microsoft.bmp"
        case .tga: return "com.truevision.tga-image"
        case .jpeg2000: return "public.jpeg-2000"
        case .exr: return "com.ilm.openexr-image"
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        }
    }

    var type: UTType { UTType(identifier) ?? .image }

    var group: String {
        switch self {
        case .png, .jpeg, .heic, .avif, .webSafeGIF: return "Everyday"
        case .tiff, .psd, .pdf, .bmp, .tga, .jpeg2000, .exr: return "Pro & Print"
        case .ico, .icns: return "Icons"
        }
    }

    var note: String {
        switch self {
        case .png: return "Lossless, keeps transparency. Best for graphics and screenshots."
        case .jpeg: return "Small files for photos. No transparency."
        case .heic: return "Apple’s photo format — about half the size of JPEG."
        case .avif: return "Modern web format with excellent compression and transparency."
        case .webSafeGIF: return "Works everywhere, but limited to 256 colors."
        case .tiff: return "Lossless, for printing and archiving."
        case .psd: return "Opens in Photoshop (flattened — save as Easel to keep layers)."
        case .pdf: return "One-page PDF, handy for sharing and printing."
        case .bmp: return "Uncompressed Windows bitmap."
        case .tga: return "Used by games and 3D apps."
        case .jpeg2000: return "High-quality compression, used in archiving and cinema."
        case .exr: return "High dynamic range for VFX and 3D."
        case .ico: return "Windows/website icon, scaled to fit 256 × 256."
        case .icns: return "macOS app icon, scaled to fit 1024 × 1024."
        }
    }

    var supportsQuality: Bool { [.jpeg, .heic, .avif, .jpeg2000].contains(self) }
    var supportsAlpha: Bool { ![.jpeg, .bmp].contains(self) }

    /// Icon formats need a square image of a fixed size.
    var fixedSide: CGFloat? {
        switch self {
        case .ico: return 256
        case .icns: return 1024
        default: return nil
        }
    }
}

enum NewBackground: String, CaseIterable, Identifiable {
    case white = "White", transparent = "Transparent", black = "Black", color = "Color"
    var id: String { rawValue }
}

@Observable @MainActor
final class Editor {
    // MARK: Document
    var hasDocument = false
    var documentName = "Untitled"
    var documentURL: URL?
    /// Set when Reel asked us to edit this image; ⌘S writes the result straight back to it.
    var linkedURL: URL?
    var canvasSize = CGSize(width: 1920, height: 1080)
    var layers: [Layer] = []
    var activeLayerID: UUID? {
        didSet { if oldValue != activeLayerID { cancelAdjustments() } }
    }
    var selection: CGRect?
    var isDirty = false

    // MARK: Tools
    var tool: Tool = .brush {
        didSet { if oldValue == .crop, tool != .crop { cropRect = nil } }
    }
    var primaryColor: Color = .black
    var secondaryColor: Color = .white
    var recentColors: [Color] = []
    var brushSize: Double = 24
    var brushOpacity: Double = 1
    var eraserSize: Double = 40
    var fillTolerance: Double = 15
    var shapeKind: ShapeKind = .rectangle
    var shapeFilled = false
    var shapeLineWidth: Double = 8
    var cropAspect: CropAspect = .free
    var cropRect: CGRect?
    var textFont = "Helvetica Neue"
    var textSize: Double = 96
    var textBold = true
    var pendingText: TextRequest?
    var brushHardness: Double = 1
    var usePressure = true

    // MARK: Adjustments
    var adjustments = Adjustments() { didSet { if adjustments != oldValue { schedulePreview() } } }
    private(set) var previewImage: CGImage?
    private(set) var previewLayerID: UUID?
    private var previewInFlight = false

    // MARK: UI state
    var effectThumbnails: [String: NSImage] = [:]
    private var thumbnailsKey: Int?
    var busyMessage: String?
    var toast: String?
    var showNewSheet = false
    var showResizeSheet = false
    var showCanvasSheet = false
    var showExportSheet = false
    var showLayerResizeSheet = false
    var renamingLayerID: UUID?

    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []
    private let undoLimit = 60

    let viewport = Viewport()

    // MARK: Derived

    var activeIndex: Int? { layers.firstIndex { $0.id == activeLayerID } }
    var activeLayer: Layer? { activeIndex.map { layers[$0] } }
    var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var primaryCG: CGColor { Self.cg(primaryColor) }
    var secondaryCG: CGColor { Self.cg(secondaryColor) }

    static func cg(_ color: Color) -> CGColor {
        (NSColor(color).usingColorSpace(.sRGB) ?? .black).cgColor
    }

    // MARK: Undo

    private var snapshot: Snapshot {
        Snapshot(canvasSize: canvasSize, layers: layers, activeLayerID: activeLayerID, selection: selection)
    }

    private func restore(_ s: Snapshot) {
        canvasSize = s.canvasSize
        layers = s.layers
        activeLayerID = s.activeLayerID ?? layers.last?.id
        selection = s.selection
        cropRect = nil
    }

    /// Call before every document mutation.
    func checkpoint() {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(s)
    }

    // MARK: Documents

    func confirmDiscard() -> Bool {
        guard hasDocument, isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Saves the layered project. Returns false if the user cancelled or saving failed.
    @discardableResult
    func save() -> Bool {
        if let linkedURL { return saveBackToReel(linkedURL) }
        guard let url = documentURL else { return saveAs() }
        return write(to: url)
    }

    /// Writes the flattened image over the file Reel handed us; Reel notices and updates the clip.
    private func saveBackToReel(_ url: URL) -> Bool {
        guard let data = exportData(format: .png, quality: 1, scale: 1) else { flash("Couldn’t save"); return false }
        do {
            try data.write(to: url, options: .atomic)
            isDirty = false
            flash("Updated in Reel")
            return true
        } catch {
            flash("Couldn’t save: \(error.localizedDescription)")
            return false
        }
    }

    /// Sends the flattened image (with transparency) to Reel as a new clip or graphic.
    func sendToReel() { send(to: .reel) }

    /// Sends the flattened image (with transparency) to another Easel Studio app.
    func send(to app: AppLink.App) {
        guard hasDocument, let data = exportData(format: .png, quality: 1, scale: 1) else { return }
        let url = AppLink.newInboxURL(for: app, named: documentName, ext: "png")
        do {
            try data.write(to: url)
        } catch {
            return flash("Couldn’t send: \(error.localizedDescription)")
        }
        if AppLink.open(url, in: app) {
            flash("Sent to \(app.rawValue)")
        } else {
            flash("Couldn’t find \(app.rawValue). Build it with Scripts/build_app.sh")
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.easelProject]
        panel.nameFieldStringValue = documentName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            let file = try ProjectFile(canvasSize: canvasSize, layers: layers, activeIndex: activeIndex ?? 0)
            try file.write(to: url)
            documentURL = url
            documentName = url.deletingPathExtension().lastPathComponent
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            flash("Saved")
            return true
        } catch {
            flash("Couldn’t save: \(error.localizedDescription)")
            return false
        }
    }

    func newDocument(size: CGSize, background: NewBackground, color: Color = .white) {
        let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        let bg: CGImage
        switch background {
        case .white: bg = Bitmap.filled(size, color: .white)
        case .black: bg = Bitmap.filled(size, color: .black)
        case .transparent: bg = Bitmap.blank(size)
        case .color: bg = Bitmap.filled(size, color: Self.cg(color))
        }
        load(layers: [Layer(name: "Background", image: bg)], size: size, name: "Untitled", url: nil)
    }

    func open(image: CGImage, name: String) {
        let size = CGSize(width: image.width, height: image.height)
        load(layers: [Layer(name: "Background", image: normalized(image, size: size))], size: size, name: name, url: nil)
    }

    private func load(layers: [Layer], size: CGSize, name: String, url: URL?, activeIndex: Int? = nil) {
        cancelAdjustments()
        canvasSize = size
        self.layers = layers
        activeLayerID = activeIndex.flatMap { layers.indices.contains($0) ? layers[$0].id : nil } ?? layers.last?.id
        selection = nil
        cropRect = nil
        undoStack.removeAll()
        redoStack.removeAll()
        documentName = name
        documentURL = url
        linkedURL = nil
        hasDocument = true
        isDirty = false
        zoomToFit()
    }

    func closeDocument() {
        guard confirmDiscard() else { return }
        hasDocument = false
        documentURL = nil
        layers = []
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false
    }

    func openPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.easelProject, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    func openFile(_ url: URL) {
        if url.pathExtension.lowercased() == "easel" {
            do {
                let file = try ProjectFile.read(from: url)
                load(layers: try file.makeLayers(), size: CGSize(width: file.width, height: file.height),
                     name: url.deletingPathExtension().lastPathComponent, url: url, activeIndex: file.activeIndex)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                flash("Couldn’t open that project.")
            }
            return
        }
        guard let img = Bitmap.load(url: url) else { return flash("Couldn’t open that file.") }
        open(image: img, name: url.deletingPathExtension().lastPathComponent)
        if AppLink.isRoundTrip(url) {
            linkedURL = url
        } else {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    func placePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { placeFile(url) }
    }

    /// Opens a file as a document, or adds it as a layer if one is already open.
    func placeFile(_ url: URL) {
        guard let img = Bitmap.load(url: url) else { return flash("Couldn’t open that file.") }
        if hasDocument {
            addImageLayer(img, name: url.deletingPathExtension().lastPathComponent)
        } else {
            open(image: img, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Draws `image` centered (or at `origin`) onto a canvas-sized bitmap.
    private func normalized(_ image: CGImage, size: CGSize, origin: CGPoint? = nil) -> CGImage {
        Bitmap.render(size) { ctx in
            let o = origin ?? CGPoint(x: ((size.width - CGFloat(image.width)) / 2).rounded(),
                                      y: ((size.height - CGFloat(image.height)) / 2).rounded())
            ctx.draw(image, in: CGRect(origin: o, size: CGSize(width: image.width, height: image.height)))
        }
    }

    // MARK: Layers

    func addImageLayer(_ image: CGImage, name: String, origin: CGPoint? = nil) {
        var image = image
        // Scale down images that are much bigger than the canvas so they're immediately usable.
        let scale = min(1, canvasSize.width / CGFloat(image.width), canvasSize.height / CGFloat(image.height))
        if scale < 1, origin == nil {
            image = ImageOps.downscaled(image, maxSide: CGFloat(max(image.width, image.height)) * scale)
        }
        insertLayer(Layer(name: name, image: normalized(image, size: canvasSize, origin: origin)))
    }

    func addEmptyLayer() {
        insertLayer(Layer(name: "Layer \(layers.count + 1)", image: Bitmap.blank(canvasSize)))
    }

    private func insertLayer(_ layer: Layer) {
        checkpoint()
        let at = activeIndex.map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: at)
        activeLayerID = layer.id
    }

    func duplicateLayer() {
        guard let l = activeLayer else { return }
        var copy = Layer(name: l.name + " copy", image: l.image)
        copy.opacity = l.opacity
        copy.blendMode = l.blendMode
        copy.text = l.text
        insertLayer(copy)
    }

    func deleteLayer(_ id: UUID? = nil) {
        guard let id = id ?? activeLayerID, let i = layers.firstIndex(where: { $0.id == id }) else { return }
        if layers.count == 1 {
            checkpoint()
            layers[0].image = Bitmap.blank(canvasSize)
            return
        }
        checkpoint()
        layers.remove(at: i)
        if activeLayerID == id { activeLayerID = layers[max(0, i - 1)].id }
    }

    func moveLayer(_ delta: Int) {
        guard let i = activeIndex else { return }
        let j = i + delta
        guard layers.indices.contains(j) else { return }
        checkpoint()
        layers.swapAt(i, j)
    }

    /// Reorder using top-first display indices from the layers list.
    func moveLayers(fromDisplay source: IndexSet, toDisplay destination: Int) {
        checkpoint()
        var display = Array(layers.reversed())
        display.move(fromOffsets: source, toOffset: destination)
        layers = display.reversed()
    }

    func mergeDown() {
        guard let i = activeIndex, i > 0 else { return }
        checkpoint()
        let below = layers[i - 1], top = layers[i]
        let merged = Bitmap.render(canvasSize) { ctx in
            ctx.setAlpha(below.opacity)
            if below.isVisible { ctx.draw(below.image, in: canvasRect) }
            ctx.setAlpha(1)
            Self.draw([top], in: ctx, rect: canvasRect)
        }
        layers[i - 1].image = merged
        layers[i - 1].opacity = 1
        layers.remove(at: i)
        activeLayerID = layers[i - 1].id
    }

    func flatten() {
        guard layers.count > 1 else { return }
        let flat = composite()
        checkpoint()
        let layer = Layer(name: "Background", image: flat)
        layers = [layer]
        activeLayerID = layer.id
    }

    func updateLayer(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout Layer) -> Void) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&layers[i])
        isDirty = true
    }

    // MARK: Compositing

    static func draw(_ layers: [Layer], in ctx: CGContext, rect: CGRect) {
        for layer in layers where layer.isVisible {
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.setBlendMode(layer.blendMode.cg)
            ctx.draw(layer.image, in: rect)
            ctx.restoreGState()
        }
    }

    func composite(background: CGColor? = nil) -> CGImage {
        Bitmap.render(canvasSize) { ctx in
            if let background {
                ctx.setFillColor(background)
                ctx.fill(canvasRect)
            }
            Self.draw(layers, in: ctx, rect: canvasRect)
        }
    }

    // MARK: Painting

    /// Replaces the active layer with the output of `renderer`, which receives the current image.
    /// Pass `moving` when the renderer only translates the layer, so text stays editable.
    func commitActive(moving: CGPoint? = nil, _ renderer: LayerRenderer) {
        guard let i = activeIndex else { return }
        if !layers[i].isVisible { flash("This layer is hidden.") }
        checkpoint()
        let src = layers[i].image, text = layers[i].text
        layers[i].image = Bitmap.render(canvasSize) { ctx in renderer(ctx, src, canvasRect) }
        if let moving, selection == nil { layers[i].text = text?.offsetBy(moving) }
    }

    func clipToSelection(_ ctx: CGContext) {
        if let selection { ctx.clip(to: selection) }
    }

    func floodFill(at point: CGPoint) {
        guard let layer = activeLayer, canvasRect.contains(point) else { return }
        if let selection, !selection.contains(point) { return }
        guard let mask = ImageOps.floodMask(layer.image, at: point, tolerance: fillTolerance) else { return }
        let color = primaryCG.copy(alpha: brushOpacity) ?? primaryCG
        let sel = selection
        rememberColor()
        commitActive { ctx, img, rect in
            ctx.draw(img, in: rect)
            if let sel { ctx.clip(to: sel) }
            ctx.clip(to: rect, mask: mask)
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
    }

    func fillSelection(secondary: Bool = false) {
        guard activeLayer != nil else { return }
        let color = secondary ? secondaryCG : primaryCG
        let area = selection ?? canvasRect
        commitActive { ctx, img, rect in
            ctx.draw(img, in: rect)
            ctx.setFillColor(color)
            ctx.fill(area)
        }
    }

    func clearSelection() {
        guard activeLayer != nil else { return }
        let area = selection ?? canvasRect
        commitActive { ctx, img, rect in
            ctx.draw(img, in: rect)
            ctx.clear(area)
        }
    }

    func pickColor(at point: CGPoint) {
        guard let c = ImageOps.color(in: composite(), at: point) else { return }
        primaryColor = Color(nsColor: c)
        rememberColor()
    }

    func rememberColor() {
        let c = primaryColor
        recentColors.removeAll { Self.cg($0) == Self.cg(c) }
        recentColors.insert(c, at: 0)
        if recentColors.count > 8 { recentColors.removeLast() }
    }

    func swapColors() { swap(&primaryColor, &secondaryColor) }
    func resetColors() { primaryColor = .black; secondaryColor = .white }

    /// Text tool click: edits the text layer under the point, or starts new text there.
    func textClick(at point: CGPoint) {
        if let layer = layers.reversed().first(where: { $0.isVisible && ($0.text?.contains(point) ?? false) }),
           let info = layer.text {
            activeLayerID = layer.id
            textFont = info.font
            textSize = info.size
            textBold = info.bold
            primaryColor = Color(.sRGB, red: info.red, green: info.green, blue: info.blue)
            pendingText = TextRequest(point: CGPoint(x: info.x, y: info.y), layerID: layer.id, string: info.string)
        } else {
            pendingText = TextRequest(point: point)
        }
    }

    func editText(of id: UUID) {
        guard let info = layers.first(where: { $0.id == id })?.text else { return }
        textClick(at: CGPoint(x: info.bounds.midX, y: info.bounds.midY))
    }

    func commitText(_ request: TextRequest, string: String) {
        let c = NSColor(cgColor: primaryCG)?.usingColorSpace(.sRGB) ?? .black
        var info = TextInfo(string: string, x: request.point.x, y: request.point.y, font: textFont, size: textSize,
                            bold: textBold, red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        // Re-editing keeps the text's angle and center.
        if let id = request.layerID, let old = layers.first(where: { $0.id == id })?.text {
            info.rotation = old.rotation
            let center = CGPoint(x: old.bounds.midX, y: old.bounds.midY), size = info.attributed.size()
            info.x = center.x - size.width / 2
            info.y = center.y + size.height / 2
        }
        let name = "T  " + (string.split(separator: "\n").first.map { String($0.prefix(24)) } ?? "Text")
        rememberColor()
        if let id = request.layerID, let i = layers.firstIndex(where: { $0.id == id }) {
            checkpoint()
            if string.isEmpty { layers.remove(at: i); activeLayerID = layers.last?.id; return }
            layers[i].image = info.render(canvas: canvasSize)
            layers[i].text = info
            layers[i].name = name
        } else if !string.isEmpty {
            var layer = Layer(name: name, image: info.render(canvas: canvasSize))
            layer.text = info
            insertLayer(layer)
        }
    }

    // MARK: Selection & clipboard

    func selectAll() { selection = canvasRect }
    func deselect() { selection = nil }

    func copy(merged: Bool = false) {
        guard let source = merged ? composite() : activeLayer?.image else { return }
        let area = (selection ?? canvasRect).intersection(canvasRect).integral
        guard !area.isEmpty else { return }
        let piece = Bitmap.render(area.size) { ctx in
            ctx.draw(source, in: CGRect(x: -area.minX, y: -area.minY, width: canvasSize.width, height: canvasSize.height))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: piece, size: area.size)])
        flash("Copied")
    }

    func cut() {
        copy()
        clearSelection()
    }

    func paste() {
        guard let ns = NSImage(pasteboard: .general), let img = Bitmap.cgImage(from: ns) else {
            return flash("Nothing to paste")
        }
        if !hasDocument {
            open(image: img, name: "Pasted Image")
        } else if let sel = selection, Int(sel.width) == img.width, Int(sel.height) == img.height {
            addImageLayer(img, name: "Pasted", origin: sel.origin)
        } else {
            addImageLayer(img, name: "Pasted")
        }
    }

    // MARK: Image operations

    /// `textShift` keeps text layers editable for operations that only translate content.
    private func transformAll(newSize: CGSize, textShift: CGPoint? = nil, _ draw: (CGContext, CGImage) -> Void) {
        checkpoint()
        for i in layers.indices {
            let img = layers[i].image, text = layers[i].text
            layers[i].image = Bitmap.render(newSize) { ctx in draw(ctx, img) }
            if let textShift { layers[i].text = text?.offsetBy(textShift) }
        }
        canvasSize = newSize
        selection = nil
        cropRect = nil
    }

    func crop(to rect: CGRect) {
        let r = rect.intersection(canvasRect).integral
        guard r.width >= 1, r.height >= 1 else { return }
        let full = canvasRect
        transformAll(newSize: r.size, textShift: CGPoint(x: -r.minX, y: -r.minY)) { ctx, img in
            ctx.draw(img, in: full.offsetBy(dx: -r.minX, dy: -r.minY))
        }
        zoomToFit()
    }

    func applyCrop() {
        if let cropRect { crop(to: cropRect) }
        cropRect = nil
    }

    func cropToSelection() {
        if let selection { crop(to: selection) }
    }

    /// Crops to the bounds of all non-transparent pixels.
    func trim() {
        guard let bounds = ImageOps.opaqueBounds(composite()) else { return flash("Nothing to trim") }
        crop(to: bounds)
    }

    // MARK: Layer transform

    @ObservationIgnored private var boundsCache: (revision: Int, rect: CGRect?)?

    /// Bounds of the layer's visible pixels, cached per revision.
    func contentBounds(_ layer: Layer) -> CGRect? {
        if let c = boundsCache, c.revision == layer.revision { return c.rect }
        let rect = ImageOps.opaqueBounds(layer.image)
        boundsCache = (layer.revision, rect)
        return rect
    }

    /// Applies an affine transform to the active layer. Scaling and rotating a text layer (without
    /// stretching or mirroring) re-renders the text so it stays sharp and editable.
    func transformActive(_ t: CGAffineTransform) {
        guard let i = activeIndex, !t.isIdentity else { return }
        let similarity = abs(t.a - t.d) < 1e-9 && abs(t.b + t.c) < 1e-9 && t.a * t.d - t.b * t.c > 0
        if let text = layers[i].text, similarity {
            var info = text
            let scale = hypot(t.a, t.b), angle = atan2(t.b, t.a)
            let center = CGPoint(x: text.bounds.midX, y: text.bounds.midY).applying(t)
            info.size = text.size * scale
            var r = (text.rotation ?? 0) + angle
            r = atan2(sin(r), cos(r))
            info.rotation = abs(r) < 1e-9 ? nil : r
            let size = info.attributed.size()
            info.x = center.x - size.width / 2
            info.y = center.y + size.height / 2
            checkpoint()
            layers[i].image = info.render(canvas: canvasSize)
            layers[i].text = info
            return
        }
        commitActive { ctx, img, rect in
            ctx.concatenate(t)
            ctx.draw(img, in: rect)
        }
    }

    /// Scales the active layer's content around its center to exactly `size`.
    func resizeActiveLayer(to size: CGSize) {
        guard let layer = activeLayer, let b = contentBounds(layer), size.width >= 1, size.height >= 1 else { return }
        transformActive(Self.scale(sx: size.width / b.width, sy: size.height / b.height, around: CGPoint(x: b.midX, y: b.midY)))
    }

    /// Scales the active layer's content up or down to fit the canvas, centered.
    func fitActiveLayerToCanvas() {
        guard let layer = activeLayer, let b = contentBounds(layer) else { return }
        let s = min(canvasSize.width / b.width, canvasSize.height / b.height)
        transformActive(CGAffineTransform(translationX: canvasSize.width / 2, y: canvasSize.height / 2)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -b.midX, y: -b.midY))
    }

    /// Rotates the active layer's content around its center (counter-clockwise for positive angles).
    func rotateActiveLayer(by angle: CGFloat) {
        guard let layer = activeLayer, let b = contentBounds(layer) else { return }
        transformActive(Self.rotation(angle, around: CGPoint(x: b.midX, y: b.midY)))
    }

    static func rotation(_ angle: CGFloat, around c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
    }

    static func scale(sx: CGFloat, sy: CGFloat, around a: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: a.x, y: a.y).scaledBy(x: sx, y: sy).translatedBy(x: -a.x, y: -a.y)
    }

    func rotate(clockwise: Bool) {
        let w = canvasSize.width, h = canvasSize.height
        let full = canvasRect
        transformAll(newSize: CGSize(width: h, height: w)) { ctx, img in
            ctx.concatenate(clockwise
                ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
                : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
            ctx.draw(img, in: full)
        }
        zoomToFit()
    }

    func flip(horizontal: Bool, layerOnly: Bool = false) {
        let w = canvasSize.width, h = canvasSize.height
        let full = canvasRect
        let flipDraw: (CGContext, CGImage) -> Void = { ctx, img in
            if horizontal { ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1) }
            else { ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1) }
            ctx.draw(img, in: full)
        }
        if layerOnly {
            commitActive { ctx, img, _ in flipDraw(ctx, img) }
        } else {
            transformAll(newSize: canvasSize, flipDraw)
        }
    }

    func resizeImage(to size: CGSize) {
        let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        transformAll(newSize: size) { ctx, img in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
        }
        zoomToFit()
    }

    func resizeCanvas(to size: CGSize, anchor: UnitPoint) {
        let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        let dx = ((size.width - canvasSize.width) * anchor.x).rounded()
        // UnitPoint is top-down; canvas is bottom-up.
        let dy = ((size.height - canvasSize.height) * (1 - anchor.y)).rounded()
        let full = canvasRect
        transformAll(newSize: size, textShift: CGPoint(x: dx, y: dy)) { ctx, img in
            ctx.draw(img, in: full.offsetBy(dx: dx, dy: dy))
        }
        zoomToFit()
    }

    // MARK: Adjustments & effects

    private func schedulePreview() {
        guard let layer = activeLayer, !adjustments.isIdentity else {
            previewImage = nil
            previewLayerID = nil
            return
        }
        guard !previewInFlight else { return }
        previewInFlight = true
        let adj = adjustments, src = layer.image, sel = selection, size = canvasSize, id = layer.id
        Task.detached(priority: .userInitiated) {
            let out = ImageOps.process(src) { adj.apply(to: $0) }
            let merged = out.map { Bitmap.merge(original: src, edited: $0, clip: sel, size: size) }
            await MainActor.run {
                self.previewInFlight = false
                guard self.activeLayerID == id, !self.adjustments.isIdentity else { return }
                self.previewImage = merged
                self.previewLayerID = id
                // Sliders moved while rendering: render the newest values.
                if self.adjustments != adj { self.schedulePreview() }
            }
        }
    }

    func preview(for layer: Layer) -> CGImage? {
        previewLayerID == layer.id ? previewImage : nil
    }

    func cancelAdjustments() {
        if !adjustments.isIdentity { adjustments = Adjustments() }
        previewImage = nil
        previewLayerID = nil
    }

    func applyAdjustments() {
        guard let i = activeIndex, !adjustments.isIdentity else { return }
        let adj = adjustments
        let src = layers[i].image
        let result = previewLayerID == layers[i].id && !previewInFlight ? previewImage : nil
        let final = result ?? ImageOps.process(src) { adj.apply(to: $0) }.map {
            Bitmap.merge(original: src, edited: $0, clip: selection, size: canvasSize)
        }
        guard let final else { return }
        checkpoint()
        layers[i].image = final
        cancelAdjustments()
    }

    /// Runs heavy work off the main thread with a progress overlay, then replaces the active layer.
    private func runOnActive(_ message: String, notFound: String = "Couldn’t find a subject in this layer",
                             _ work: @escaping @Sendable (CGImage) throws -> CGImage?) {
        guard let i = activeIndex, busyMessage == nil else { return }
        let id = layers[i].id, src = layers[i].image, sel = selection, size = canvasSize
        busyMessage = message
        Task.detached(priority: .userInitiated) {
            let result: Result<CGImage?, Error> = Result { try work(src) }
            await MainActor.run {
                self.busyMessage = nil
                switch result {
                case .success(let img?):
                    guard let j = self.layers.firstIndex(where: { $0.id == id }) else { return }
                    self.checkpoint()
                    self.layers[j].image = Bitmap.merge(original: src, edited: img, clip: sel, size: size)
                case .success(nil):
                    self.flash(notFound)
                case .failure(let e):
                    self.flash(e.localizedDescription)
                }
            }
        }
    }

    func applyEffect(_ effect: Effect) {
        runOnActive("Applying \(effect.name)…") { src in
            ImageOps.process(src, effect.apply)
        }
    }

    func removeBackground() {
        runOnActive("Removing background…") { src in
            try ImageOps.removeBackground(src)
        }
    }

    func blurBackground() {
        runOnActive("Blurring background…") { src in
            try ImageOps.blurBackground(src)
        }
    }

    func colorBackground() {
        let color = secondaryCG
        runOnActive("Replacing background…") { src in
            try ImageOps.colorBackground(src, color: color)
        }
    }

    /// Copies the detected subject onto a new layer, leaving the original untouched.
    func liftSubject() {
        guard let layer = activeLayer, busyMessage == nil else { return }
        let src = layer.image, name = layer.name
        busyMessage = "Finding subject…"
        Task.detached(priority: .userInitiated) {
            let result = Result { try ImageOps.removeBackground(src) }
            await MainActor.run {
                self.busyMessage = nil
                switch result {
                case .success(let img?): self.insertLayer(Layer(name: "\(name) subject", image: img))
                case .success(nil): self.flash("Couldn’t find a subject in this layer")
                case .failure(let e): self.flash(e.localizedDescription)
                }
            }
        }
    }

    // MARK: AI tools

    var showGenerateSheet = false

    /// Runs `work` off the main thread with a progress message, then hands the result back.
    private func runAI<T: Sendable>(_ message: String, _ work: @escaping @Sendable () async throws -> T,
                                    then done: @escaping (T) -> Void) {
        guard busyMessage == nil else { return }
        busyMessage = message
        Task.detached(priority: .userInitiated) {
            do {
                let value = try await work()
                await MainActor.run { self.busyMessage = nil; done(value) }
            } catch {
                await MainActor.run { self.busyMessage = nil; self.flash(error.localizedDescription) }
            }
        }
    }

    func fixRedEye() {
        runOnActive("Fixing red eye…", notFound: "No red eyes found") { AIOps.fixRedEye($0) }
    }

    func smoothSkin() {
        runOnActive("Smoothing skin…", notFound: "No faces found") { try AIOps.smoothSkin($0) }
    }

    func hideFaces() {
        runOnActive("Hiding faces…", notFound: "No faces found") { try AIOps.hideFaces($0) }
    }

    func eraseObject() {
        guard let hole = selection else { return flash("Select the object first with the Select tool (M)") }
        runOnActive("Erasing…") { AIOps.fill($0, hole: hole) }
    }

    func selectSubject() {
        guard let src = activeLayer?.image else { return }
        runAI("Finding subject…", { try AIOps.subjectBounds(src) }) { rect in
            guard let rect else { return self.flash("Couldn’t find a subject in this layer") }
            self.selection = rect.insetBy(dx: -4, dy: -4).intersection(self.canvasRect).integral
            self.flash("Subject selected")
        }
    }

    func copyText() {
        let src = composite(background: .white)
        runAI("Reading text…", { try AIOps.recognizeText(src) }) { lines in
            guard !lines.isEmpty else { return self.flash("No text found") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            self.flash("Copied \(lines.count) line\(lines.count == 1 ? "" : "s") of text")
        }
    }

    /// Levels a tilted horizon, zooming in just enough to hide the rotated corners.
    func straighten() {
        let src = composite(background: .white)
        runAI("Finding the horizon…", { try AIOps.horizonAngle(src) }) { angle in
            guard let angle else { return self.flash("Couldn’t find a horizon") }
            guard abs(angle) > 0.1 * .pi / 180 else { return self.flash("Already straight") }
            // Vision reports the rotation that levels the image, so apply it as-is.
            self.rotateAll(by: angle)
            self.flash(String(format: "Straightened by %.1f°", angle * 180 / .pi))
        }
    }

    func rotateAll(by angle: CGFloat) {
        let w = canvasSize.width, h = canvasSize.height
        let s = abs(cos(angle)) + abs(sin(angle)) * max(w / h, h / w)
        let full = canvasRect
        transformAll(newSize: canvasSize) { ctx, img in
            ctx.translateBy(x: w / 2, y: h / 2)
            ctx.rotate(by: angle)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -w / 2, y: -h / 2)
            ctx.draw(img, in: full)
        }
    }

    /// Proposes a crop around the most interesting part of the image; the user can adjust it.
    func smartCrop() {
        let src = composite(background: .white)
        runAI("Finding the best crop…", { try AIOps.salientRect(src) }) { found in
            guard let found else { return self.flash("Nothing stood out to crop to") }
            var r = found.insetBy(dx: -found.width * 0.12, dy: -found.height * 0.12)
            let ratio = self.cropAspect.ratio ?? (self.canvasSize.width / self.canvasSize.height)
            if r.width / r.height < ratio {
                r = r.insetBy(dx: -(r.height * ratio - r.width) / 2, dy: 0)
            } else {
                r = r.insetBy(dx: 0, dy: -(r.width / ratio - r.height) / 2)
            }
            // Fit inside the canvas, keeping the ratio.
            let fit = min(1, self.canvasSize.width / r.width, self.canvasSize.height / r.height)
            r = r.insetBy(dx: r.width * (1 - fit) / 2, dy: r.height * (1 - fit) / 2)
            r.origin.x = min(max(0, r.minX), self.canvasSize.width - r.width)
            r.origin.y = min(max(0, r.minY), self.canvasSize.height - r.height)
            self.tool = .crop
            self.cropRect = r.integral.intersection(self.canvasRect)
            self.flash("Adjust the box if you like, then press Return")
        }
    }

    /// "Edit with words": Apple Intelligence when available, otherwise keyword matching.
    func editWithWords(_ request: String) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeLayer != nil else { return }
        let useModel = AIOps.languageModelAvailable
        runAI(useModel ? "Thinking…" : "Applying…", {
            var changes: [String: Double] = [:]
            if useModel { changes = (try? await AIOps.adjustmentsFromModel(text)) ?? [:] }
            return changes.isEmpty ? KeywordEdits.parse(text) : changes
        }) { changes in
            var adj = self.adjustments
            var applied = 0
            for (key, delta) in changes {
                guard let path = KeywordEdits.path(for: key),
                      let control = Adjustments.groups.flatMap(\.controls).first(where: { $0.id == path }) else { continue }
                adj[keyPath: path] = min(control.range.upperBound, max(control.range.lowerBound, adj[keyPath: path] + delta))
                applied += 1
            }
            guard applied > 0 else {
                return self.flash("Try words like warmer, brighter, moody, vintage or black and white")
            }
            self.adjustments = adj
            UserDefaults.standard.set("adjust", forKey: "inspectorTab")
            self.flash("Preview ready. Press Apply to keep it")
        }
    }

    func generateImage(prompt: String, style: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runAI("Creating image…", { try await AIOps.generateImage(prompt: text, style: style) }) { image in
            guard let image else { return self.flash("Couldn’t create an image") }
            if self.hasDocument {
                self.addImageLayer(image, name: "AI: " + text.prefix(30))
            } else {
                self.open(image: image, name: String(text.prefix(40)))
            }
        }
    }

    func refreshEffectThumbnails() {
        guard let layer = activeLayer else { return }
        let key = layer.revision
        guard thumbnailsKey != key else { return }
        thumbnailsKey = key
        let src = layer.image
        Task.detached(priority: .utility) {
            let small = ImageOps.downscaled(src, maxSide: 180)
            var out: [String: NSImage] = [:]
            for effect in Effect.all {
                if let img = ImageOps.process(small, effect.apply) {
                    out[effect.id] = NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))
                }
            }
            let thumbs = out
            await MainActor.run {
                if self.thumbnailsKey == key { self.effectThumbnails = thumbs }
            }
        }
    }

    // MARK: Export

    func exportSize(format: ExportFormat, scale: Double) -> CGSize {
        if let side = format.fixedSide { return CGSize(width: side, height: side) }
        return CGSize(width: (canvasSize.width * scale).rounded(), height: (canvasSize.height * scale).rounded())
    }

    func exportData(format: ExportFormat, quality: Double, scale: Double) -> Data? {
        var image = composite(background: format.supportsAlpha ? nil : .white)
        let size = exportSize(format: format, scale: scale)
        if size != canvasSize {
            let src = image
            // Fit inside the target (icons are square), centered.
            let s = min(size.width / canvasSize.width, size.height / canvasSize.height)
            let w = canvasSize.width * s, h = canvasSize.height * s
            image = Bitmap.render(size) { ctx in
                ctx.interpolationQuality = .high
                ctx.draw(src, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            }
        }
        let data = NSMutableData()
        switch format {
        case .pdf:
            // One page the size of the image (1 px = 1 pt).
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: box)
            pdf.endPDFPage()
            pdf.closePDF()
        case .icns:
            // macOS icons hold every standard size in one file.
            let sides: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]
            guard let dest = CGImageDestinationCreateWithData(data, format.identifier as CFString, sides.count, nil) else { return nil }
            let src = image
            for side in sides {
                let scaled = side == size.width ? src : Bitmap.render(CGSize(width: side, height: side)) { ctx in
                    ctx.interpolationQuality = .high
                    ctx.draw(src, in: CGRect(x: 0, y: 0, width: side, height: side))
                }
                // 1024 is stored as the 512 @2x (retina) variant.
                let dpi = side == 1024 ? 144 : 72
                CGImageDestinationAddImage(dest, scaled, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else { return nil }
        default:
            guard let dest = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
        }
        return data as Data
    }

    func export(format: ExportFormat, quality: Double, scale: Double) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = documentName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = exportData(format: format, quality: quality, scale: scale) else {
            return flash("Export failed")
        }
        do {
            try data.write(to: url)
            // A flat export only fully captures a single-layer document.
            if layers.count == 1 && documentURL == nil {
                documentName = url.deletingPathExtension().lastPathComponent
                isDirty = false
            }
            flash("Exported \(url.lastPathComponent)")
        } catch {
            flash(error.localizedDescription)
        }
    }

    // MARK: View

    func zoomToFit() {
        let vs = viewport.viewSize
        guard vs.width > 0, vs.height > 0 else { viewport.zoom = 1; return }
        let z = min((vs.width - 48) / canvasSize.width, (vs.height - 48) / canvasSize.height)
        viewport.zoom = max(0.02, min(z, 4))
        viewport.offset = .zero
    }

    func actualSize() {
        viewport.zoom = 1
        viewport.offset = .zero
    }

    func zoom(in zoomIn: Bool) {
        let z = viewport.zoom
        let next = zoomIn
            ? Viewport.zoomLevels.first { $0 > z * 1.01 } ?? z
            : Viewport.zoomLevels.last { $0 < z * 0.99 } ?? z
        viewport.offset = CGPoint(x: viewport.offset.x * next / z, y: viewport.offset.y * next / z)
        viewport.zoom = next
    }

    private var toastTask: Task<Void, Never>?

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }
}
