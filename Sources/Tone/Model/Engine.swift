import AVFoundation
import Accelerate
import AudioToolbox

/// Audio of each region with gain and fades baked in, cached so playback starts instantly.
final class RegionBuffers: @unchecked Sendable {
    private let cache = NSCache<NSString, AVAudioPCMBuffer>()

    init() { cache.totalCostLimit = 1_500_000_000 }

    private func key(_ r: Region, _ a: AudioAsset) -> NSString {
        "\(a.id)|\(a.url.lastPathComponent)|\(r.offset)|\(r.duration)|\(r.gainDB)|\(r.fadeIn)|\(r.fadeOut)" as NSString
    }

    func buffer(for region: Region, asset: AudioAsset) -> AVAudioPCMBuffer? {
        let k = key(region, asset)
        if let hit = cache.object(forKey: k) { return hit }
        let sr = AudioIO.sampleRate
        guard var data = try? AudioIO.read(asset.url, from: Int(region.offset * sr), count: Int(region.duration * sr)),
              data.frameCount > 0 else { return nil }
        if region.gainDB != 0 { DSP.gain(&data, db: region.gainDB) }
        applyFades(&data, fadeIn: region.fadeIn, fadeOut: region.fadeOut)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioIO.format, frameCapacity: AVAudioFrameCount(data.frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(data.frameCount)
        for c in 0..<2 {
            data.channels[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: data.frameCount) }
        }
        cache.setObject(buffer, forKey: k, cost: data.frameCount * 8)
        return buffer
    }

    /// Equal-power fade curves.
    private func applyFades(_ data: inout AudioData, fadeIn: Double, fadeOut: Double) {
        let n = data.frameCount
        let fi = min(n, Int(fadeIn * data.sampleRate)), fo = min(n, Int(fadeOut * data.sampleRate))
        for c in data.channels.indices {
            for i in 0..<fi { data.channels[c][i] *= sin(Float(i) / Float(fi) * .pi / 2) }
            for i in 0..<fo { data.channels[c][n - 1 - i] *= sin(Float(i) / Float(fo) * .pi / 2) }
        }
    }

    static func slice(_ buffer: AVAudioPCMBuffer, from frame: Int) -> AVAudioPCMBuffer? {
        let remaining = Int(buffer.frameLength) - frame
        guard remaining > 0, let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(remaining)) else { return nil }
        out.frameLength = AVAudioFrameCount(remaining)
        for c in 0..<Int(buffer.format.channelCount) {
            out.floatChannelData![c].update(from: buffer.floatChannelData![c] + frame, count: remaining)
        }
        return out
    }

    func clear() { cache.removeAllObjects() }
}

/// One channel strip: players → EQ → compressor → delay → reverb → volume/pan.
/// A player can only play one clip at a time, so overlapping clips get a player each.
final class Strip {
    private(set) var players = [AVAudioPlayerNode()]
    let voices = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    let mixer = AVAudioMixerNode()
    private var room: ReverbRoom?
    private weak var engine: AVAudioEngine?

    var nodes: [AVAudioNode] { players + [voices, eq, compressor, delay, reverb, mixer] }

    init() {
        let bands = eq.bands
        bands[0].filterType = .highPass; bands[0].frequency = 80
        bands[1].filterType = .lowShelf; bands[1].frequency = 120
        bands[2].filterType = .parametric; bands[2].frequency = 1200; bands[2].bandwidth = 1.2
        bands[3].filterType = .highShelf; bands[3].frequency = 8000
    }

    func attach(to engine: AVAudioEngine, output: AVAudioNode, bus: AVAudioNodeBus) {
        self.engine = engine
        nodes.forEach { engine.attach($0) }
        let f = AudioIO.format
        for player in players { engine.connect(player, to: voices, fromBus: 0, toBus: voices.nextAvailableInputBus, format: f) }
        engine.connect(voices, to: eq, format: f)
        engine.connect(eq, to: compressor, format: f)
        engine.connect(compressor, to: delay, format: f)
        engine.connect(delay, to: reverb, format: f)
        engine.connect(reverb, to: mixer, format: f)
        engine.connect(mixer, to: output, fromBus: 0, toBus: bus, format: f)
    }

