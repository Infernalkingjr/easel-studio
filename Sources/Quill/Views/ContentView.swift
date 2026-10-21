import SwiftUI
import EaselKit

struct ContentView: View {
    @Bindable var studio: QuillStudio

    var body: some View {
        HStack(spacing: 0) {
            ToolPalette(studio: studio)
            Divider()
            ZStack {
                CanvasView(studio: studio)
                Overlays(studio: studio)
            }
            Divider()
            Inspector(studio: studio).frame(width: 290)
        }
        .background(KeyCatcher(studio: studio))
        .frame(minWidth: 1100, minHeight: 700)
        .navigationTitle(studio.documentName)
        .navigationSubtitle("\(Int(studio.doc.width))×\(Int(studio.doc.height))\(studio.isDirty ? " — Edited" : "")")
        .toolbar { MainToolbar(studio: studio) }
        .sheet(isPresented: $studio.showExport) { ExportSheet(studio: studio) }
        .sheet(isPresented: $studio.showNewDocument) { NewDocumentSheet(studio: studio) }
        .preferredColorScheme(.dark)
    }
}

extension Notification.Name {
    /// object: zoom factor, or 0 for actual size.
    static let quillZoom = Notification.Name("QuillZoom")
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        self.init(r: n.redComponent, g: n.greenComponent, b: n.blueComponent, a: n.alphaComponent)
    }
}

/// Points the shared macOS color panel at one color at a time.
@MainActor
final class ColorPanelLink: NSObject {
    static let shared = ColorPanelLink()
    private var apply: ((RGBA) -> Void)?

    func edit(_ current: RGBA, apply: @escaping (RGBA) -> Void) {
        self.apply = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = NSColor(srgbRed: current.r, green: current.g, blue: current.b, alpha: current.a)
        self.apply = apply
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        let c = panel.color.usingColorSpace(.sRGB) ?? .black
        apply?(RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent))
    }
}

struct ToolPalette: View {
    @Bindable var studio: QuillStudio

    var body: some View {
        VStack(spacing: 4) {
            ForEach(QuillTool.allCases) { tool in
                Button { studio.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 30)
                        .foregroundStyle(studio.tool == tool ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(studio.tool == tool ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.key.map { "\(tool.title) (\(String($0).uppercased()))" } ?? tool.title)
            }
            Spacer()
            ColorWells(studio: studio)
        }
        .padding(.vertical, 10)
        .frame(width: 54)
        .background(.bar)
    }
}

/// Illustrator's overlapping fill (front) and stroke (back) swatches.
struct ColorWells: View {
    let studio: QuillStudio

    var body: some View {
        let shown = studio.selectedItems.last
        let fill = shown.map { $0.fill } ?? studio.fill
        let stroke = shown.map { $0.stroke } ?? studio.stroke
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                well(stroke, isStroke: true)
                    .offset(x: 13, y: 13)
                    .help("Stroke color")
                    .onTapGesture { edit(stroke: true, current: stroke) }
                well(fill, isStroke: false)
                    .help("Fill color")
                    .onTapGesture { edit(stroke: false, current: fill) }
            }
            .frame(width: 40, height: 40, alignment: .topLeading)
            HStack(spacing: 4) {
                Button { studio.swapColors() } label: { Image(systemName: "arrow.left.arrow.right").font(.system(size: 9)) }
                    .help("Swap fill and stroke (⇧X)")
                Button { studio.style { $0.fill = nil; $0.gradient = nil } } label: { Image(systemName: "slash.circle").font(.system(size: 9)) }
                    .help("No fill")
            }
            .buttonStyle(.plain)
        }
    }

    private func edit(stroke: Bool, current: RGBA?) {
        if !studio.selection.isEmpty { studio.checkpoint() }
        ColorPanelLink.shared.edit(current ?? .black) { c in
            studio.style(checkpoint: false) { item in
                if stroke { item.stroke = c } else { item.fill = c; item.gradient = nil }
            }
        }
    }

    private func well(_ c: RGBA?, isStroke: Bool) -> some View {
        ZStack {
            if let c {
                RoundedRectangle(cornerRadius: 4).fill(c.color)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                Path { p in p.move(to: CGPoint(x: 2, y: 24)); p.addLine(to: CGPoint(x: 24, y: 2)) }.stroke(Color.red, lineWidth: 2)
            }
            if isStroke { RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: .windowBackgroundColor)).frame(width: 10, height: 10) }
        }
        .frame(width: 26, height: 26)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }
}

