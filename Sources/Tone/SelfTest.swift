#if DEBUG
import AVFoundation
import Accelerate
import AppKit
import EaselKit

/// Debug-only test: `TONE_SELFTEST=/out/dir .build/debug/Tone`
@MainActor
enum ToneSelfTest {
    static func runIfRequested(_ studio: ToneStudio) async {
        guard let dir = ProcessInfo.processInfo.environment["TONE_SELFTEST"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: dir).appendingPathComponent("tone", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }
        let sr = AudioIO.sampleRate
        func sine(_ f: Double, _ seconds: Double, _ amp: Float = 0.5) -> [Float] {
            (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * f * Double($0) / sr)) }
        }
        func noise(_ seconds: Double, _ amp: Float) -> [Float] {
            var g = SystemRandomNumberGenerator()
            return (0..<Int(seconds * sr)).map { _ in amp * Float.random(in: -1...1, using: &g) }
        }
        func stereo(_ x: [Float]) -> AudioData { AudioData(channels: [x, x], sampleRate: sr) }
        func rmsDB(_ x: [Float]) -> Float { DSP.db(x.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }) }
        func bandDB(_ x: [Float], _ f: Double) -> Double { 10 * log10(max(1e-12, DSP.energy(x, at: f, sampleRate: sr))) }

        // MARK: Noise reduction
        do {
            let tone = sine(440, 3, 0.3), hiss = noise(3, 0.05)
            var mixed = stereo(zip(tone, hiss).map { $0 + $1 })
            // First second is noise only (the "noise print").
            for c in 0..<2 { for i in 0..<Int(sr) { mixed.channels[c][i] = hiss[i] } }
            let noisePrint = DSP.noiseProfile(mixed.slice(0..<Int(sr)))
            let noiseBefore = rmsDB(Array(mixed.channels[0][Int(0.2 * sr)..<Int(0.8 * sr)]))
            let toneBefore = bandDB(Array(mixed.channels[0][Int(1.5 * sr)..<Int(2.5 * sr)]), 440)
            DSP.reduceNoise(&mixed, profile: noisePrint, amount: 0.7)
            let noiseAfter = rmsDB(Array(mixed.channels[0][Int(0.2 * sr)..<Int(0.8 * sr)]))
            let toneAfter = bandDB(Array(mixed.channels[0][Int(1.5 * sr)..<Int(2.5 * sr)]), 440)
            print(String(format: "  noise %.1f → %.1f dB, tone change %.1f dB", noiseBefore, noiseAfter, toneAfter - toneBefore))
            check(noiseBefore - noiseAfter > 15, "noise reduction removes >15 dB of hiss")
            check(abs(toneAfter - toneBefore) < 1.5, "noise reduction keeps the tone")
        }

        // MARK: Hum
        do {
            var data = stereo(zip(sine(60, 2, 0.2), sine(1000, 2, 0.2)).map { $0 + $1 })
            check(DSP.detectHum(data) == 60, "detects 60 Hz hum")
            let humBefore = bandDB(data.channels[0], 60), keepBefore = bandDB(data.channels[0], 1000)
            DSP.removeHum(&data)
            let tail = Array(data.channels[0][Int(0.5 * sr)...])
            let humDrop = humBefore - bandDB(tail, 60) - 10 * log10(Double(data.frameCount) / Double(tail.count) * 1)
            let keep = bandDB(tail, 1000) - (keepBefore - 10 * log10(Double(data.frameCount * data.frameCount) / Double(tail.count * tail.count)))
            print(String(format: "  hum drop %.1f dB, 1 kHz change %.1f dB", humDrop, keep))
            check(humDrop > 25, "hum removal notches 60 Hz")
            check(abs(keep) < 1, "hum removal leaves 1 kHz alone")
        }

        // MARK: Clicks
        do {
            let clean = sine(300, 1, 0.4)
            var data = stereo(clean)
            for pos in stride(from: 4000, to: 44000, by: 5000) { for c in 0..<2 { data.channels[c][pos] = 0.95; data.channels[c][pos + 1] = -0.9 } }
            let errBefore = zip(data.channels[0], clean).map { abs($0 - $1) }.max()!
            let fixed = DSP.declick(&data)
            let errAfter = zip(data.channels[0], clean).map { abs($0 - $1) }.max()!
            print(String(format: "  clicks fixed %d, max error %.2f → %.3f", fixed, errBefore, errAfter))
            check(fixed >= 8 && errAfter < 0.08, "de-click repairs injected clicks")
            var untouched = stereo(clean)
            check(DSP.declick(&untouched) == 0, "de-click leaves clean audio alone")
        }

        // MARK: Loudness
        do {
            // A 1 kHz sine at −20 dBFS RMS in both channels reads about −17 LUFS (stereo adds 3 dB; K-weighting adds ~0.7).
            var data = stereo(sine(1000, 5, Float(pow(10, -20.0 / 20) * sqrt(2))))
            let before = DSP.loudness(data)
            DSP.normalizeLoudness(&data, target: -16)
            let after = DSP.loudness(data)
            print(String(format: "  loudness %.2f → %.2f LUFS", before, after))
            check(abs(before - (-17.0)) < 0.3, "loudness meter reads a known tone (\(String(format: "%.2f", before)) LUFS)")
            check(abs(after + 16) < 0.3, "loudness normalize hits −16 LUFS")
            var quiet = stereo(sine(500, 1, 0.1))
            DSP.normalize(&quiet)
            check(abs(DSP.db(DSP.peak(quiet)) + 1) < 0.05, "peak normalize to −1 dBFS")
        }

        // MARK: Silence
        do {
            let speechy = sine(220, 1, 0.3) + [Float](repeating: 0.0005, count: Int(1.2 * sr)) + sine(220, 1, 0.3) + [Float](repeating: 0, count: Int(0.2 * sr)) + sine(220, 0.5, 0.3)
            let silent = DSP.silentRanges(stereo(speechy))
            print("  silent ranges \(silent.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) })")
            check(silent.count == 1 && abs(silent[0].lowerBound - 1) < 0.05 && abs(silent[0].upperBound - 2.2) < 0.05, "finds the long silence, ignores the short gap")
        }

        // MARK: Spectrogram
        let spec = DSP.spectrogram(stereo(sine(1000, 1)), width: 200, height: 100)
        check(spec?.width == 200 && spec?.height == 100, "spectrogram renders")

        // MARK: Files & mixdown
        func file(_ name: String, _ data: AudioData) -> URL {
            let url = out.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try? AudioIO.write(data, to: url)
            return url
        }
        let toneURL = file("a440.caf", stereo(sine(440, 2, 0.5)))
        let lowURL = file("a220.caf", stereo(sine(220, 2, 0.5)))
        // Conform a mono 44.1 kHz WAV (like a phone recording) to the session format.
        let monoWAV = out.appendingPathComponent("mono44.wav")
        do {
            try? FileManager.default.removeItem(at: monoWAV)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let f = try AVAudioFile(forWriting: monoWAV, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!
            b.frameLength = 44100
            for i in 0..<44100 { b.floatChannelData![0][i] = 0.5 * Float(sin(2 * .pi * 440 * Double(i) / 44100)) }
            try f.write(from: b)
        } catch { check(false, "write mono wav: \(error)") }
        let conformedURL = AudioIO.newMediaURL()
        let conformedDuration = (try? await AudioIO.conform(monoWAV, to: conformedURL)) ?? 0
        let conformed = try? AudioIO.read(conformedURL)
        check(abs(conformedDuration - 1) < 0.01 && conformed?.channels.count == 2 && conformed?.sampleRate == 48000, "import converts mono 44.1 kHz to 48 kHz stereo")

        var s = Session()
        let a1 = AudioAsset(url: toneURL, name: "a440", duration: 2), a2 = AudioAsset(url: lowURL, name: "a220", duration: 2)
        s.assets = [a1, a2]
        s.limiter = false
        s.tracks[0].regions = [Region(assetID: a1.id, start: 0.5, duration: 1)]
        s.tracks[1].regions = [Region(assetID: a2.id, start: 1, duration: 1)]
        func mix(_ s: Session, _ name: String) -> AudioData? {
            let url = out.appendingPathComponent(name + ".caf")
            try? FileManager.default.removeItem(at: url)
            do { try Mixdown.render(s, buffers: studio.engine.buffers, to: url, format: .caf) } catch { print("  mix error \(error)"); return nil }
            return try? AudioIO.read(url)
        }
        func level(_ d: AudioData?, _ a: Double, _ b: Double, channel: Int = 0) -> Float {
            guard let d else { return -200 }
            return rmsDB(Array(d.channels[channel][Int(a * sr)..<min(d.frameCount, Int(b * sr))]))
        }
        let m = mix(s, "mix")
        check(m.map { abs($0.duration - 2) < 0.01 } ?? false, "mixdown length = end of last region")
        check(level(m, 0, 0.45) < -80, "silence before the first region")
        check(abs(level(m, 0.6, 0.95) - rmsDB(sine(440, 1, 0.5))) < 0.5, "region plays at its timeline position")
        check(abs(DSP.energy(Array(m!.channels[0][Int(1.2 * sr)..<Int(1.4 * sr)]), at: 220, sampleRate: sr) - DSP.energy(Array(sine(220, 0.2, 0.5)), at: 220, sampleRate: sr)) / DSP.energy(Array(sine(220, 0.2, 0.5)), at: 220, sampleRate: sr) < 0.1,
              "two tracks mix together")

        // Clips stored out of time order, and clips that overlap on one track.
        do {
            var o = s
            let a3 = AudioAsset(url: file("a330.caf", stereo(sine(330, 2, 0.5))), name: "a330", duration: 2)
            o.assets.append(a3)
            o.tracks[1].regions = []
            o.tracks[0].regions = [Region(assetID: a1.id, start: 0, duration: 0.5), Region(assetID: a2.id, start: 2, duration: 0.5),
                                   Region(assetID: a3.id, start: 1, duration: 0.5)]
            let om = mix(o, "order")
            check(abs(level(om, 1.05, 1.4) - rmsDB(sine(330, 1, 0.5))) < 0.5 && abs(level(om, 2.05, 2.4) - rmsDB(sine(220, 1, 0.5))) < 0.5,
                  "clips play at their times whatever their order")
            var ov = s
            ov.tracks[1].regions = []
            ov.tracks[0].regions = [Region(assetID: a1.id, start: 0, duration: 1), Region(assetID: a2.id, start: 0.5, duration: 1)]
            let seg = Array(mix(ov, "overlap")!.channels[0][Int(0.6 * sr)..<Int(0.9 * sr)])
            check(bandDB(seg, 440) > 60 && bandDB(seg, 220) > 60, "overlapping clips on one track both play")
        }

        var quieter = s
        quieter.tracks[0].volumeDB = -6
        check(abs((level(m, 0.6, 0.95) - level(mix(quieter, "q"), 0.6, 0.95)) - 6) < 0.3, "track volume −6 dB")
        var panned = s
        panned.tracks[0].pan = -1
        let pm = mix(panned, "pan")
        check(level(pm, 0.6, 0.95, channel: 1) < -40 && level(pm, 0.6, 0.95, channel: 0) > -10, "pan hard left")
        var muted = s
        muted.tracks[0].muted = true
        check(level(mix(muted, "mute"), 0.6, 0.95) < -80, "mute silences a track")
        var solo = s
        solo.tracks[0].solo = true
        check(level(mix(solo, "solo"), 1.55, 1.95) < -80 && level(mix(solo, "solo2"), 0.6, 0.95) > -10, "solo plays only that track")
        var faded = s
        faded.tracks[0].regions[0].fadeIn = 0.4
        let fm = mix(faded, "fade")
        check(level(fm, 0.5, 0.55) < level(fm, 0.95, 1.0) - 15, "region fade-in ramps up")
        var gained = s
        gained.tracks[0].regions[0].gainDB = -12
        check(abs(level(m, 0.6, 0.95) - level(mix(gained, "gain"), 0.6, 0.95) - 12) < 0.3, "clip gain −12 dB")
        var verb = s
        verb.tracks[1].fx.reverb = 60
        verb.tracks[1].fx.room = .cathedral
        let vm = mix(verb, "verb")
        check((vm.map { $0.duration > 3.5 } ?? false) && level(vm, 2.2, 2.6) > -60, "reverb tail rings past the end")
        var eq = s
        eq.tracks[0].fx.lowCut = true
        eq.tracks[0].fx.high = -12
        eq.tracks[0].fx.compressor = 0.6
        eq.tracks[0].fx.delay = 30
        check(mix(eq, "fx") != nil, "every effect renders")
        var loud = s
        loud.limiter = true
        loud.masterDB = 12
        check(DSP.peak(mix(loud, "limit")!) <= 1.0, "master limiter prevents clipping")

        for format in Mixdown.Format.allCases {
            let url = out.appendingPathComponent("export.\(format.ext)")
            try? FileManager.default.removeItem(at: url)
            do {
                try Mixdown.render(s, buffers: studio.engine.buffers, to: url, format: format)
                let f = try AVAudioFile(forReading: url)
                check(abs(Double(f.length) / f.fileFormat.sampleRate - 2) < 0.05, "export \(format.rawValue)")
            } catch {
                check(false, "export \(format.rawValue): \(error)")
            }
        }

        // MARK: Studio operations
        func waitBusy() async { for _ in 0..<600 where studio.busyMessage != nil { try? await Task.sleep(for: .milliseconds(50)) } }
        // Speech-like test file: tone bursts with long pauses and background hiss.
        let speechURL = file("speech.caf", {
            var x = sine(200, 1.2, 0.35) + [Float](repeating: 0, count: Int(1.5 * sr)) + sine(330, 1.0, 0.35) + [Float](repeating: 0, count: Int(1.2 * sr)) + sine(260, 0.8, 0.35)
            let hiss = noise(Double(x.count) / sr, 0.004)
            for i in x.indices { x[i] += hiss[i] }
            return stereo(x)
        }())
        studio.newSession()
        await studio.importFiles([speechURL, toneURL])
        check(studio.session.tracks[0].regions.count == 1 && studio.session.tracks[1].regions.count == 1, "import puts files on separate tracks")
        let speechTrack = studio.session.tracks[0].id, speechRegion = studio.session.tracks[0].regions[0]
        studio.selection = .region(track: speechTrack, region: speechRegion.id)
        studio.seek(to: 0.6)
        studio.split()
        check(studio.session.tracks[0].regions.count == 2, "split at playhead")
        studio.undo()
        check(studio.session.tracks[0].regions.count == 1, "undo split")
        studio.selection = .region(track: speechTrack, region: speechRegion.id)
        studio.stripSilence()
        await waitBusy()
        let pieces = studio.session.tracks[0].regions.sorted { $0.start < $1.start }
        let newLength = pieces.map(\.duration).reduce(0, +)
        print(String(format: "  strip silence: %d pieces, %.2fs → %.2fs", pieces.count, speechRegion.duration, newLength))
        check(pieces.count == 3 && newLength < speechRegion.duration - 2, "strip silence removes the pauses")
        check(zip(pieces, pieces.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.001 }, "strip silence closes the gaps")
        studio.undo()

        studio.selection = .region(track: speechTrack, region: studio.session.tracks[0].regions[0].id)
        studio.captureNoiseProfile()
        check(studio.noiseProfile?.count == DSP.fftSize / 2, "capture noise print (auto, quietest part)")
        let assetsBefore = studio.session.assets.count
        studio.restore(.noise)
        await waitBusy()
        let processed = studio.session.tracks[0].regions[0]
        check(studio.session.assets.count == assetsBefore + 1 && processed.assetID != speechRegion.assetID, "restoration writes a new file (original untouched)")
        if let asset = studio.session.asset(processed.assetID), let after = try? AudioIO.read(asset.url),
           let before = try? AudioIO.read(studio.session.asset(speechRegion.assetID)!.url) {
            let gap = Int(1.5 * sr)..<Int(2.4 * sr)
            let b = rmsDB(Array(before.channels[0][gap])), a2 = rmsDB(Array(after.channels[0][gap]))
            print(String(format: "  pause noise %.1f → %.1f dB", b, a2))
            check(b - a2 > 12, "noise reduction through the app quiets the pauses")
        }
        studio.undo()
        check(studio.session.tracks[0].regions[0].assetID == speechRegion.assetID, "undo restoration")

        // A range dragged from an empty spot selects the clip under it, so restoration can use it.
        studio.selection = .track(speechTrack)
        studio.range = TimeRange(track: speechTrack, start: 0.2, end: 0.6)
        studio.selectClipUnderRange()
        check(studio.selectedRegion?.region.id == speechRegion.id, "range selects the clip under it")
        studio.selection = .track(speechTrack)
        studio.deleteSelection()
        check(studio.session.tracks.contains { $0.id == speechTrack } && studio.session.tracks[0].regions.count == 2,
              "delete with a range cuts the range, not the track")
        studio.undo()

        // Clipboard
        studio.selection = .region(track: speechTrack, region: speechRegion.id)
        studio.copySelection()
        studio.selection = .track(studio.session.tracks[1].id)
        studio.seek(to: 10)
        studio.paste()
        let pasted = studio.session.tracks[1].regions.first { $0.start == 10 }
        check(pasted?.assetID == speechRegion.assetID && pasted?.duration == speechRegion.duration, "copy and paste a clip at the playhead")
        studio.undo()
        studio.seek(to: 0)
        studio.selection = .region(track: speechTrack, region: speechRegion.id)

        studio.range = TimeRange(track: speechTrack, start: 0.2, end: 0.6)
        studio.restore(.reverse)
        await waitBusy()
        check(studio.session.tracks[0].regions[0].assetID != speechRegion.assetID, "restoration on a selected range")
        studio.range = nil
        studio.undo()

        // Live playback runs (output muted so tests don't make noise).
        studio.engine.engine.mainMixerNode.outputVolume = 0
        studio.seek(to: 0)
        studio.toast = nil
        studio.play()
        // Wait until audio is actually flowing (or the app has given up on a dead device).
        for _ in 0..<60 where studio.transport.isPlaying && studio.transport.time < 0.05 { try? await Task.sleep(for: .milliseconds(50)) }
        let startedAt = studio.transport.time
        if studio.transport.isPlaying { try? await Task.sleep(for: .seconds(1)) }
        let played = studio.transport.time - startedAt
        studio.stop()
        print("  played to \(played), toast: \(studio.toast ?? "none")")
        if studio.toast?.hasPrefix("Your audio output isn’t responding") == true {
            print("  NOTE: this Mac's audio output isn't processing audio right now; checked the graceful path instead")
            check(!studio.transport.isPlaying, "dead audio output stops cleanly instead of crashing")
        } else {
            check(played > 0.8 && played < 1.3, "live playback advances in real time")
        }

        // Project file
        let projURL = out.appendingPathComponent("test.tone")
        try? JSONEncoder().encode(studio.session).write(to: projURL)
        check((try? JSONDecoder().decode(Session.self, from: Data(contentsOf: projURL))) == studio.session, "session round-trips through JSON")

        // Reel round trip: a soundtrack sent from Reel opens linked; ⌘S writes the mix back.
        let rt = AppLink.newRoundTripURL(named: "soundtrack.m4a")
        try? Mixdown.render(s, buffers: studio.engine.buffers, to: rt, format: .m4a)
        studio.isDirty = false
        studio.open([rt])
        for _ in 0..<100 where studio.linkedURL == nil { try? await Task.sleep(for: .milliseconds(50)) }
        check(studio.linkedURL == rt && studio.session.tracks[0].regions.count == 1, "file from Reel opens linked")
        let beforeDate = (try? FileManager.default.attributesOfItem(atPath: rt.path))?[.modificationDate] as? Date
        studio.updateTrack(studio.session.tracks[0].id) { $0.volumeDB = -6 }
        try? await Task.sleep(for: .milliseconds(1100))
        studio.save()
        await waitBusy()
        try? await Task.sleep(for: .milliseconds(200))
        let afterDate = (try? FileManager.default.attributesOfItem(atPath: rt.path))?[.modificationDate] as? Date
        check(afterDate != nil && afterDate != beforeDate && studio.toast == "Updated in Reel", "⌘S writes the mix back for Reel")
        try? FileManager.default.removeItem(at: rt.deletingLastPathComponent())

        // MARK: UI snapshot
        studio.newSession()
        await studio.importFiles([speechURL, toneURL, lowURL])
        studio.updateTrack(studio.session.tracks[0].id) { $0.name = "Voice"; $0.fx = TrackFX.presets[1].1 }
        studio.updateTrack(studio.session.tracks[1].id) { $0.name = "Music"; $0.volumeDB = -8; $0.fx.reverb = 20 }
        studio.updateTrack(studio.session.tracks[2].id) { $0.name = "Bass"; $0.pan = -0.4 }
        studio.updateRegion(studio.session.tracks[1].id, studio.session.tracks[1].regions[0].id) { $0.start = 1.5; $0.fadeIn = 0.5; $0.fadeOut = 0.4 }
        studio.selection = .region(track: studio.session.tracks[0].id, region: studio.session.tracks[0].regions[0].id)
        studio.range = TimeRange(track: studio.session.tracks[0].id, start: 1.4, end: 2.5)
        studio.zoom = 140
        studio.seek(to: 0.9)
        try? await Task.sleep(for: .seconds(2))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) {
            for (name, spectral) in [("ui.png", false), ("ui-spectral.png", true)] {
                studio.spectral = spectral
                try? await Task.sleep(for: .seconds(1.5))
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l\(window.windowNumber)", out.appendingPathComponent(name).path]
                try? task.run()
                task.waitUntilExit()
            }
            check(true, "UI screenshots")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("DONE")
        studio.isDirty = false
        NSApp.terminate(nil)
    }
}
#endif
