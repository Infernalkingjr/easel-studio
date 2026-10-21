import Foundation
import AVFoundation

struct AudioAsset: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Tone's conformed 48 kHz stereo copy.
    var url: URL
    var name: String
    var duration: Double
}

struct Region: Identifiable, Codable, Equatable {
    var id = UUID()
    var assetID: UUID
    /// Timeline position (seconds).
    var start: Double
    /// Where in the file the region begins.
    var offset: Double = 0
    var duration: Double
    var gainDB: Double = 0
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var muted = false

    var end: Double { start + duration }
}

enum ReverbRoom: String, Codable, CaseIterable, Identifiable {
    case smallRoom = "Small Room", mediumRoom = "Room", mediumHall = "Hall", plate = "Plate", cathedral = "Cathedral"
    var id: String { rawValue }
    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .mediumHall: return .mediumHall
        case .plate: return .plate
        case .cathedral: return .cathedral
        }
    }
}

struct TrackFX: Codable, Equatable {
    var lowCut = false
    var low: Double = 0      // dB, shelf at 120 Hz
    var mid: Double = 0      // dB, bell at 1.2 kHz
    var high: Double = 0     // dB, shelf at 8 kHz
    var compressor: Double = 0   // 0…1
    var reverb: Double = 0       // wet %, 0…100
    var room: ReverbRoom = .mediumRoom
    var delay: Double = 0        // wet %, 0…100
    var delayTime: Double = 0.3
    var delayFeedback: Double = 35

    /// Quick starting points.
    static let presets: [(String, TrackFX)] = [
        ("Clean", TrackFX()),
        ("Podcast Voice", TrackFX(lowCut: true, low: -2, mid: 2, high: 3, compressor: 0.6)),
        ("Warm Vocal", TrackFX(lowCut: true, low: 2, mid: -1, high: 2, compressor: 0.45, reverb: 12, room: .plate)),
        ("Radio", TrackFX(lowCut: true, low: -12, mid: 6, high: -10, compressor: 0.8)),
        ("Big Room", TrackFX(reverb: 35, room: .mediumHall)),
        ("Echo", TrackFX(delay: 30, delayTime: 0.38, delayFeedback: 45)),
        ("Phone", TrackFX(lowCut: true, low: -24, mid: 8, high: -24, compressor: 0.7)),
    ]
}

struct Track: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var colorIndex = 0
    var volumeDB: Double = 0
    var pan: Double = 0
    var muted = false
    var solo = false
    var armed = false
    var fx = TrackFX()
    var regions: [Region] = []
}

struct Session: Codable, Equatable {
    var version = 1
    var tracks: [Track] = [Track(name: "Track 1", colorIndex: 0), Track(name: "Track 2", colorIndex: 1)]
    var assets: [AudioAsset] = []
    var masterDB: Double = 0
    var limiter = true

    func asset(_ id: UUID) -> AudioAsset? { assets.first { $0.id == id } }

    var duration: Double {
        tracks.flatMap(\.regions).map(\.end).max() ?? 0
    }

    var anySolo: Bool { tracks.contains { $0.solo } }

    /// Whether a track is heard, taking mute and solo into account.
    func isAudible(_ track: Track) -> Bool {
        !track.muted && (!anySolo || track.solo)
    }
}
