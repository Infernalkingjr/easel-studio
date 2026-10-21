import Foundation
import CoreGraphics
import EaselKit

enum MediaKind: String, Codable {
    case video, image, audio
}

struct MediaItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var kind: MediaKind
    /// Seconds. Images report 0 and can be any length on the timeline.
    var duration: Double
    /// Display size in pixels, with rotation already applied.
    var size: CGSize
    var hasAudio: Bool
    /// Images with transparent areas are treated as graphics (overlays).
    var hasAlpha = false

    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fill = "Fill", fit = "Fit"
    var id: String { rawValue }
}

enum Motion: String, Codable, CaseIterable, Identifiable {
    case none = "None", zoomIn = "Zoom In", zoomOut = "Zoom Out", panLeft = "Pan Left", panRight = "Pan Right"
    var id: String { rawValue }
}

enum TransitionKind: String, Codable, CaseIterable, Identifiable {
    case crossfade = "Crossfade", dipBlack = "Dip to Black", dipWhite = "Dip to White"
    case slide = "Slide", push = "Push", zoom = "Zoom", spin = "Spin", wipe = "Wipe"
    case flash = "Flash", bars = "Bars", pageCurl = "Page Curl", ripple = "Ripple", blur = "Blur"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .crossfade: return "circle.lefthalf.filled"
        case .dipBlack: return "circle.fill"
        case .dipWhite: return "circle"
        case .slide: return "arrow.left.square"
        case .push: return "rectangle.portrait.and.arrow.right"
        case .zoom: return "plus.magnifyingglass"
        case .spin: return "arrow.clockwise.circle"
        case .wipe: return "rectangle.lefthalf.inset.filled"
        case .flash: return "bolt.fill"
        case .bars: return "line.3.horizontal"
        case .pageCurl: return "book.pages"
        case .ripple: return "water.waves"
        case .blur: return "aqi.medium"
        }
    }
}

struct Transition: Codable, Equatable {
    var kind: TransitionKind = .crossfade
    var duration: Double = 0.6
}

struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var mediaID: UUID
    /// Trimmed range in the source file, in source seconds.
    var sourceStart: Double = 0
    var sourceDuration: Double
    var speed: Double = 1
    var volume: Double = 1
    var muted = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var fit: FitMode = .fill
    var motion: Motion = .none
    var quarterTurns = 0
    var flipped = false
    var look: String?
    var adjustments = Adjustments()
    var autoEnhance = false
    /// Transition into the next clip.
    var transition: Transition?

    /// Length on the timeline.
    var duration: Double { sourceDuration / speed }
}

struct RGB: Codable, Equatable {
    var r: Double, g: Double, b: Double
    static let white = RGB(r: 1, g: 1, b: 1)
    static let yellow = RGB(r: 1, g: 0.85, b: 0.2)
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum TitleStyle: String, Codable, CaseIterable, Identifiable {
    case bold = "Bold", clean = "Clean", outline = "Outline", boxed = "Boxed", lowerThird = "Lower Third"
    case subtitle = "Subtitle", neon = "Neon", serif = "Serif", handwritten = "Marker"
    var id: String { rawValue }
}

enum TitleAnimation: String, Codable, CaseIterable, Identifiable {
    case none = "None", fade = "Fade", pop = "Pop", slideUp = "Slide Up", reveal = "Reveal", zoom = "Zoom", bounce = "Bounce"
    var id: String { rawValue }
}

enum TitlePosition: String, Codable, CaseIterable, Identifiable {
    case top = "Top", center = "Center", lowerThird = "Lower Third", bottom = "Bottom"
    var id: String { rawValue }
}

struct TitleItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var start: Double
    var duration: Double = 3
    var style: TitleStyle = .bold
    var animation: TitleAnimation = .pop
    var position: TitlePosition = .center
    var color: RGB = .white
    var size: Double = 1

    var end: Double { start + duration }
}

/// A still image (often a transparent PNG from Easel) shown over the video.
struct Graphic: Identifiable, Codable, Equatable {
    var id = UUID()
    var mediaID: UUID
    var start: Double
    var duration: Double = 4
    /// Center, as fractions of the frame (0,0 = top-left).
    var x: Double = 0.5
    var y: Double = 0.5
    /// Width as a fraction of the frame width.
    var scale: Double = 0.4
    var opacity: Double = 1
    var animation: TitleAnimation = .fade

    var end: Double { start + duration }
}

struct MusicClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var mediaID: UUID
    var start: Double
    var sourceStart: Double = 0
    var duration: Double
    var volume: Double = 0.8
    var fadeIn: Double = 0.5
    var fadeOut: Double = 1.5

    var end: Double { start + duration }
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case landscape = "16:9", portrait = "9:16", square = "1:1", vertical = "4:5", classic = "4:3", cinema = "21:9"
    var id: String { rawValue }

    var ratio: CGFloat {
        switch self {
        case .landscape: return 16.0 / 9
        case .portrait: return 9.0 / 16
        case .square: return 1
        case .vertical: return 4.0 / 5
        case .classic: return 4.0 / 3
        case .cinema: return 21.0 / 9
        }
    }

    /// Frame size whose short side is `short` pixels (even numbers, as encoders require).
    func size(short: CGFloat) -> CGSize {
        let w = ratio >= 1 ? short * ratio : short
        let h = ratio >= 1 ? short : short / ratio
        return CGSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
    }

    var label: String {
        switch self {
        case .landscape: return "16:9 Widescreen"
        case .portrait: return "9:16 Stories & Reels"
        case .square: return "1:1 Square"
        case .vertical: return "4:5 Portrait"
        case .classic: return "4:3 Classic"
        case .cinema: return "21:9 Cinema"
        }
    }
}

enum Background: String, Codable, CaseIterable, Identifiable {
    case blur = "Blur", black = "Black", white = "White"
    var id: String { rawValue }
}

struct Project: Codable, Equatable {
    var version = 1
    var aspect: AspectRatio = .landscape
    var background: Background = .blur
    var fps = 30
    var media: [MediaItem] = []
    var clips: [Clip] = []
    var titles: [TitleItem] = []
    var graphics: [Graphic] = []
    var music: [MusicClip] = []

    func media(_ id: UUID) -> MediaItem? { media.first { $0.id == id } }

    /// How long clip `i` overlaps the next one (its outgoing transition), limited so transitions
    /// never eat more than half of either clip.
    func overlap(after i: Int) -> Double {
        guard i + 1 < clips.count, let t = clips[i].transition else { return 0 }
        return max(0, min(t.duration, clips[i].duration / 2, clips[i + 1].duration / 2))
    }

    /// Timeline start of every clip on the main track (clips are back to back, minus transition overlaps).
    var clipStarts: [Double] {
        var starts: [Double] = []
        var t = 0.0
        for i in clips.indices {
            starts.append(t)
            t += clips[i].duration - overlap(after: i)
        }
        return starts
    }

    var mainDuration: Double {
        guard let last = clips.indices.last else { return 0 }
        return clipStarts[last] + clips[last].duration
    }

    /// The whole movie: the main track, or longer if titles or graphics run past it.
    var duration: Double {
        max(mainDuration, titles.map(\.end).max() ?? 0, graphics.map(\.end).max() ?? 0)
    }

    /// Index of the main-track clip under time `t` (the later one during a transition).
    func clipIndex(at t: Double) -> Int? {
        let starts = clipStarts
        return clips.indices.last { starts[$0] <= t + 1e-9 && t < starts[$0] + clips[$0].duration }
    }
}
