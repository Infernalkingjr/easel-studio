import SwiftUI
import EaselKit

struct InspectorPanel: View {
    let studio: Studio

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch studio.selection {
                case .clip(let id)?:
                    if let clip = studio.project.clips.first(where: { $0.id == id }) { ClipInspector(studio: studio, clip: clip) }
                case .title(let id)?:
                    if let title = studio.project.titles.first(where: { $0.id == id }) { TitleInspector(studio: studio, title: title) }
                case .graphic(let id)?:
                    if let g = studio.project.graphics.first(where: { $0.id == id }) { GraphicInspector(studio: studio, graphic: g) }
                case .music(let id)?:
                    if let m = studio.project.music.first(where: { $0.id == id }) { MusicInspector(studio: studio, music: m) }
                case nil:
                    ProjectInspector(studio: studio)
                }
            }
            .padding(14)
        }
        .background(.bar)
    }
}

// MARK: Shared pieces

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(.bottom, 4)
    }
}

/// A slider that edits the project live and records one undo step per drag.
struct LiveSlider: View {
    let studio: Studio
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    /// Structural edits (speed, audio) apply on release so playback isn't rebuilt mid-drag.
    var commitOnRelease = false
    let set: (Double) -> Void
    @State private var local: Double?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(local ?? value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { local ?? value }, set: { v in
                if commitOnRelease { local = v } else { set(v) }
            }), in: range) { editing in
                if editing {
                    studio.checkpoint()
                } else if let v = local {
                    set(v)
                    local = nil
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: Clip

private struct ClipInspector: View {
    let studio: Studio
    let clip: Clip
    @State private var words = ""
    @State private var showAdjust = false

    private var media: MediaItem? { studio.project.media(clip.mediaID) }
    private func update(_ change: @escaping (inout Clip) -> Void) { studio.updateClip(clip.id, change) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(media?.name ?? "Clip").font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(TimelineNSView.timecode(clip.duration, fine: true)) on timeline · \(media?.kind == .image ? "Photo" : "Video")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Clip") {
                LiveSlider(studio: studio, title: "Speed", value: clip.speed, range: 0.25...4,
                           format: { String(format: "%.2g×", $0) }, commitOnRelease: true) { v in
                    let snapped = [0.25, 0.5, 1, 1.5, 2, 3, 4].first { abs($0 - v) < 0.06 } ?? (v * 100).rounded() / 100
                    update { $0.speed = snapped }
                }
                HStack {
                    ForEach([0.5, 1, 2, 4], id: \.self) { s in
                        Button(String(format: "%g×", s)) { studio.checkpoint(); update { $0.speed = s } }
                    }
                }
                .controlSize(.small)
                if media?.hasAudio == true {
                    LiveSlider(studio: studio, title: "Volume", value: clip.volume, range: 0...2,
                               format: { "\(Int($0 * 100))%" }, commitOnRelease: true) { v in update { $0.volume = v } }
                    Toggle("Mute", isOn: Binding(get: { clip.muted }, set: { v in studio.checkpoint(); update { $0.muted = v } }))
                }
                LiveSlider(studio: studio, title: "Fade In", value: clip.fadeIn, range: 0...3, format: { String(format: "%.1fs", $0) },
                           commitOnRelease: true) { v in update { $0.fadeIn = v } }
                LiveSlider(studio: studio, title: "Fade Out", value: clip.fadeOut, range: 0...3, format: { String(format: "%.1fs", $0) },
                           commitOnRelease: true) { v in update { $0.fadeOut = v } }
            }

            Section("Frame") {
                Picker("Fit", selection: Binding(get: { clip.fit }, set: { v in studio.checkpoint(); update { $0.fit = v } })) {
                    ForEach(FitMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Motion", selection: Binding(get: { clip.motion }, set: { v in studio.checkpoint(); update { $0.motion = v } })) {
                    ForEach(Motion.allCases) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Button { studio.checkpoint(); update { $0.quarterTurns -= 1 } } label: { Image(systemName: "rotate.left") }
                    Button { studio.checkpoint(); update { $0.quarterTurns += 1 } } label: { Image(systemName: "rotate.right") }
                    Toggle("Flip", isOn: Binding(get: { clip.flipped }, set: { v in studio.checkpoint(); update { $0.flipped = v } }))
                        .toggleStyle(.button)
                }
            }

            Section("Color") {
                Picker("Look", selection: Binding(get: { clip.look ?? "" }, set: { v in studio.checkpoint(); update { $0.look = v.isEmpty ? nil : v } })) {
                    Text("None").tag("")
                    ForEach(Effect.all.filter { $0.id != "auto" }) { Text($0.name).tag($0.id) }
                }
                Toggle(isOn: Binding(get: { clip.autoEnhance }, set: { v in
                    studio.checkpoint()
                    update { $0.autoEnhance = v }
                    if v { studio.computeAutoEnhance(clip.id) }
                })) {
                    Label("Auto Enhance", systemImage: "wand.and.stars")
                }
                HStack(spacing: 6) {
                    TextField("Edit with words: warmer, moody…", text: $words)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { studio.editClipWithWords(words); words = "" }
                    Button { studio.editClipWithWords(words); words = "" } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.borderless)
                        .disabled(words.isEmpty)
                }
                DisclosureGroup("Adjustments", isExpanded: $showAdjust) {
                    ForEach(Adjustments.groups.flatMap(\.controls)) { control in
                        LiveSlider(studio: studio, title: control.title, value: clip.adjustments[keyPath: control.id],
                                   range: control.range, format: { "\(Int($0))" }) { v in
                            update { $0.adjustments[keyPath: control.id] = v }
                        }
                    }
                    if !clip.adjustments.isIdentity {
                        Button("Reset Adjustments") { studio.checkpoint(); update { $0.adjustments = Adjustments() } }
                    }
                }
            }

            if let i = studio.clipIndex(clip.id), i + 1 < studio.project.clips.count {
                Section("Transition to next clip") {
                    Picker("Style", selection: Binding(get: { clip.transition?.kind }, set: { v in studio.setTransition(v) })) {
                        Text("None").tag(TransitionKind?.none)
                        ForEach(TransitionKind.allCases) { Text($0.rawValue).tag(TransitionKind?.some($0)) }
                    }
                    if let t = clip.transition {
                        LiveSlider(studio: studio, title: "Duration", value: t.duration, range: 0.2...2,
                                   format: { String(format: "%.1fs", $0) }, commitOnRelease: true) { v in
                            update { $0.transition?.duration = v }
                        }
                    }
                }
            }

            Section("Actions") {
                ActionGrid {
                    ActionButton("Split", "scissors") { studio.split() }
                    ActionButton("Duplicate", "plus.square.on.square") { studio.duplicateSelection() }
                    ActionButton("Freeze", "snowflake") { studio.freezeFrame() }
                    if media?.kind == .video {
                        ActionButton("Find Scenes", "film.stack") { studio.detectScenes() }
                    }
                    if media?.kind == .image {
                        ActionButton("Edit in Easel", "paintbrush.pointed") { studio.editInEasel(mediaID: clip.mediaID) }
                    }
                    ActionButton("Delete", "trash") { studio.deleteSelection() }
                }
            }
        }
    }
}