    func detach(from engine: AVAudioEngine) {
        stop()
        nodes.forEach { engine.detach($0) }
    }

    func play() { players.forEach { $0.play() } }
    func stop() { players.forEach { $0.stop() } }

    /// Spreads the track's clips over as few players as possible so none of them overlap.
    static func lanes(_ regions: [Region]) -> [[Region]] {
        var lanes: [[Region]] = []
        for region in regions.filter({ !$0.muted }).sorted(by: { $0.start < $1.start }) {
            if let i = lanes.firstIndex(where: { $0.last!.end <= region.start + 1e-6 }) {
                lanes[i].append(region)
            } else {
                lanes.append([region])
            }
        }
        return lanes
    }

    func apply(_ track: Track, audible: Bool) {
        if let engine {
            for _ in players.count..<max(players.count, Self.lanes(track.regions).count) {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: voices, fromBus: 0, toBus: voices.nextAvailableInputBus, format: AudioIO.format)
                players.append(player)
            }
        }
        let fx = track.fx
        mixer.outputVolume = audible ? DSP.linear(track.volumeDB) : 0
        mixer.pan = Float(track.pan)

        let b = eq.bands
        b[0].bypass = !fx.lowCut
        b[1].gain = Float(fx.low); b[1].bypass = fx.low == 0
        b[2].gain = Float(fx.mid); b[2].bypass = fx.mid == 0
        b[3].gain = Float(fx.high); b[3].bypass = fx.high == 0
        eq.bypass = !fx.lowCut && fx.low == 0 && fx.mid == 0 && fx.high == 0

        compressor.bypass = fx.compressor <= 0.001
        if !compressor.bypass {
            let unit = compressor.audioUnit, amount = Float(fx.compressor)
            AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -8 - 30 * amount, 0)
            AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6 - 3 * amount, 0)
            AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
            AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.12, 0)
            AudioUnitSetParameter(unit, 6 /* overall/master gain */, kAudioUnitScope_Global, 0, 10 * amount, 0)
        }

        delay.bypass = fx.delay <= 0.01
        delay.wetDryMix = Float(fx.delay)
        delay.delayTime = fx.delayTime
        delay.feedback = Float(fx.delayFeedback)
        delay.lowPassCutoff = 9000

        reverb.bypass = fx.reverb <= 0.01
        if room != fx.room {
            reverb.loadFactoryPreset(fx.room.preset)
            room = fx.room
        }
        reverb.wetDryMix = Float(fx.reverb)
    }

    /// Queues every region that is still ahead of `from` on its player's own clock.
    func schedule(_ track: Track, session: Session, from: Double, buffers: RegionBuffers) {
        let sr = AudioIO.sampleRate
        for (lane, player) in zip(Self.lanes(track.regions), players) {
            for region in lane where region.end > from {
                guard let asset = session.asset(region.assetID), let full = buffers.buffer(for: region, asset: asset) else { continue }
                if region.start >= from {
                    player.scheduleBuffer(full, at: AVAudioTime(sampleTime: AVAudioFramePosition((region.start - from) * sr), atRate: sr))
                } else if let rest = RegionBuffers.slice(full, from: Int((from - region.start) * sr)) {
                    player.scheduleBuffer(rest, at: AVAudioTime(sampleTime: 0, atRate: sr))
                }
            }
        }
    }
}

