import Accelerate
import AVFoundation
import CoreGraphics
import EaselKit

/// Planar float audio. All of Tone's media is stored as 48 kHz stereo, so processing never has to
/// juggle formats.
struct AudioData {
    var channels: [[Float]]
    var sampleRate: Double

    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: Double { Double(frameCount) / sampleRate }

    init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    init(frames: Int, sampleRate: Double = AudioIO.sampleRate, channels: Int = 2) {
        self.channels = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        self.sampleRate = sampleRate
    }

    /// Mono mix (average of channels).
    var mono: [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var out = [Float](repeating: 0, count: frameCount)
        for c in channels { vDSP.add(out, c, result: &out) }
        vDSP.multiply(1 / Float(channels.count), out, result: &out)
        return out
    }

    func slice(_ range: Range<Int>) -> AudioData {
        let r = range.clamped(to: 0..<frameCount)
        return AudioData(channels: channels.map { Array($0[r]) }, sampleRate: sampleRate)
    }

    /// Replaces `range` with `other`, with tiny crossfades at the joins to avoid clicks.
    mutating func splice(_ other: AudioData, at start: Int) {
        let fade = min(64, other.frameCount / 4)
        for c in channels.indices where c < other.channels.count {
            for i in 0..<other.frameCount where start + i < frameCount {
                var w: Float = 1
                if i < fade { w = Float(i) / Float(fade) }
                if i >= other.frameCount - fade { w = min(w, Float(other.frameCount - 1 - i) / Float(fade)) }
                channels[c][start + i] = channels[c][start + i] * (1 - w) + other.channels[c][i] * w
            }
        }
    }
}

enum AudioIO {
    static let sampleRate = 48_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    enum IOError: LocalizedError {
        case noAudio, unreadable
        var errorDescription: String? {
            switch self {
            case .noAudio: return "That file has no audio"
            case .unreadable: return "Couldn’t read that audio"
            }
        }
    }

    static var mediaFolder: URL {
        let dir = AppLink.folder("Tone").appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newMediaURL() -> URL { mediaFolder.appendingPathComponent(UUID().uuidString + ".caf") }

    /// Converts any audio or video file to 48 kHz stereo float CAF. Returns the duration.
    static func conform(_ source: URL, to out: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw IOError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw IOError.unreadable }
        let file = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            // Interleaved → planar.
            pointer.withMemoryRebound(to: Float.self, capacity: count * 2) { src in
                let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
                for i in 0..<count {
                    l[i] = src[i * 2]
                    r[i] = src[i * 2 + 1]
                }
            }
            try file.write(from: buffer)
            frames += count
        }
        if reader.status == .failed { throw reader.error ?? IOError.unreadable }
        return Double(frames) / sampleRate
    }

    static func read(_ url: URL, from start: Int = 0, count: Int? = nil) throws -> AudioData {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(file.length)
        let first = min(max(0, start), total)
        let n = min(count ?? (total - first), total - first)
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else {
            return AudioData(frames: 0)
        }
        file.framePosition = AVAudioFramePosition(first)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
        let ch = Int(file.processingFormat.channelCount)
        var channels: [[Float]] = (0..<ch).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        if channels.count == 1 { channels.append(channels[0]) }
        return AudioData(channels: Array(channels.prefix(2)), sampleRate: file.processingFormat.sampleRate)
    }

    static func write(_ data: AudioData, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var offset = 0
        while offset < data.frameCount {
            let n = min(chunk, data.frameCount - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 {
                let src = data.channels[min(c, data.channels.count - 1)]
                src.withUnsafeBufferPointer { p in
                    buffer.floatChannelData![c].update(from: p.baseAddress! + offset, count: n)
                }
            }
            try file.write(from: buffer)
            offset += n
        }
    }

    /// Peak level per 1/`rate` second (max of both channels), for waveform drawing.
    static func peaks(_ url: URL, rate: Double = 200) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let per = max(1, Int(file.processingFormat.sampleRate / rate))
        let chunk = per * 512
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return [] }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(file.length) / per + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(chunk))
            let n = Int(buffer.frameLength)
            guard n > 0 else { break }
            var i = 0
            while i < n {
                let m = min(per, n - i)
                var peak: Float = 0
                for c in 0..<Int(buffer.format.channelCount) {
                    var v: Float = 0
                    vDSP_maxmgv(buffer.floatChannelData![c] + i, 1, &v, vDSP_Length(m))
                    peak = max(peak, v)
                }
                peaks.append(peak)
                i += m
            }
        }
        return peaks
    }
}

