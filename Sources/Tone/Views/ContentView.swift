import SwiftUI
import EaselKit

struct ContentView: View {
    @Bindable var studio: ToneStudio

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(studio: studio, transport: studio.transport)
            Divider()
            HStack(spacing: 0) {
                VSplitView {
                    ZStack {
                        TracksView(studio: studio)
                        Overlays(studio: studio)
                    }
                    .frame(minHeight: 260)
                    if studio.showMixer {
                        MixerView(studio: studio)
                            .frame(minHeight: 230, idealHeight: 260, maxHeight: 340)
                    }
                }
                Divider()
                InspectorView(studio: studio)
                    .frame(width: 300)
            }
        }
        .background(KeyCatcher(studio: studio))
        .frame(minWidth: 1100, minHeight: 680)
        .navigationTitle(studio.documentName)
        .navigationSubtitle(studio.linkedURL != nil ? "Editing Reel’s soundtrack — ⌘S updates it" : (studio.isDirty ? "Edited" : ""))
        .toolbar { MainToolbar(studio: studio) }
        .sheet(isPresented: $studio.showExport) { ExportSheet(studio: studio) }
        .preferredColorScheme(.dark)
    }
}

struct Overlays: View {
    let studio: ToneStudio

    var body: some View {
        VStack {
            if let message = studio.busyMessage {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(message) }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 34)
            }
            Spacer()
            if let toast = studio.toast {
                Text(toast)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.toast)
        .animation(.easeOut(duration: 0.2), value: studio.busyMessage)
        .allowsHitTesting(false)
    }
}

struct TransportBar: View {
    let studio: ToneStudio
    let transport: Transport

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Button { studio.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Go to start (Home)")
                Button { studio.togglePlay() } label: {
                    Image(systemName: transport.isPlaying ? "stop.fill" : "play.fill").font(.title2).frame(width: 30)
                }
                .help("Play / Stop (Space)")
                Button { studio.toggleRecord() } label: {
                    Image(systemName: "record.circle").font(.title2)
                        .foregroundStyle(transport.isRecording ? Color.red : Color.red.opacity(0.75))
                        .symbolEffect(.pulse, isActive: transport.isRecording)
                }
                .help("Record on the armed track (R)")
            }
            .buttonStyle(.borderless)

            Text(TracksNSView.timecode(transport.time))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(transport.isRecording ? .red : .primary)
                .frame(width: 150, alignment: .leading)

            if transport.isRecording {
                InputMeter(studio: studio).frame(width: 120, height: 8)
            }
            Spacer()
            if let r = studio.range {
                Text(String(format: "Selection %@ – %@  (%.2fs)", TracksNSView.timecode(r.start), TracksNSView.timecode(r.end), r.length))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Bindable(studio).spectral) { Label("Spectral", systemImage: "waveform.path") }
                .toggleStyle(.button).help("Spectral frequency display")
            Toggle(isOn: Bindable(studio).showMixer) { Label("Mixer", systemImage: "slider.vertical.3") }
                .toggleStyle(.button).help("Show the mixer")
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(studio.zoom) }, set: { studio.zoom = exp($0) }), in: log(2)...log(4000))
                .frame(width: 110)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.bar)
    }
}

struct InputMeter: View {
    let studio: ToneStudio
    var body: some View {
        let _ = studio.meterFrame
        MeterBar(level: studio.inputLevel, vertical: false)
    }
}

struct MeterBar: View {
    let level: Float
    var vertical = true

    var body: some View {
        GeometryReader { geo in
            let db = max(-60, 20 * log10(max(Double(level), 1e-6)))
            let f = CGFloat((db + 60) / 60)
            ZStack(alignment: vertical ? .bottom : .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing))
                    .mask(alignment: vertical ? .bottom : .leading) {
                        Rectangle().frame(width: vertical ? nil : geo.size.width * f, height: vertical ? geo.size.height * f : nil)
                    }
            }
        }
    }
}

