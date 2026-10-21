import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ExportSettings: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case h264 = "MP4 (H.264)", hevc = "MOV (HEVC)", gif = "GIF", audio = "Audio (M4A)"
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .h264: return "mp4"
            case .hevc: return "mov"
            case .gif: return "gif"
            case .audio: return "m4a"
            }
        }
        var note: String {
            switch self {
            case .h264: return "Plays everywhere — best for sharing and uploading."
            case .hevc: return "Same quality at about half the size. Great on Apple devices."
            case .gif: return "Silent looping animation, small and low frame rate."
            case .audio: return "Just the soundtrack."
            }
        }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case standard = "Standard", high = "High", best = "Best"
        var id: String { rawValue }
        var bitsPerPixel: Double {
            switch self {
            case .standard: return 0.1
            case .high: return 0.18
            case .best: return 0.3
            }
        }
    }

    var format: Format = .h264
    var shortSide: CGFloat = 1080
    var fps = 30
    var quality: Quality = .high
}

enum Exporter {
    enum ExportError: LocalizedError {
        case setup(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .setup(let s), .failed(let s): return s
            }
        }
    }

    static func export(_ project: Project, library: MediaLibrary, filler: AVAssetTrack, autoFilters: [UUID: [FilterSpec]],
                       settings: ExportSettings, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var project = project
        project.fps = settings.format == .gif ? min(settings.fps, 15) : settings.fps
        let short = settings.format == .gif ? min(settings.shortSide, 480) : settings.shortSide
        let size = project.aspect.size(short: short)
        let built = try TimelineBuilder.build(project, library: library, filler: filler, renderSize: size, autoFilters: autoFilters)
        try? FileManager.default.removeItem(at: url)

        switch settings.format {
        case .audio:
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw ExportError.setup("Couldn’t prepare the audio export")
            }
            session.audioMix = built.audioMix
            try await session.export(to: url, as: .m4a)
            progress(1)
        case .gif:
            try await exportGIF(built, fps: project.fps, to: url, progress: progress)
        case .h264, .hevc:
            try await exportMovie(built, settings: settings, size: size, fps: project.fps, to: url, progress: progress)
        }
    }

    private static func audioTracks(_ built: BuiltTimeline) -> [AVAssetTrack] {
        built.composition.tracks(withMediaType: .audio).filter { !$0.segments.isEmpty }
    }

    private static func exportMovie(_ built: BuiltTimeline, settings: ExportSettings, size: CGSize, fps: Int,
                                    to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        let audio = audioTracks(built)
        let audioOut: AVAssetReaderAudioMixOutput? = audio.isEmpty ? nil : AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        if let audioOut {
            audioOut.audioMix = built.audioMix
            audioOut.audioTimePitchAlgorithm = .spectral
            reader.add(audioOut)
        }

        let fileType: AVFileType = settings.format == .hevc ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let bitrate = Double(size.width * size.height) * Double(fps) * settings.quality.bitsPerPixel * (settings.format == .hevc ? 0.6 : 1)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        if settings.format == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.format == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        let audioIn: AVAssetWriterInput? = audioOut == nil ? nil : AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        if let audioIn {
            audioIn.expectsMediaDataInRealTime = false
            writer.add(audioIn)
        }

        guard reader.startReading() else { throw ExportError.setup(reader.error?.localizedDescription ?? "Couldn’t read the timeline") }
        guard writer.startWriting() else { throw ExportError.setup(writer.error?.localizedDescription ?? "Couldn’t write the file") }
        writer.startSession(atSourceTime: .zero)

        let duration = built.duration
        // Video and audio are written in parallel, each on its own queue.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoOut, into: videoIn, queue: DispatchQueue(label: "reel.export.video")) { time in
                progress(min(0.999, time / duration))
            } }
            if let audioOut, let audioIn {
                group.addTask { await pump(audioOut, into: audioIn, queue: DispatchQueue(label: "reel.export.audio")) { _ in } }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed(reader.error?.localizedDescription ?? "Reading failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.failed(writer.error?.localizedDescription ?? "Writing failed") }
        progress(1)
    }

    /// AVFoundation's reader/writer objects are used from one serial queue here, which is safe.
    private struct Pipe: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue: DispatchQueue,
                             onTime: @escaping @Sendable (Double) -> Void) async {
        let pipe = Pipe(output: output, input: input)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var done = false
            pipe.input.requestMediaDataWhenReady(on: queue) {
                guard !done else { return }
                while pipe.input.isReadyForMoreMediaData {
                    guard let buffer = pipe.output.copyNextSampleBuffer() else {
                        done = true
                        pipe.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onTime(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                    if !pipe.input.append(buffer) {
                        done = true
                        pipe.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    private static func exportGIF(_ built: BuiltTimeline, fps: Int, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = built.videoComposition
        reader.add(out)
        // The reader can deliver a frame or two more than duration × fps; ImageIO rejects extras.
        let frameCount = max(1, Int((built.duration * Double(fps)).rounded(.up)) + 4)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.setup("Couldn’t create the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        guard reader.startReading() else { throw ExportError.setup(reader.error?.localizedDescription ?? "Couldn’t read the timeline") }
        let delay = 1.0 / Double(fps)
        let context = CIContext()
        while let buffer = out.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let ci = CIImage(cvPixelBuffer: pixels)
            if let cg = context.createCGImage(ci, from: ci.extent) {
                CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            progress(min(0.999, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / built.duration))
        }
        guard reader.status != .failed, CGImageDestinationFinalize(dest) else {
            throw ExportError.failed(reader.error?.localizedDescription ?? "Couldn’t finish the GIF")
        }
        progress(1)
    }
}
