import SwiftUI

struct MixerView: View {
    let studio: ToneStudio

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(studio.session.tracks) { track in
                    ChannelStrip(studio: studio, track: track)
                }
                Divider().padding(.vertical, 10)
                MasterStrip(studio: studio)
            }
            .padding(10)
        }
        .background(Color(nsColor: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.105, alpha: 1)))
    }
}

/// A vertical fader with dB markings; one undo step per drag.
struct Fader: View {
    let value: Double                    // dB
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    private let range = -60.0...6.0
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - 20
            let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 4).frame(maxHeight: .infinity).padding(.vertical, 10)
                ForEach([6, 0, -6, -12, -24, -48], id: \.self) { mark in
                    let y = 10 + h * (1 - CGFloat((Double(mark) - range.lowerBound) / (range.upperBound - range.lowerBound)))
                    Rectangle().fill(Color.white.opacity(mark == 0 ? 0.5 : 0.2)).frame(width: mark == 0 ? 16 : 10, height: 1)
                        .offset(y: y)
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 14)
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1))
                    .shadow(radius: 2)
                    .offset(y: 10 + h * (1 - f) - 7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if !dragging { dragging = true; onBegin() }
                let p = 1 - min(1, max(0, (g.location.y - 10) / h))
                var db = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                if abs(db) < 0.8 { db = 0 }
                onChange((db * 10).rounded() / 10)
            }.onEnded { _ in dragging = false })
            .onTapGesture(count: 2) { onBegin(); onChange(0) }
        }
    }
}

private struct ChannelStrip: View {
    let studio: ToneStudio
    let track: Track

    var body: some View {
        let selected = studio.selectedTrack?.id == track.id
        VStack(spacing: 6) {
            Text(track.name).font(.caption.weight(.semibold)).lineLimit(1)
            Slider(value: Binding(get: { track.pan }, set: { v in studio.updateTrack(track.id) { $0.pan = abs(v) < 0.05 ? 0 : v } }),
                   in: -1...1) { editing in if editing { studio.checkpoint() } }
                .controlSize(.mini)
                .help("Pan")
            HStack(spacing: 6) {
                Fader(value: track.volumeDB, onBegin: { studio.checkpoint() }) { v in studio.updateTrack(track.id) { $0.volumeDB = v } }
                TrackMeter(studio: studio, id: track.id).frame(width: 7)
            }
            Text(String(format: "%+.1f", track.volumeDB)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                SmallToggle("M", on: track.muted, color: .orange) { studio.updateTrack(track.id, checkpoint: true) { $0.muted.toggle() } }
                SmallToggle("S", on: track.solo, color: .yellow) { studio.updateTrack(track.id, checkpoint: true) { $0.solo.toggle() } }
            }
            Text(fxSummary).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .frame(width: 92)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.12 : 0.05)))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: ToneStudio.colors[track.colorIndex % ToneStudio.colors.count])).frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .onTapGesture { studio.selection = .track(track.id) }
    }

    private var fxSummary: String {
        var parts: [String] = []
        let fx = track.fx
        if fx.lowCut || fx.low != 0 || fx.mid != 0 || fx.high != 0 { parts.append("EQ") }
        if fx.compressor > 0 { parts.append("Comp") }
        if fx.delay > 0 { parts.append("Dly") }
        if fx.reverb > 0 { parts.append("Verb") }
        return parts.isEmpty ? "No FX" : parts.joined(separator: " · ")
    }
}

private struct MasterStrip: View {
    let studio: ToneStudio

    var body: some View {
        VStack(spacing: 6) {
            Text("Master").font(.caption.weight(.bold))
            Toggle("Limiter", isOn: Binding(get: { studio.session.limiter }, set: { v in studio.checkpoint(); studio.session.limiter = v }))
                .toggleStyle(.button).controlSize(.mini)
            HStack(spacing: 6) {
                Fader(value: studio.session.masterDB, onBegin: { studio.checkpoint() }) { v in studio.session.masterDB = v }
                MasterMeter(studio: studio).frame(width: 16)
            }
            Text(String(format: "%+.1f", studio.session.masterDB)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 100)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }
}

private struct TrackMeter: View {
    let studio: ToneStudio
    let id: UUID
    var body: some View {
        let _ = studio.meterFrame
        MeterBar(level: studio.levels[id] ?? 0)
    }
}

private struct MasterMeter: View {
    let studio: ToneStudio
    var body: some View {
        let _ = studio.meterFrame
        HStack(spacing: 2) {
            MeterBar(level: studio.masterLevels.0)
            MeterBar(level: studio.masterLevels.1)
        }
    }
}

struct SmallToggle: View {
    let label: String
    let on: Bool
    let color: Color
    let action: () -> Void

    init(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) {
        self.label = label
        self.on = on
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label).font(.caption2.weight(.bold))
                .frame(width: 24, height: 18)
                .foregroundStyle(on ? .black : .white.opacity(0.8))
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? color : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
