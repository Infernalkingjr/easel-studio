import AppKit
import Observation
import UniformTypeIdentifiers
import EaselKit

enum QuillTool: String, CaseIterable, Identifiable {
    case select, direct, pen, pencil, rect, ellipse, polygon, star, line, text, eyedropper, hand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Selection"
        case .direct: return "Direct Selection"
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .polygon: return "Polygon"
        case .star: return "Star"
        case .line: return "Line Segment"
        case .text: return "Type"
        case .eyedropper: return "Eyedropper"
        case .hand: return "Hand"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .direct: return "cursorarrow.rays"
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .polygon: return "hexagon"
        case .star: return "star"
        case .line: return "line.diagonal"
        case .text: return "textformat"
        case .eyedropper: return "eyedropper"
        case .hand: return "hand.raised"
        }
    }

    /// Illustrator's single-key shortcuts.
    var key: Character? {
        switch self {
        case .select: return "v"
        case .direct: return "a"
        case .pen: return "p"
        case .pencil: return "n"
        case .rect: return "m"
        case .ellipse: return "l"
        case .line: return "\\"
        case .text: return "t"
        case .eyedropper: return "i"
        case .hand: return "h"
        case .polygon, .star: return nil
        }
    }

    var hint: String {
        switch self {
        case .select: return "Click to select, drag to move. Handles scale; drag just outside a corner to rotate. ⌥-drag duplicates."
        case .direct: return "Drag points and handles to reshape. ⌥ breaks a smooth point. ⌫ deletes points."
        case .pen: return "Click for corners, drag for curves. Click the first point to close; Return or Esc to finish."
        case .pencil: return "Draw freely; the line is smoothed into curves. End near the start to close it."
        case .rect: return "Drag a rectangle. ⇧ square, ⌥ from the center."
        case .ellipse: return "Drag an ellipse. ⇧ circle, ⌥ from the center."
        case .polygon: return "Drag out a polygon from its center. ⇧ keeps it upright."
        case .star: return "Drag out a star from its center."
        case .line: return "Drag a line. ⇧ snaps to 45°."
        case .text: return "Click to type. Double-click text with the Selection tool to edit it."
        case .eyedropper: return "Click an object to copy its fill and stroke onto the selection."
        case .hand: return "Drag to pan. Pinch or ⌘ + scroll to zoom."
        }
    }
}

enum Pathfinder: String, CaseIterable, Identifiable {
    case unite = "Unite", minusFront = "Minus Front", intersect = "Intersect", exclude = "Exclude"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .unite: return "square.on.square.squareshape.controlhandles"
        case .minusFront: return "minus.square"
        case .intersect: return "square.on.square.intersection.dashed"
        case .exclude: return "square.on.square.dashed"
        }
    }
}

enum AlignEdge: CaseIterable {
    case left, hCenter, right, top, vCenter, bottom
    var symbol: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .hCenter: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .vCenter: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        }
    }
}

struct NodeRef: Hashable {
    var item: UUID
    var contour: Int
    var node: Int
}

extension UTType {
    static let quillProject = UTType(exportedAs: "app.easel.quill.project", conformingTo: .json)
}

@Observable @MainActor
final class QuillStudio {
    var doc = ArtDocument() {
        didSet { if doc != oldValue { isDirty = true } }
    }
    var layerID: UUID
    var selection: Set<UUID> = []
    var nodeSelection: Set<NodeRef> = []
    var tool: QuillTool = .select {
        didSet { if tool != .pen { finishPen() } }
    }
    /// The path the Pen tool is building.
    var penNodes: [Node] = []
    /// Colors and stroke for new objects (and the selection, when there is one).
    var fill: RGBA? = RGBA(r: 1, g: 0.8, b: 0.2)
    var stroke: RGBA? = .black
    var strokeWidth: Double = 2
    var sides = 6
    var starPoints = 5
    var starInner = 0.5
    var font = "HelveticaNeue-Bold"
    var fontSize: Double = 64
    var editingTextID: UUID?
    /// Text just created by a click, so committing it doesn't add a second undo step.
    @ObservationIgnored private var freshTextID: UUID?
    var documentURL: URL?
    var documentName = "Untitled"
    var isDirty = false
    var toast: String?
    var showExport = false
    var showNewDocument = false
    var fitRequest = 0

