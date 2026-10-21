import EaselKit
import SwiftUI

struct ToolPalette: View {
    @Bindable var editor: Editor

    private let groups: [[Tool]] = [
        [.move, .select, .crop],
        [.brush, .eraser, .fill, .gradient],
        [.shape, .text],
        [.eyedropper, .hand],
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(groups.indices, id: \.self) { i in
                if i > 0 { Divider().frame(width: 28).padding(.vertical, 2) }
                ForEach(groups[i]) { tool in
                    ToolButton(tool: tool, selected: editor.tool == tool) { editor.tool = tool }
                }
            }
            Spacer()
            ColorWell(editor: editor)
        }
        .padding(.vertical, 10)
        .frame(width: 54)
        .background(.bar)
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 34)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.accentColor : (hover ? Color.primary.opacity(0.08) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
    }
}

/// Primary/secondary color squares, Photoshop-style.
private struct ColorWell: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                swatch($editor.secondaryColor)
                    .offset(x: 13, y: 13)
                    .help("Secondary color — click to change")
                swatch($editor.primaryColor)
                    .help("Primary color — click to change")
            }
            .frame(width: 40, height: 40, alignment: .topLeading)
            HStack(spacing: 6) {
                Button { editor.swapColors() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap colors (X)")
                Button { editor.resetColors() } label: { Image(systemName: "circle.lefthalf.filled") }
                    .help("Black & white (D)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private func swatch(_ color: Binding<Color>) -> some View {
        Button { ColorPanelLink.shared.edit(color) } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.wrappedValue)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white, lineWidth: 2))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Points the shared macOS color panel at one color binding at a time.
@MainActor
final class ColorPanelLink: NSObject {
    static let shared = ColorPanelLink()
    private var binding: Binding<Color>?

    func edit(_ color: Binding<Color>) {
        binding = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(color.wrappedValue)
        binding = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        binding?.wrappedValue = Color(nsColor: panel.color)
    }
}

struct OptionsBar: View {
    @Bindable var editor: Editor

