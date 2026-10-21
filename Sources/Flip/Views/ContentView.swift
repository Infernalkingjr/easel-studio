import SwiftUI
import EaselKit

struct ContentView: View {
    @Bindable var studio: FlipStudio

    var body: some View {
        VSplitView {
            HStack(spacing: 0) {
                ToolPalette(studio: studio)
                Divider()
                ZStack {
                    StageView(studio: studio)
                    Overlays(studio: studio)
                }
                Divider()
                Inspector(studio: studio).frame(width: 280)
            }
            .frame(minHeight: 380)
            VStack(spacing: 0) {
                TimelineBar(studio: studio)
                TimelineGridView(studio: studio)
            }
            .frame(minHeight: 150, idealHeight: 210)
        }
        .background(KeyCatcher(studio: studio))
        .frame(minWidth: 1100, minHeight: 700)
        .navigationTitle(studio.documentName)
        .navigationSubtitle("\(Int(studio.doc.width))×\(Int(studio.doc.height)) · \(studio.doc.fps) fps\(studio.isDirty ? " — Edited" : "")")
        .toolbar { MainToolbar(studio: studio) }
        .sheet(isPresented: $studio.showExport) { ExportSheet(studio: studio) }
        .sheet(isPresented: $studio.showNewDocument) { NewDocumentSheet(studio: studio) }
        .preferredColorScheme(.dark)
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        self.init(r: n.redComponent, g: n.greenComponent, b: n.blueComponent, a: n.alphaComponent)
    }
}

struct ToolPalette: View {
    @Bindable var studio: FlipStudio

    var body: some View {
        VStack(spacing: 6) {
            ForEach(FlipTool.allCases) { tool in
                Button { studio.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 32)
                        .foregroundStyle(studio.tool == tool ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 8).fill(studio.tool == tool ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.key).uppercased()))")
            }
            Spacer()
            ZStack(alignment: .topLeading) {
                swatch(studio.fillColor) { ColorPanelLink.shared.edit(studio.fillColor) { studio.fillColor = $0 } }
                    .offset(x: 13, y: 13)
                    .help("Fill color")
                swatch(studio.color) { ColorPanelLink.shared.edit(studio.color) { studio.color = $0 } }
                    .help("Stroke color")
            }
            .frame(width: 40, height: 40, alignment: .topLeading)
        }
        .padding(.vertical, 10)
        .frame(width: 54)
        .background(.bar)
    }

    private func swatch(_ c: RGBA, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5).fill(c.color)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
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

struct Overlays: View {
    let studio: FlipStudio