struct ActionGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) { content }
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.regular)
    }
}

// MARK: Title

private struct TitleInspector: View {
    let studio: Studio
    let title: TitleItem
    @State private var text = ""

    private func update(_ change: @escaping (inout TitleItem) -> Void) { studio.updateTitle(title.id, change) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text").font(.title3.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .onAppear { text = title.text }
                .onChange(of: title.id) { text = title.text }
                .onChange(of: text) { _, v in if v != title.text { update { $0.text = v } } }

            Section("Style") {
                Picker("Style", selection: Binding(get: { title.style }, set: { v in studio.checkpoint(); update { $0.style = v } })) {
                    ForEach(TitleStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Animation", selection: Binding(get: { title.animation }, set: { v in studio.checkpoint(); update { $0.animation = v } })) {
                    ForEach(TitleAnimation.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Position", selection: Binding(get: { title.position }, set: { v in studio.checkpoint(); update { $0.position = v } })) {
                    ForEach(TitlePosition.allCases) { Text($0.rawValue).tag($0) }
                }
                ColorPicker("Color", selection: Binding(
                    get: { Color(.sRGB, red: title.color.r, green: title.color.g, blue: title.color.b) },
                    set: { c in
                        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                        update { $0.color = RGB(r: n.redComponent, g: n.greenComponent, b: n.blueComponent) }
                    }), supportsOpacity: false)
                LiveSlider(studio: studio, title: "Size", value: title.size, range: 0.4...2.5, format: { "\(Int($0 * 100))%" }) { v in
                    update { $0.size = v }
                }
            }
            Section("Timing") {
                LiveSlider(studio: studio, title: "Duration", value: title.duration, range: 0.5...20,
                           format: { String(format: "%.1fs", $0) }) { v in update { $0.duration = v } }
                Button("Move to Playhead") { studio.checkpoint(); update { $0.start = studio.playback.time } }
            }
            ActionGrid {
                ActionButton("Duplicate", "plus.square.on.square") { studio.duplicateSelection() }
                ActionButton("Delete", "trash") { studio.deleteSelection() }
            }
        }
    }
}

// MARK: Graphic

private struct GraphicInspector: View {
    let studio: Studio
    let graphic: Graphic
    private func update(_ change: @escaping (inout Graphic) -> Void) { studio.updateGraphic(graphic.id, change) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(studio.project.media(graphic.mediaID)?.name ?? "Graphic").font(.title3.weight(.semibold))
            Text("Drag it on the preview to move it.").font(.caption).foregroundStyle(.secondary)
            Section("Placement") {
                LiveSlider(studio: studio, title: "Size", value: graphic.scale, range: 0.05...1.5, format: { "\(Int($0 * 100))%" }) { v in update { $0.scale = v } }
                LiveSlider(studio: studio, title: "Horizontal", value: graphic.x, range: 0...1, format: { "\(Int($0 * 100))%" }) { v in update { $0.x = v } }
                LiveSlider(studio: studio, title: "Vertical", value: graphic.y, range: 0...1, format: { "\(Int($0 * 100))%" }) { v in update { $0.y = v } }
                LiveSlider(studio: studio, title: "Opacity", value: graphic.opacity, range: 0...1, format: { "\(Int($0 * 100))%" }) { v in update { $0.opacity = v } }
                Picker("Animation", selection: Binding(get: { graphic.animation }, set: { v in studio.checkpoint(); update { $0.animation = v } })) {
                    ForEach(TitleAnimation.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Timing") {
                LiveSlider(studio: studio, title: "Duration", value: graphic.duration, range: 0.5...60,
                           format: { String(format: "%.1fs", $0) }) { v in update { $0.duration = v } }
            }
            ActionGrid {
                ActionButton("Edit in Easel", "paintbrush.pointed") { studio.editInEasel(mediaID: graphic.mediaID) }
                ActionButton("Delete", "trash") { studio.deleteSelection() }
            }
        }
    }
}

// MARK: Music

private struct MusicInspector: View {
    let studio: Studio
    let music: MusicClip
    private func update(_ change: @escaping (inout MusicClip) -> Void) { studio.updateMusic(music.id, change) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(studio.project.media(music.mediaID)?.name ?? "Music").font(.title3.weight(.semibold))
            Section("Audio") {
                LiveSlider(studio: studio, title: "Volume", value: music.volume, range: 0...1.5, format: { "\(Int($0 * 100))%" },
                           commitOnRelease: true) { v in update { $0.volume = v } }
                LiveSlider(studio: studio, title: "Fade In", value: music.fadeIn, range: 0...5, format: { String(format: "%.1fs", $0) },
                           commitOnRelease: true) { v in update { $0.fadeIn = v } }
                LiveSlider(studio: studio, title: "Fade Out", value: music.fadeOut, range: 0...8, format: { String(format: "%.1fs", $0) },
                           commitOnRelease: true) { v in update { $0.fadeOut = v } }
                Button("Fit to Video") {
                    studio.checkpoint()
                    let media = studio.project.media(music.mediaID)
                    update { m in
                        m.start = 0
                        m.duration = min(media?.duration ?? m.duration, max(1, studio.project.mainDuration))
                    }
                }
            }
            ActionGrid {
                ActionButton("Edit in Tone", "waveform") { studio.editInTone(mediaID: music.mediaID) }
                ActionButton("Split", "scissors") { studio.split() }
                ActionButton("Delete", "trash") { studio.deleteSelection() }
            }
        }
    }
}

// MARK: Project

private struct ProjectInspector: View {
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project").font(.title3.weight(.semibold))
            Section("Frame") {
                Picker("Shape", selection: Binding(get: { studio.project.aspect }, set: { v in studio.checkpoint(); studio.project.aspect = v })) {
                    ForEach(AspectRatio.allCases) { Text($0.label).tag($0) }
                }
                Picker("Background", selection: Binding(get: { studio.project.background }, set: { v in studio.checkpoint(); studio.project.background = v })) {
                    ForEach(Background.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Background shows behind clips that don’t fill the frame. Blur uses the clip itself.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Frame rate", selection: Binding(get: { studio.project.fps }, set: { v in studio.checkpoint(); studio.project.fps = v })) {
                    ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            Section("AI · On-device") {
                ActionGrid {
                    ActionButton("Captions", "captions.bubble") { studio.autoCaptions() }
                    ActionButton("Frame → Easel", "paintbrush.pointed") { studio.openFrameInEasel() }
                }
                Text("Select a clip for Auto Enhance, Find Scenes and Edit with Words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach([("Space", "Play / pause"), ("J  K  L", "Reverse · stop · fast forward"), ("← →", "Step a frame (⇧ = 1s)"),
                             ("S", "Split at playhead"), ("T", "Add text"), ("⌫", "Delete"), ("Pinch / ⌘-scroll", "Zoom timeline")], id: \.0) { k, v in
                        HStack(alignment: .top) {
                            Text(k).font(.caption.monospaced().weight(.semibold)).frame(width: 112, alignment: .leading)
                            Text(v).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