/// Live playback, metering and recording.
final class ToneEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
    let buffers = RegionBuffers()
    private(set) var strips: [UUID: Strip] = [:]
    private var order: [UUID] = []
    private let busMixer = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

    private let levelLock = NSLock()
    private var levels: [UUID: Float] = [:]
    private var masterLevel: (Float, Float) = (0, 0)
    static let masterID = UUID()

    private(set) var isRunning = false
    private var startHostTime: UInt64 = 0
    private var startOffset: Double = 0

    // Recording
    private var recordFile: AVAudioFile?
    private(set) var recordingURL: URL?
    private(set) var recordStart: Double = 0
    private var inputLevel: Float = 0

    init() {
        engine.attach(busMixer)
        engine.attach(limiter)
        engine.connect(busMixer, to: limiter, format: AudioIO.format)
        engine.connect(limiter, to: engine.mainMixerNode, format: AudioIO.format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            var l: Float = 0, r: Float = 0
            vDSP_maxmgv(data[0], 1, &l, vDSP_Length(buffer.frameLength))
            if buffer.format.channelCount > 1 { vDSP_maxmgv(data[1], 1, &r, vDSP_Length(buffer.frameLength)) } else { r = l }
            self.levelLock.withLock { self.masterLevel = (l, r) }
        }
    }

    /// Adds/removes strips to match the session and applies every parameter.
    func sync(_ session: Session) {
        let ids = session.tracks.map(\.id)
        for (id, strip) in strips where !ids.contains(id) {
            strip.mixer.removeTap(onBus: 0)
            strip.detach(from: engine)
            strips[id] = nil
        }
        if ids != order {
            // Reconnect in track order so mixer inputs are stable.
            for id in ids where strips[id] == nil {
                let strip = Strip()
                strip.attach(to: engine, output: busMixer, bus: busMixer.nextAvailableInputBus)
                strip.mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                    guard let self, let data = buffer.floatChannelData else { return }
                    var peak: Float = 0
                    for c in 0..<Int(buffer.format.channelCount) {
                        var v: Float = 0
                        vDSP_maxmgv(data[c], 1, &v, vDSP_Length(buffer.frameLength))
                        peak = max(peak, v)
                    }
                    self.levelLock.withLock { self.levels[id] = peak }
                }
                strips[id] = strip
            }
            order = ids
        }
        for track in session.tracks { strips[track.id]?.apply(track, audible: session.isAudible(track)) }
        busMixer.outputVolume = DSP.linear(session.masterDB)
        limiter.bypass = !session.limiter
    }

    func start() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    var currentTime: Double {
        guard isRunning else { return startOffset }
        // Players start a few milliseconds in the future; until then time hasn't moved.
        let now = mach_absolute_time()
        guard now > startHostTime else { return startOffset }
        return startOffset + AVAudioTime.seconds(forHostTime: now - startHostTime)
    }

    /// The output's render clock, or nil if the device isn't running.
    var renderSampleTime: AVAudioFramePosition? {
        guard let t = engine.outputNode.lastRenderTime, t.isSampleTimeValid else { return nil }
        return t.sampleTime
    }

    /// Calls back with true once the output device is actually processing audio (its clock moves).
    /// Starting players before that raises an exception, e.g. when the output device is a virtual
    /// device whose host app isn't running.
    func whenOutputIsLive(timeout: Double = 1.5, _ done: @escaping (Bool) -> Void) {
        let first = renderSampleTime
        func check(_ remaining: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                if let now = self.renderSampleTime, let first, now > first + 256 { return done(true) }
                if remaining <= 0 { return done(false) }
                check(remaining - 0.03)
            }
        }
        check(timeout)
    }

    /// Prepares the graph and starts the engine (players stay stopped).
    func prepare(_ session: Session) throws {
        sync(session)
        try start()
    }

    /// Schedules and starts every track. Only call once `whenOutputIsLive` has confirmed IO.
    func play(_ session: Session, from t: Double) throws {
        stopPlayers()
        sync(session)
        try start()
        for track in session.tracks {
            strips[track.id]?.schedule(track, session: session, from: t, buffers: buffers)
        }
        // Start all players back to back. (Timed starts raise an uncatchable exception whenever
        // the audio device hasn't run an IO cycle yet, e.g. right after wake, so they're avoided.)
        for strip in strips.values { strip.play() }
        startHostTime = mach_absolute_time()
        startOffset = t
        isRunning = true
    }

    func stop() {
        let t = currentTime
        stopPlayers()
        startOffset = t
        isRunning = false
    }

    func seek(to t: Double, session: Session) throws {
        startOffset = t
    }

    private func stopPlayers() {
        for strip in strips.values { strip.stop() }
    }

    // MARK: Meters

    /// Recent peak per track (0…1), plus master as (left, right).
    func meters() -> (tracks: [UUID: Float], master: (Float, Float), input: Float) {
        levelLock.withLock {
            let out = (levels, masterLevel, inputLevel)
            // Decay so meters fall when audio stops.
            for k in levels.keys { levels[k]! *= 0.6 }
            masterLevel = (masterLevel.0 * 0.6, masterLevel.1 * 0.6)
            inputLevel *= 0.6
            return out
        }
    }

    // MARK: Recording

    enum RecordError: LocalizedError {
        case noInput, denied
        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone found"
            case .denied: return "Allow microphone access for Tone in System Settings → Privacy & Security"
            }
        }
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Records the input while playing the session from `t` (overdub). Call `prepareRecording`
    /// first, then this once the output is live.
    func prepareRecording() throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecordError.noInput }
        try start()
    }

    func startRecording(_ session: Session, from t: Double) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecordError.noInput }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-take-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        recordFile = file
        recordingURL = url
        recordStart = t
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.recordFile?.write(from: buffer)
            var peak: Float = 0
            if let data = buffer.floatChannelData { vDSP_maxmgv(data[0], 1, &peak, vDSP_Length(buffer.frameLength)) }
            self.levelLock.withLock { self.inputLevel = max(self.inputLevel, peak) }
        }
        try play(session, from: t)
    }

    /// Stops and returns the raw take.
    func stopRecording() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        stop()
        recordFile = nil
        defer { recordingURL = nil }
        return recordingURL
    }
}