    @ObservationIgnored let images = ImageStore()
    private(set) var undoStack: [ArtDocument] = []
    private(set) var redoStack: [ArtDocument] = []

    static let layerColors: [NSColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple, .systemTeal]

    init() {
        layerID = UUID()
        layerID = doc.layers[0].id
    }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(doc)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    @ObservationIgnored private var lastCoalesced: (key: String, at: Date)?

    /// One undo step for a burst of changes to the same control (e.g. dragging in a color picker).
    func coalescedCheckpoint(_ key: String) {
        if let last = lastCoalesced, last.key == key, Date().timeIntervalSince(last.at) < 1.5 {
            lastCoalesced = (key, Date())
            return
        }
        if !selection.isEmpty || key == "background" { checkpoint() }
        lastCoalesced = (key, Date())
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
        let ids = Set(doc.allItems.map(\.id))
        selection = selection.intersection(ids)
        nodeSelection = nodeSelection.filter { ids.contains($0.item) }
        if !doc.layers.contains(where: { $0.id == layerID }) { layerID = doc.layers[0].id }
        if let e = editingTextID, !ids.contains(e) { editingTextID = nil }
    }

    // MARK: Lookups

    var layerIndex: Int { doc.layers.firstIndex { $0.id == layerID } ?? 0 }
    var layer: ArtLayer { doc.layers[layerIndex] }

    func locate(_ id: UUID) -> (layer: Int, index: Int)? {
        for (l, layer) in doc.layers.enumerated() {
            if let i = layer.items.firstIndex(where: { $0.id == id }) { return (l, i) }
        }
        return nil
    }

    func item(_ id: UUID) -> Item? { locate(id).map { doc.layers[$0.layer].items[$0.index] } }

    /// Selected items, bottom to top.
    var selectedItems: [Item] { doc.allItems.filter { selection.contains($0.id) } }

    func updateItem(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let (l, i) = locate(id) else { return }
        change(&doc.layers[l].items[i])
    }

    /// Whether an item can be picked: its layer is visible and unlocked.
    func isEditable(_ id: UUID) -> Bool {
        guard let (l, _) = locate(id) else { return false }
        return doc.layers[l].visible && !doc.layers[l].locked
    }

    var selectionBounds: CGRect? {
        let items = selectedItems
        guard !items.isEmpty else { return nil }
        return items.reduce(CGRect.null) { $0.union($1.geometryBounds) }
    }

    // MARK: Selection

