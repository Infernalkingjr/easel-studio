import AVFoundation
import AppKit
import CoreImage
import EaselKit

struct BuiltTimeline: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let plan: RenderPlan
    let duration: Double
}

enum TimelineBuilder {
    static let timescale: CMTimeScale = 600

    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((max(0, seconds) * Double(timescale)).rounded()), timescale: timescale)
    }

    /// Builds the playable/exportable movie. Fast: no media is decoded here.
    static func build(_ project: Project, library: MediaLibrary, filler: AVAssetTrack,
                      renderSize: CGSize, autoFilters: [UUID: [FilterSpec]] = [:]) throws -> BuiltTimeline {
        let composition = AVMutableComposition()
        let total = max(project.duration, 0.1)
        let totalTime = time(total)

        // A black backbone track spanning the whole movie keeps the compositor running over photos and gaps.
        let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        // 29 of the filler's 30 frames: safely inside the file however its last frame was timed.
        let fillerRange = CMTimeRange(start: .zero, duration: CMTime(value: 29, timescale: 30))
        try labeled("filler") { try base.insertTimeRange(fillerRange, of: filler, at: .zero) }
        base.scaleTimeRange(CMTimeRange(start: .zero, duration: fillerRange.duration), toDuration: totalTime)

        let videoTracks = (0..<2).map { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)! }
        let audioTracks = (0..<2).map { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)! }
        var audioParams: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        func params(_ track: AVMutableCompositionTrack) -> AVMutableAudioMixInputParameters {
            if let p = audioParams[track.trackID] { return p }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            audioParams[track.trackID] = p
            return p
        }

        var renders: [RenderPlan.ClipRender] = []
        let starts = project.clipStarts
        for (i, clip) in project.clips.enumerated() {
            guard let media = project.media(clip.mediaID) else { continue }
            let start = starts[i], end = start + clip.duration
            let overlapIn = i > 0 ? project.overlap(after: i - 1) : 0
            let overlapOut = project.overlap(after: i)
            var trackID: CMPersistentTrackID?
            var orientation: Int32 = 1

            if media.kind == .video, let loaded = library.loadedMedia(media.id), let video = loaded.video {
                let srcStart = min(clip.sourceStart, max(0, media.duration - 0.05))
                let srcDuration = min(clip.sourceDuration, media.duration - srcStart)
                let srcRange = CMTimeRange(start: time(srcStart), duration: time(srcDuration))
                let track = videoTracks[i % 2]
                try labeled("video clip \(i)") { try track.insertTimeRange(srcRange, of: video, at: time(start)) }
                if abs(clip.speed - 1) > 0.001 {
                    track.scaleTimeRange(CMTimeRange(start: time(start), duration: srcRange.duration), toDuration: time(clip.duration))
                }
                trackID = track.trackID
                orientation = loaded.orientation

                if let audio = loaded.audio, !clip.muted, clip.volume > 0 {
                    let aTrack = audioTracks[i % 2]
                    try labeled("audio clip \(i)") { try aTrack.insertTimeRange(srcRange, of: audio, at: time(start)) }
                    if abs(clip.speed - 1) > 0.001 {
                        aTrack.scaleTimeRange(CMTimeRange(start: time(start), duration: srcRange.duration), toDuration: time(clip.duration))
                    }
                    ramp(params(aTrack), start: start, end: end, volume: clip.volume,
                         fadeIn: max(clip.fadeIn, overlapIn), fadeOut: max(clip.fadeOut, overlapOut))
                }
            }
            renders.append(RenderPlan.ClipRender(
                clip: clip, start: start, end: end, trackID: trackID,
                photo: media.kind == .image ? library.image(media.id) : nil,
                orientation: orientation, autoFilters: clip.autoEnhance ? (autoFilters[clip.id] ?? []) : []))
        }

        // Music gets its own track per clip so pieces can overlap.
        for music in project.music {
            guard let media = project.media(music.mediaID), let audio = library.loadedMedia(media.id)?.audio else { continue }
            let length = min(music.duration, media.duration - music.sourceStart, total - music.start)
            guard length > 0.05 else { continue }
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try labeled("music") { try track.insertTimeRange(CMTimeRange(start: time(music.sourceStart), duration: time(length)), of: audio, at: time(music.start)) }
            ramp(params(track), start: music.start, end: music.start + length, volume: music.volume,
                 fadeIn: music.fadeIn, fadeOut: music.fadeOut)
        }

        let plan = RenderPlan(size: renderSize, background: project.background, clips: renders,
                              overlays: overlays(for: project, library: library, size: renderSize))

        // One instruction per stretch where the same video tracks are on screen.
        var cuts = Set<CMTimeValue>([0, totalTime.value])
        for r in renders where r.trackID != nil {
            cuts.insert(time(r.start).value)
            cuts.insert(min(time(r.end).value, totalTime.value))
        }
        let sorted = cuts.sorted()
        var instructions: [ReelInstruction] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            let range = CMTimeRange(start: CMTime(value: a, timescale: timescale), end: CMTime(value: b, timescale: timescale))
            let mid = range.start.seconds + range.duration.seconds / 2
            let ids = renders.filter { $0.trackID != nil && $0.start <= mid && mid < $0.end }.compactMap(\.trackID)
            instructions.append(ReelInstruction(timeRange: range, trackIDs: ids, plan: plan))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ReelCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.fps))
        videoComposition.instructions = instructions

        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(audioParams.values)
        return BuiltTimeline(composition: composition, videoComposition: videoComposition,
                             audioMix: mix, plan: plan, duration: total)
    }

    struct BuildError: LocalizedError {
        let step: String
        let underlying: Error
        var errorDescription: String? { "\(step): \(underlying.localizedDescription)" }
    }

    private static func labeled(_ step: String, _ work: () throws -> Void) throws {
        do { try work() } catch { throw BuildError(step: step, underlying: error) }
    }

    /// Volume envelope for one piece of audio: fade in, hold, fade out.
    private static func ramp(_ p: AVMutableAudioMixInputParameters, start: Double, end: Double,
                             volume: Double, fadeIn: Double, fadeOut: Double) {
        let v = Float(volume)
        let fi = min(fadeIn, (end - start) / 2), fo = min(fadeOut, (end - start) / 2)
        if fi > 0.01 {
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: time(start), duration: time(fi)))
        } else {
            p.setVolume(v, at: time(start))
        }
        if fo > 0.01 {
            p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: time(end - fo), duration: time(fo)))
        } else {
            p.setVolume(0, at: time(end))
        }
    }

    // MARK: Titles & graphics

    static func overlays(for project: Project, library: MediaLibrary, size: CGSize) -> [RenderPlan.Overlay] {
        var result: [RenderPlan.Overlay] = []
        for g in project.graphics {
            guard let image = library.image(g.mediaID) else { continue }
            let s = size.width * g.scale / max(1, image.extent.width)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            result.append(RenderPlan.Overlay(start: g.start, end: g.end, image: scaled,
                                             center: CGPoint(x: size.width * g.x, y: size.height * (1 - g.y)),
                                             animation: g.animation, opacity: g.opacity))
        }
        for title in project.titles where !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let image = TitleRenderer.image(for: title, frame: size) else { continue }
            let w = image.extent.width, h = image.extent.height
            let center: CGPoint
            switch title.position {
            case .top: center = CGPoint(x: size.width / 2, y: size.height * 0.86)
            case .center: center = CGPoint(x: size.width / 2, y: size.height / 2)
            case .lowerThird: center = CGPoint(x: size.width * 0.06 + w / 2, y: size.height * 0.2)
            case .bottom: center = CGPoint(x: size.width / 2, y: size.height * 0.07 + h / 2)
            }
            result.append(RenderPlan.Overlay(start: title.start, end: title.end, image: image, center: center,
                                             animation: title.animation, opacity: 1))
        }
        return result
    }
}

