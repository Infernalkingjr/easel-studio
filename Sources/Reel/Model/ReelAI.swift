import AVFoundation
import CoreImage
import Speech

enum ReelAI {
    // MARK: Auto enhance

    static func autoEnhanceFilters(for media: MediaItem, at time: Double, library: MediaLibrary) async -> [FilterSpec] {
        let image: CIImage?
        if media.kind == .image {
            image = library.image(media.id)
        } else if let asset = library.loadedMedia(media.id)?.asset {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            image = (try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image).map { CIImage(cgImage: $0) }
        } else {
            image = nil
        }
        guard let image else { return [] }
        return image.autoAdjustmentFilters(options: [.redEye: false]).map { filter in
            var params: [String: Any] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                if let value = filter.value(forKey: key) { params[key] = value }
            }
            return FilterSpec(name: filter.name, parameters: params)
        }
    }

    // MARK: Scene detection

    /// Source times where the picture changes abruptly (hard cuts between shots).
    static func sceneCuts(in media: MediaItem, from start: Double, length: Double, library: MediaLibrary) async -> [Double] {
        guard let asset = library.loadedMedia(media.id)?.asset else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
        let step = 0.2
        let times = stride(from: start, to: start + length, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }

        var previous: [Float]?
        var history: [Float] = []
        var cuts: [Double] = []
        var lastCut = start
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            let t = result.requestedTime.seconds
            let hist = histogram(image)
            defer { previous = hist }
            guard let previous else { continue }
            let distance = zip(hist, previous).reduce(0) { $0 + abs($1.0 - $1.1) } / 2
            let typical = history.isEmpty ? 0 : history.reduce(0, +) / Float(history.count)
            history.append(distance)
            if history.count > 10 { history.removeFirst() }
            if distance > 0.45 && distance > typical * 3 && t - lastCut >= 0.8 {
                cuts.append(t - step / 2)
                lastCut = t
            }
        }
        return cuts.filter { $0 > start + 0.3 && $0 < start + length - 0.3 }
    }

    /// 8 bins per channel, normalised so each channel sums to 1.
    private static func histogram(_ image: CGImage) -> [Float] {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bins = [Float](repeating: 0, count: 24)
        for i in 0..<(w * h) {
            bins[Int(data[i * 4]) >> 5] += 1
            bins[8 + Int(data[i * 4 + 1]) >> 5] += 1
            bins[16 + Int(data[i * 4 + 2]) >> 5] += 1
        }
        let n = Float(w * h)
        return bins.map { $0 / n }
    }

    // MARK: Captions

    struct Caption: Equatable {
        var text: String
        var start: Double
        var duration: Double
    }

    struct Word {
        let text: String
        let start: Double
        let duration: Double
    }

    enum CaptionError: LocalizedError {
        case denied, unavailable, noAudio

        var errorDescription: String? {
            switch self {
            case .denied: return "Allow Speech Recognition for Reel in System Settings → Privacy & Security"
            case .unavailable: return "Speech recognition isn’t available right now"
            case .noAudio: return "This video has no audio to caption"
            }
        }
    }

    /// Transcribes the timeline's mixed audio, on-device when the Mac supports it.
    static func captions(for built: BuiltTimeline) async throws -> [Caption] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw CaptionError.denied }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw CaptionError.unavailable }

        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("reel-captions-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard !built.composition.tracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptionError.noAudio
        }
        export.audioMix = built.audioMix
        try await export.export(to: audioURL, as: .m4a)

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true

        let words: [Word] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    })
                } else if let error {
                    finished = true
                    // "No speech detected" is an empty result, not a failure.
                    if (error as NSError).code == 1110 { continuation.resume(returning: []) } else { continuation.resume(throwing: error) }
                }
            }
        }
        return group(words)
    }

    /// Joins words into short caption lines, breaking on pauses and length.
    static func group(_ words: [Word], maxWords: Int = 6, maxChars: Int = 38, pause: Double = 0.6) -> [Caption] {
        var lines: [Caption] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(Caption(text: current.map(\.text).joined(separator: " "), start: first.start,
                                 duration: max(0.6, last.start + last.duration - first.start)))
            current.removeAll()
        }
        for word in words {
            if let last = current.last {
                let gap = word.start - (last.start + last.duration)
                let chars = current.map(\.text.count).reduce(0, +) + current.count + word.text.count
                if gap > pause || current.count >= maxWords || chars > maxChars { flush() }
            }
            current.append(word)
            if word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") { flush() }
        }
        flush()
        // Let each line linger a little, without running into the next.
        for i in lines.indices {
            let limit = i + 1 < lines.count ? lines[i + 1].start - lines[i].start : lines[i].duration + 0.5
            lines[i].duration = min(lines[i].duration + 0.35, limit)
        }
        return lines
    }
}
