import SwiftUI
import EaselKit

struct LibraryPanel: View {
    let studio: Studio
    @AppStorage("libraryTab") private var tab = "media"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Media").tag("media")
                Text("Text").tag("text")
                Text("Transitions").tag("transitions")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            switch tab {
            case "text": TitlePresets(studio: studio)
            case "transitions": TransitionPresets(studio: studio)
            default: MediaGrid(studio: studio)
            }
        }
        .background(.bar)
    }
}

private struct MediaGrid: View {
    let studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            Button { studio.importPanel() } label: {
                Label("Import Media", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if studio.project.media.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text("Drop videos, photos and music here or onto the timeline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Images sent from Easel show up here too.").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(24)
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 10) {
                        ForEach(studio.project.media) { item in
                            MediaTile(studio: studio, item: item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await studio.importAndPlace([url]) }
                }
            }
            return true
        }
    }
}

private struct MediaTile: View {
    let studio: Studio
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.4)
                    .frame(height: 70)
                    .overlay {
                        if let thumb = thumbnail {
                            Image(nsImage: NSImage(cgImage: thumb, size: CGSize(width: thumb.width, height: thumb.height)))
                                .resizable().scaledToFill()
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        } else if item.kind == .audio {
                            Image(systemName: "waveform").font(.title).foregroundStyle(.green)
                        }
                    }
                    .clipped()
                if item.kind != .image {
                    Text(TimelineNSView.timecode(item.duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 4) {
                Image(systemName: item.kind == .video ? "film" : item.kind == .audio ? "music.note" : (item.hasAlpha ? "sparkles" : "photo"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(item.name).font(.caption).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { studio.addToTimeline(item) }
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .contextMenu {
            Button("Add to Timeline") { studio.addToTimeline(item) }
            if item.kind == .image {
                Button("Add as Graphic") { studio.addGraphic(item, at: studio.playback.time) }
                Button("Edit in Easel") { studio.editInEasel(mediaID: item.id) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .help("\(item.name) — double-click or drag to the timeline")
    }

    private var thumbnail: CGImage? {
        _ = studio.mediaRevision
        return studio.library.thumbnail(for: item, at: min(1, item.duration / 2))
    }
}

private struct TitlePresets: View {
    let studio: Studio

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(TitleStyle.allCases) { style in
                    Button { studio.addTitle(style: style) } label: {
                        Text(sample(style))
                            .font(font(style))
                            .foregroundStyle(style == .boxed ? .black : .white)
                            .shadow(color: style == .neon ? .cyan : .black.opacity(0.5), radius: style == .neon ? 6 : 2)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(style == .boxed ? Color.yellow : (style == .subtitle ? Color.black.opacity(0.6) : .clear),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(LinearGradient(colors: [.indigo.opacity(0.6), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Add a \(style.rawValue) title at the playhead")
                }
            }
            .padding(10)
            Text("Titles appear at the playhead. Drag them on the timeline to move or resize.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
        }
    }

    private func sample(_ s: TitleStyle) -> String {
        switch s {
        case .lowerThird: return "Lower Third"
        case .subtitle: return "Subtitle"
        default: return s.rawValue
        }
    }

    private func font(_ s: TitleStyle) -> Font {
        switch s {
        case .bold, .outline: return .system(size: 17, weight: .black)
        case .clean: return .system(size: 16, weight: .medium)
        case .boxed, .lowerThird, .subtitle: return .system(size: 13, weight: .semibold)
        case .neon: return .custom("AvenirNext-Heavy", size: 17)
        case .serif: return .custom("Didot-Bold", size: 18)
        case .handwritten: return .custom("MarkerFelt-Wide", size: 18)
        }
    }
}

private struct TransitionPresets: View {
    let studio: Studio

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select a clip, then pick how it moves into the next one.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile(nil)
                    ForEach(TransitionKind.allCases) { tile($0) }
                }
            }
            .padding(10)
        }
    }

    private func tile(_ kind: TransitionKind?) -> some View {
        let current = studio.selectedClip?.transition?.kind
        let selected = studio.selectedClip != nil && current == kind
        return Button { studio.setTransition(kind) } label: {
            VStack(spacing: 6) {
                Image(systemName: kind?.symbol ?? "xmark").font(.title3)
                Text(kind?.rawValue ?? "None").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
