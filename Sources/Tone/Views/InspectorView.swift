import SwiftUI

struct InspectorView: View {
    let studio: ToneStudio
    @AppStorage("toneInspectorTab") private var tab = "clip"

    var body: some View {
        VStack(spacing: 0) {
            if studio.selectedRegion != nil {
                Picker("", selection: $tab) {
                    Text("Clip").tag("clip")
                    Text("Track").tag("track")
                }
                .pickerStyle(.segmented).labelsHidden().padding(10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let sel = studio.selectedRegion, tab == "clip" {
                        ClipInspector(studio: studio, track: sel.track, region: sel.region)
                    } else if let track = studio.selectedTrack {
                        TrackInspector(studio: studio, track: track)
                    } else {
                        SessionInspector(studio: studio)
                    }
                }
                .padding(14)
            }
        }
        .background(.bar)
    }
}

struct Group2<Content: View>: View {
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

/// Slider bound to the session with one undo step per drag.
struct ParamSlider: View {
    let studio: ToneStudio
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    let set: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in if editing { studio.checkpoint() } }
                .controlSize(.small)
        }
    }
}

private struct ClipInspector: View {
    let studio: ToneStudio
    let track: Track
    let region: Region

    private func update(_ change: @escaping (inout Region) -> Void) { studio.updateRegion(track.id, region.id, change) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(studio.session.asset(region.assetID)?.name ?? "Clip").font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(TracksNSView.timecode(region.start)) · \(String(format: "%.2fs", region.duration)) on \(track.name)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group2("Clip") {
                ParamSlider(studio: studio, title: "Gain", value: region.gainDB, range: -24...24, format: { String(format: "%+.1f dB", $0) }) { v in
                    update { $0.gainDB = abs(v) < 0.3 ? 0 : v }
                }
                ParamSlider(studio: studio, title: "Fade In", value: region.fadeIn, range: 0...max(0.01, region.duration / 2), format: { String(format: "%.2fs", $0) }) { v in update { $0.fadeIn = v } }
                ParamSlider(studio: studio, title: "Fade Out", value: region.fadeOut, range: 0...max(0.01, region.duration / 2), format: { String(format: "%.2fs", $0) }) { v in update { $0.fadeOut = v } }
                Toggle("Mute clip", isOn: Binding(get: { region.muted }, set: { v in studio.checkpoint(); update { $0.muted = v } }))
            }

            Group2("Restoration") {
                Text(studio.range != nil ? "Applies to the selected range of this clip." : "Applies to the whole clip. ⌥-drag across it to work on part of it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { studio.captureNoiseProfile() } label: { Label("Capture Noise Print", systemImage: "eyedropper") }
                    if studio.noiseProfile != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Noise print ready") }
                }
                ParamSlider(studio: studio, title: "Strength", value: studio.restoreAmount, range: 0.1...1, format: { "\(Int($0 * 100))%" }) { v in studio.restoreAmount = v }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(Restoration.allCases) { r in
                        Button { studio.restore(r) } label: {
                            Label(r.rawValue, systemImage: r.symbol).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        }
                        .help(r.help)
                    }
                    Button { studio.stripSilence() } label: {
                        Label("Strip Silence", systemImage: "scissors").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Cuts out pauses longer than half a second and closes the gaps")
                }
                .controlSize(.small)
            }

            Group2("Edit") {
                HStack {
                    Button("Split") { studio.split() }
                    Button("Duplicate") { studio.duplicateSelection() }
                    Button("Delete") { studio.deleteSelection() }
                }
            }
        }
    }
}

private struct TrackInspector: View {
    let studio: ToneStudio
    let track: Track
    @State private var name = ""

