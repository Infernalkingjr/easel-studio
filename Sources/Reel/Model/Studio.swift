import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers
import EaselKit

enum Selection: Equatable {
    case clip(UUID), title(UUID), graphic(UUID), music(UUID)
}

/// Playback position lives apart from the project so the 30–60 Hz time updates only touch the
/// few views that show time.
@Observable @MainActor
final class Playback {
    var time: Double = 0
    var isPlaying = false
    var loop = false
}

extension UTType {
    static let reelProject = UTType(exportedAs: "app.easel.reel.project", conformingTo: .json)
}

@Observable @MainActor
final class Studio {
    // MARK: State

    var project = Project() {
        didSet { if project != oldValue { isDirty = true; scheduleRebuild() } }
    }
    var selection: Selection?
    var documentURL: URL?
    var documentName = "Untitled"
    var isDirty = false
    var busyMessage: String?
    var toast: String?
    var showExport = false
    var timelineZoom: Double = 60  // points per second
    var snapping = true

    let playback = Playback()
    @ObservationIgnored let library = MediaLibrary()
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private(set) var built: BuiltTimeline?
    @ObservationIgnored private var filler: AVAssetTrack?
    /// Tracks don't keep their asset alive, so hold it here.
    @ObservationIgnored private var fillerAsset: AVAsset?
    @ObservationIgnored private var lastSignature: Signature?
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored var autoFilters: [UUID: [FilterSpec]] = [:]
    @ObservationIgnored private var watchedDates: [UUID: Date] = [:]
    @ObservationIgnored private var watcher: Timer?
    /// Bumped when thumbnails/waveforms arrive so the timeline redraws.
    var mediaRevision = 0

    private(set) var undoStack: [Project] = []
    private(set) var redoStack: [Project] = []