enum DSP {
    static func db(_ linear: Float) -> Float { 20 * log10(max(linear, 1e-9)) }
    static func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    // MARK: Level

    static func peak(_ data: AudioData) -> Float {
        data.channels.map { vDSP.maximumMagnitude($0) }.max() ?? 0
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
    }

    static func gain(_ data: inout AudioData, db: Double) {
        let g = linear(db)
        for c in data.channels.indices { vDSP.multiply(g, data.channels[c], result: &data.channels[c]) }
    }

    /// Scales so the loudest sample hits `peakDB` (dBFS).
    static func normalize(_ data: inout AudioData, peakDB: Double = -1) {
        let p = peak(data)
        guard p > 1e-6 else { return }
        gain(&data, db: peakDB - Double(db(p)))
    }

    static func reverse(_ data: inout AudioData) {
        for c in data.channels.indices { data.channels[c].reverse() }
    }

    static func invert(_ data: inout AudioData) {
        for c in data.channels.indices { vDSP.negative(data.channels[c], result: &data.channels[c]) }
    }

    static func removeDC(_ data: inout AudioData) {
        for c in data.channels.indices {
            let mean = vDSP.mean(data.channels[c])
            vDSP.add(-mean, data.channels[c], result: &data.channels[c])
        }
    }

    // MARK: Loudness (ITU-R BS.1770, integrated, gated)

