import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers
import EaselKit

enum ToneSelection: Equatable {
    case region(track: UUID, region: UUID)
    case track(UUID)
}

/// A time range the user dragged out on a track, used to limit processing or capture a noise print.
struct TimeRange: Equatable {
    var track: UUID
    var start: Double
    var end: Double
    var length: Double { end - start }
}

@Observable @MainActor
final class Transport {
    var time: Double = 0
    var isPlaying = false
    var isRecording = false
}

enum Restoration: String, CaseIterable, Identifiable {
    case noise = "Reduce Noise", hum = "Remove Hum", clicks = "Remove Clicks", normalize = "Normalize Peak"
    case loudness = "Loudness −16 LUFS", dc = "Remove DC Offset", reverse = "Reverse", invert = "Invert Polarity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .noise: return "waveform.badge.minus"
        case .hum: return "bolt.horizontal"
        case .clicks: return "waveform.path.ecg"
        case .normalize: return "arrow.up.and.down.text.horizontal"
        case .loudness: return "speaker.wave.3"
        case .dc: return "minus.circle"
        case .reverse: return "arrow.uturn.backward"
        case .invert: return "arrow.up.arrow.down"
        }
    }
    var help: String {
        switch self {
        case .noise: return "Removes steady background noise (fans, hiss, room tone). Capture a noise print first for best results."
        case .hum: return "Removes 50/60 Hz electrical hum and its harmonics."
        case .clicks: return "Repairs clicks, pops and crackle."
        case .normalize: return "Raises the level so the loudest peak sits at −1 dB."
        case .loudness: return "Matches the streaming/podcast loudness standard."
        case .dc: return "Centers a waveform that sits off the zero line."
        case .reverse: return "Plays the audio backwards."
        case .invert: return "Flips the waveform upside down."
        }
    }
}

extension UTType {
    static let toneProject = UTType(exportedAs: "app.easel.tone.project", conformingTo: .json)
}

@Observable @MainActor
final class ToneStudio {
    var session = Session() {
        didSet { if session != oldValue { isDirty = true; engineNeedsSync() } }
    }
    var selection: ToneSelection?
    var range: TimeRange?
    var documentURL: URL?
    var documentName = "Untitled"
    var isDirty = false
    var busyMessage: String?
    var toast: String?
    var zoom: Double = 50       // points per second
    var spectral = false
    var noiseProfile: [Float]?
    var restoreAmount: Double = 0.7
    var showExport = false
    var showMixer = true
    /// When set (a file sent from Reel), ⌘S renders the mix back to it.
    var linkedURL: URL?
    var mediaRevision = 0
    /// Bumped each frame while meters move, so only meter views redraw.
    var meterFrame = 0
    @ObservationIgnored private(set) var levels: [UUID: Float] = [:]
    @ObservationIgnored private(set) var masterLevels: (Float, Float) = (0, 0)
    @ObservationIgnored private(set) var inputLevel: Float = 0

    let transport = Transport()
    @ObservationIgnored let engine = ToneEngine()
    @ObservationIgnored private var peaks: [UUID: [Float]] = [:]
    @ObservationIgnored private var peakJobs: Set<UUID> = []
    @ObservationIgnored private var spectra: [String: CGImage] = [:]
    @ObservationIgnored private var spectrumJobs: Set<String> = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var syncScheduled = false