/// Draws styled text into images, cached so re-planning while editing is instant.
enum TitleRenderer {
    private static let cache = NSCache<NSString, CIImage>()

    static func image(for title: TitleItem, frame: CGSize) -> CIImage? {
        let key = "\(title.text)|\(title.style)|\(title.color.r),\(title.color.g),\(title.color.b)|\(title.size)|\(title.position)|\(frame.width)x\(frame.height)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = render(title, frame: frame) else { return nil }
        let ci = CIImage(cgImage: cg)
        cache.setObject(ci, forKey: key)
        return ci
    }

    static func render(_ title: TitleItem, frame: CGSize) -> CGImage? {
        let unit = min(frame.width, frame.height)
        let style = title.style
        let base: CGFloat = switch style {
        case .bold: 0.11
        case .clean: 0.085
        case .outline: 0.11
        case .boxed: 0.075
        case .lowerThird: 0.06
        case .subtitle: 0.055
        case .neon: 0.1
        case .serif: 0.095
        case .handwritten: 0.1
        }
        let fontSize = unit * base * title.size
        let font: NSFont = switch style {
        case .bold: .systemFont(ofSize: fontSize, weight: .heavy)
        case .clean: .systemFont(ofSize: fontSize, weight: .medium)
        case .outline: .systemFont(ofSize: fontSize, weight: .black)
        case .boxed, .lowerThird, .subtitle: .systemFont(ofSize: fontSize, weight: .semibold)
        case .neon: NSFont(name: "AvenirNext-Heavy", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .heavy)
        case .serif: NSFont(name: "Didot-Bold", size: fontSize) ?? NSFont(name: "Georgia-Bold", size: fontSize) ?? .systemFont(ofSize: fontSize)
        case .handwritten: NSFont(name: "MarkerFelt-Wide", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .bold)
        }
        let color = NSColor(cgColor: title.color.cg) ?? .white
        let luminance = 0.299 * title.color.r + 0.587 * title.color.g + 0.114 * title.color.b
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style == .lowerThird ? .left : .center

        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: color]
        let shadow = NSShadow()
        switch style {
        case .bold, .clean, .serif, .handwritten:
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = fontSize * 0.12
            shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.03)
            attrs[.shadow] = shadow
        case .outline:
            attrs[.strokeColor] = NSColor.black
            attrs[.strokeWidth] = -7
        case .boxed:
            attrs[.foregroundColor] = luminance > 0.6 ? NSColor.black : NSColor.white
        case .neon:
            shadow.shadowColor = color
            shadow.shadowBlurRadius = fontSize * 0.35
            attrs[.shadow] = shadow
            attrs[.foregroundColor] = color.blended(withFraction: 0.65, of: .white) ?? color
        case .lowerThird, .subtitle:
            break
        }

        let text = NSAttributedString(string: title.text, attributes: attrs)
        let maxWidth = frame.width * (style == .lowerThird ? 0.6 : 0.86)
        let bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).integral
        let pad: CGFloat = switch style {
        case .boxed, .subtitle: fontSize * 0.45
        case .lowerThird: fontSize * 0.5
        case .neon: fontSize * 0.6
        default: fontSize * 0.25
        }
        let accent: CGFloat = style == .lowerThird ? fontSize * 0.18 : 0
        let size = CGSize(width: bounds.width + pad * 2 + accent, height: bounds.height + pad * 2)
        guard size.width >= 1, size.height >= 1 else { return nil }

        return Bitmap.render(size) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let full = CGRect(origin: .zero, size: size)
            switch style {
            case .boxed:
                color.setFill()
                NSBezierPath(roundedRect: full, xRadius: fontSize * 0.25, yRadius: fontSize * 0.25).fill()
            case .subtitle:
                NSColor.black.withAlphaComponent(0.62).setFill()
                NSBezierPath(roundedRect: full, xRadius: fontSize * 0.25, yRadius: fontSize * 0.25).fill()
            case .lowerThird:
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: full, xRadius: fontSize * 0.12, yRadius: fontSize * 0.12).fill()
                color.setFill()
                NSRect(x: 0, y: 0, width: accent, height: size.height).fill()
            default:
                break
            }
            let drawRect = CGRect(x: pad + accent, y: pad, width: bounds.width, height: bounds.height)
            text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            if style == .neon { text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading]) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
