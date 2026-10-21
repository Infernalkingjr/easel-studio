import SwiftUI

struct ExportSheet: View {
    let studio: Studio
    @State private var settings = ExportSettings()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            Form {
                Picker("Format", selection: $settings.format) {
                    ForEach(ExportSettings.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(settings.format.note).font(.caption).foregroundStyle(.secondary)
                if settings.format == .h264 || settings.format == .hevc {
                    Picker("Resolution", selection: $settings.shortSide) {
                        Text("720p").tag(CGFloat(720))
                        Text("1080p").tag(CGFloat(1080))
                        Text("1440p").tag(CGFloat(1440))
                        Text("4K").tag(CGFloat(2160))
                    }
                    .pickerStyle(.segmented)
                    Picker("Frame rate", selection: $settings.fps) {
                        ForEach([24, 25, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(ExportSettings.Quality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if settings.format != .audio {
                    let size = studio.project.aspect.size(short: settings.format == .gif ? min(settings.shortSide, 480) : settings.shortSide)
                    LabeledContent("Size", value: "\(Int(size.width)) × \(Int(size.height))")
                }
                LabeledContent("Length", value: TimelineNSView.timecode(studio.project.duration, fine: true))
                if settings.format == .h264 || settings.format == .hevc {
                    LabeledContent("Estimated file", value: estimate)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let s = settings
                    dismiss()
                    DispatchQueue.main.async { studio.export(s) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { settings.fps = studio.project.fps }
    }

    private var estimate: String {
        let size = studio.project.aspect.size(short: settings.shortSide)
        let bits = Double(size.width * size.height) * Double(settings.fps) * settings.quality.bitsPerPixel
            * (settings.format == .hevc ? 0.6 : 1) * studio.project.duration + 192_000 * studio.project.duration
        return ByteCountFormatter.string(fromByteCount: Int64(bits / 8), countStyle: .file)
    }
}

struct ReelCommands: Commands {
    let studio: Studio

    @MainActor
    private func textAction(_ selector: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return NSApp.sendAction(selector, to: responder, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { studio.newProject() }.keyboardShortcut("n")
            Button("Open…") { studio.importPanel() }.keyboardShortcut("o")
            Button("Import Media…") { studio.importPanel() }.keyboardShortcut("i")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { studio.saveProject() }.keyboardShortcut("s")
            Button("Save As…") { studio.saveProject(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export…") { studio.showExport = true }.keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if !textAction(Selector(("undo:"))) { studio.undo() } }.keyboardShortcut("z")
            Button("Redo") { if !textAction(Selector(("redo:"))) { studio.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Split at Playhead") { studio.split() }.keyboardShortcut("b")
            Button("Duplicate") { studio.duplicateSelection() }.keyboardShortcut("d")
            Button("Delete") { studio.deleteSelection() }
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { studio.togglePlay() }
            Button("Go to Start") { studio.seek(to: 0) }
            Button("Next Frame") { studio.step(frames: 1) }
            Button("Previous Frame") { studio.step(frames: -1) }
            Divider()
            Button(studio.playback.loop ? "Turn Loop Off" : "Turn Loop On") { studio.playback.loop.toggle() }.keyboardShortcut("l", modifiers: [.command])
        }
        CommandMenu("Clip") {
            Button("Add Text") { studio.addTitle(style: .bold) }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("Freeze Frame") { studio.freezeFrame() }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Scenes in Clip") { studio.detectScenes() }
            Button("Auto Captions") { studio.autoCaptions() }.keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            Button("Open Frame in Easel") { studio.openFrameInEasel() }.keyboardShortcut("e", modifiers: [.command, .option])
            if case .clip(let id)? = studio.selection, let clip = studio.project.clips.first(where: { $0.id == id }),
               studio.project.media(clip.mediaID)?.kind == .image {
                Button("Edit Photo in Easel") { studio.editInEasel(mediaID: clip.mediaID) }
            }
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom Timeline In") { studio.timelineZoom = min(600, studio.timelineZoom * 1.5) }.keyboardShortcut("=")
            Button("Zoom Timeline Out") { studio.timelineZoom = max(4, studio.timelineZoom / 1.5) }.keyboardShortcut("-")
            Button("Fit Timeline") { NotificationCenter.default.post(name: .reelFitTimeline, object: nil) }.keyboardShortcut("0")
            Divider()
        }
    }
}