    var previewSize: CGSize { project.aspect.size(short: 1080) }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        library.onUpdate = { [weak self] in self?.mediaRevision += 1 }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            DispatchQueue.main.async { self?.tick(time.seconds) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            DispatchQueue.main.async {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                if self.playback.loop { self.seek(to: 0); self.player.play() } else { self.pause() }
            }
        }
        Task {
            let asset = try await MediaLibrary.ensureFiller()
            fillerAsset = asset
            filler = try await asset.loadTracks(withMediaType: .video).first
            rebuild()
        }
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkRoundTrips() }
        }
    }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(project)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let p = undoStack.popLast() else { return }
        redoStack.append(project)
        project = p
        validateSelection()
    }

    func redo() {
        guard let p = redoStack.popLast() else { return }
        undoStack.append(project)
        project = p
        validateSelection()
    }

    private func validateSelection() {
        switch selection {
        case .clip(let id)? where !project.clips.contains { $0.id == id }: selection = nil
        case .title(let id)? where !project.titles.contains { $0.id == id }: selection = nil
        case .graphic(let id)? where !project.graphics.contains { $0.id == id }: selection = nil
        case .music(let id)? where !project.music.contains { $0.id == id }: selection = nil
        default: break
        }
    }

    // MARK: Building

    /// What forces a new AVComposition. Anything else (looks, titles, transition style…) only
    /// needs a fresh render plan, which is instant and keeps playback running.
    private struct Signature: Equatable {
        struct C: Equatable {
            let media: UUID, start: Double, length: Double, speed: Double, muted: Bool
            let volume: Double, fadeIn: Double, fadeOut: Double, transition: Double?
        }
        let clips: [C]
        let music: [MusicClip]
        let duration: Double
        let fps: Int
    }

    private var signature: Signature {
        Signature(clips: project.clips.map {
            .init(media: $0.mediaID, start: $0.sourceStart, length: $0.sourceDuration, speed: $0.speed, muted: $0.muted,
                  volume: $0.volume, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut, transition: $0.transition?.duration)
        }, music: project.music, duration: project.duration, fps: project.fps)
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    func rebuild() {
        guard let filler else { return }
        do {
            let next = try TimelineBuilder.build(project, library: library, filler: filler,
                                                 renderSize: previewSize, autoFilters: autoFilters)
            let sig = signature
            if sig != lastSignature || player.currentItem == nil {
                let item = AVPlayerItem(asset: next.composition)
                item.videoComposition = next.videoComposition
                item.audioMix = next.audioMix
                item.audioTimePitchAlgorithm = .spectral
                let t = min(playback.time, max(0, next.duration - 0.001))
                let playing = playback.isPlaying
                player.replaceCurrentItem(with: item)
                lastSignature = sig
                built = next
                seek(to: t)
                if playing { player.play() }
            } else if let item = player.currentItem {
                item.videoComposition = next.videoComposition
                item.audioMix = next.audioMix
                built = next
                if !playback.isPlaying { seek(to: playback.time) }
            }
        } catch {
            flash("Couldn’t build the timeline: \(error.localizedDescription)")
        }
    }

    // MARK: Playback

    private func tick(_ t: Double) {
        guard !seeking, t.isFinite else { return }
        playback.time = t
    }

    func togglePlay() { playback.isPlaying ? pause() : play() }

    func play() {
        if playback.time >= project.duration - 0.05 { seek(to: 0) }
        player.rate = 1
        playback.isPlaying = true
    }

    func pause() {
        player.pause()
        playback.isPlaying = false
    }

    /// J/K/L-style shuttle.
    func shuttle(_ rate: Float) {
        player.rate = rate
        playback.isPlaying = rate != 0
    }

    /// Exact seeks, coalesced so scrubbing never queues up stale frames.
    func seek(to t: Double) {
        let clamped = min(max(0, t), max(0, project.duration))
        playback.time = clamped
        pendingSeek = clamped
        guard !seeking else { return }
        performSeek()
    }

    private func performSeek() {
        guard let t = pendingSeek else { return }
        pendingSeek = nil
        seeking = true
        player.seek(to: TimelineBuilder.time(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if self.pendingSeek != nil { self.performSeek() }
            }
        }
    }

    func step(frames: Int) {
        pause()
        seek(to: playback.time + Double(frames) / Double(project.fps))
    }

    // MARK: Import

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .image, .reelProject]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    /// Opens projects, or imports media and places it on the timeline.
    func open(_ urls: [URL]) {
        if let proj = urls.first(where: { $0.pathExtension.lowercased() == "reel" }) {
            openProject(proj)
            return
        }
        Task { await importAndPlace(urls) }
    }

    func importAndPlace(_ urls: [URL], at time: Double? = nil, lane: TimelineLane? = nil) async {
        busyMessage = urls.count == 1 ? "Importing…" : "Importing \(urls.count) files…"
        var added: [MediaItem] = []
        for url in urls {
            if let item = await library.importMedia(url) { added.append(item) }
        }
        busyMessage = nil
        guard !added.isEmpty else { return flash("Couldn’t import those files") }
        checkpoint()
        project.media += added
        var insertAt = time.flatMap { insertionIndex(at: $0) } ?? project.clips.count
        for item in added {
            let fromEasel = AppLink.isFromEasel(item.url)
            switch item.kind {
            case .audio:
                addMusic(item, at: time ?? (project.music.isEmpty ? 0 : playback.time), checkpoint: false)
            case .image where (lane == .graphics || (lane == nil && item.hasAlpha)):
                addGraphic(item, at: time ?? playback.time, checkpoint: false)
            case .video, .image:
                if lane == .graphics || lane == .music { continue }
                project.clips.insert(Clip(mediaID: item.id, sourceDuration: item.kind == .image ? 3 : item.duration), at: insertAt)
                selection = .clip(project.clips[insertAt].id)
                insertAt += 1
            }
            if fromEasel { flash("Added from Easel") }
        }
        if case .clip? = selection, project.clips.count == added.count { seek(to: 0) }
    }

    /// The clip slot nearest to time `t` on the main track.
    func insertionIndex(at t: Double) -> Int {
        let starts = project.clipStarts
        for (i, clip) in project.clips.enumerated() where t < starts[i] + clip.duration / 2 { return i }
        return project.clips.count
    }

    func addMusic(_ item: MediaItem, at t: Double, checkpoint shouldCheckpoint: Bool = true) {
        if shouldCheckpoint { checkpoint() }
        let room = project.mainDuration > 0 ? max(1, project.mainDuration - t) : item.duration
        let music = MusicClip(mediaID: item.id, start: t, duration: min(item.duration, room))
        project.music.append(music)
        selection = .music(music.id)
    }

    func addGraphic(_ item: MediaItem, at t: Double, checkpoint shouldCheckpoint: Bool = true) {
        if shouldCheckpoint { checkpoint() }
        let g = Graphic(mediaID: item.id, start: t)
        project.graphics.append(g)
        selection = .graphic(g.id)
    }

    func addToTimeline(_ item: MediaItem) {
        switch item.kind {
        case .audio: addMusic(item, at: project.music.isEmpty ? 0 : playback.time)
        case .image where item.hasAlpha: addGraphic(item, at: playback.time)
        default:
            checkpoint()
            let clip = Clip(mediaID: item.id, sourceDuration: item.kind == .image ? 3 : item.duration)
            project.clips.append(clip)
            selection = .clip(clip.id)
        }
    }

    // MARK: Editing

    func clipIndex(_ id: UUID) -> Int? { project.clips.firstIndex { $0.id == id } }

    var selectedClip: Clip? {
        if case .clip(let id)? = selection { return project.clips.first { $0.id == id } }
        return nil
    }

    func updateClip(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout Clip) -> Void) {
        guard let i = clipIndex(id) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&project.clips[i])
    }

    func updateTitle(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout TitleItem) -> Void) {
        guard let i = project.titles.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&project.titles[i])
    }

    func updateGraphic(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout Graphic) -> Void) {
        guard let i = project.graphics.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&project.graphics[i])
    }

    func updateMusic(_ id: UUID, checkpoint shouldCheckpoint: Bool = false, _ change: (inout MusicClip) -> Void) {
        guard let i = project.music.firstIndex(where: { $0.id == id }) else { return }
        if shouldCheckpoint { checkpoint() }
        change(&project.music[i])
    }

    /// Splits whatever is under the playhead: the selected title/graphic/music, or the main clip.
    func split() {
        let t = playback.time
        switch selection {
        case .title(let id)?:
            guard let i = project.titles.firstIndex(where: { $0.id == id }), project.titles[i].start < t, t < project.titles[i].end else { break }
            checkpoint()
            var second = project.titles[i]
            second.id = UUID()
            second.duration = project.titles[i].end - t
            second.start = t
            project.titles[i].duration = t - project.titles[i].start
            project.titles.append(second)
            return
        case .music(let id)?:
            guard let i = project.music.firstIndex(where: { $0.id == id }), project.music[i].start < t, t < project.music[i].end else { break }
            checkpoint()
            var second = project.music[i]
            second.id = UUID()
            let cut = t - project.music[i].start
            second.start = t
            second.sourceStart += cut
            second.duration -= cut
            project.music[i].duration = cut
            project.music.append(second)
            return
        default:
            break
        }
        guard let i = project.clipIndex(at: t) else { return flash("Move the playhead over a clip to split it") }
        let start = project.clipStarts[i]
        let clip = project.clips[i]
        let offset = (t - start) * clip.speed
        guard offset > 0.05, clip.sourceDuration - offset > 0.05 else { return }
        checkpoint()
        var first = clip, second = clip
        second.id = UUID()
        first.sourceDuration = offset
        first.transition = nil
        first.fadeOut = 0
        second.sourceStart = clip.sourceStart + offset
        second.sourceDuration = clip.sourceDuration - offset
        second.fadeIn = 0
        project.clips[i] = first
        project.clips.insert(second, at: i + 1)
        selection = .clip(second.id)
    }

    func deleteSelection() {
        guard let selection else { return }
        checkpoint()
        switch selection {
        case .clip(let id): project.clips.removeAll { $0.id == id }
        case .title(let id): project.titles.removeAll { $0.id == id }
        case .graphic(let id): project.graphics.removeAll { $0.id == id }
        case .music(let id): project.music.removeAll { $0.id == id }
        }
        self.selection = nil
        if playback.time > project.duration { seek(to: project.duration) }
    }

    func duplicateSelection() {
        switch selection {
        case .clip(let id)?:
            guard let i = clipIndex(id) else { return }
            checkpoint()
            var copy = project.clips[i]
            copy.id = UUID()
            project.clips.insert(copy, at: i + 1)
            self.selection = .clip(copy.id)
        case .title(let id)?:
            guard let t = project.titles.first(where: { $0.id == id }) else { return }
            checkpoint()
            var copy = t
            copy.id = UUID()
            copy.start = t.end
            project.titles.append(copy)
            self.selection = .title(copy.id)
        default:
            break
        }
    }

    func moveClip(from: Int, to: Int) {
        guard from != to, project.clips.indices.contains(from) else { return }
        checkpoint()
        let clip = project.clips.remove(at: from)
        project.clips.insert(clip, at: min(max(0, to > from ? to - 1 : to), project.clips.count))
    }

    func addTitle(style: TitleStyle, text: String? = nil) {
        checkpoint()
        var title = TitleItem(text: text ?? (style == .lowerThird ? "Your Name\nTitle" : "Your Title"), start: playback.time)
        title.style = style
        switch style {
        case .lowerThird: title.position = .lowerThird; title.animation = .slideUp; title.color = RGB(r: 1, g: 0.42, b: 0.2)
        case .subtitle: title.position = .bottom; title.animation = .fade
        case .neon: title.color = RGB(r: 0.2, g: 0.9, b: 1); title.animation = .zoom
        case .boxed: title.color = .yellow; title.animation = .bounce
        case .handwritten: title.animation = .reveal
        default: break
        }
        project.titles.append(title)
        selection = .title(title.id)
    }

    /// Applies a transition between the selected clip and the next (or the clip under the playhead).
    func setTransition(_ kind: TransitionKind?) {
        let id: UUID? = selectedClip?.id ?? project.clipIndex(at: playback.time).map { project.clips[$0].id }
        guard let id, let i = clipIndex(id), i + 1 < project.clips.count else {
            return flash("Select a clip that has another clip after it")
        }
        checkpoint()
        project.clips[i].transition = kind.map { Transition(kind: $0, duration: project.clips[i].transition?.duration ?? 0.6) }
    }

    // MARK: Frames & Easel

    /// Renders the current frame at high resolution.
    func currentFrame(shortSide: CGFloat = 2160) async throws -> CGImage {
        guard let filler else { throw CocoaError(.featureUnsupported) }
        let built = try TimelineBuilder.build(project, library: library, filler: filler,
                                              renderSize: project.aspect.size(short: shortSide), autoFilters: autoFilters)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let t = min(playback.time, max(0, built.duration - 1.0 / Double(project.fps)))
        return try await generator.image(at: TimelineBuilder.time(t)).image
    }

    static var framesFolder: URL {
        let dir = AppLink.sharedFolder.appendingPathComponent("Reel/Frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func openFrameInEasel() {
        Task {
            busyMessage = "Grabbing frame…"
            defer { busyMessage = nil }
            do {
                let frame = try await currentFrame()
                let url = Self.framesFolder.appendingPathComponent("\(documentName) frame \(Int(playback.time * 1000)).png")
                try Bitmap.png(frame)?.write(to: url)
                if !AppLink.open(url, inApp: AppLink.easelBundleID, fallbackName: "Easel.app") {
                    flash("Couldn’t find Easel. Build it with Scripts/build_app.sh")
                }
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    /// Inserts a still of the current frame at the playhead.
    func freezeFrame(seconds: Double = 2) {
        Task {
            busyMessage = "Freezing frame…"
            defer { busyMessage = nil }
            do {
                let frame = try await currentFrame(shortSide: 1080)
                let url = Self.framesFolder.appendingPathComponent("freeze-\(UUID().uuidString).png")
                try Bitmap.png(frame)?.write(to: url)
                guard let item = await library.importMedia(url) else { return }
                let t = playback.time
                checkpoint()
                project.media.append(item)
                var index = insertionIndex(at: t)
                // Split the clip under the playhead so the still lands exactly there.
                if let i = project.clipIndex(at: t) {
                    let start = project.clipStarts[i], clip = project.clips[i]
                    let offset = (t - start) * clip.speed
                    if offset > 0.05, clip.sourceDuration - offset > 0.05 {
                        var first = clip, second = clip
                        second.id = UUID()
                        first.sourceDuration = offset
                        first.transition = nil
                        second.sourceStart += offset
                        second.sourceDuration -= offset
                        project.clips[i] = first
                        project.clips.insert(second, at: i + 1)
                        index = i + 1
                    }
                }
                let still = Clip(mediaID: item.id, sourceDuration: seconds)
                project.clips.insert(still, at: index)
                selection = .clip(still.id)
                flash("Freeze frame added")
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    /// Sends a photo clip or graphic to Easel; saving there updates it here automatically.
    func editInEasel(mediaID: UUID) {
        guard let i = project.media.firstIndex(where: { $0.id == mediaID }), project.media[i].kind == .image else { return }
        var url = project.media[i].url
        if !AppLink.isRoundTrip(url) {
            // Work on a copy so the original file is never changed.
            let copy = AppLink.newRoundTripURL(named: project.media[i].name + ".png")
            guard let cg = Bitmap.load(url: url), let data = Bitmap.png(cg) else { return flash("Couldn’t read that image") }
            do { try data.write(to: copy) } catch { return flash(error.localizedDescription) }
            checkpoint()
            project.media[i].url = copy
            url = copy
        }
        editInEaselWatchOnly(mediaID: mediaID)
        if AppLink.open(url, inApp: AppLink.easelBundleID, fallbackName: "Easel.app") {
            flash("Editing in Easel. Press ⌘S there to update this clip")
        } else {
            flash("Couldn’t find Easel. Build it with Scripts/build_app.sh")
        }
    }

    /// Sends a music clip to Tone; saving there updates the soundtrack here.
    func editInTone(mediaID: UUID) {
        guard let i = project.media.firstIndex(where: { $0.id == mediaID }), project.media[i].kind == .audio else { return }
        let source = project.media[i]
        if AppLink.isRoundTrip(source.url) {
            editInEaselWatchOnly(mediaID: mediaID)
            if !AppLink.open(source.url, in: .tone) { flash("Couldn’t find Tone. Build it with Scripts/build_app.sh") }
            return
        }
        busyMessage = "Preparing audio…"
        Task {
            defer { busyMessage = nil }
            // Work on an M4A copy so the original file is never changed.
            let copy = AppLink.newRoundTripURL(named: source.name + ".m4a")
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: source.url), presetName: AVAssetExportPresetAppleM4A),
                  (try? await session.export(to: copy, as: .m4a)) != nil else { return flash("Couldn’t prepare that audio") }
            checkpoint()
            project.media[i].url = copy
            _ = await library.importMedia(copy, id: mediaID)
            editInEaselWatchOnly(mediaID: mediaID)
            if AppLink.open(copy, in: .tone) {
                flash("Editing in Tone. Press ⌘S there to update the soundtrack")
            } else {
                flash("Couldn’t find Tone. Build it with Scripts/build_app.sh")
            }
        }
    }

    /// Starts watching a photo's file for saves from Easel.
    func editInEaselWatchOnly(mediaID: UUID) {
        guard let item = project.media(mediaID) else { return }
        watchedDates[mediaID] = modificationDate(item.url)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Picks up photos that were saved back from Easel.
    private func checkRoundTrips() {
        var changed = false
        for item in project.media where item.kind == .audio && AppLink.isRoundTrip(item.url) {
            let date = modificationDate(item.url)
            guard let previous = watchedDates[item.id] else { watchedDates[item.id] = date; continue }
            if let date, date > previous {
                watchedDates[item.id] = date
                Task {
                    guard let fresh = await library.importMedia(item.url, id: item.id),
                          let i = project.media.firstIndex(where: { $0.id == item.id }) else { return }
                    project.media[i].duration = fresh.duration
                    lastSignature = nil   // same edit list, new audio: force a full rebuild
                    mediaRevision += 1
                    rebuild()
                    flash("Soundtrack updated from Tone")
                }
            }
        }
        for item in project.media where item.kind == .image && AppLink.isRoundTrip(item.url) {
            let date = modificationDate(item.url)
            guard let previous = watchedDates[item.id] else { watchedDates[item.id] = date; continue }
            if let date, date > previous {
                watchedDates[item.id] = date
                library.refreshImage(item)
                if let cg = Bitmap.load(url: item.url), let i = project.media.firstIndex(where: { $0.id == item.id }) {
                    project.media[i].size = CGSize(width: cg.width, height: cg.height)
                }
                changed = true
            }
        }
        if changed {
            mediaRevision += 1
            rebuild()
            flash("Updated from Easel")
        }
    }

    // MARK: Projects

    func saveProject(as: Bool = false) {
        var url = documentURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.reelProject]
            panel.nameFieldStringValue = documentName
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            documentURL = url
            documentName = url.deletingPathExtension().lastPathComponent
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            flash("Saved")
        } catch {
            flash("Couldn’t save: \(error.localizedDescription)")
        }
    }

    func openProject(_ url: URL) {
        guard confirmDiscard() else { return }
        Task {
            do {
                let loaded = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
                busyMessage = "Opening…"
                var missing = 0
                for item in loaded.media where !(await library.reload(item)) { missing += 1 }
                busyMessage = nil
                undoStack.removeAll()
                redoStack.removeAll()
                project = loaded
                documentURL = url
                documentName = url.deletingPathExtension().lastPathComponent
                isDirty = false
                selection = nil
                seek(to: 0)
                for clip in loaded.clips where clip.autoEnhance { computeAutoEnhance(clip.id) }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                if missing > 0 { flash("\(missing) media file\(missing == 1 ? " is" : "s are") missing") }
            } catch {
                busyMessage = nil
                flash("Couldn’t open that project")
            }
        }
    }

    func confirmDiscard() -> Bool {
        guard isDirty, !project.clips.isEmpty || !project.titles.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentName)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject()
            return !isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func newProject() {
        guard confirmDiscard() else { return }
        pause()
        project = Project()
        undoStack.removeAll()
        redoStack.removeAll()
        documentURL = nil
        documentName = "Untitled"
        isDirty = false
        selection = nil
        seek(to: 0)
    }

    // MARK: AI

    /// Samples the clip once and keeps Core Image's suggested corrections for every frame.
    func computeAutoEnhance(_ clipID: UUID) {
        guard let clip = project.clips.first(where: { $0.id == clipID }), let media = project.media(clip.mediaID) else { return }
        Task {
            let specs = await ReelAI.autoEnhanceFilters(for: media, at: clip.sourceStart + clip.sourceDuration / 2, library: library)
            autoFilters[clipID] = specs
            rebuild()
        }
    }

    func editClipWithWords(_ text: String) {
        guard let clip = selectedClip else { return flash("Select a clip first") }
        let changes = KeywordEdits.parse(text)
        guard !changes.isEmpty else { return flash("Try words like warmer, brighter, moody, vintage or black and white") }
        checkpoint()
        updateClip(clip.id) { c in
            for (key, delta) in changes {
                guard let path = KeywordEdits.path(for: key),
                      let control = Adjustments.groups.flatMap(\.controls).first(where: { $0.id == path }) else { continue }
                c.adjustments[keyPath: path] = min(control.range.upperBound, max(control.range.lowerBound, c.adjustments[keyPath: path] + delta))
            }
        }
        flash("Applied “\(text)”")
    }

    func detectScenes() {
        guard let clip = selectedClip, let media = project.media(clip.mediaID), media.kind == .video else {
            return flash("Select a video clip first")
        }
        busyMessage = "Finding scene changes…"
        Task {
            let cuts = await ReelAI.sceneCuts(in: media, from: clip.sourceStart, length: clip.sourceDuration, library: library)
            busyMessage = nil
            guard !cuts.isEmpty, let i = clipIndex(clip.id) else { return flash("No scene changes found") }
            checkpoint()
            var pieces: [Clip] = []
            var edges = [clip.sourceStart] + cuts + [clip.sourceStart + clip.sourceDuration]
            edges = edges.sorted()
            for (a, b) in zip(edges, edges.dropFirst()) where b - a > 0.1 {
                var piece = clip
                piece.id = UUID()
                piece.sourceStart = a
                piece.sourceDuration = b - a
                piece.transition = nil
                pieces.append(piece)
            }
            pieces[pieces.count - 1].transition = clip.transition
            project.clips.replaceSubrange(i...i, with: pieces)
            selection = .clip(pieces[0].id)
            flash("Split into \(pieces.count) scenes")
        }
    }

    func autoCaptions() {
        guard let built, !project.clips.isEmpty else { return flash("Add a clip with speech first") }
        busyMessage = "Listening for speech…"
        Task {
            do {
                let lines = try await ReelAI.captions(for: built)
                busyMessage = nil
                guard !lines.isEmpty else { return flash("No speech found") }
                checkpoint()
                project.titles.removeAll { $0.style == .subtitle }
                for line in lines {
                    var title = TitleItem(text: line.text, start: line.start, duration: line.duration)
                    title.style = .subtitle
                    title.position = .bottom
                    title.animation = .fade
                    project.titles.append(title)
                }
                flash("Added \(lines.count) captions")
            } catch {
                busyMessage = nil
                flash(error.localizedDescription)
            }
        }
    }

    // MARK: Export

    var exportProgress: Double?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    func export(_ settings: ExportSettings) {
        guard let filler else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(documentName).\(settings.format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: settings.format.fileExtension) ?? .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(settings, to: url, filler: filler)
    }

    func export(_ settings: ExportSettings, to url: URL, filler: AVAssetTrack? = nil) {
        guard let filler = filler ?? self.filler else { return }
        pause()
        exportProgress = 0
        let project = self.project, library = self.library, filters = autoFilters
        exportTask = Task {
            do {
                try await Exporter.export(project, library: library, filler: filler, autoFilters: filters,
                                          settings: settings, to: url) { p in
                    Task { @MainActor in if self.exportProgress != nil { self.exportProgress = p } }
                }
                exportProgress = nil
                flash("Exported \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportProgress = nil
                if !Task.isCancelled { flash("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgress = nil
    }

    /// For tests and tools: the filler track once it's ready.
    var fillerTrack: AVAssetTrack? { filler }

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

enum TimelineLane: Int, CaseIterable {
    case titles, graphics, video, music
}
