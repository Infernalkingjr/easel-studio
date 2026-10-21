import SwiftUI
import EaselKit

struct ContentView: View {
    @Bindable var studio: Studio

    var body: some View {
        VSplitView {
            HStack(spacing: 0) {
                LibraryPanel(studio: studio)
                    .frame(width: 260)
                Divider()
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        PreviewView(studio: studio)
                        Overlays(studio: studio)
                    }
                    TransportBar(studio: studio, playback: studio.playback)
                }
                .frame(minWidth: 480)
                Divider()
                InspectorPanel(studio: studio)
                    .frame(width: 300)
            }
            .frame(minHeight: 360)
            VStack(spacing: 0) {
                TimelineToolbar(studio: studio)
                TimelineView(studio: studio)
            }
            .frame(minHeight: 240, idealHeight: 290)
        }
        .background(KeyCatcher(studio: studio))
        .frame(minWidth: 1100, minHeight: 700)
        .navigationTitle(studio.documentName)
        .navigationSubtitle("\(studio.project.aspect.rawValue) · \(TimelineNSView.timecode(studio.project.duration, fine: true))\(studio.isDirty ? " — Edited" : "")")
        .toolbar { MainToolbar(studio: studio) }
        .sheet(isPresented: $studio.showExport) { ExportSheet(studio: studio) }
        .preferredColorScheme(.dark)
    }
}

struct Overlays: View {
    let studio: Studio

    var body: some View {
        VStack {
            if let message = studio.busyMessage {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(message) }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 14)
            }
            if let progress = studio.exportProgress {
                VStack(spacing: 8) {
                    Text("Exporting… \(Int(progress * 100))%").font(.headline)
                    ProgressView(value: progress).frame(width: 260)
                    Button("Cancel") { studio.cancelExport() }.controlSize(.small)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 14)
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
        .animation(.easeOut(duration: 0.2), value: studio.busyMessage)
        .allowsHitTesting(studio.exportProgress != nil)
    }
}

struct TransportBar: View {
    let studio: Studio
    let playback: Playback

    var body: some View {
        HStack(spacing: 14) {
            Text(TimelineNSView.timecode(playback.time, fine: true))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 90, alignment: .leading)
            Spacer()
            Button { studio.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }.help("Go to start (Home)")
            Button { studio.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame (←)")
            Button { studio.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 30)
            }
            .help("Play / Pause (Space)")
            Button { studio.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame (→)")
            Button { studio.seek(to: studio.project.duration) } label: { Image(systemName: "forward.end.fill") }.help("Go to end (End)")
            Spacer()
            Toggle(isOn: Bindable(playback).loop) { Image(systemName: "repeat") }
                .toggleStyle(.button).help("Loop playback")
            Text(TimelineNSView.timecode(studio.project.duration, fine: true))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.bar)
    }
}

struct TimelineToolbar: View {
    @Bindable var studio: Studio

    var body: some View {
        HStack(spacing: 10) {
            Button { studio.split() } label: { Label("Split", systemImage: "scissors") }.help("Split at playhead (S)")
            Button { studio.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .disabled(studio.selection == nil).help("Delete (⌫)")
            Button { studio.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .disabled(studio.selection == nil).help("Duplicate (⌘D)")
            Divider().frame(height: 18)
            Button { studio.addTitle(style: .bold) } label: { Label("Text", systemImage: "textformat") }.help("Add text at playhead (T)")
            Button { studio.freezeFrame() } label: { Label("Freeze", systemImage: "snowflake") }
                .disabled(studio.project.clips.isEmpty).help("Insert a 2-second freeze frame at the playhead")
            Button { studio.autoCaptions() } label: { Label("Captions", systemImage: "captions.bubble") }
                .disabled(studio.project.clips.isEmpty).help("Auto-caption speech (on-device)")
            Button { studio.openFrameInEasel() } label: { Label("Frame → Easel", systemImage: "paintbrush.pointed") }
                .disabled(studio.project.clips.isEmpty).help("Open the current frame in Easel")
            Spacer()
            Toggle(isOn: $studio.snapping) { Image(systemName: "dot.squareshape.split.2x2") }
                .toggleStyle(.button).help("Snapping")
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(studio.timelineZoom) }, set: { studio.timelineZoom = exp($0) }), in: log(4)...log(600))
                .frame(width: 120)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button { NotificationCenter.default.post(name: .reelFitTimeline, object: nil) } label: {
                Image(systemName: "arrow.left.and.right.square")
            }
            .help("Fit timeline")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(nsColor: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)))
    }
}

extension Notification.Name {
    static let reelFitTimeline = Notification.Name("ReelFitTimeline")
}

struct MainToolbar: ToolbarContent {
    let studio: Studio

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { studio.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(studio.undoStack.isEmpty).help("Undo (⌘Z)")
            Button { studio.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(studio.redoStack.isEmpty).help("Redo (⇧⌘Z)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { studio.importPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Import media (⌘I)")
            Menu {
                ForEach(AspectRatio.allCases) { a in
                    Button(a.label) { studio.checkpoint(); studio.project.aspect = a }
                }
            } label: { Label(studio.project.aspect.rawValue, systemImage: "aspectratio") }
            .help("Frame shape")
            Button { studio.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(studio.project.clips.isEmpty && studio.project.titles.isEmpty)
                .help("Export (⌘E)")
        }
    }
}