    var body: some View {
        VStack {
            HStack {
                Text(studio.tool.hint).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
            .padding(10)
            if let p = studio.exportProgress {
                VStack(spacing: 8) {
                    Text("Exporting… \(Int(p * 100))%").font(.headline)
                    ProgressView(value: p).frame(width: 240)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
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

struct TimelineBar: View {
    @Bindable var studio: FlipStudio

    var body: some View {
        HStack(spacing: 12) {
            Group {
                Button { studio.pause(); studio.go(to: 0) } label: { Image(systemName: "backward.end.fill") }.help("First frame")
                Button { studio.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame (,)")
                Button { studio.togglePlay() } label: { Image(systemName: studio.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                    .help("Play / Pause (Return)")
                Button { studio.step(1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame (.)")
                Button { studio.pause(); studio.go(to: studio.doc.usedFrames - 1) } label: { Image(systemName: "forward.end.fill") }.help("Last frame")
            }
            Text("\(studio.frame + 1) / \(studio.doc.usedFrames)")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .frame(width: 80)
            Text(String(format: "%.2fs", Double(studio.frame) / Double(studio.doc.fps)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { studio.insertKeyframe() } label: { Label("Keyframe", systemImage: "circle.fill") }.help("Insert keyframe (F6)")
            Button { studio.insertKeyframe(blank: true) } label: { Label("Blank", systemImage: "circle") }.help("Insert blank keyframe (F7)")
            Button { studio.setTween(!(studio.activeKey?.tween ?? false)) } label: {
                Label("Tween", systemImage: "arrow.right")
            }
            .help("Animate from this keyframe to the next")
            Button { studio.insertFrame() } label: { Label("Frame", systemImage: "plus.square") }.help("Insert frame (F5)")
            Spacer()
            Toggle(isOn: $studio.onion) { Label("Onion Skin", systemImage: "square.3.layers.3d") }.toggleStyle(.button)
                .help("Show neighbouring frames")
            Toggle(isOn: $studio.loop) { Image(systemName: "repeat") }.toggleStyle(.button).help("Loop")
            Divider().frame(height: 16)
            Button { studio.addLayer() } label: { Image(systemName: "plus.rectangle.on.rectangle") }.help("New layer")
            Button { studio.moveLayer(up: true) } label: { Image(systemName: "chevron.up") }.help("Move layer up")
            Button { studio.moveLayer(up: false) } label: { Image(systemName: "chevron.down") }.help("Move layer down")
            Button { studio.deleteLayer() } label: { Image(systemName: "trash") }.help("Delete layer")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(nsColor: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)))
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

struct Inspector: View {
    @Bindable var studio: FlipStudio
    @State private var layerName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section(studio.tool.title) {
                    switch studio.tool {
                    case .brush, .line, .rect, .ellipse:
                        Row(title: "Size", value: studio.brushSize, range: 1...80, format: { "\(Int($0))px" }) { studio.brushSize = $0 }
                        if studio.tool == .brush {
                            Row(title: "Smoothing", value: studio.smoothing, range: 0...1, format: { "\(Int($0 * 100))%" }) { studio.smoothing = $0 }
                        }
                        if studio.tool == .rect || studio.tool == .ellipse {
                            Toggle("Fill shape", isOn: $studio.shapeFill)
                        }
                    case .eraser:
                        Row(title: "Size", value: studio.eraserSize, range: 4...120, format: { "\(Int($0))px" }) { studio.eraserSize = $0 }
                    case .fill:
                        Text("Fills closed shapes with the fill color.").font(.caption).foregroundStyle(.secondary)
                    default:
                        Text(studio.tool.hint).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        ForEach(Array((studio.recentColors + swatches).prefix(10).enumerated()), id: \.offset) { _, c in
                            Circle().fill(c.color).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                                .onTapGesture { studio.color = c }
                        }
                    }
                }

                Section("Frame \(studio.frame + 1) · \(studio.layer.name)") {
                    let isKey = studio.layer.keyframes.contains { $0.frame == studio.frame }
                    Text(isKey ? "Keyframe" : (studio.activeKey?.tween == true ? "Tweened frame" : "Holds the previous keyframe"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let key = studio.activeKey {
                        Toggle("Motion tween to next keyframe", isOn: Binding(get: { key.tween }, set: { studio.setTween($0) }))
                        if key.tween {
                            Picker("Easing", selection: Binding(get: { key.ease }, set: { studio.setEase($0) })) {
                                ForEach(Ease.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                    }
                    let p = studio.currentPlacement
                    Row(title: "X", value: p.x, range: -studio.doc.width...studio.doc.width, onBegin: { studio.checkpoint() }) { v in
                        var q = p; q.x = v; studio.setPlacement(q, checkpoint: false)
                    }
                    Row(title: "Y", value: p.y, range: -studio.doc.height...studio.doc.height, onBegin: { studio.checkpoint() }) { v in
                        var q = p; q.y = v; studio.setPlacement(q, checkpoint: false)
                    }
                    Row(title: "Scale", value: p.scale, range: 0.05...4, format: { "\(Int($0 * 100))%" }, onBegin: { studio.checkpoint() }) { v in
                        var q = p; q.scale = v; studio.setPlacement(q, checkpoint: false)
                    }
                    Row(title: "Rotation", value: p.rotation, range: -360...360, format: { "\(Int($0))°" }, onBegin: { studio.checkpoint() }) { v in
                        var q = p; q.rotation = v; studio.setPlacement(q, checkpoint: false)
                    }
                    Row(title: "Opacity", value: p.opacity, range: 0...1, format: { "\(Int($0 * 100))%" }, onBegin: { studio.checkpoint() }) { v in
                        var q = p; q.opacity = v; studio.setPlacement(q, checkpoint: false)
                    }
                    HStack {
                        Button("Clear Frame") { studio.clearFrame() }
                        Button("Reset Position") { studio.setPlacement(Placement()) }
                    }
                    .controlSize(.small)
                }

                Section("Layer") {
                    TextField("Name", text: $layerName)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { layerName = studio.layer.name }
                        .onChange(of: studio.layerID) { layerName = studio.layer.name }
                        .onSubmit { studio.updateLayer(studio.layerID, checkpoint: true) { $0.name = layerName } }
                    HStack {
                        Toggle("Visible", isOn: Binding(get: { studio.layer.visible }, set: { v in studio.updateLayer(studio.layerID, checkpoint: true) { $0.visible = v } }))
                        Toggle("Locked", isOn: Binding(get: { studio.layer.locked }, set: { v in studio.updateLayer(studio.layerID, checkpoint: true) { $0.locked = v } }))
                    }
                }

                Section("Scene") {
                    Picker("Frame rate", selection: Binding(get: { studio.doc.fps }, set: { v in studio.checkpoint(); studio.doc.fps = v })) {
                        ForEach([8, 12, 15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Stepper("Length: \(studio.doc.frameCount) frames", value: Binding(get: { studio.doc.frameCount }, set: { v in studio.doc.frameCount = max(1, v) }), in: 1...10000)
                    Picker("Background", selection: Binding(get: { studio.doc.background == nil ? 1 : 0 }, set: { v in
                        studio.checkpoint()
                        studio.doc.background = v == 1 ? nil : (studio.doc.background ?? .white)
                    })) {
                        Text("Color").tag(0)
                        Text("Transparent").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if let bg = studio.doc.background {
                        ColorPicker("Background color", selection: Binding(get: { bg.color }, set: { studio.doc.background = RGBA($0) }), supportsOpacity: false)
                    }
                    Button("New Animation…") { studio.showNewDocument = true }
                }
            }
            .padding(14)
        }
        .background(.bar)
    }

    private var swatches: [RGBA] {
        [.black, .white, RGBA(r: 0.93, g: 0.26, b: 0.24), RGBA(r: 1, g: 0.6, b: 0.1), RGBA(r: 1, g: 0.85, b: 0.2),
         RGBA(r: 0.3, g: 0.78, b: 0.4), RGBA(r: 0.2, g: 0.6, b: 1), RGBA(r: 0.55, g: 0.35, b: 0.95)]
    }
}

// MARK: Sheets & toolbar

struct MainToolbar: ToolbarContent {
    let studio: FlipStudio

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { studio.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(studio.undoStack.isEmpty)
            Button { studio.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(studio.redoStack.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { studio.importPanel() } label: { Label("Import", systemImage: "photo.badge.plus") }.help("Import images (⌘I)")
            Button { studio.sendToReel() } label: { Label("Send to Reel", systemImage: "film") }.help("Add this animation to Reel")
            Button { studio.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }.help("Export (⌘E)")
        }
    }
}

struct ExportSheet: View {
    let studio: FlipStudio
    @State private var format = FlipExporter.Format.mp4
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Animation").font(.title2.weight(.semibold))
            Picker("Format", selection: $format) {
                ForEach(FlipExporter.Format.allCases) { Text($0.rawValue).tag($0) }
            }
            Text(format.note).font(.caption).foregroundStyle(.secondary)
            Text("\(studio.doc.usedFrames) frames at \(studio.doc.fps) fps (\(String(format: "%.1f", Double(studio.doc.usedFrames) / Double(studio.doc.fps)))s)")
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let f = format
                    dismiss()
                    DispatchQueue.main.async { studio.export(f) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { format = studio.doc.background == nil ? .movAlpha : .mp4 }
    }
}

struct NewDocumentSheet: View {
    let studio: FlipStudio
    @State private var width = 1280.0
    @State private var height = 720.0
    @State private var fps = 24
    @State private var transparent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Animation").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                ForEach(FlipDocument.presets, id: \.0) { p in
                    Button(p.0) { width = p.1; height = p.2 }
                        .buttonStyle(.bordered)
                        .tint(width == p.1 && height == p.2 ? .accentColor : nil)
                }
            }
            Picker("Frame rate", selection: $fps) {
                ForEach([12, 15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Transparent background", isOn: $transparent)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    dismiss()
                    studio.newDocument(width: width, height: height, fps: fps, transparent: transparent)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// Animate-style keys. Ignored while typing.
struct KeyCatcher: NSViewRepresentable {
    let studio: FlipStudio

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

        func install(_ studio: FlipStudio, _ view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] e in
                guard let window = view?.window, e.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return e }
                guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
                let shift = e.modifierFlags.contains(.shift)
                switch e.keyCode {
                case 36, 76: studio.togglePlay(); return nil              // return
                case 96: shift ? studio.removeFrame() : studio.insertFrame(); return nil   // F5
                case 97: studio.insertKeyframe(); return nil                 // F6
                case 98: studio.insertKeyframe(blank: true); return nil      // F7
                case 123: studio.step(-1); return nil
                case 124: studio.step(1); return nil
                case 51, 117: studio.clearFrame(); return nil
                case 49: return e                                            // space: stage pans
                default: break
                }
                guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return e }
                if ch == "," { studio.step(-1); return nil }
                if ch == "." { studio.step(1); return nil }
                if let tool = FlipTool.allCases.first(where: { $0.key == ch }) { studio.tool = tool; return nil }
                return e
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct FlipCommands: Commands {
    let studio: FlipStudio

    @MainActor
    private func textAction(_ selector: Selector) -> Bool {
        guard let r = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return NSApp.sendAction(selector, to: r, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Animation…") { studio.showNewDocument = true }.keyboardShortcut("n")
            Button("Open…") { studio.importPanel() }.keyboardShortcut("o")
            Button("Import Image…") { studio.importPanel() }.keyboardShortcut("i")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { studio.save() }.keyboardShortcut("s")
            Button("Save As…") { studio.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export…") { studio.showExport = true }.keyboardShortcut("e")
            Button("Send to Reel") { studio.sendToReel() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if !textAction(Selector(("undo:"))) { studio.undo() } }.keyboardShortcut("z")
            Button("Redo") { if !textAction(Selector(("redo:"))) { studio.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Timeline") {
            Button("Play / Pause") { studio.togglePlay() }
            Button("Next Frame") { studio.step(1) }
            Button("Previous Frame") { studio.step(-1) }
            Divider()
            Button("Insert Keyframe") { studio.insertKeyframe() }
            Button("Insert Blank Keyframe") { studio.insertKeyframe(blank: true) }
            Button("Clear Keyframe") { studio.clearKeyframe() }
            Button("Create Motion Tween") { studio.setTween(true) }
            Button("Remove Tween") { studio.setTween(false) }
            Divider()
            Button("Insert Frame") { studio.insertFrame() }
            Button("Remove Frame") { studio.removeFrame() }
            Divider()
            Button("New Layer") { studio.addLayer() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Delete Layer") { studio.deleteLayer() }
        }
        CommandGroup(before: .toolbar) {
            Button(studio.onion ? "Hide Onion Skin" : "Show Onion Skin") { studio.onion.toggle() }.keyboardShortcut("o", modifiers: [.command, .option])
            Button("Fit Stage") { studio.fitRequest += 1 }.keyboardShortcut("0")
            Divider()
        }
    }
}