/// Renders the session to a file with exactly the same graph as live playback.
enum Mixdown {
    enum Format: String, CaseIterable, Identifiable {
        case wav24 = "WAV 24-bit", wav16 = "WAV 16-bit", aiff = "AIFF", m4a = "AAC (M4A)", caf = "CAF 32-bit float"
        var id: String { rawValue }
        var ext: String {
            switch self {
            case .wav24, .wav16: return "wav"
            case .aiff: return "aiff"
            case .m4a: return "m4a"
            case .caf: return "caf"
            }
        }
        var settings: [String: Any] {
            let base: [String: Any] = [AVSampleRateKey: AudioIO.sampleRate, AVNumberOfChannelsKey: 2]
            switch self {
            case .wav24: return base.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]) { $1 }
            case .wav16: return base.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]) { $1 }
            case .aiff: return base.merging([AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]) { $1 }
            case .m4a: return base.merging([AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 256_000]) { $1 }
            case .caf: return AudioIO.format.settings
            }
        }
    }

    static func render(_ session: Session, buffers: RegionBuffers, to url: URL, format: Format,
                       range: ClosedRange<Double>? = nil, progress: (Double) -> Void = { _ in }) throws {
        let engine = AVAudioEngine()
        let bus = AVAudioMixerNode()
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(bus)
        engine.attach(limiter)
        try engine.enableManualRenderingMode(.offline, format: AudioIO.format, maximumFrameCount: 4096)
        engine.connect(bus, to: limiter, format: AudioIO.format)
        engine.connect(limiter, to: engine.mainMixerNode, format: AudioIO.format)
        bus.outputVolume = DSP.linear(session.masterDB)
        limiter.bypass = !session.limiter

        let start = range?.lowerBound ?? 0
        var strips: [Strip] = []
        for track in session.tracks {
            let strip = Strip()
            strip.attach(to: engine, output: bus, bus: bus.nextAvailableInputBus)
            strip.apply(track, audible: session.isAudible(track))
            strips.append(strip)
        }
        try engine.start()
        for (track, strip) in zip(session.tracks, strips) {
            strip.schedule(track, session: session, from: start, buffers: buffers)
            strip.play()
        }

        // Let reverb and delay tails ring out.
        let hasTail = session.tracks.contains { $0.fx.reverb > 0 || $0.fx.delay > 0 }
        let end = range?.upperBound ?? (session.duration + (hasTail ? 2 : 0))
        let total = AVAudioFramePosition(max(0.01, end - start) * AudioIO.sampleRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while engine.manualRenderingSampleTime < total {
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            if status == .success {
                try file.write(from: buffer)
                progress(Double(engine.manualRenderingSampleTime) / Double(total))
            } else if status == .error {
                throw NSError(domain: "Tone", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rendering failed"])
            }
        }
        engine.stop()
    }
}