    static let swatches: [Color] = [
        .black, .white, Color(red: 0.93, green: 0.26, blue: 0.24), Color(red: 1, green: 0.6, blue: 0.1),
        Color(red: 1, green: 0.85, blue: 0.2), Color(red: 0.3, green: 0.78, blue: 0.4), Color(red: 0.2, green: 0.6, blue: 1),
        Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 1, green: 0.4, blue: 0.7),
    ]

    var body: some View {
        HStack(spacing: 14) {
            Label(editor.tool.title, systemImage: editor.tool.symbol)
                .font(.headline)
                .frame(minWidth: 110, alignment: .leading)
            Divider().frame(height: 20)
            options
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }

    @ViewBuilder private var options: some View {
        switch editor.tool {
        case .brush:
            SizeSlider(title: "Size", value: $editor.brushSize)
            PercentSlider(title: "Opacity", value: $editor.brushOpacity)
            PercentSlider(title: "Hardness", value: $editor.brushHardness)
            pressureToggle
            swatchRow
        case .eraser:
            SizeSlider(title: "Size", value: $editor.eraserSize)
            PercentSlider(title: "Strength", value: $editor.brushOpacity)
            PercentSlider(title: "Hardness", value: $editor.brushHardness)
            pressureToggle
        case .fill:
            LabeledSlider(title: "Tolerance", value: $editor.fillTolerance, range: 0...100, format: { "\(Int($0))" })
            PercentSlider(title: "Opacity", value: $editor.brushOpacity)
            swatchRow
            Button("Fill Selection") { editor.fillSelection() }.help("⌥⌫")
        case .gradient:
            PercentSlider(title: "Opacity", value: $editor.brushOpacity)
            Text("Primary → Secondary color").foregroundStyle(.secondary)
        case .shape:
            Picker("", selection: $editor.shapeKind) {
                ForEach(ShapeKind.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Filled", isOn: $editor.shapeFilled).toggleStyle(.checkbox)
            if !editor.shapeFilled || [.line, .arrow].contains(editor.shapeKind) {
                SizeSlider(title: "Line", value: $editor.shapeLineWidth, maxValue: 200)
            }
            swatchRow
        case .text:
            Picker("", selection: $editor.textFont) {
                ForEach(TextSheet.fonts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            SizeSlider(title: "Size", value: $editor.textSize, maxValue: 600)
            Toggle("Bold", isOn: $editor.textBold).toggleStyle(.checkbox)
            swatchRow
        case .crop:
            Picker("Aspect", selection: $editor.cropAspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            if editor.cropRect != nil {
                Button("Apply Crop") { editor.applyCrop() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { editor.cropRect = nil }
            } else {
                Button("Trim Transparent Edges") { editor.trim() }
            }
        case .select:
            Button("Select All") { editor.selectAll() }
            Button("Deselect") { editor.deselect() }.disabled(editor.selection == nil)
            if editor.selection != nil {
                Button("Crop to Selection") { editor.cropToSelection() }
                Button("Copy to New Layer") { editor.copy(); editor.paste() }
                if let s = editor.selection {
                    Text("\(Int(s.width)) × \(Int(s.height))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .move:
            if let layer = editor.activeLayer, let b = editor.contentBounds(layer) {
                Text("\(Int(b.width)) × \(Int(b.height)) px").foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Resize…") { editor.showLayerResizeSheet = true }.help("Type an exact size (⌘T)")
            Button("Fit to Canvas") { editor.fitActiveLayerToCanvas() }
            Button { editor.rotateActiveLayer(by: .pi / 2) } label: { Image(systemName: "rotate.left") }
                .help("Rotate 90° left")
            Button { editor.rotateActiveLayer(by: -.pi / 2) } label: { Image(systemName: "rotate.right") }
                .help("Rotate 90° right")
            Button { editor.flip(horizontal: true, layerOnly: true) } label: { Label("Flip ↔", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .help("Flip horizontally")
            Button { editor.flip(horizontal: false, layerOnly: true) } label: { Label("Flip ↕", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                .help("Flip vertically")
            Text("Corners resize · ◯ or outside a corner rotates · ⇧ snaps").foregroundStyle(.secondary).lineLimit(1)
        case .eyedropper:
            Circle().fill(editor.primaryColor).frame(width: 18, height: 18).overlay(Circle().strokeBorder(.secondary))
            Text(hex(editor.primaryColor)).monospaced().textSelection(.enabled)
        case .hand:
            Button("Fit on Screen") { editor.zoomToFit() }
            Button("Actual Size") { editor.actualSize() }
        }
    }

    private var pressureToggle: some View {
        Toggle(isOn: $editor.usePressure) { Image(systemName: "pencil.tip") }
            .toggleStyle(.button)
            .help("Pen pressure controls size (drawing tablets)")
    }

    private var swatchRow: some View {
        HStack(spacing: 4) {
            ForEach(Array((editor.recentColors + Self.swatches).prefix(12).enumerated()), id: \.offset) { _, color in
                Button { editor.primaryColor = color } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Slider(value: $value, in: range).frame(width: 90)
            Text(format(value)).monospacedDigit().frame(width: 42, alignment: .leading)
        }
    }
}

struct SizeSlider: View {
    let title: String
    @Binding var value: Double
    var maxValue: Double = 500

    var body: some View {
        // Square-root scale so small brush sizes are easy to dial in.
        LabeledSlider(title: title, value: Binding(get: { value.squareRoot() }, set: { value = max(1, ($0 * $0).rounded()) }),
                      range: 1...maxValue.squareRoot(), format: { "\(Int(($0 * $0).rounded()))px" })
    }
}

struct PercentSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledSlider(title: title, value: $value, range: 0.01...1, format: { "\(Int(($0 * 100).rounded()))%" })
    }
}