struct Overlays: View {
    let studio: QuillStudio

    var body: some View {
        VStack {
            HStack {
                Text(studio.tool.hint).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
            .padding(10)
            Spacer()
            if let toast = studio.toast {
                Text(toast)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 14)
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.toast)
        .allowsHitTesting(false)
    }
}

// MARK: Inspector

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct Row: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var onBegin: () -> Void = {}
    let set: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range) { if $0 { onBegin() } }.controlSize(.small)
        }
    }
}

/// A number box that applies on Return.
private struct NumberField: View {
    let label: String
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            TextField("", value: Binding(get: { (value * 10).rounded() / 10 }, set: set), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }
}

struct Inspector: View {
    @Bindable var studio: QuillStudio

    private var items: [Item] { studio.selectedItems }
    private var first: Item? { items.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let b = studio.selectionBounds { transform(b) }
                appearance
                if studio.tool == .polygon || studio.tool == .star { shapeOptions }
                if studio.tool == .text || items.contains(where: \.isText) { character }
                if !items.isEmpty { arrange }
                LayersPanel(studio: studio)
                document
            }
            .padding(14)
        }
        .background(.bar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(items.isEmpty ? studio.tool.title : (items.count == 1 ? first!.name : "\(items.count) objects"))
                .font(.title3.weight(.semibold)).lineLimit(1)
            Text(items.isEmpty ? "Settings below apply to new objects." : (Set(items.compactMap(\.group)).count == 1 && items.count > 1 ? "Group" : kindName))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var kindName: String {
        guard let first else { return "" }
        switch first.kind {
        case .path(let c): return "Path · \(c.reduce(0) { $0 + $1.nodes.count }) points"
        case .text: return "Text"
        case .image(_, let s): return "Image · \(Int(s.width))×\(Int(s.height)) px"
        }
    }

    private func transform(_ b: CGRect) -> some View {
        Section("Transform") {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField(label: "X", value: b.minX) { studio.setFrame(x: $0) }
                    NumberField(label: "Y", value: b.minY) { studio.setFrame(y: $0) }
                }
                GridRow {
                    NumberField(label: "W", value: b.width) { studio.setFrame(w: $0) }
                    NumberField(label: "H", value: b.height) { studio.setFrame(h: $0) }
                }
            }
            HStack {
                Button { studio.rotateSelection(by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate 90° left")
                Button { studio.rotateSelection(by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate 90° right")
                Button { studio.flip(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip horizontal")
                Button { studio.flip(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }.help("Flip vertical")
            }
            .controlSize(.small)
        }
    }

    private var fillValue: RGBA? { first.map { $0.fill } ?? studio.fill }
    private var strokeValue: RGBA? { first.map { $0.stroke } ?? studio.stroke }
    private var widthValue: Double { first?.strokeWidth ?? studio.strokeWidth }

    private var appearance: some View {
        Section("Appearance") {
            HStack {
                Toggle("Fill", isOn: Binding(get: { fillValue != nil || first?.gradient != nil }, set: { on in
                    studio.style { $0.fill = on ? ($0.fill ?? RGBA(r: 1, g: 0.8, b: 0.2)) : nil; if !on { $0.gradient = nil } }
                }))
                Spacer()
                if first?.gradient == nil, let f = fillValue {
                    ColorPicker("", selection: Binding(get: { f.color }, set: { c in
                        studio.coalescedCheckpoint("fill")
                        studio.style(checkpoint: false) { $0.fill = RGBA(c) }
                    })).labelsHidden()
                }
            }
            if !items.isEmpty, !items.contains(where: { if case .image = $0.kind { return true } else { return false } }) {
                gradient
            }
            HStack {
                Toggle("Stroke", isOn: Binding(get: { strokeValue != nil }, set: { on in
                    studio.style { $0.stroke = on ? ($0.stroke ?? .black) : nil }
                }))
                Spacer()
                if let s = strokeValue {
                    ColorPicker("", selection: Binding(get: { s.color }, set: { c in
                        studio.coalescedCheckpoint("stroke")
                        studio.style(checkpoint: false) { $0.stroke = RGBA(c) }
                    })).labelsHidden()
                }
            }
            if strokeValue != nil {
                Row(title: "Weight", value: widthValue, range: 0...60, format: { String(format: "%.1f pt", $0) },
                    onBegin: { if !items.isEmpty { studio.checkpoint() } }) { v in studio.style(checkpoint: false) { $0.strokeWidth = v } }
                if let first {
                    HStack {
                        Picker("Cap", selection: Binding(get: { first.cap }, set: { v in studio.style { $0.cap = v } })) {
                            ForEach(LineCap.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Join", selection: Binding(get: { first.join }, set: { v in studio.style { $0.join = v } })) {
                            ForEach(LineJoin.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    .controlSize(.small)
                    Toggle("Dashed", isOn: Binding(get: { first.dashed }, set: { v in studio.style { $0.dashed = v } }))
                }
            }
            if let first {
                Row(title: "Opacity", value: first.opacity, range: 0...1, format: { "\(Int($0 * 100))%" },
                    onBegin: { studio.checkpoint() }) { v in studio.style(checkpoint: false) { $0.opacity = v } }
            }
        }
    }

    @ViewBuilder private var gradient: some View {
        let g = first?.gradient
        Toggle("Gradient fill", isOn: Binding(get: { g != nil }, set: { on in
            studio.style { item in
                item.gradient = on ? FillGradient(from: item.fill ?? RGBA(r: 1, g: 0.8, b: 0.2), to: RGBA(r: 0.9, g: 0.2, b: 0.5)) : nil
                if !on && item.fill == nil { item.fill = RGBA(r: 1, g: 0.8, b: 0.2) }
            }
        }))
        if let g {
            HStack {
                ColorPicker("From", selection: Binding(get: { g.from.color }, set: { c in
                    studio.coalescedCheckpoint("gfrom"); studio.style(checkpoint: false) { $0.gradient?.from = RGBA(c) }
                }))
                ColorPicker("To", selection: Binding(get: { g.to.color }, set: { c in
                    studio.coalescedCheckpoint("gto"); studio.style(checkpoint: false) { $0.gradient?.to = RGBA(c) }
                }))
            }
            Picker("", selection: Binding(get: { g.radial }, set: { v in studio.style { $0.gradient?.radial = v } })) {
                Text("Linear").tag(false)
                Text("Radial").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if !g.radial {
                Row(title: "Angle", value: g.angle, range: -180...180, format: { "\(Int($0))°" },
                    onBegin: { studio.checkpoint() }) { v in studio.style(checkpoint: false) { $0.gradient?.angle = v } }
            }
        }
    }

    private var shapeOptions: some View {
        Section(studio.tool.title) {
            if studio.tool == .polygon {
                Stepper("Sides: \(studio.sides)", value: $studio.sides, in: 3...24)
            } else {
                Stepper("Points: \(studio.starPoints)", value: $studio.starPoints, in: 3...24)
                Row(title: "Inner radius", value: studio.starInner, range: 0.1...0.95, format: { "\(Int($0 * 100))%" }) { studio.starInner = $0 }
            }
        }
    }

    private var spec: TextSpec {
        for item in items.reversed() { if case .text(let s) = item.kind { return s } }
        return TextSpec(string: "", font: studio.font, size: studio.fontSize)
    }

    private var character: some View {
        let s = spec
        let family = NSFont(name: s.font, size: 12)?.familyName ?? "Helvetica Neue"
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return Section("Character") {
            Picker("Font", selection: Binding(get: { family }, set: { fam in
                let m = NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []
                // Keep the weight if the new family has it.
                let style = members.first { ($0[0] as? String) == s.font }?[1] as? String
                let pick = m.first { ($0[1] as? String) == style } ?? m.first { ($0[1] as? String) == "Regular" } ?? m.first
                if let name = pick?[0] as? String { studio.setText { $0.font = name } }
            })) {
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Picker("Style", selection: Binding(get: { s.font }, set: { v in studio.setText { $0.font = v } })) {
                ForEach(members.compactMap { $0[0] as? String }, id: \.self) { name in
                    Text(members.first { ($0[0] as? String) == name }?[1] as? String ?? name).tag(name)
                }
            }
            Row(title: "Size", value: s.size, range: 6...400, format: { "\(Int($0)) pt" },
                onBegin: { studio.checkpoint() }) { v in studio.setText(checkpoint: false) { $0.size = v.rounded() } }
            Row(title: "Tracking", value: s.tracking, range: -10...60, format: { String(format: "%.1f", $0) },
                onBegin: { studio.checkpoint() }) { v in studio.setText(checkpoint: false) { $0.tracking = v } }
            Row(title: "Leading", value: s.leading, range: 0.6...3, format: { String(format: "%.2f×", $0) },
                onBegin: { studio.checkpoint() }) { v in studio.setText(checkpoint: false) { $0.leading = v } }
            Picker("", selection: Binding(get: { s.alignment }, set: { v in studio.setText { $0.alignment = v } })) {
                Image(systemName: "text.alignleft").tag(0)
                Image(systemName: "text.aligncenter").tag(1)
                Image(systemName: "text.alignright").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            if items.contains(where: \.isText) {
                Button("Create Outlines") { studio.createOutlines() }.help("Turn letters into editable shapes (⇧⌘O)")
            }
        }
    }

    private var arrange: some View {
        Section("Align & Arrange") {
            HStack(spacing: 2) {
                ForEach(Array(AlignEdge.allCases.enumerated()), id: \.offset) { _, edge in
                    Button { studio.align(edge) } label: { Image(systemName: edge.symbol).frame(width: 24) }
                }
                Button { studio.distribute(horizontal: true) } label: { Image(systemName: "distribute.horizontal.center").frame(width: 24) }
                    .help("Distribute horizontally")
                Button { studio.distribute(horizontal: false) } label: { Image(systemName: "distribute.vertical.center").frame(width: 24) }
                    .help("Distribute vertically")
            }
            .buttonStyle(.borderless)
            Text(items.count == 1 || Set(items.compactMap(\.group)).count == 1 ? "Aligns to the artboard" : "Aligns to the selection")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Pathfinder").font(.callout)
                Spacer()
                ForEach(Pathfinder.allCases) { op in
                    Button { studio.pathfinder(op) } label: { Image(systemName: op.symbol).frame(width: 26) }.help(op.rawValue)
                }
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                Button("Group") { studio.group() }.disabled(items.count < 2)
                Button("Ungroup") { studio.ungroup() }.disabled(!items.contains { $0.group != nil })
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                Button("To Front") { studio.arrange(.front) }
                Button("Forward") { studio.arrange(.forward) }
                Button("Backward") { studio.arrange(.backward) }
                Button("To Back") { studio.arrange(.back) }
            }
            .controlSize(.small)
        }
    }

    private var document: some View {
        Section("Artboard") {
            HStack {
                Text("\(Int(studio.doc.width)) × \(Int(studio.doc.height)) pt").font(.callout.monospacedDigit())
                Spacer()
                Button("New…") { studio.showNewDocument = true }.controlSize(.small)
            }
            Picker("Background", selection: Binding(get: { studio.doc.background == nil ? 1 : 0 }, set: { v in
                studio.checkpoint()
                studio.doc.background = v == 1 ? nil : (studio.doc.background ?? .white)
            })) {
                Text("Color").tag(0)
                Text("Transparent").tag(1)
            }
            .pickerStyle(.segmented)
            if let bg = studio.doc.background {
                ColorPicker("Background color", selection: Binding(get: { bg.color }, set: {
                    studio.coalescedCheckpoint("background")
                    studio.doc.background = RGBA($0)
                }), supportsOpacity: false)
            }
        }
    }
}

struct LayersPanel: View {
    @Bindable var studio: QuillStudio
    @State private var renaming: UUID?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LAYERS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { studio.addLayer() } label: { Image(systemName: "plus") }.help("New layer")
                Button { studio.deleteLayer(studio.layerID) } label: { Image(systemName: "trash") }.help("Delete layer")
            }
            .buttonStyle(.borderless)
            VStack(spacing: 1) {
                ForEach(studio.doc.layers.reversed()) { layer in
                    row(layer)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2)))
        }
    }

    private func row(_ layer: ArtLayer) -> some View {
        let active = layer.id == studio.layerID
        let hasSelection = layer.items.contains { studio.selection.contains($0.id) }
        return HStack(spacing: 6) {
            Button { studio.updateLayer(layer.id) { $0.visible.toggle() } } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash").frame(width: 18)
            }
            Button { studio.updateLayer(layer.id) { $0.locked.toggle() } } label: {
                Image(systemName: layer.locked ? "lock.fill" : "lock.open").frame(width: 18).opacity(layer.locked ? 1 : 0.35)
            }
            Rectangle().fill(Color(nsColor: QuillStudio.layerColors[layer.colorIndex % QuillStudio.layerColors.count])).frame(width: 3, height: 16)
            if renaming == layer.id {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit { studio.updateLayer(layer.id) { $0.name = name }; renaming = nil }
            } else {
                Text(layer.name).lineLimit(1)
                    .onTapGesture(count: 2) { name = layer.name; renaming = layer.id }
            }
            Spacer()
            Text("\(layer.items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if hasSelection { Image(systemName: "square.fill").font(.system(size: 7)).foregroundStyle(Color.accentColor) }
            Menu {
                Button("Move Up") { studio.moveLayer(layer.id, up: true) }
                Button("Move Down") { studio.moveLayer(layer.id, up: false) }
                Button("Move Selection Here") { studio.moveSelection(toLayer: layer.id) }.disabled(studio.selection.isEmpty)
                Button("Select Everything on Layer") { studio.select(Set(layer.items.map(\.id))) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(active ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { studio.layerID = layer.id }
    }
}

// MARK: Toolbar & sheets

struct MainToolbar: ToolbarContent {
    let studio: QuillStudio

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { studio.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(studio.undoStack.isEmpty)
            Button { studio.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(studio.redoStack.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { studio.importPanel() } label: { Label("Place", systemImage: "photo.badge.plus") }.help("Place an image (⇧⌘P)")
            Menu {
                Button("Folio (PDF)") { studio.send(to: .folio) }
                Button("Easel (photo)") { studio.send(to: .easel) }
                Button("Reel (video)") { studio.send(to: .reel) }
                Button("Flip (animation)") { studio.send(to: .flip) }
            } label: { Label("Send to", systemImage: "arrow.up.forward.app") }
            Button { studio.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.help("Export (⌘E)")
        }
    }
}

struct ExportSheet: View {
    let studio: QuillStudio
    @AppStorage("quillExportFormat") private var format = QuillStudio.ExportFormat.png.rawValue
    @AppStorage("quillExportScale") private var scale = 2.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let f = QuillStudio.ExportFormat(rawValue: format) ?? .png
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Artwork").font(.title2.weight(.semibold))
            Picker("Format", selection: $format) {
                ForEach(QuillStudio.ExportFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(f.note).font(.caption).foregroundStyle(.secondary)
            if f == .png || f == .jpeg {
                Picker("Scale", selection: $scale) {
                    ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("\(Int(studio.doc.width * scale)) × \(Int(studio.doc.height * scale)) px").font(.callout.monospacedDigit())
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let s = scale
                    dismiss()
                    DispatchQueue.main.async { studio.export(f, scale: s) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

struct NewDocumentSheet: View {
    let studio: QuillStudio
    @State private var width = 1200.0
    @State private var height = 800.0
    @State private var transparent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Artwork").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(ArtDocument.presets, id: \.0) { p in
                    Button(p.0) { width = p.1; height = p.2 }
                        .buttonStyle(.bordered)
                        .tint(width == p.1 && height == p.2 ? .accentColor : nil)
                }
            }
            HStack {
                TextField("Width", value: $width, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("×")
                TextField("Height", value: $height, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("pt").foregroundStyle(.secondary)
            }
            Toggle("Transparent background", isOn: $transparent)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    dismiss()
                    studio.newDocument(width: max(16, width), height: max(16, height), transparent: transparent)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

/// Illustrator-style single keys. Ignored while typing.
struct KeyCatcher: NSViewRepresentable {
    let studio: QuillStudio

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.install(studio, v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(_ studio: QuillStudio, _ view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] e in
                guard let window = view?.window, e.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return e }
                guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
                let shift = e.modifierFlags.contains(.shift)
                let step: CGFloat = shift ? 10 : 1
                switch e.keyCode {
                case 36, 76: studio.finishPen(); return nil                       // return
                case 53:                                                           // esc
                    if studio.penNodes.isEmpty { studio.deselect() } else { studio.finishPen() }
                    return nil
                case 51, 117: studio.deleteSelection(); return nil
                case 123: studio.nudge(-step, 0); return nil
                case 124: studio.nudge(step, 0); return nil
                case 125: studio.nudge(0, step); return nil
                case 126: studio.nudge(0, -step); return nil
                case 49: return e                                                  // space: canvas pans
                default: break
                }
                guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return e }
                if shift && ch == "x" { studio.swapColors(); return nil }
                if ch == "d" { studio.defaultColors(); return nil }
                if !shift, let tool = QuillTool.allCases.first(where: { $0.key == ch }) { studio.tool = tool; return nil }
                return e
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct QuillCommands: Commands {
    let studio: QuillStudio

    @MainActor
    private func textAction(_ selector: Selector) -> Bool {
        guard let r = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return NSApp.sendAction(selector, to: r, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Artwork…") { studio.showNewDocument = true }.keyboardShortcut("n")
            Button("Open…") { studio.importPanel() }.keyboardShortcut("o")
            Button("Place…") { studio.importPanel() }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { studio.save() }.keyboardShortcut("s")
            Button("Save As…") { studio.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export…") { studio.showExport = true }.keyboardShortcut("e")
            Menu("Send to") {
                Button("Folio") { studio.send(to: .folio) }
                Button("Easel") { studio.send(to: .easel) }
                Button("Reel") { studio.send(to: .reel) }
                Button("Flip") { studio.send(to: .flip) }
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if !textAction(Selector(("undo:"))) { studio.undo() } }.keyboardShortcut("z")
            Button("Redo") { if !textAction(Selector(("redo:"))) { studio.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { if !textAction(Selector(("cut:"))) { studio.cutSelection() } }.keyboardShortcut("x")
            Button("Copy") { if !textAction(Selector(("copy:"))) { studio.copySelection() } }.keyboardShortcut("c")
            Button("Paste") { if !textAction(Selector(("paste:"))) { studio.paste() } }.keyboardShortcut("v")
            Button("Duplicate") { studio.duplicateSelection() }.keyboardShortcut("d")
            Button("Delete") { studio.deleteSelection() }
            Divider()
            Button("Select All") { if !textAction(Selector(("selectAll:"))) { studio.selectAll() } }.keyboardShortcut("a")
            Button("Deselect") { studio.deselect() }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandMenu("Object") {
            Button("Group") { studio.group() }.keyboardShortcut("g")
            Button("Ungroup") { studio.ungroup() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Bring to Front") { studio.arrange(.front) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Bring Forward") { studio.arrange(.forward) }.keyboardShortcut("]")
            Button("Send Backward") { studio.arrange(.backward) }.keyboardShortcut("[")
            Button("Send to Back") { studio.arrange(.back) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Rotate 90° Right") { studio.rotateSelection(by: 90) }
            Button("Flip Horizontal") { studio.flip(horizontal: true) }
            Button("Flip Vertical") { studio.flip(horizontal: false) }
            Divider()
            Menu("Pathfinder") {
                ForEach(Pathfinder.allCases) { op in Button(op.rawValue) { studio.pathfinder(op) } }
            }
            Button("Create Outlines") { studio.createOutlines() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Smooth / Corner Point") { studio.toggleSmooth() }
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { NotificationCenter.default.post(name: .quillZoom, object: 1.5) }.keyboardShortcut("=")
            Button("Zoom Out") { NotificationCenter.default.post(name: .quillZoom, object: 1 / 1.5) }.keyboardShortcut("-")
            Button("Fit Artboard") { studio.fitRequest += 1 }.keyboardShortcut("0")
            Button("Actual Size") { NotificationCenter.default.post(name: .quillZoom, object: 0.0) }.keyboardShortcut("1")
            Divider()
        }
    }
}
