import AVFoundation
import AppKit
import CoreImage
import EaselKit

/// Loaded AVFoundation objects for one media item, so rebuilding the timeline never waits on I/O.
final class LoadedMedia: @unchecked Sendable {
    let asset: AVURLAsset
    let video: AVAssetTrack?
    let audio: AVAssetTrack?
    /// EXIF-style orientation for the video track (1 = up).
    let orientation: Int32

    init(asset: AVURLAsset, video: AVAssetTrack?, audio: AVAssetTrack?, orientation: Int32) {
        self.asset = asset
        self.video = video
        self.audio = audio
        self.orientation = orientation
    }
}

/// Imports media and caches everything derived from it: decoded photos, filmstrip thumbnails and
/// audio waveforms. All heavy work happens off the main thread.
final class MediaLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [UUID: LoadedMedia] = [:]
    private var images: [UUID: CIImage] = [:]
    private var waveforms: [UUID: [Float]] = [:]
    private var waveformJobs: Set<UUID> = []
    private let thumbs = NSCache<NSString, CGImage>()
    private var thumbJobs: Set<String> = []
    private var generators: [UUID: AVAssetImageGenerator] = [:]

    /// Called on the main thread whenever a thumbnail or waveform finishes loading.
    var onUpdate: (() -> Void)?

    init() { thumbs.countLimit = 4000 }

    // MARK: Import

    static let videoTypes = ["mov", "mp4", "m4v", "avi", "mkv", "hevc", "3gp"]
    static let audioTypes = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "caf", "flac"]

    /// Reads a file's kind, duration and size. Returns nil for unsupported files.
    func importMedia(_ url: URL, id: UUID = UUID()) async -> MediaItem? {
        let ext = url.pathExtension.lowercased()
        if Self.audioTypes.contains(ext) || Self.videoTypes.contains(ext) {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
            let video = try? await asset.loadTracks(withMediaType: .video).first
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            var size = CGSize.zero
            var orientation: Int32 = 1
            if let video {
                let natural = (try? await video.load(.naturalSize)) ?? .zero
                let transform = (try? await video.load(.preferredTransform)) ?? .identity
                orientation = Self.exifOrientation(transform)
                size = [5, 6, 7, 8].contains(orientation) ? CGSize(width: natural.height, height: natural.width) : natural
            }
            let item = MediaItem(id: id, url: url, kind: video == nil ? .audio : .video, duration: duration.seconds,
                                 size: size, hasAudio: audio != nil)
            store(LoadedMedia(asset: asset, video: video, audio: audio, orientation: orientation), for: item.id)
            return item
        }
        guard let cg = Bitmap.load(url: url) else { return nil }
        var item = MediaItem(id: id, url: url, kind: .image, duration: 0, size: CGSize(width: cg.width, height: cg.height), hasAudio: false)
        item.hasAlpha = Self.hasTransparency(cg)
        lock.withLock { images[item.id] = Self.ciImage(cg) }
        return item
    }

    /// Re-opens media referenced by a saved project, keeping its id.
    func reload(_ item: MediaItem) async -> Bool {
        await importMedia(item.url, id: item.id) != nil
    }

    /// Reloads a photo after it changed on disk (e.g. saved back from Easel).
    func refreshImage(_ item: MediaItem) {
        guard let cg = Bitmap.load(url: item.url) else { return }
        lock.withLock {
            images[item.id] = Self.ciImage(cg)
            thumbs.removeAllObjects()
        }
    }

    private func store(_ media: LoadedMedia, for id: UUID) {
        lock.withLock { loaded[id] = media }
    }

    func loadedMedia(_ id: UUID) -> LoadedMedia? { lock.withLock { loaded[id] } }
    func image(_ id: UUID) -> CIImage? { lock.withLock { images[id] } }

    private static func ciImage(_ cg: CGImage) -> CIImage {
        // Decode once into a GPU-friendly image; cap huge photos so playback stays light.
        let maxSide: CGFloat = 4096
        let scaled = max(cg.width, cg.height) > Int(maxSide) ? ImageOps.downscaled(cg, maxSide: maxSide) : cg
        return CIImage(cgImage: scaled, options: [.applyOrientationProperty: false])
    }

    private static func hasTransparency(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let small = ImageOps.downscaled(cg, maxSide: 64)
        let ctx = Bitmap.context(CGSize(width: small.width, height: small.height))
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * small.height) else { return false }
        for y in 0..<small.height {
            for x in 0..<small.width where data[y * ctx.bytesPerRow + x * 4 + 3] < 250 { return true }
        }
        return false
    }

    static func exifOrientation(_ t: CGAffineTransform) -> Int32 {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): return 6    // rotated 90° (portrait iPhone video)
        case (0, -1, 1, 0): return 8    // rotated 270°
        case (-1, 0, 0, -1): return 3   // upside down
        default: return 1
        }
    }

    // MARK: Thumbnails

    /// A filmstrip thumbnail near `time`, or nil while it loads (then `onUpdate` fires).
    func thumbnail(for item: MediaItem, at time: Double) -> CGImage? {
        if item.kind == .image {
            let key = "\(item.id)-img" as NSString
            if let hit = thumbs.object(forKey: key) { return hit }
            guard let ci = image(item.id),
                  let cg = ImageOps.ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            let small = ImageOps.downscaled(cg, maxSide: 240)
            thumbs.setObject(small, forKey: key)
            return small
        }
        guard item.kind == .video else { return nil }
        let slot = (time * 2).rounded() / 2
        let key = "\(item.id)-\(slot)"
        if let hit = thumbs.object(forKey: key as NSString) { return hit }
        let start: Bool = lock.withLock {
            if thumbJobs.contains(key) { return false }
            thumbJobs.insert(key)
            return true
        }
        guard start, let media = loadedMedia(item.id) else { return nil }
        let generator: AVAssetImageGenerator = lock.withLock {
            if let g = generators[item.id] { return g }
            let g = AVAssetImageGenerator(asset: media.asset)
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 240, height: 240)
            g.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            generators[item.id] = g
            return g
        }
        let t = CMTime(seconds: min(slot, max(0, item.duration - 0.05)), preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { [weak self] _, image, _, _, _ in
            guard let self else { return }
            if let image { self.thumbs.setObject(image, forKey: key as NSString) }
            self.lock.withLock { _ = self.thumbJobs.remove(key) }
            DispatchQueue.main.async { self.onUpdate?() }
        }
        return nil
    }

    // MARK: Waveforms

    static let waveformRate: Double = 50  // peaks per second

    /// Peak levels (0…1) at `waveformRate` per second, or nil while loading.
    func waveform(for item: MediaItem) -> [Float]? {
        guard item.hasAudio else { return nil }
        let (cached, start): ([Float]?, Bool) = lock.withLock {
            if let w = waveforms[item.id] { return (w, false) }
            if waveformJobs.contains(item.id) { return (nil, false) }
            waveformJobs.insert(item.id)
            return (nil, true)
        }
        if let cached { return cached }
        guard start, let media = loadedMedia(item.id), let track = media.audio else { return nil }
        let id = item.id
        Task.detached(priority: .utility) { [weak self] in
            let peaks = Self.readPeaks(asset: media.asset, track: track)
            guard let self else { return }
            self.lock.withLock { self.waveforms[id] = peaks }
            await MainActor.run { self.onUpdate?() }
        }
        return nil
    }

    private static func readPeaks(asset: AVAsset, track: AVAssetTrack) -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perPeak = Int(sampleRate / waveformRate)
        var peaks: [Float] = []
        var current: Int16 = 0, count = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let v = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                    if v > current { current = v }
                    count += 1
                    if count == perPeak {
                        peaks.append(Float(current) / Float(Int16.max))
                        current = 0
                        count = 0
                    }
                }
            }
        }
        return peaks
    }

    // MARK: Filler

    /// A short black video used as the timeline's backbone, so playback always has a video track
    /// even across photos and gaps. Created once and cached on disk.
    static let fillerURL: URL = {
        let dir = AppLink.sharedFolder.appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("filler-v1.mov")
    }()

    static func ensureFiller() async throws -> AVURLAsset {
        if !FileManager.default.fileExists(atPath: fillerURL.path) {
            try await writeFiller(to: fillerURL)
        }
        return AVURLAsset(url: fillerURL)
    }

    private static func writeFiller(to url: URL) async throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent("filler-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