    private(set) var undoStack: [Session] = []
    private(set) var redoStack: [Session] = []

    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.25, green: 0.62, blue: 1, alpha: 1), NSColor(srgbRed: 0.98, green: 0.45, blue: 0.3, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.82, blue: 0.5, alpha: 1), NSColor(srgbRed: 0.75, green: 0.48, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 0.78, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.3, green: 0.85, blue: 0.85, alpha: 1),
    ]

    init() {
        engine.sync(session)
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(session)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(session)
        session = s
        validateSelection()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(session)
        session = s
        validateSelection()
    }

    private func validateSelection() {
        if case .region(let t, let r)? = selection, region(t, r) == nil { selection = nil }
        if case .track(let t)? = selection, !session.tracks.contains(where: { $0.id == t }) { selection = nil }
    }

    // MARK: Engine

    private func engineNeedsSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.engine.sync(self.session)
            // Restart playback so edits are heard immediately.
            if self.engine.isRunning && !self.transport.isRecording { self.startPlayback(from: self.engine.currentTime) }
            self.prewarm()
        }
    }

    /// Decodes regions in the background so pressing play never waits.
    private func prewarm() {
        let session = self.session, buffers = engine.buffers
        Task.detached(priority: .utility) {
            for track in session.tracks {
                for region in track.regions {
                    if let asset = session.asset(region.assetID) { _ = buffers.buffer(for: region, asset: asset) }
                }
            }
        }
    }

    private func tick() {
        let m = engine.meters()
        let moving = transport.isPlaying || m.master.0 > 0.001 || m.master.1 > 0.001
        if moving {
            levels = m.tracks
            masterLevels = m.master
            inputLevel = m.input
            meterFrame &+= 1
        }
        guard transport.isPlaying else { return }
        let t = engine.currentTime
        transport.time = t
        if !transport.isRecording && t > session.duration + 0.25 { stop() }
    }

    // MARK: Transport

    func togglePlay() { transport.isPlaying ? stop() : play() }

    func play() {
        if transport.time >= session.duration { transport.time = 0 }
        transport.isPlaying = true
        startPlayback(from: transport.time)
    }

    /// Every way of starting audio goes through here. CoreAudio is only touched from plain
    /// main-queue callbacks (it can spin the run loop, which is unsafe inside async tasks), and
    /// players only start once the output device is confirmed to be processing audio.
    private func startPlayback(from t: Double, recording: Bool = false) {
        DispatchQueue.main.async {
            guard self.transport.isPlaying || recording else { return }
            do {
                if recording { try self.engine.prepareRecording() }
                try self.engine.prepare(self.session)
            } catch {
                self.transport.isPlaying = false
                return self.flash("Couldn’t start audio: \(error.localizedDescription)")
            }
            self.engine.whenOutputIsLive { live in
                guard self.transport.isPlaying || recording else { return }
                guard live else {
                    self.transport.isPlaying = false
                    return self.flash("Your audio output isn’t responding. Check Sound settings (or the app behind your output device).")
                }
                do {
                    if recording {
                        try self.engine.startRecording(self.session, from: t)
                        self.transport.isRecording = true
                        self.transport.isPlaying = true
                    } else {
                        try self.engine.play(self.session, from: t)
                    }
                } catch {
                    self.transport.isPlaying = false
                    self.flash(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        if transport.isRecording { finishRecording(); return }
        engine.stop()
        transport.isPlaying = false
        transport.time = engine.currentTime
    }

    func seek(to t: Double) {
        let clamped = max(0, t)
        transport.time = clamped
        if engine.isRunning {
            startPlayback(from: clamped)
        } else {
            try? engine.seek(to: clamped, session: session)
        }
    }

    func toggleRecord() {
        if transport.isRecording { finishRecording(); return }
        guard let track = session.tracks.first(where: { $0.armed }) ?? selectedTrack ?? session.tracks.first else { return }
        Task {
            guard await ToneEngine.requestMicrophone() else { return flash(ToneEngine.RecordError.denied.localizedDescription) }
            if !session.tracks.contains(where: { $0.armed }) { updateTrack(track.id) { $0.armed = true } }
            startPlayback(from: transport.time, recording: true)
        }
    }

    private func finishRecording() {
        let start = engine.recordStart
        let take = engine.stopRecording()
        transport.isRecording = false
        transport.isPlaying = false
        transport.time = engine.currentTime
        guard let take, let trackID = session.tracks.first(where: { $0.armed })?.id else { return }
        Task {
            busyMessage = "Saving take…"
            defer { busyMessage = nil }
            guard let asset = await conform(take, name: "Take \(session.assets.count + 1)") else { return }
            try? FileManager.default.removeItem(at: take)
            checkpoint()
            session.assets.append(asset)
            let region = Region(assetID: asset.id, start: start, duration: asset.duration)
            updateTrack(trackID) { $0.regions.append(region) }
            selection = .region(track: trackID, region: region.id)
        }
    }

    // MARK: Lookups

    func trackIndex(_ id: UUID) -> Int? { session.tracks.firstIndex { $0.id == id } }

    func region(_ track: UUID, _ id: UUID) -> Region? {
        session.tracks.first { $0.id == track }?.regions.first { $0.id == id }
    }

    var selectedRegion: (track: Track, region: Region)? {
        guard case .region(let t, let r)? = selection, let track = session.tracks.first(where: { $0.id == t }),
              let region = track.regions.first(where: { $0.id == r }) else { return nil }
        return (track, region)
    }

    var selectedTrack: Track? {
        switch selection {
        case .track(let id)?: return session.tracks.first { $0.id == id }
        case .region(let id, _)?: return session.tracks.first { $0.id == id }
        default: return nil
        }
    }

    func updateTrack(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout Track) -> Void) {
        guard let i = trackIndex(id) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&session.tracks[i])
    }

    func updateRegion(_ track: UUID, _ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout Region) -> Void) {
        guard let t = trackIndex(track), let r = session.tracks[t].regions.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&session.tracks[t].regions[r])
    }

    // MARK: Waveforms & spectra

    func peaks(for asset: AudioAsset) -> [Float]? {
        if let p = peaks[asset.id] { return p }
        guard !peakJobs.contains(asset.id) else { return nil }
        peakJobs.insert(asset.id)
        let url = asset.url, id = asset.id
        Task.detached(priority: .userInitiated) {
            let p = (try? AudioIO.peaks(url)) ?? []
            await MainActor.run {
                self.peaks[id] = p
                self.peakJobs.remove(id)
                self.mediaRevision += 1
            }
        }
        return nil
    }

    func spectrum(for region: Region, width: Int, height: Int) -> CGImage? {
        let key = "\(region.assetID)-\(region.offset)-\(region.duration)-\(width / 64)-\(height)"
        if let hit = spectra[key] { return hit }
        guard let asset = session.asset(region.assetID), !spectrumJobs.contains(key) else { return nil }
        spectrumJobs.insert(key)
        let sr = AudioIO.sampleRate
        let url = asset.url, offset = region.offset, duration = region.duration
        let w = max(64, (width / 64 + 1) * 64)
        Task.detached(priority: .utility) {
            let data = try? AudioIO.read(url, from: Int(offset * sr), count: Int(duration * sr))
            let image = data.flatMap { DSP.spectrogram($0, width: min(w, 4096), height: height) }
            await MainActor.run {
                self.spectrumJobs.remove(key)
                guard let image else { return }
                self.spectra[key] = image
                self.mediaRevision += 1
            }
        }
        return nil
    }

    // MARK: Import

    private func conform(_ url: URL, name: String? = nil) async -> AudioAsset? {
        let out = AudioIO.newMediaURL()
        guard let duration = try? await AudioIO.conform(url, to: out), duration > 0 else { return nil }
        return AudioAsset(url: out, name: name ?? url.deletingPathExtension().lastPathComponent, duration: duration)
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .toneProject]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "tone" }) { return openProject(project) }
        if let linked = urls.first(where: AppLink.isRoundTrip) {
            // Reel sent us its soundtrack to edit: start a fresh session around it.
            guard confirmDiscard() else { return }
            newSession()
            Task {
                await importFiles([linked], track: session.tracks[0].id, at: 0)
                linkedURL = linked
                documentName = linked.deletingPathExtension().lastPathComponent
                isDirty = false
            }
            return
        }
        Task { await importFiles(urls) }
    }

    /// Imports files onto `track` (or new/empty tracks) starting at `time`, one after another.
    func importFiles(_ urls: [URL], track: UUID? = nil, at time: Double? = nil) async {
        busyMessage = urls.count == 1 ? "Importing…" : "Importing \(urls.count) files…"
        var assets: [AudioAsset] = []
        for url in urls {
            if let a = await conform(url) { assets.append(a) }
        }
        busyMessage = nil
        guard !assets.isEmpty else { return flash("Couldn’t import that audio") }
        checkpoint()
        session.assets += assets
        var t = time ?? transport.time
        var targetID = track
        for asset in assets {
            if targetID == nil {
                // First empty track, or a new one.
                if let empty = session.tracks.first(where: { $0.regions.isEmpty }) {
                    targetID = empty.id
                } else {
                    let new = Track(name: "Track \(session.tracks.count + 1)", colorIndex: session.tracks.count % Self.colors.count)
                    session.tracks.append(new)
                    targetID = new.id
                }
            }
            let region = Region(assetID: asset.id, start: t, duration: asset.duration)
            updateTrack(targetID!) { $0.regions.append(region) }
            selection = .region(track: targetID!, region: region.id)
            if track == nil { targetID = nil } else { t += asset.duration }
        }
    }

    // MARK: Editing

    func addTrack() {
        checkpoint()
        session.tracks.append(Track(name: "Track \(session.tracks.count + 1)", colorIndex: session.tracks.count % Self.colors.count))
    }

    func deleteTrack(_ id: UUID) {
        guard session.tracks.count > 1 else { return }
        checkpoint()
        session.tracks.removeAll { $0.id == id }
        selection = nil
    }

    func deleteSelection() {
        if let r = range { return deleteRange(r) }
        switch selection {
        case .region(let t, let r)?:
            checkpoint()
            updateTrack(t) { $0.regions.removeAll { $0.id == r } }
            selection = .track(t)
        case .track(let t)?:
            deleteTrack(t)
        case nil:
            break
        }
    }

    /// Cuts the selected time range out of every region on that track (leaves a gap).
    private func deleteRange(_ r: TimeRange) {
        checkpoint()
        updateTrack(r.track) { track in
            var out: [Region] = []
            for region in track.regions {
                if region.end <= r.start || region.start >= r.end { out.append(region); continue }
                if region.start < r.start {
                    var left = region
                    left.duration = r.start - region.start
                    left.fadeOut = min(left.fadeOut, left.duration / 2)
                    out.append(left)
                }
                if region.end > r.end {
                    var right = region
                    right.id = UUID()
                    let cut = r.end - region.start
                    right.start = r.end
                    right.offset += cut
                    right.duration -= cut
                    right.fadeIn = min(right.fadeIn, right.duration / 2)
                    out.append(right)
                }
            }
            track.regions = out
        }
        range = nil
        selection = .track(r.track)
    }

    /// Splits the selected region (or every region under the playhead on the selected track).
    func split() {
        let t = transport.time
        let trackID = selectedTrack?.id ?? session.tracks.first { $0.regions.contains { $0.start < t && t < $0.end } }?.id
        guard let trackID, let ti = trackIndex(trackID),
              let ri = session.tracks[ti].regions.firstIndex(where: { $0.start + 0.01 < t && t < $0.end - 0.01 }) else {
            return flash("Move the playhead over a clip to split it")
        }
        checkpoint()
        let region = session.tracks[ti].regions[ri]
        var left = region, right = region
        right.id = UUID()
        left.duration = t - region.start
        left.fadeOut = 0
        right.start = t
        right.offset += t - region.start
        right.duration = region.end - t
        right.fadeIn = 0
        session.tracks[ti].regions[ri] = left
        session.tracks[ti].regions.append(right)
        selection = .region(track: trackID, region: right.id)
    }

    /// Selects the clip the range covers most, so restoration works on that part of it.
    func selectClipUnderRange() {
        guard let r = range, let track = session.tracks.first(where: { $0.id == r.track }) else { return }
        func overlap(_ x: Region) -> Double { min(x.end, r.end) - max(x.start, r.start) }
        guard let region = track.regions.filter({ overlap($0) > 0 }).max(by: { overlap($0) < overlap($1) }) else { return }
        selection = .region(track: track.id, region: region.id)
    }

    // MARK: Clipboard

    @ObservationIgnored private var clipboard: (region: Region, asset: AudioAsset)?

    var canPaste: Bool { clipboard != nil }

    func copySelection() {
        guard let sel = selectedRegion, let asset = session.asset(sel.region.assetID) else { return }
        clipboard = (sel.region, asset)
    }

    func cutSelection() {
        guard let sel = selectedRegion else { return }
        copySelection()
        range = nil
        checkpoint()
        updateTrack(sel.track.id) { $0.regions.removeAll { $0.id == sel.region.id } }
        selection = .track(sel.track.id)
    }

    /// Pastes the copied clip at the playhead on the selected track.
    func paste() {
        guard let (copied, asset) = clipboard, let trackID = selectedTrack?.id ?? session.tracks.first?.id else { return }
        checkpoint()
        // The clip may come from a session that has since been closed.
        if session.asset(asset.id) == nil { session.assets.append(asset) }
        var region = copied
        region.id = UUID()
        region.start = transport.time
        updateTrack(trackID) { $0.regions.append(region) }
        selection = .region(track: trackID, region: region.id)
        seek(to: region.end)
    }

    func duplicateSelection() {
        guard let sel = selectedRegion else { return }
        checkpoint()
        var copy = sel.region
        copy.id = UUID()
        copy.start = sel.region.end
        updateTrack(sel.track.id) { $0.regions.append(copy) }
        selection = .region(track: sel.track.id, region: copy.id)
    }

    /// Removes silent stretches from the selected region and closes the gaps.
    func stripSilence(thresholdDB: Double = -45) {
        guard let sel = selectedRegion, let asset = session.asset(sel.region.assetID) else { return flash("Select a clip first") }
        let region = sel.region, trackID = sel.track.id
        busyMessage = "Finding silence…"
        Task.detached(priority: .userInitiated) {
            let sr = AudioIO.sampleRate
            let data = (try? AudioIO.read(asset.url, from: Int(region.offset * sr), count: Int(region.duration * sr))) ?? AudioData(frames: 0)
            let silent = DSP.silentRanges(data, thresholdDB: thresholdDB, minLength: 0.5)
            await MainActor.run {
                self.busyMessage = nil
                guard !silent.isEmpty else { return self.flash("No long silences found") }
                // Keep a little air around each piece.
                let pad = 0.12
                var keep: [ClosedRange<Double>] = []
                var cursor = 0.0
                for s in silent {
                    let a = cursor, b = min(region.duration, s.lowerBound + pad)
                    if b - a > 0.05 { keep.append(a...b) }
                    cursor = max(cursor, s.upperBound - pad)
                }
                if region.duration - cursor > 0.05 { keep.append(cursor...region.duration) }
                self.checkpoint()
                var t = region.start
                var pieces: [Region] = []
                for k in keep {
                    var piece = region
                    piece.id = UUID()
                    piece.start = t
                    piece.offset = region.offset + k.lowerBound
                    piece.duration = k.upperBound - k.lowerBound
                    piece.fadeIn = 0.01
                    piece.fadeOut = 0.01
                    pieces.append(piece)
                    t += piece.duration
                }
                let removed = region.duration - (t - region.start)
                self.updateTrack(trackID) { track in
                    track.regions.removeAll { $0.id == region.id }
                    // Pull later regions on this track earlier by the time removed.
                    for i in track.regions.indices where track.regions[i].start >= region.end - 0.001 {
                        track.regions[i].start -= removed
                    }
                    track.regions += pieces
                }
                self.selection = pieces.first.map { .region(track: trackID, region: $0.id) }
                self.flash(String(format: "Removed %.1fs of silence", removed))
            }
        }
    }

    // MARK: Restoration

    /// Uses the selected range (or the quietest part of the clip) as the "sound of silence" to remove.
    func captureNoiseProfile() {
        guard let sel = selectedRegion, let asset = session.asset(sel.region.assetID) else { return flash("Select a clip first") }
        let sr = AudioIO.sampleRate
        let region = sel.region
        var startTime = region.offset, length = region.duration
        if let r = range, r.track == sel.track.id {
            startTime = region.offset + max(0, r.start - region.start)
            length = min(r.end, region.end) - max(r.start, region.start)
        }
        guard let data = try? AudioIO.read(asset.url, from: Int(startTime * sr), count: Int(length * sr)) else { return }
        let noise = range == nil ? data.slice(DSP.quietestRange(data)) : data
        noiseProfile = DSP.noiseProfile(noise)
        flash(range == nil ? "Captured noise print from the quietest part" : String(format: "Captured %.1fs noise print", noise.duration))
    }

    /// Processes the selected clip (or just the selected range of it) into a new file.
    func restore(_ kind: Restoration) {
        guard let sel = selectedRegion, let asset = session.asset(sel.region.assetID) else { return flash("Select a clip first") }
        let region = sel.region, trackID = sel.track.id
        let sr = AudioIO.sampleRate
        var sub: Range<Int>?
        if let r = range, r.track == trackID, r.end > region.start, r.start < region.end {
            let a = Int((max(r.start, region.start) - region.start) * sr), b = Int((min(r.end, region.end) - region.start) * sr)
            if b - a > 64 { sub = a..<b }
        }
        let amount = restoreAmount, profile = noiseProfile
        busyMessage = "\(kind.rawValue)…"
        Task.detached(priority: .userInitiated) {
            do {
                var data = try AudioIO.read(asset.url, from: Int(region.offset * sr), count: Int(region.duration * sr))
                var target = sub.map { data.slice($0) } ?? data
                var detail = ""
                switch kind {
                case .noise:
                    let print = profile ?? DSP.noiseProfile(target.slice(DSP.quietestRange(target)))
                    DSP.reduceNoise(&target, profile: print, amount: amount)
                case .hum:
                    let f = DSP.detectHum(target)
                    DSP.removeHum(&target, base: f)
                    detail = " (\(Int(f)) Hz)"
                case .clicks:
                    let n = DSP.declick(&target, sensitivity: Float(0.5 + amount))
                    detail = " (\(n) fixed)"
                case .normalize: DSP.normalize(&target)
                case .loudness:
                    let before = DSP.loudness(target)
                    DSP.normalizeLoudness(&target)
                    detail = String(format: " (was %.1f LUFS)", before)
                case .dc: DSP.removeDC(&target)
                case .reverse: DSP.reverse(&target)
                case .invert: DSP.invert(&target)
                }
                if let sub { data.splice(target, at: sub.lowerBound) } else { data = target }
                let out = AudioIO.newMediaURL()
                try AudioIO.write(data, to: out)
                let processed = AudioAsset(url: out, name: asset.name, duration: data.duration)
                let message = kind.rawValue + detail
                await MainActor.run {
                    self.busyMessage = nil
                    self.checkpoint()
                    self.session.assets.append(processed)
                    self.updateRegion(trackID, region.id) {
                        $0.assetID = processed.id
                        $0.offset = 0
                    }
                    self.flash(message)
                }
            } catch {
                await MainActor.run {
                    self.busyMessage = nil
                    self.flash(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Files

    func exportMix(format: Mixdown.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).\(format.ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        render(to: url, format: format) { [weak self] in
            self?.flash("Exported \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func render(to url: URL, format: Mixdown.Format, then done: @escaping @MainActor () -> Void) {
        guard session.duration > 0 else { return flash("Nothing to export yet") }
        stop()
        busyMessage = "Mixing down…"
        let session = self.session, buffers = engine.buffers
        Task.detached(priority: .userInitiated) {
            do {
                try? FileManager.default.removeItem(at: url)
                try Mixdown.render(session, buffers: buffers, to: url, format: format)
                await MainActor.run { self.busyMessage = nil; done() }
            } catch {
                await MainActor.run { self.busyMessage = nil; self.flash("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Sends the mix to Reel as music.
    func sendToReel() {
        let url = AppLink.newInboxURL(for: .reel, named: documentName, ext: "m4a")
        render(to: url, format: .m4a) { [weak self] in
            if AppLink.open(url, in: .reel) { self?.flash("Sent to Reel") } else { self?.flash("Couldn’t find Reel. Build it with Scripts/build_app.sh") }
        }
    }

    func save(as saveAs: Bool = false) {
        if let target = linkedTarget, !saveAs {
            // Write the mix back where Reel expects it; Reel reloads it automatically.
            render(to: target.tmp, format: target.format) { [weak self] in
                _ = try? FileManager.default.replaceItemAt(target.url, withItemAt: target.tmp)
                self?.isDirty = false
                self?.flash("Updated in Reel")
            }
            return
        }
        var url = documentURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.toneProject]
            panel.nameFieldStringValue = documentName
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: url, options: .atomic)
            documentURL = url
            documentName = url.deletingPathExtension().lastPathComponent
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            flash("Saved")
        } catch {
            flash("Couldn’t save: \(error.localizedDescription)")
        }
    }

    /// Reel's file, the format to write it in, and a temporary file beside it to render into.
    private var linkedTarget: (url: URL, format: Mixdown.Format, tmp: URL)? {
        guard let linkedURL else { return nil }
        let format: Mixdown.Format = linkedURL.pathExtension.lowercased() == "wav" ? .wav24 : .m4a
        return (linkedURL, format, linkedURL.deletingLastPathComponent().appendingPathComponent(".tone-\(UUID().uuidString).\(format.ext)"))
    }

    /// Writes the mix back to Reel before returning, for when the app is about to quit or move on.
    private func writeBackNow() -> Bool {
        guard let target = linkedTarget else { return false }
        stop()
        do {
            try Mixdown.render(session, buffers: engine.buffers, to: target.tmp, format: target.format)
            _ = try FileManager.default.replaceItemAt(target.url, withItemAt: target.tmp)
            isDirty = false
            return true
        } catch {
            try? FileManager.default.removeItem(at: target.tmp)
            flash("Couldn’t update Reel: \(error.localizedDescription)")
            return false
        }
    }

    func openProject(_ url: URL) {
        guard confirmDiscard() else { return }
        do {
            let loaded = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
            stop()
            undoStack.removeAll()
            redoStack.removeAll()
            session = loaded
            documentURL = url
            documentName = url.deletingPathExtension().lastPathComponent
            linkedURL = nil
            isDirty = false
            selection = nil
            seek(to: 0)
            let missing = loaded.assets.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
            if missing > 0 { flash("\(missing) audio file\(missing == 1 ? " is" : "s are") missing") }
        } catch {
            flash("Couldn’t open that project")
        }
    }

    func newSession() {
        stop()
        session = Session()
        undoStack.removeAll()
        redoStack.removeAll()
        documentURL = nil
        linkedURL = nil
        documentName = "Untitled"
        isDirty = false
        selection = nil
        range = nil
        seek(to: 0)
    }

    func confirmDiscard() -> Bool {
        guard isDirty, session.duration > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentName)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if linkedURL != nil { return writeBackNow() }
            save()
            return !isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Messages

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}
