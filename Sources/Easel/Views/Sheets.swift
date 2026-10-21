import EaselKit
import SwiftUI

private struct SheetFrame<Content: View>: View {
    let title: String
    let actionTitle: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { action(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct NewDocumentSheet: View {
    let editor: Editor
    @State private var width = 1920.0
    @State private var height = 1080.0
    @State private var background = NewBackground.white
    @State private var color = Color.blue

    private let presets: [(String, Double, Double)] = [
        ("HD 1920×1080", 1920, 1080), ("4K 3840×2160", 3840, 2160), ("Square 1080", 1080, 1080),
        ("Story 1080×1920", 1080, 1920), ("A4 300dpi", 2480, 3508), ("Icon 1024", 1024, 1024),
    ]

    var body: some View {
        SheetFrame(title: "New Canvas", actionTitle: "Create", action: {
            editor.newDocument(size: CGSize(width: width, height: height), background: background, color: color)
        }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(presets, id: \.0) { p in
                    Button { width = p.1; height = p.2 } label: {
                        Text(p.0).font(.callout).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(width == p.1 && height == p.2 ? .accentColor : nil)
                }
                if let clip = NSImage(pasteboard: .general) {
                    Button { width = clip.size.width; height = clip.size.height } label: {
                        Text("Clipboard size").font(.callout).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Form {
                SizeFields(width: $width, height: $height, lockable: false)
                Picker("Background", selection: $background) {
                    ForEach(NewBackground.allCases) { Text($0.rawValue).tag($0) }
                }
                if background == .color { ColorPicker("Color", selection: $color, supportsOpacity: false) }
            }
        }
    }
}

private struct SizeFields: View {
    @Binding var width: Double
    @Binding var height: Double
    var lockable = true
    var aspect: Double = 1
    @State private var locked = true

    var body: some View {
        HStack {
            TextField("Width", value: Binding(get: { width }, set: { v in
                width = max(1, v)
                if lockable && locked { height = max(1, (v / aspect).rounded()) }
            }), format: .number.grouping(.never))
            Text("×")
            TextField("Height", value: Binding(get: { height }, set: { v in
                height = max(1, v)
                if lockable && locked { width = max(1, (v * aspect).rounded()) }
            }), format: .number.grouping(.never))
            Text("px").foregroundStyle(.secondary)
            if lockable {
                Toggle(isOn: $locked) { Image(systemName: locked ? "lock.fill" : "lock.open") }
                    .toggleStyle(.button)
                    .help("Keep proportions")
            }
        }
    }
}

struct ResizeSheet: View {
    let editor: Editor
    let canvasMode: Bool
    @State private var width = 0.0
    @State private var height = 0.0
    @State private var anchor = UnitPoint.center

    private let anchors: [UnitPoint] = [.topLeading, .top, .topTrailing, .leading, .center, .trailing, .bottomLeading, .bottom, .bottomTrailing]

    var body: some View {
        SheetFrame(title: canvasMode ? "Canvas Size" : "Resize Image", actionTitle: canvasMode ? "Change" : "Resize", action: {
            let size = CGSize(width: width, height: height)
            if canvasMode { editor.resizeCanvas(to: size, anchor: anchor) } else { editor.resizeImage(to: size) }
        }) {
            Text("Currently \(Int(editor.canvasSize.width)) × \(Int(editor.canvasSize.height)) px")
                .foregroundStyle(.secondary)
            Form {
                SizeFields(width: $width, height: $height, lockable: !canvasMode,
                           aspect: editor.canvasSize.width / editor.canvasSize.height)
                if !canvasMode {
                    HStack {
                        ForEach([25, 50, 75, 150, 200], id: \.self) { pct in
                            Button("\(pct)%") {
                                width = (editor.canvasSize.width * Double(pct) / 100).rounded()
                                height = (editor.canvasSize.height * Double(pct) / 100).rounded()
                            }
                        }
                    }
                } else {
                    LabeledContent("Anchor") {
                        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                            ForEach(0..<3) { row in
                                GridRow {
                                    ForEach(0..<3) { col in
                                        let a = anchors[row * 3 + col]
                                        Button { anchor = a } label: {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(anchor == a ? Color.accentColor : Color.primary.opacity(0.12))
                                                .frame(width: 18, height: 18)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            width = editor.canvasSize.width
            height = editor.canvasSize.height
        }
    }
}

struct LayerResizeSheet: View {
    let editor: Editor
    @State private var width = 0.0
    @State private var height = 0.0
    @State private var original = CGSize(width: 1, height: 1)

    var body: some View {
        SheetFrame(title: "Resize Layer", actionTitle: "Resize", action: {
            editor.resizeActiveLayer(to: CGSize(width: width, height: height))
        }) {
            Text("“\(editor.activeLayer?.name ?? "")” is \(Int(original.width)) × \(Int(original.height)) px")
                .foregroundStyle(.secondary)
            Form {
                SizeFields(width: $width, height: $height, aspect: original.width / original.height)
                HStack {
                    ForEach([25, 50, 75, 150, 200], id: \.self) { pct in
                        Button("\(pct)%") {
                            width = (original.width * Double(pct) / 100).rounded()
                            height = (original.height * Double(pct) / 100).rounded()
                        }
                    }
                }
            }
        }
        .onAppear {
            if let layer = editor.activeLayer, let b = editor.contentBounds(layer) { original = b.size }
            width = original.width
            height = original.height
        }
    }
}

struct ExportSheet: View {
    let editor: Editor
    @AppStorage("exportFormat") private var format = ExportFormat.png
    @AppStorage("exportLayered") private var layered = false
    @AppStorage("exportQuality") private var quality = 0.9
    @State private var scale = 1.0
    @State private var estimate: String?

    private var groups: [(String, [ExportFormat])] {
        ["Everyday", "Pro & Print", "Icons"].map { g in (g, ExportFormat.allCases.filter { $0.group == g }) }
    }

    var body: some View {
        SheetFrame(title: "Export", actionTitle: layered ? "Save…" : "Export…", action: {
            DispatchQueue.main.async {
                if layered { editor.saveAs() } else { editor.export(format: format, quality: quality, scale: scale) }
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("KEEP LAYERS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                FormatChip(title: "Easel Project (.easel)", selected: layered) { layered = true }
                ForEach(groups, id: \.0) { group in
                    Text(group.0.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                        ForEach(group.1) { f in
                            FormatChip(title: f.rawValue, selected: !layered && format == f) {
                                layered = false
                                format = f
                            }
                        }
                    }
                }
            }
            Text(layered ? "Keeps every layer, editable text, opacity and blend modes. Open it again in Easel to keep working."
                         : format.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !layered {
                Form {
                    if format.supportsQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $quality, in: 0.1...1)
                                Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40)
                            }
                        }
                    }
                    if format.fixedSide == nil {
                        Picker("Size", selection: $scale) {
                            Text("25%").tag(0.25)
                            Text("50%").tag(0.5)
                            Text("100%").tag(1.0)
                            Text("200%").tag(2.0)
                        }
                        .pickerStyle(.segmented)
                    }
                    let size = editor.exportSize(format: format, scale: scale)
                    LabeledContent("Dimensions", value: "\(Int(size.width)) × \(Int(size.height)) px")
                    LabeledContent("File size", value: estimate ?? "…")
                    if !format.supportsAlpha {
                        Text("\(format.rawValue) has no transparency, so transparent areas become white.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    editor.copy(merged: true)
                } label: {
                    Label("Copy Image to Clipboard", systemImage: "doc.on.doc")
                }
            }
        }
        .task(id: "\(layered)-\(format.rawValue)-\(quality)-\(scale)") {
            estimate = nil
            guard !layered else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if let data = editor.exportData(format: format, quality: quality, scale: scale) {
                estimate = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            } else {
                estimate = "Unavailable"
            }
        }
    }
}

private struct FormatChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TextSheet: View {
    @Bindable var editor: Editor
    let request: TextRequest
    @State private var text = ""
    @FocusState private var focused: Bool

    static let fonts = ["Helvetica Neue", "SF Pro", "Avenir Next", "Futura", "Georgia", "Times New Roman",
                        "Menlo", "Impact", "Marker Felt", "Chalkboard SE", "Noteworthy", "Snell Roundhand",
                        "Didot", "Baskerville", "Copperplate", "American Typewriter", "Rockwell"]

    var body: some View {
        SheetFrame(title: request.layerID == nil ? "Add Text" : "Edit Text", actionTitle: request.layerID == nil ? "Add" : "Update",
                   action: { editor.commitText(request, string: text) }) {
            TextEditor(text: $text)
                .font(.custom(editor.textFont, size: 18).weight(editor.textBold ? .bold : .regular))
                .frame(height: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .focused($focused)
            HStack {
                Picker("", selection: $editor.textFont) {
                    ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                TextField("Size", value: $editor.textSize, format: .number)
                    .frame(width: 56)
                Text("px").foregroundStyle(.secondary)
                Toggle("Bold", isOn: $editor.textBold).toggleStyle(.checkbox)
                ColorPicker("", selection: $editor.primaryColor, supportsOpacity: false).labelsHidden()
            }
            Text("Text gets its own layer. Move it with the Move tool; click it with the Text tool to edit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            text = request.string
            focused = true
        }
    }
}
