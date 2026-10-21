import EaselKit
import SwiftUI

struct Inspector: View {
    let editor: Editor
    @AppStorage("inspectorTab") private var tab = "adjust"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Adjust").tag("adjust")
                Text("Effects").tag("effects")
                Text("AI").tag("ai")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Group {
                switch tab {
                case "effects": EffectsPanel(editor: editor)
                case "ai": AIPanel(editor: editor)
                default: AdjustPanel(editor: editor)
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(!editor.hasDocument || editor.activeLayer == nil)

            Divider()
            LayersPanel(editor: editor)
                .frame(height: 300)
        }
        .background(.bar)
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Adjustments.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.id.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.controls) { control in
                                AdjustRow(control: control, value: $editor.adjustments[dynamicMember: control.id])
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            if !editor.adjustments.isIdentity {
                Divider()
                HStack {
                    Button("Reset") { editor.cancelAdjustments() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Apply") { editor.applyAdjustments() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
        }
    }
}

private extension Binding where Value == Adjustments {
    subscript(dynamicMember keyPath: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding<Double>(get: { wrappedValue[keyPath: keyPath] }, set: { wrappedValue[keyPath: keyPath] = $0 })
    }
}

private struct AdjustRow: View {
    let control: Adjustments.Control
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Label(control.title, systemImage: control.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                Spacer()
                Text("\(Int(value.rounded()))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            Slider(value: $value, in: control.range)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = 0 }
        .help("Double-click to reset")
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    let editor: Editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("LOOKS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                LooksGrid(effects: Effect.all, thumbnails: editor.effectThumbnails) { editor.applyEffect($0) }
                Text(editor.selection == nil ? "Applies to the selected layer." : "Applies inside the selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .onAppear { editor.refreshEffectThumbnails() }
        .onChange(of: editor.activeLayer?.revision) { editor.refreshEffectThumbnails() }
    }
}

struct LooksGrid: View {
    let effects: [Effect]
    let thumbnails: [String: NSImage]
    let apply: (Effect) -> Void

    var body: some View {
        // Fixed column count: every tile gets the same width whatever the image's shape.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            ForEach(effects) { effect in
                EffectTile(effect: effect, thumbnail: thumbnails[effect.id]) { apply(effect) }
            }
        }
    }
}

struct QuickAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}

struct EffectTile: View {
    let effect: Effect
    let thumbnail: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // A fixed-size box with the thumbnail overlaid, so wide images can't widen the grid cell.
                Color.primary.opacity(0.06)
                    .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hover ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: hover ? 2 : 1))
                Text(effect.name).font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Layers

struct LayersPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                if let layer = editor.activeLayer {
                    Picker("", selection: Binding(
                        get: { layer.blendMode },
                        set: { mode in editor.updateLayer(layer.id, checkpoint: true) { $0.blendMode = mode } }
                    )) {
                        ForEach(BlendMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 110)
                    .help("Blend mode")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let layer = editor.activeLayer {
                OpacityRow(editor: editor, layer: layer)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            List(selection: $editor.activeLayerID) {
                ForEach(editor.layers.reversed()) { layer in
                    LayerRow(editor: editor, layer: layer)
                        .tag(layer.id)
                        .contextMenu {
                            Button("Rename…") { editor.activeLayerID = layer.id; editor.renamingLayerID = layer.id }
                            if layer.text != nil {
                                Button("Edit Text…") { editor.editText(of: layer.id) }
                                Divider()
                            }
                            Button("Duplicate") { editor.activeLayerID = layer.id; editor.duplicateLayer() }
                            Button("Merge Down") { editor.activeLayerID = layer.id; editor.mergeDown() }
                            Divider()
                            Button("Delete", role: .destructive) { editor.deleteLayer(layer.id) }
                        }
                }
                .onMove { editor.moveLayers(fromDisplay: $0, toDisplay: $1) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: 2) {
                LayerButton(symbol: "plus", help: "New layer (⇧⌘N)") { editor.addEmptyLayer() }
                LayerButton(symbol: "plus.square.on.square", help: "Duplicate layer (⌘J)") { editor.duplicateLayer() }
                LayerButton(symbol: "photo.badge.plus", help: "Add image as layer…") { editor.placePanel() }
                LayerButton(symbol: "square.stack.3d.down.forward", help: "Merge down (⌘E)") { editor.mergeDown() }
                Spacer()
                LayerButton(symbol: "chevron.up", help: "Move up") { editor.moveLayer(1) }
                LayerButton(symbol: "chevron.down", help: "Move down") { editor.moveLayer(-1) }
                LayerButton(symbol: "trash", help: "Delete layer") { editor.deleteLayer() }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .disabled(!editor.hasDocument)
        }
    }
}

private struct OpacityRow: View {
    let editor: Editor
    let layer: Layer

    var body: some View {
        HStack(spacing: 6) {
            Text("Opacity").font(.callout).foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { layer.opacity }, set: { v in editor.updateLayer(layer.id) { $0.opacity = v } }),
                in: 0...1,
                onEditingChanged: { began in if began { editor.checkpoint() } }
            )
            .controlSize(.small)
            Text("\(Int((layer.opacity * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }
}

private struct LayerRow: View {
    let editor: Editor
    let layer: Layer
    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    private var editing: Bool { editor.renamingLayerID == layer.id }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                editor.updateLayer(layer.id, checkpoint: true) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "Hide" : "Show")

            Image(nsImage: ThumbnailCache.shared.thumbnail(for: layer))
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 30)
                .background(CheckerSwatch())
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.15)))

            if editing {
                TextField("Layer name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { editor.renamingLayerID = nil }
                    .onAppear {
                        name = layer.name
                        DispatchQueue.main.async { fieldFocused = true }
                    }
                    // Clicking elsewhere keeps the new name.
                    .onChange(of: fieldFocused) { _, focused in if !focused && editing { commitName() } }
            } else {
                Text(layer.name)
                    .lineLimit(1)
                    .opacity(layer.isVisible ? 1 : 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { editor.renamingLayerID = layer.id })
                    .help("Double-click to rename")
            }
            Spacer(minLength: 0)
            if layer.blendMode != .normal || layer.opacity < 1 {
                Text(layer.blendMode != .normal ? layer.blendMode.title : "\(Int(layer.opacity * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func commitName() {
        editor.renamingLayerID = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != layer.name else { return }
        editor.updateLayer(layer.id, checkpoint: true) { $0.name = trimmed }
    }
}

private struct CheckerSwatch: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 5
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
        .background(Color.white)
    }
}

private struct LayerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