    /// Grows a set of ids to whole groups.
    func withGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(doc.allItems.filter { ids.contains($0.id) }.compactMap(\.group))
        guard !groups.isEmpty else { return ids }
        return ids.union(doc.allItems.filter { $0.group.map(groups.contains) ?? false }.map(\.id))
    }

    func select(_ ids: Set<UUID>, extend: Bool = false) {
        let grown = withGroups(ids)
        selection = extend ? selection.symmetricDifference(grown) : grown
        nodeSelection = []
        if let first = selectedItems.last, let (l, _) = locate(first.id) { layerID = doc.layers[l].id }
    }

    func selectAll() {
        tool = tool == .direct ? .direct : .select
        selection = Set(doc.layers.filter { $0.visible && !$0.locked }.flatMap(\.items).map(\.id))
    }

    func deselect() {
        selection = []
        nodeSelection = []
    }

    // MARK: Adding

    private var canAdd: Bool {
        if layer.locked { flash("“\(layer.name)” is locked"); return false }
        if !layer.visible { flash("“\(layer.name)” is hidden"); return false }
        return true
    }

    func styled(_ item: Item) -> Item {
        var i = item
        i.fill = fill
        i.stroke = stroke
        i.strokeWidth = strokeWidth
        return i
    }

    /// Adds an item to the active layer and selects it.
    @discardableResult
    func add(_ item: Item, checkpoint shouldCheckpoint: Bool = true) -> Bool {
        guard canAdd else { return false }
        if shouldCheckpoint { checkpoint() }
        doc.layers[layerIndex].items.append(item)
        selection = [item.id]
        nodeSelection = []
        return true
    }

    func addPath(_ contours: [Contour], name: String, open: Bool = false) {
        var item = styled(Item(name: name, kind: .path(contours)))
        // Open paths would fill as if closed; most people expect a line.
        if open && contours.allSatisfy({ !$0.closed }) && item.stroke != nil { item.fill = nil }
        add(item)
    }

    func addText(at p: CGPoint) -> UUID? {
        var item = Item(name: "Text", kind: .text(TextSpec(string: "", font: font, size: fontSize)))
        item.fill = fill ?? .black
        item.stroke = nil
        item.transform = Affine(CGAffineTransform(translationX: p.x, y: p.y - fontSize * 0.8))
        guard add(item) else { return nil }
        editingTextID = item.id
        freshTextID = item.id
        return item.id
    }

    /// Ends in-place typing; empty text disappears.
    func commitText(_ id: UUID, _ string: String) {
        editingTextID = nil
        let fresh = freshTextID == id
        freshTextID = nil
        guard let it = item(id), case .text(var spec) = it.kind else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if fresh { _ = undoStack.popLast() } else { checkpoint() }
            if let (l, i) = locate(id) { doc.layers[l].items.remove(at: i) }
            selection.remove(id)
            return
        }
        guard spec.string != string else { return }
        if !fresh { checkpoint() }
        spec.string = string
        updateItem(id) { $0.kind = .text(spec) }
    }

    /// Turns the Pen tool's points into a path.
    func finishPen(close: Bool = false) {
        let nodes = penNodes
        guard !nodes.isEmpty else { return }
        penNodes = []
        guard nodes.count >= 2 else { return }
        addPath([Contour(nodes: nodes, closed: close)], name: "Path", open: !close)
    }

    // MARK: Editing

    func deleteSelection() {
        if !nodeSelection.isEmpty { return deleteNodes() }
        guard !selection.isEmpty else { return }
        checkpoint()
        for l in doc.layers.indices { doc.layers[l].items.removeAll { selection.contains($0.id) } }
        selection = []
    }

    /// Applies an artboard-space transform to the selection. Paths take it into their points so their
    /// strokes keep their width; text and images keep it as a transform.
    func transformSelection(_ t: CGAffineTransform, ids: Set<UUID>? = nil) {
        for id in ids ?? selection {
            updateItem(id) { item in
                if case .path(let contours) = item.kind {
                    let full = item.transform.cg.concatenating(t)
                    item.kind = .path(contours.map { Contour(nodes: $0.nodes.map { $0.applying(full) }, closed: $0.closed) })
                    item.transform = .identity
                } else {
                    item.transform = Affine(item.transform.cg.concatenating(t))
                }
            }
        }
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        if !nodeSelection.isEmpty { checkpoint(); moveNodes(nodeSelection, by: CGPoint(x: dx, y: dy)); return }
        guard !selection.isEmpty else { return }
        checkpoint()
        transformSelection(CGAffineTransform(translationX: dx, y: dy))
    }

    func setFrame(x: Double? = nil, y: Double? = nil, w: Double? = nil, h: Double? = nil) {
        guard let b = selectionBounds else { return }
        let nw = max(0.5, w ?? b.width), nh = max(0.5, h ?? b.height)
        let sx = b.width > 0 ? nw / b.width : 1, sy = b.height > 0 ? nh / b.height : 1
        let t = CGAffineTransform(translationX: -b.minX, y: -b.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: x ?? b.minX, y: y ?? b.minY))
        checkpoint()
        transformSelection(t)
    }

    func rotateSelection(by degrees: Double) {
        guard let b = selectionBounds else { return }
        checkpoint()
        transformSelection(CGAffineTransform(translationX: -b.midX, y: -b.midY)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: b.midX, y: b.midY)))
    }

    func flip(horizontal: Bool) {
        guard let b = selectionBounds else { return }
        checkpoint()
        transformSelection(CGAffineTransform(translationX: -b.midX, y: -b.midY)
            .concatenating(CGAffineTransform(scaleX: horizontal ? -1 : 1, y: horizontal ? 1 : -1))
            .concatenating(CGAffineTransform(translationX: b.midX, y: b.midY)))
    }

    /// Copies of the selection (regrouped together), placed on top. Returns the new ids.
    @discardableResult
    func duplicateSelection(offset: CGPoint = CGPoint(x: 12, y: 12), checkpoint shouldCheckpoint: Bool = true) -> Set<UUID> {
        guard !selection.isEmpty else { return [] }
        if shouldCheckpoint { checkpoint() }
        var newIDs: Set<UUID> = []
        var groupMap: [UUID: UUID] = [:]
        for l in doc.layers.indices {
            for item in doc.layers[l].items where selection.contains(item.id) {
                var copy = item
                copy.id = UUID()
                if let g = item.group { copy.group = groupMap[g] ?? { let n = UUID(); groupMap[g] = n; return n }() }
                doc.layers[l].items.append(copy)
                newIDs.insert(copy.id)
            }
        }
        selection = newIDs
        transformSelection(CGAffineTransform(translationX: offset.x, y: offset.y))
        return newIDs
    }

    /// Changes the selected items' look; with nothing selected, changes the defaults for new objects.
    func style(checkpoint shouldCheckpoint: Bool = true, _ change: (inout Item) -> Void) {
        if selection.isEmpty {
            var probe = styled(Item(name: "", kind: .path([])))
            change(&probe)
            fill = probe.fill
            stroke = probe.stroke
            strokeWidth = probe.strokeWidth
            return
        }
        if shouldCheckpoint { checkpoint() }
        for id in selection { updateItem(id, change) }
        if let first = selectedItems.last {
            fill = first.fill
            stroke = first.stroke
            strokeWidth = first.strokeWidth
        }
    }

    func setText(checkpoint shouldCheckpoint: Bool = true, _ change: (inout TextSpec) -> Void) {
        let texts = selectedItems.filter(\.isText)
        if texts.isEmpty {
            var spec = TextSpec(string: "", font: font, size: fontSize)
            change(&spec)
            font = spec.font
            fontSize = spec.size
            return
        }
        if shouldCheckpoint { checkpoint() }
        for t in texts {
            updateItem(t.id) { item in
                if case .text(var spec) = item.kind { change(&spec); item.kind = .text(spec) }
            }
        }
    }

    /// Swaps fill and stroke (⇧X).
    func swapColors() {
        if selection.isEmpty { (fill, stroke) = (stroke, fill); return }
        style { item in (item.fill, item.stroke) = (item.stroke, item.fill) }
    }

    /// Black stroke, white fill (D).
    func defaultColors() {
        style { $0.fill = .white; $0.stroke = .black; $0.gradient = nil }
    }

    /// Eyedropper: copies the clicked object's look onto the selection.
    func pickStyle(from id: UUID) {
        guard let src = item(id) else { return }
        if selection.isEmpty || selection == [id] {
            fill = src.fill; stroke = src.stroke; strokeWidth = src.strokeWidth
            return flash("Picked up its colors")
        }
        style { item in
            item.fill = src.fill
            item.gradient = src.gradient
            item.stroke = src.stroke
            item.strokeWidth = src.strokeWidth
            item.cap = src.cap
            item.join = src.join
            item.dashed = src.dashed
            item.opacity = src.opacity
        }
    }

    // MARK: Arrange

    enum Arrange { case front, forward, backward, back }

    func arrange(_ how: Arrange) {
        guard !selection.isEmpty else { return }
        checkpoint()
        for l in doc.layers.indices {
            var items = doc.layers[l].items
            let picked = items.filter { selection.contains($0.id) }
            guard !picked.isEmpty else { continue }
            switch how {
            case .front:
                items.removeAll { selection.contains($0.id) }
                items += picked
            case .back:
                items.removeAll { selection.contains($0.id) }
                items = picked + items
            case .forward:
                for i in stride(from: items.count - 2, through: 0, by: -1) where selection.contains(items[i].id) && !selection.contains(items[i + 1].id) {
                    items.swapAt(i, i + 1)
                }
            case .backward:
                for i in 1..<max(1, items.count) where selection.contains(items[i].id) && !selection.contains(items[i - 1].id) {
                    items.swapAt(i, i - 1)
                }
            }
            doc.layers[l].items = items
        }
    }

    func group() {
        guard selection.count > 1 else { return flash("Select two or more objects to group") }
        checkpoint()
        let g = UUID()
        for id in selection { updateItem(id) { $0.group = g } }
        flash("Grouped \(selection.count) objects")
    }

    func ungroup() {
        guard selectedItems.contains(where: { $0.group != nil }) else { return }
        checkpoint()
        for id in selection { updateItem(id) { $0.group = nil } }
    }

    // MARK: Align

    /// Aligns the selection to its own bounds, or to the artboard when only one object is selected.
    func align(_ edge: AlignEdge) {
        let items = selectedItems
        guard !items.isEmpty, let sb = selectionBounds else { return }
        let target = units(items).count == 1 ? CGRect(origin: .zero, size: doc.size) : sb
        checkpoint()
        for unit in units(items) {
            let b = unit.reduce(CGRect.null) { $0.union($1.geometryBounds) }
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch edge {
            case .left: dx = target.minX - b.minX
            case .hCenter: dx = target.midX - b.midX
            case .right: dx = target.maxX - b.maxX
            case .top: dy = target.minY - b.minY
            case .vCenter: dy = target.midY - b.midY
            case .bottom: dy = target.maxY - b.maxY
            }
            transformSelection(CGAffineTransform(translationX: dx, y: dy), ids: Set(unit.map(\.id)))
        }
    }

    /// Spaces objects evenly between the outermost ones.
    func distribute(horizontal: Bool) {
        let us = units(selectedItems).map { u in (u, u.reduce(CGRect.null) { $0.union($1.geometryBounds) }) }
            .sorted { horizontal ? $0.1.midX < $1.1.midX : $0.1.midY < $1.1.midY }
        guard us.count > 2 else { return flash("Select three or more objects to distribute") }
        checkpoint()
        let first = horizontal ? us.first!.1.midX : us.first!.1.midY, last = horizontal ? us.last!.1.midX : us.last!.1.midY
        for (k, (unit, b)) in us.enumerated() {
            let target = first + (last - first) * CGFloat(k) / CGFloat(us.count - 1)
            let d = target - (horizontal ? b.midX : b.midY)
            transformSelection(CGAffineTransform(translationX: horizontal ? d : 0, y: horizontal ? 0 : d), ids: Set(unit.map(\.id)))
        }
    }

    /// Groups move as one unit when aligning.
    private func units(_ items: [Item]) -> [[Item]] {
        var out: [[Item]] = []
        var seen: [UUID: Int] = [:]
        for item in items {
            if let g = item.group, let k = seen[g] { out[k].append(item); continue }
            if let g = item.group { seen[g] = out.count }
            out.append([item])
        }
        return out
    }

    // MARK: Pathfinder & outlines

    /// Combines the selected shapes into one. Text is converted to outlines first; images are left alone.
    func pathfinder(_ op: Pathfinder) {
        let items = selectedItems.filter { if case .image = $0.kind { return false } else { return true } }
        guard items.count >= 2 else { return flash("Select two or more shapes") }
        let paths = items.map { ($0.worldPath, $0.evenOdd ? CGPathFillRule.evenOdd : .winding) }
        var result: CGPath
        switch op {
        case .unite:
            result = paths.dropFirst().reduce(paths[0].0) { $0.union($1.0, using: $1.1) }
        case .intersect:
            result = paths.dropFirst().reduce(paths[0].0) { $0.intersection($1.0, using: $1.1) }
        case .exclude:
            result = paths.dropFirst().reduce(paths[0].0) { $0.symmetricDifference($1.0, using: $1.1) }
        case .minusFront:
            let front = paths.dropFirst().reduce(CGMutablePath() as CGPath) { $0.union($1.0, using: $1.1) }
            result = paths[0].0.subtracting(front, using: paths[0].1)
        }
        let contours = Geo.contours(result)
        guard !contours.isEmpty else { return flash("Those shapes don’t overlap") }
        // Unite keeps the top object's look (like Illustrator); the others keep the bottom one's.
        var base = op == .unite ? items.last! : items.first!
        checkpoint()
        let removed = Set(items.map(\.id))
        let (l, i) = locate(items.last!.id)!
        doc.layers[l].items.insert(Item(name: op.rawValue, kind: .path(contours)), at: i + 1)
        let newID = doc.layers[l].items[i + 1].id
        base.id = newID
        base.name = op.rawValue
        base.kind = .path(contours)
        base.transform = .identity
        base.evenOdd = true
        base.group = nil
        if base.fill == nil && base.gradient == nil { base.fill = base.stroke }
        doc.layers[l].items[i + 1] = base
        for k in doc.layers.indices { doc.layers[k].items.removeAll { removed.contains($0.id) } }
        selection = [newID]
    }

    /// Turns text into editable letter shapes.
    func createOutlines() {
        let texts = selectedItems.filter(\.isText)
        guard !texts.isEmpty else { return flash("Select some text first") }
        checkpoint()
        for t in texts {
            updateItem(t.id) { item in
                guard case .text(let spec) = item.kind else { return }
                let local = Geo.contours(TextLayout.outlines(spec))
                item.kind = .path(local.map { Contour(nodes: $0.nodes.map { $0.applying(item.transform.cg) }, closed: $0.closed) })
                item.transform = .identity
                item.name = String(spec.string.prefix(24))
                if item.stroke != nil && item.strokeWidth > 0 && item.fill == nil { item.fill = .black }
            }
        }
        flash("Created outlines")
    }

    // MARK: Points (direct selection)

    func node(_ r: NodeRef) -> Node? {
        guard let c = item(r.item)?.contours, c.indices.contains(r.contour), c[r.contour].nodes.indices.contains(r.node) else { return nil }
        return c[r.contour].nodes[r.node]
    }

    func setNode(_ r: NodeRef, _ n: Node) {
        updateItem(r.item) { item in
            guard case .path(var c) = item.kind, c.indices.contains(r.contour), c[r.contour].nodes.indices.contains(r.node) else { return }
            c[r.contour].nodes[r.node] = n
            item.kind = .path(c)
        }
    }

    func moveNodes(_ refs: Set<NodeRef>, by d: CGPoint) {
        for r in refs {
            guard var n = node(r) else { continue }
            n.p.x += d.x; n.p.y += d.y
            n.i.x += d.x; n.i.y += d.y
            n.o.x += d.x; n.o.y += d.y
            setNode(r, n)
        }
    }

    func deleteNodes() {
        guard !nodeSelection.isEmpty else { return }
        checkpoint()
        for id in Set(nodeSelection.map(\.item)) {
            guard let (l, i) = locate(id), case .path(var contours) = doc.layers[l].items[i].kind else { continue }
            for c in contours.indices {
                let drop = Set(nodeSelection.filter { $0.item == id && $0.contour == c }.map(\.node))
                contours[c].nodes = contours[c].nodes.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            }
            contours.removeAll { $0.nodes.count < 2 }
            if contours.isEmpty {
                doc.layers[l].items.remove(at: i)
                selection.remove(id)
            } else {
                doc.layers[l].items[i].kind = .path(contours)
            }
        }
        nodeSelection = []
    }

    /// Smooth ↔ corner for the selected points.
    func toggleSmooth() {
        guard !nodeSelection.isEmpty else { return }
        checkpoint()
        for r in nodeSelection {
            guard var n = node(r), let c = item(r.item)?.contours?[r.contour] else { continue }
            if n.isCorner {
                let count = c.nodes.count
                let prev = c.nodes[(r.node - 1 + count) % count].p, next = c.nodes[(r.node + 1) % count].p
                let t = CGPoint(x: (next.x - prev.x) / 6, y: (next.y - prev.y) / 6)
                n.i = CGPoint(x: n.p.x - t.x, y: n.p.y - t.y)
                n.o = CGPoint(x: n.p.x + t.x, y: n.p.y + t.y)
            } else {
                n.i = n.p; n.o = n.p
            }
            setNode(r, n)
        }
    }

    // MARK: Layers

    func addLayer() {
        checkpoint()
        let l = ArtLayer(name: "Layer \(doc.layers.count + 1)", colorIndex: doc.layers.count % Self.layerColors.count)
        doc.layers.insert(l, at: layerIndex + 1)
        layerID = l.id
    }

    func deleteLayer(_ id: UUID) {
        guard doc.layers.count > 1 else { return flash("Artwork needs at least one layer") }
        checkpoint()
        doc.layers.removeAll { $0.id == id }
        fixSelection()
    }

    func moveLayer(_ id: UUID, up: Bool) {
        guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i + 1 : i - 1
        guard doc.layers.indices.contains(j) else { return }
        checkpoint()
        doc.layers.swapAt(i, j)
    }

    func updateLayer(_ id: UUID, checkpoint shouldCheckpoint: Bool = true, _ change: (inout ArtLayer) -> Void) {
        guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&doc.layers[i])
        if !doc.layers[i].visible || doc.layers[i].locked { selection.subtract(doc.layers[i].items.map(\.id)) }
    }

    func moveSelection(toLayer id: UUID) {
        guard let target = doc.layers.firstIndex(where: { $0.id == id }), !selection.isEmpty else { return }
        checkpoint()
        let moving = selectedItems
        for l in doc.layers.indices { doc.layers[l].items.removeAll { selection.contains($0.id) } }
        doc.layers[target].items += moving
        layerID = id
    }

    // MARK: Clipboard

    static let pasteboardType = NSPasteboard.PasteboardType("app.easel.quill.items")

    func copySelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let assets = doc.images.filter { a in items.contains { if case .image(a.id, _) = $0.kind { return true } else { return false } } }
        guard let data = try? JSONEncoder().encode(Clip(items: items, images: assets)) else { return }
        var sub = doc
        sub.layers = [ArtLayer(name: "Copy", items: items)]
        sub.background = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        // Other apps get a PDF and a PNG of the selection, cropped to it.
        if let b = selectionBounds?.insetBy(dx: -4, dy: -4) {
            var cropped = sub
            cropped.width = b.width; cropped.height = b.height
            for l in cropped.layers.indices { for i in cropped.layers[l].items.indices {
                let t = CGAffineTransform(translationX: -b.minX, y: -b.minY)
                var it = cropped.layers[l].items[i]
                if case .path(let c) = it.kind {
                    it.kind = .path(c.map { Contour(nodes: $0.nodes.map { $0.applying(it.transform.cg.concatenating(t)) }, closed: $0.closed) })
                    it.transform = .identity
                } else {
                    it.transform = Affine(it.transform.cg.concatenating(t))
                }
                cropped.layers[l].items[i] = it
            } }
            pb.setData(QuillRenderer.pdf(cropped, images: images), forType: .pdf)
            if let png = Bitmap.png(QuillRenderer.image(cropped, images: images, scale: 2, background: false)) { pb.setData(png, forType: .png) }
        }
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteboardType), let clip = try? JSONDecoder().decode(Clip.self, from: data) {
            guard canAdd else { return }
            checkpoint()
            for a in clip.images where doc.image(a.id) == nil { doc.images.append(a) }
            var ids: Set<UUID> = []
            var groupMap: [UUID: UUID] = [:]
            for var item in clip.items {
                item.id = UUID()
                if let g = item.group { item.group = groupMap[g] ?? { let n = UUID(); groupMap[g] = n; return n }() }
                doc.layers[layerIndex].items.append(item)
                ids.insert(item.id)
            }
            selection = ids
            transformSelection(CGAffineTransform(translationX: 12, y: 12))
            return
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let img = Bitmap.load(data: data) {
            placeImage(img, name: "Pasted Image")
        }
    }

    private struct Clip: Codable {
        var items: [Item]
        var images: [ImageAsset]
    }

    // MARK: Images

    static var mediaFolder: URL {
        let dir = AppLink.folder("Quill").appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func placeImage(_ cg: CGImage, name: String, at center: CGPoint? = nil, checkpoint shouldCheckpoint: Bool = true) -> Bool {
        guard canAdd, let png = Bitmap.png(cg) else { return false }
        let copy = Self.mediaFolder.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? png.write(to: copy)) != nil else { return false }
        let size = CGSize(width: cg.width, height: cg.height)
        let asset = ImageAsset(url: copy, size: size)
        if shouldCheckpoint { checkpoint() }
        doc.images.append(asset)
        let fit = min(1, doc.width * 0.6 / size.width, doc.height * 0.6 / size.height)
        let c = center ?? CGPoint(x: doc.width / 2, y: doc.height / 2)
        var item = Item(name: name, kind: .image(asset.id, size))
        item.fill = nil
        item.stroke = nil
        item.transform = Affine(CGAffineTransform(translationX: c.x - size.width * fit / 2, y: c.y - size.height * fit / 2).scaledBy(x: fit, y: fit))
        return add(item, checkpoint: false)
    }

    func placeImages(_ urls: [URL], at point: CGPoint? = nil) {
        var placed = 0
        for url in urls {
            guard let cg = Bitmap.load(url: url) else { continue }
            if placeImage(cg, name: url.deletingPathExtension().lastPathComponent, at: point, checkpoint: placed == 0) { placed += 1 }
        }
        if placed == 0 { return flash("Couldn’t place those files") }
        tool = .select
        let fromEasel = urls.contains { AppLink.isInInbox($0, of: .quill) }
        flash(fromEasel ? "Added from Easel" : "Placed \(placed) image\(placed == 1 ? "" : "s")")
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .quillProject]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "quill" }) { return openProject(project) }
        placeImages(urls)
    }

    // MARK: Files

    func newDocument(width: Double, height: Double, transparent: Bool) {
        guard confirmDiscard() else { return }
        var d = ArtDocument()
        d.width = width
        d.height = height
        d.background = transparent ? nil : .white
        load(d, url: nil)
    }

    private func load(_ d: ArtDocument, url: URL?) {
        doc = d
        layerID = d.layers[0].id
        selection = []
        nodeSelection = []
        editingTextID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        documentURL = url
        documentName = url?.deletingPathExtension().lastPathComponent ?? "Untitled"
        isDirty = false
        fitRequest += 1
    }

    func save(as saveAs: Bool = false) {
        var url = documentURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.quillProject]
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
            load(try JSONDecoder().decode(ArtDocument.self, from: Data(contentsOf: url)), url: url)
            let missing = doc.images.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
            if missing > 0 { flash("\(missing) placed image\(missing == 1 ? " is" : "s are") missing") }
        } catch {
            flash("Couldn’t open that artwork")
        }
    }

    func confirmDiscard() -> Bool {
        guard isDirty, !doc.allItems.isEmpty else { return true }
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

    enum ExportFormat: String, CaseIterable, Identifiable {
        case png = "PNG", jpeg = "JPEG", svg = "SVG", pdf = "PDF"
        var id: String { rawValue }
        var ext: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
        var note: String {
            switch self {
            case .png: return "Pixels, with transparency where there’s no background."
            case .jpeg: return "Small photo-style file; transparent areas become white."
            case .svg: return "Vector for the web and other design apps."
            case .pdf: return "Vector, for print and for reading in Folio."
            }
        }
    }

    func exportData(_ format: ExportFormat, scale: CGFloat = 1) -> Data? {
        switch format {
        case .png: return Bitmap.png(QuillRenderer.image(doc, images: images, scale: scale))
        case .jpeg:
            var opaque = doc
            if opaque.background == nil { opaque.background = .white }
            return QuillRenderer.encode(QuillRenderer.image(opaque, images: images, scale: scale), type: .jpeg)
        case .svg: return QuillRenderer.svg(doc, images: images).data(using: .utf8)
        case .pdf: return QuillRenderer.pdf(doc, images: images)
        }
    }

    func export(_ format: ExportFormat, scale: CGFloat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).\(format.ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = exportData(format, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            flash("Exported \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    /// Sends the artwork to another app: a PDF for Folio (stays vector), a 2× PNG for the others.
    func send(to app: AppLink.App) {
        guard !doc.allItems.isEmpty else { return flash("Draw something first") }
        let format: ExportFormat = app == .folio ? .pdf : .png
        let url = AppLink.newInboxURL(for: app, named: documentName, ext: format.ext)
        do {
            guard let data = exportData(format, scale: 2) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
        } catch {
            return flash("Couldn’t send: \(error.localizedDescription)")
        }
        if AppLink.open(url, in: app) { flash("Sent to \(app.rawValue)") } else { flash("Couldn’t find \(app.rawValue). Build it with Scripts/build_app.sh") }
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