    static func loudness(_ data: AudioData) -> Double {
        let sr = data.sampleRate
        // K-weighting coefficients are defined for 48 kHz.
        let stage1: [Double] = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
        let stage2: [Double] = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        let weighted = data.channels.map { biquad($0, sections: [stage1, stage2]) }
        let block = Int(0.4 * sr), hop = Int(0.1 * sr)
        guard data.frameCount >= block else { return -70 }
        var powers: [Double] = []
        var start = 0
        while start + block <= data.frameCount {
            var z = 0.0
            for ch in weighted {
                var ms: Float = 0
                ch.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &ms, vDSP_Length(block)) }
                z += Double(ms)
            }
            powers.append(z)
            start += hop
        }
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-12)) }
        let absolute = powers.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -70 }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return -70 }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Matches integrated loudness to `target` LUFS (−16 is the podcast/streaming norm), without clipping.
    static func normalizeLoudness(_ data: inout AudioData, target: Double = -16) {
        let current = loudness(data)
        guard current > -70 else { return }
        var change = target - current
        // Never push peaks past −1 dBFS.
        let headroom = -1 - Double(db(peak(data)))
        change = min(change, headroom)
        gain(&data, db: change)
    }

    // MARK: Filters

    /// Runs cascaded biquads. Each section is [b0, b1, b2, a1, a2] (a0 = 1).
    static func biquad(_ x: [Float], sections: [[Double]]) -> [Float] {
        guard !x.isEmpty, let setup = vDSP_biquad_CreateSetup(sections.flatMap { $0 }, vDSP_Length(sections.count)) else { return x }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * sections.count + 2)
        var out = [Float](repeating: 0, count: x.count)
        vDSP_biquad(setup, &delay, x, 1, &out, 1, vDSP_Length(x.count))
        return out
    }

    static func notch(frequency f: Double, q: Double, sampleRate sr: Double) -> [Double] {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return [1 / a0, -2 * cos(w) / a0, 1 / a0, -2 * cos(w) / a0, (1 - alpha) / a0]
    }

    static func highPass(frequency f: Double, sampleRate sr: Double) -> [Double] {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * 0.7071), c = cos(w), a0 = 1 + alpha
        return [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0]
    }

    /// Energy at one frequency (Goertzel).
    static func energy(_ x: [Float], at f: Double, sampleRate sr: Double) -> Double {
        let k = 2 * cos(2 * Double.pi * f / sr)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + k * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - k * s1 * s2
    }

    /// Which mains frequency (50 or 60 Hz) is humming, if any.
    static func detectHum(_ data: AudioData) -> Double {
        let mono = Array(data.mono.prefix(Int(data.sampleRate * 10)))
        return energy(mono, at: 50, sampleRate: data.sampleRate) > energy(mono, at: 60, sampleRate: data.sampleRate) ? 50 : 60
    }

    /// Notches out mains hum and its harmonics.
    static func removeHum(_ data: inout AudioData, base: Double? = nil, harmonics: Int = 8) {
        let f0 = base ?? detectHum(data)
        let sections = (1...harmonics).compactMap { h -> [Double]? in
            let f = f0 * Double(h)
            return f < data.sampleRate / 2 - 100 ? notch(frequency: f, q: 18 + Double(h) * 4, sampleRate: data.sampleRate) : nil
        }
        for c in data.channels.indices { data.channels[c] = biquad(data.channels[c], sections: sections) }
    }

    // MARK: De-click

    /// Finds short spikes that don't fit the waveform and redraws them by interpolation.
    /// Returns how many clicks were repaired.
    @discardableResult
    static func declick(_ data: inout AudioData, sensitivity: Float = 1) -> Int {
        var repaired = 0
        let span = 12
        for c in data.channels.indices {
            var x = data.channels[c]
            let n = x.count
            guard n > 4 else { continue }
            // Prediction error: how far each sample is from a straight continuation of the last two.
            var err = [Float](repeating: 0, count: n)
            for i in 2..<n { err[i] = abs(x[i] - (2 * x[i - 1] - x[i - 2])) }
            let block = 2048
            var i = 2
            while i < n {
                let blockStart = (i / block) * block
                let slice = err[blockStart..<min(n, blockStart + block)]
                let typical = slice.reduce(0, +) / Float(max(1, slice.count))
                let threshold = max(0.05, typical * 12 / max(0.2, sensitivity))
                if err[i] > threshold {
                    let a = max(0, i - 3), b = min(n - 1, i + span)
                    // Extend while the error stays high.
                    var end = b
                    while end < n - 1 && end - a < 200 && err[end] > threshold * 0.5 { end += 1 }
                    let left = x[a], right = x[min(n - 1, end + 1)]
                    let len = Float(end + 1 - a)
                    for k in a...end { x[k] = left + (right - left) * Float(k - a) / len }
                    repaired += 1
                    i = end + 1
                } else {
                    i += 1
                }
            }
            data.channels[c] = x
        }
        return repaired / max(1, data.channels.count)
    }

    // MARK: Noise reduction (spectral subtraction)

    static let fftSize = 2048

    private final class FFT {
        let n: Int, log2n: vDSP_Length, setup: FFTSetup
        let window: [Float]

        init(n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            // √Hann for analysis and synthesis: their product is a Hann window.
            window = (0..<n).map { sqrt(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n))) }
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Real FFT of a windowed frame into split complex (n/2 bins, DC and Nyquist packed in bin 0).
        func forward(_ frame: [Float], re: inout [Float], im: inout [Float]) {
            var windowed = [Float](repeating: 0, count: n)
            vDSP.multiply(frame, window, result: &windowed)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { w in
                        w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        func inverse(re: inout [Float], im: inout [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: n)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    out.withUnsafeMutableBufferPointer { o in
                        o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2))
                        }
                    }
                }
            }
            // zrip round trip scales by 2n.
            vDSP.multiply(1 / Float(2 * n), out, result: &out)
            vDSP.multiply(out, window, result: &out)
            return out
        }

        /// Magnitudes for bins 0..<n/2 (bin 0 = DC).
        func magnitudes(re: [Float], im: [Float]) -> [Float] {
            var m = [Float](repeating: 0, count: n / 2)
            m[0] = abs(re[0])
            for k in 1..<(n / 2) { m[k] = hypot(re[k], im[k]) }
            return m
        }
    }

    /// Average magnitude spectrum of a stretch of pure noise (the "noise print").
    static func noiseProfile(_ data: AudioData) -> [Float] {
        let fft = FFT(n: fftSize), hop = fftSize / 4
        let mono = data.mono
        var sum = [Float](repeating: 0, count: fftSize / 2)
        var frames = 0
        var re = [Float](repeating: 0, count: fftSize / 2), im = re
        var start = 0
        while start + fftSize <= mono.count {
            fft.forward(Array(mono[start..<start + fftSize]), re: &re, im: &im)
            vDSP.add(sum, fft.magnitudes(re: re, im: im), result: &sum)
            frames += 1
            start += hop
        }
        guard frames > 0 else { return sum }
        return vDSP.multiply(1 / Float(frames), sum)
    }

    /// The quietest half-second, used when no noise print was captured.
    static func quietestRange(_ data: AudioData, length: Double = 0.5) -> Range<Int> {
        let window = min(data.frameCount, Int(length * data.sampleRate))
        guard window > 0 else { return 0..<0 }
        let mono = data.mono
        var best = 0, bestRMS = Float.greatestFiniteMagnitude
        var start = 0
        while start + window <= mono.count {
            let r = rms(mono[start..<start + window])
            if r < bestRMS { bestRMS = r; best = start }
            start += window / 4
        }
        return best..<best + window
    }

    /// Removes steady background noise. `amount` 0…1 sets how far noise is pushed down (6–36 dB).
    static func reduceNoise(_ data: inout AudioData, profile: [Float], amount: Double = 0.7) {
        let n = fftSize, hop = n / 4, bins = n / 2
        guard profile.count == bins, data.frameCount > n else { return }
        let fft = FFT(n: n)
        let floorGain = Float(pow(10, -(6 + 30 * amount) / 20))
        let oversubtract: Float = 2 + 2 * Float(amount)
        let noisePower = profile.map { $0 * $0 }

        for c in data.channels.indices {
            let x = data.channels[c]
            // Pad so the edges get full overlap.
            let padded = [Float](repeating: 0, count: n) + x + [Float](repeating: 0, count: n)
            var out = [Float](repeating: 0, count: padded.count)
            var smoothedPower = [Float](repeating: 0, count: bins)
            var previousGain = [Float](repeating: 1, count: bins)
            var first = true
            var re = [Float](repeating: 0, count: bins), im = re
            var start = 0
            while start + n <= padded.count {
                fft.forward(Array(padded[start..<start + n]), re: &re, im: &im)
                let mag = fft.magnitudes(re: re, im: im)
                // Average the signal power over time and neighbouring bins before deciding what is
                // noise: raw noise spikes far above its mean and would otherwise leak through.
                var power = [Float](repeating: 0, count: bins)
                for k in 0..<bins {
                    let lo = max(0, k - 1), hi = min(bins - 1, k + 1)
                    var p: Float = 0
                    for j in lo...hi { p += mag[j] * mag[j] }
                    power[k] = p / Float(hi - lo + 1)
                }
                for k in 0..<bins { smoothedPower[k] = first ? power[k] : 0.55 * smoothedPower[k] + 0.45 * power[k] }
                first = false
                var smooth = [Float](repeating: 1, count: bins)
                for k in 0..<bins {
                    let ratio = noisePower[k] / max(1e-12, smoothedPower[k])
                    let g = max(floorGain, sqrt(max(0, 1 - oversubtract * ratio)))
                    // Gentle smoothing over time avoids "musical noise".
                    smooth[k] = 0.6 * g + 0.4 * previousGain[k]
                }
                previousGain = smooth
                re[0] *= smooth[0]
                im[0] *= smooth[bins - 1]
                for k in 1..<bins {
                    re[k] *= smooth[k]
                    im[k] *= smooth[k]
                }
                let frame = fft.inverse(re: &re, im: &im)
                // √Hann² at 75% overlap sums to 2.
                for i in 0..<n { out[start + i] += frame[i] * 0.5 }
                start += hop
            }
            data.channels[c] = Array(out[n..<(n + x.count)])
        }
    }

    // MARK: Silence

    /// Stretches quieter than `thresholdDB` for at least `minLength` seconds.
    static func silentRanges(_ data: AudioData, thresholdDB: Double = -45, minLength: Double = 0.5) -> [ClosedRange<Double>] {
        let window = max(1, Int(0.02 * data.sampleRate))
        let threshold = linear(thresholdDB)
        let mono = data.channels.count > 1 ? zip(data.channels[0], data.channels[1]).map { max(abs($0), abs($1)) } : data.channels[0].map(abs)
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?
        var i = 0
        while i < mono.count {
            let end = min(mono.count, i + window)
            let level = mono[i..<end].withUnsafeBufferPointer { vDSP.rootMeanSquare($0) } * 1.414
            if level < threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if Double(i - s) / data.sampleRate >= minLength { ranges.append(Double(s) / data.sampleRate...Double(i) / data.sampleRate) }
                runStart = nil
            }
            i = end
        }
        if let s = runStart, Double(mono.count - s) / data.sampleRate >= minLength {
            ranges.append(Double(s) / data.sampleRate...Double(mono.count) / data.sampleRate)
        }
        return ranges
    }

    // MARK: Spectrogram

    /// A spectrogram image (time → x, log frequency → y, loudness → color).
    static func spectrogram(_ data: AudioData, width: Int, height: Int) -> CGImage? {
        let n = 1024, bins = n / 2
        let fft = FFT(n: n)
        let mono = data.mono
        guard mono.count > n, width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var re = [Float](repeating: 0, count: bins), im = re
        let nyquist = data.sampleRate / 2
        let rowBins: [Int] = (0..<height).map { y in
            // Log frequency scale from 30 Hz to Nyquist; row 0 is the top (highest frequency).
            let t = 1 - Double(y) / Double(height - 1)
            let f = 30 * pow(nyquist / 30, t)
            return min(bins - 1, max(1, Int(f / nyquist * Double(bins))))
        }
        for x in 0..<width {
            let start = min(mono.count - n, Int(Double(x) / Double(width) * Double(mono.count - n)))
            fft.forward(Array(mono[start..<start + n]), re: &re, im: &im)
            let mag = fft.magnitudes(re: re, im: im)
            for y in 0..<height {
                let dbv = 20 * log10(max(1e-7, mag[rowBins[y]] / Float(n) * 4))
                let v = min(1, max(0, (dbv + 100) / 100))
                let (r, g, b) = heat(v)
                let o = (y * width + x) * 4
                pixels[o] = r; pixels[o + 1] = g; pixels[o + 2] = b; pixels[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Black → violet → orange → yellow → white.
    private static func heat(_ v: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0, 0, 0.02), (0.35, 0.05, 0.5), (0.9, 0.3, 0.2), (1, 0.75, 0.1), (1, 1, 0.9)]
        let p = v * Float(stops.count - 1)
        let i = min(stops.count - 2, Int(p)), t = p - Float(i)
        let a = stops[i], b = stops[i + 1]
        return (UInt8((a.0 + (b.0 - a.0) * t) * 255), UInt8((a.1 + (b.1 - a.1) * t) * 255), UInt8((a.2 + (b.2 - a.2) * t) * 255))
    }
}