struct MainToolbar: ToolbarContent {
    let studio: ToneStudio

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { studio.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(studio.undoStack.isEmpty).help("Undo (⌘Z)")
            Button { studio.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(studio.redoStack.isEmpty).help("Redo (⇧⌘Z)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { studio.importPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }.help("Import audio (⌘I)")
            Button { studio.addTrack() } label: { Label("Add Track", systemImage: "plus.rectangle.on.rectangle") }.help("Add a track (⇧⌘N)")
            Button { studio.sendToReel() } label: { Label("Send to Reel", systemImage: "film") }
                .disabled(studio.session.duration == 0).help("Send the mix to Reel as music")
            Button { studio.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(studio.session.duration == 0).help("Export the mix (⌘E)")
        }
    }
}

struct ExportSheet: View {
    let studio: ToneStudio
    @AppStorage("toneExportFormat") private var format = Mixdown.Format.wav24.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Mix").font(.title2.weight(.semibold))
            Picker("Format", selection: $format) {
                ForEach(Mixdown.Format.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Text("48 kHz stereo. The mix runs through the same effects and limiter you hear, including reverb tails.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let f = Mixdown.Format(rawValue: format) ?? .wav24
                    dismiss()
                    DispatchQueue.main.async { studio.exportMix(format: f) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

/// Global keys, ignored while typing in a text field.
struct KeyCatcher: NSViewRepresentable {
    let studio: ToneStudio

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(studio: studio, view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(studio: ToneStudio, view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] e in
                guard let window = view?.window, e.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return e }
                guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
                let shift = e.modifierFlags.contains(.shift)
                switch e.keyCode {
                case 49: studio.togglePlay(); return nil
                case 51, 117: studio.deleteSelection(); return nil
                case 115: studio.seek(to: 0); return nil
                case 119: studio.seek(to: studio.session.duration); return nil
                case 123: studio.seek(to: studio.transport.time - (shift ? 5 : 1)); return nil
                case 124: studio.seek(to: studio.transport.time + (shift ? 5 : 1)); return nil
                case 53: studio.range = nil; return nil
                default: break
                }
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "r"?: studio.toggleRecord(); return nil
                case "s"?, "b"?: studio.split(); return nil
                case "m"?:
                    if let t = studio.selectedTrack { studio.updateTrack(t.id, checkpoint: true) { $0.muted.toggle() } }
                    return nil
                default: return e
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct ToneCommands: Commands {
    let studio: ToneStudio

    @MainActor
    private func textAction(_ selector: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return NSApp.sendAction(selector, to: responder, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { if studio.confirmDiscard() { studio.newSession() } }.keyboardShortcut("n")
            Button("Open…") { studio.importPanel() }.keyboardShortcut("o")
            Button("Import Audio…") { studio.importPanel() }.keyboardShortcut("i")
            Button("Add Track") { studio.addTrack() }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { studio.save() }.keyboardShortcut("s")
            Button("Save As…") { studio.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export Mix…") { studio.showExport = true }.keyboardShortcut("e")
            Button("Send Mix to Reel") { studio.sendToReel() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if !textAction(Selector(("undo:"))) { studio.undo() } }.keyboardShortcut("z")
            Button("Redo") { if !textAction(Selector(("redo:"))) { studio.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            // Text fields keep their own cut/copy/paste; otherwise these act on clips.
            Button("Cut") { if !textAction(Selector(("cut:"))) { studio.cutSelection() } }.keyboardShortcut("x")
            Button("Copy") { if !textAction(Selector(("copy:"))) { studio.copySelection() } }.keyboardShortcut("c")
            Button("Paste") { if !textAction(Selector(("paste:"))) { studio.paste() } }.keyboardShortcut("v")
            Button("Select All") { _ = textAction(Selector(("selectAll:"))) }.keyboardShortcut("a")
            Divider()
            Button("Split at Playhead") { studio.split() }.keyboardShortcut("b")
            Button("Duplicate Clip") { studio.duplicateSelection() }.keyboardShortcut("d")
            Button("Delete") { studio.deleteSelection() }
        }
        CommandMenu("Transport") {
            Button("Play / Stop") { studio.togglePlay() }
            Button(studio.transport.isRecording ? "Stop Recording" : "Record") { studio.toggleRecord() }.keyboardShortcut("r")
            Button("Go to Start") { studio.seek(to: 0) }
        }
        CommandMenu("Restore") {
            Button("Capture Noise Print") { studio.captureNoiseProfile() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            ForEach(Restoration.allCases) { r in Button(r.rawValue) { studio.restore(r) } }
            Divider()
            Button("Strip Silence") { studio.stripSilence() }
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { studio.zoom = min(4000, studio.zoom * 1.5) }.keyboardShortcut("=")
            Button("Zoom Out") { studio.zoom = max(2, studio.zoom / 1.5) }.keyboardShortcut("-")
            Button("Fit Timeline") { NotificationCenter.default.post(name: .toneFitTimeline, object: nil) }.keyboardShortcut("0")
            Button(studio.spectral ? "Waveform Display" : "Spectral Display") { studio.spectral.toggle() }.keyboardShortcut("y", modifiers: [.command])
            Button(studio.showMixer ? "Hide Mixer" : "Show Mixer") { studio.showMixer.toggle() }.keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
        }
    }
}