    private func update(_ change: @escaping (inout Track) -> Void) { studio.updateTrack(track.id, change) }
    private func fx(_ change: @escaping (inout TrackFX) -> Void) { studio.updateTrack(track.id) { change(&$0.fx) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Track name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3.weight(.semibold))
                .onAppear { name = track.name }
                .onChange(of: track.id) { name = track.name }
                .onSubmit { studio.updateTrack(track.id, checkpoint: true) { $0.name = name } }
            HStack(spacing: 6) {
                ForEach(0..<ToneStudio.colors.count, id: \.self) { i in
                    Circle().fill(Color(nsColor: ToneStudio.colors[i])).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: track.colorIndex == i ? 2 : 0))
                        .onTapGesture { studio.updateTrack(track.id, checkpoint: true) { $0.colorIndex = i } }
                }
            }
            Group2("Mix") {
                ParamSlider(studio: studio, title: "Volume", value: track.volumeDB, range: -60...6, format: { String(format: "%+.1f dB", $0) }) { v in update { $0.volumeDB = v } }
                ParamSlider(studio: studio, title: "Pan", value: track.pan, range: -1...1,
                            format: { $0 == 0 ? "Center" : ($0 < 0 ? "L \(Int(-$0 * 100))" : "R \(Int($0 * 100))") }) { v in update { $0.pan = abs(v) < 0.04 ? 0 : v } }
            }
            Group2("Effects") {
                Menu("Preset…") {
                    ForEach(TrackFX.presets, id: \.0) { name, preset in
                        Button(name) { studio.updateTrack(track.id, checkpoint: true) { $0.fx = preset } }
                    }
                }
                Toggle("Low cut (rumble filter)", isOn: Binding(get: { track.fx.lowCut }, set: { v in studio.checkpoint(); fx { $0.lowCut = v } }))
                ParamSlider(studio: studio, title: "Bass", value: track.fx.low, range: -15...15, format: { String(format: "%+.0f dB", $0) }) { v in fx { $0.low = v } }
                ParamSlider(studio: studio, title: "Mids", value: track.fx.mid, range: -15...15, format: { String(format: "%+.0f dB", $0) }) { v in fx { $0.mid = v } }
                ParamSlider(studio: studio, title: "Treble", value: track.fx.high, range: -15...15, format: { String(format: "%+.0f dB", $0) }) { v in fx { $0.high = v } }
                ParamSlider(studio: studio, title: "Compressor", value: track.fx.compressor, range: 0...1, format: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" }) { v in fx { $0.compressor = v } }
                ParamSlider(studio: studio, title: "Reverb", value: track.fx.reverb, range: 0...100, format: { $0 == 0 ? "Off" : "\(Int($0))%" }) { v in fx { $0.reverb = v } }
                if track.fx.reverb > 0 {
                    Picker("Room", selection: Binding(get: { track.fx.room }, set: { v in studio.checkpoint(); fx { $0.room = v } })) {
                        ForEach(ReverbRoom.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                ParamSlider(studio: studio, title: "Echo", value: track.fx.delay, range: 0...100, format: { $0 == 0 ? "Off" : "\(Int($0))%" }) { v in fx { $0.delay = v } }
                if track.fx.delay > 0 {
                    ParamSlider(studio: studio, title: "Echo time", value: track.fx.delayTime, range: 0.05...1.5, format: { String(format: "%.2fs", $0) }) { v in fx { $0.delayTime = v } }
                    ParamSlider(studio: studio, title: "Repeats", value: track.fx.delayFeedback, range: 0...90, format: { "\(Int($0))%" }) { v in fx { $0.delayFeedback = v } }
                }
            }
            HStack {
                Button("Add Track") { studio.addTrack() }
                Button("Delete Track") { studio.deleteTrack(track.id) }.disabled(studio.session.tracks.count < 2)
            }
        }
    }
}

private struct SessionInspector: View {
    let studio: ToneStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session").font(.title3.weight(.semibold))
            Text("\(studio.session.tracks.count) tracks · \(TracksNSView.timecode(studio.session.duration, fine: false)) long · 48 kHz")
                .font(.caption).foregroundStyle(.secondary)
            Group2("Get started") {
                Text("• Drop audio or video files on a track\n• Press R to record on the armed (or selected) track\n• Select a clip for restoration tools\n• Select a track for effects")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Group2("Shortcuts") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach([("Space", "Play / stop"), ("R", "Record"), ("S", "Split"), ("M", "Mute track"), ("⌫", "Delete"),
                             ("← →", "Move 1s (⇧ 5s)"), ("⌥-drag", "Select part of a clip"), ("⌘C ⌘V", "Copy / paste clip"),
                             ("⌘Y", "Spectral view"), ("⌘0", "Fit timeline"), ("Pinch", "Zoom")], id: \.0) { k, v in
                        HStack {
                            Text(k).font(.caption.monospaced().weight(.semibold)).frame(width: 60, alignment: .leading)
                            Text(v).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
