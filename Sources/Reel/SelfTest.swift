#if DEBUG
import AVFoundation
import AppKit
import SwiftUI
import EaselKit

/// Debug-only end-to-end test: `REEL_SELFTEST=/out/dir .build/debug/Reel`
@MainActor
enum ReelSelfTest {
    static func runIfRequested(_ studio: Studio) async {
        guard let dir = ProcessInfo.processInfo.environment["REEL_SELFTEST"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: dir).appendingPathComponent("reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }

        // Wait for the filler track.
        for _ in 0..<200 where studio.fillerTrack == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard let filler = studio.fillerTrack else { print("FAIL filler"); exit(1) }
        check(true, "filler video ready")

        // MARK: Test media
        let red = out.appendingPathComponent("red.mov"), blue = out.appendingPathComponent("blue.mov")
        let scenes = out.appendingPathComponent("scenes.mov"), tone = out.appendingPathComponent("tone.wav")
        let portrait = out.appendingPathComponent("portrait.png"), sticker = out.appendingPathComponent("sticker.png")
        let redWithAudio = out.appendingPathComponent("red-audio.mov")
        do {
            try await makeVideo(red, segments: [(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), 2)])
            try await makeVideo(blue, segments: [(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), 2)])
            try await makeVideo(scenes, segments: [(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), 1.5),
                                                  (CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1), 1.5),
                                                  (CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), 1.5)])
            try makeTone(tone, seconds: 6)
            try await mux(video: red, audio: tone, to: redWithAudio)
            try Bitmap.png(Bitmap.filled(CGSize(width: 300, height: 600), color: CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1)))!.write(to: portrait)
            try Bitmap.png(Bitmap.render(CGSize(width: 200, height: 200)) { ctx in
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 200, height: 200))
            })!.write(to: sticker)
            check(true, "made test media")
        } catch {
            check(false, "made test media: \(error)")
        }

        let lib = studio.library
        guard let mRed = await lib.importMedia(red), let mBlue = await lib.importMedia(blue),
              let mScenes = await lib.importMedia(scenes), let mTone = await lib.importMedia(tone),
              let mPortrait = await lib.importMedia(portrait), let mSticker = await lib.importMedia(sticker),
              let mRedAudio = await lib.importMedia(redWithAudio) else {
            print("FAIL import"); exit(1)
        }
        check(mRed.kind == .video && abs(mRed.duration - 2) < 0.1 && mRed.size == CGSize(width: 320, height: 180), "import video \(mRed.size) \(mRed.duration)")
        check(mTone.kind == .audio && abs(mTone.duration - 6) < 0.1, "import audio")
        check(mPortrait.kind == .image && !mPortrait.hasAlpha, "import photo")
        check(mSticker.hasAlpha, "transparent image detected as graphic")
        check(mRedAudio.hasAudio, "video with audio")

        // MARK: Rendering
        let size = CGSize(width: 320, height: 180)
        func frame(_ p: Project, _ t: Double) async -> CGImage? {
            let built: BuiltTimeline
            do { built = try TimelineBuilder.build(p, library: lib, filler: filler, renderSize: size, autoFilters: studio.autoFilters) }
            catch { print("  build error: \(error)"); return nil }
            let g = AVAssetImageGenerator(asset: built.composition)
            g.videoComposition = built.videoComposition
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            do { return try await g.image(at: TimelineBuilder.time(t)).image }
            catch { print("  frame error at \(t): \(error)"); return nil }
        }
        func rgb(_ img: CGImage?, _ x: CGFloat = 0.5, _ y: CGFloat = 0.5) -> (Double, Double, Double)? {
            guard let img, let c = ImageOps.color(in: img, at: CGPoint(x: CGFloat(img.width) * x, y: CGFloat(img.height) * y)) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        // Video codecs store YUV, so pure colors come back slightly off (red ≈ 0.90, 0.13, 0.00).
        func near(_ c: (Double, Double, Double)?, _ r: Double, _ g: Double, _ b: Double, _ tol: Double = 0.17) -> Bool {
            guard let c else { return false }
            return abs(c.0 - r) < tol && abs(c.1 - g) < tol && abs(c.2 - b) < tol
        }

        var p = Project()
        p.media = [mRed, mBlue, mScenes, mTone, mPortrait, mSticker, mRedAudio]
        p.clips = [Clip(mediaID: mRed.id, sourceDuration: 2), Clip(mediaID: mBlue.id, sourceDuration: 2)]
        check(abs(p.duration - 4) < 0.01, "two clips back to back = 4s")
        let f05 = rgb(await frame(p, 0.5)), f3 = rgb(await frame(p, 3))
        check(near(f05, 1, 0, 0), "frame 0.5s is red \(String(describing: f05))")
        check(near(f3, 0, 0, 1), "frame 3s is blue \(String(describing: f3))")

        p.clips[0].transition = Transition(kind: .crossfade, duration: 1)
        check(abs(p.duration - 3) < 0.01, "1s crossfade overlaps clips (3s total)")
        let mid = rgb(await frame(p, 1.5))
        print("  crossfade midpoint \(String(describing: mid))")
        check(mid.map { $0.0 > 0.25 && $0.2 > 0.25 && $0.0 < 0.8 } ?? false, "crossfade midpoint mixes red and blue")

        for kind in TransitionKind.allCases {
            var q = p
            q.clips[0].transition = Transition(kind: kind, duration: 1)
            let img = await frame(q, 1.5)
            let a = rgb(img, 0.5, 0.5), b = rgb(img, 0.15, 0.5), c = rgb(img, 0.85, 0.5)
            let changed = [a, b, c].contains { c in c.map { !near($0, 1, 0, 0, 0.05) && !near($0, 0, 0, 1, 0.05) } ?? false }
                || !(near(b, a?.0 ?? 0, a?.1 ?? 0, a?.2 ?? 0, 0.05) && near(c, a?.0 ?? 0, a?.1 ?? 0, a?.2 ?? 0, 0.05))
            check(img != nil && changed, "transition \(kind.rawValue) renders mid-way")
            if let img, let png = Bitmap.png(img) { try? png.write(to: out.appendingPathComponent("transition-\(kind.rawValue).png")) }
        }
        p.clips[0].transition = nil

        p.clips[1].speed = 2
        check(abs(p.duration - 3) < 0.01, "2× speed halves the clip")
        let fast = rgb(await frame(p, 2.8))
        check(near(fast, 0, 0, 1), "fast clip still renders \(String(describing: fast))")
        p.clips[1].speed = 1

        p.clips.append(Clip(mediaID: mPortrait.id, sourceDuration: 2))
        p.clips[2].fit = .fit
        p.background = .blur
        let photo = await frame(p, 4.5)
        check(near(rgb(photo), 0, 0.8, 0), "photo clip renders")
        check(rgb(photo, 0.05, 0.5).map { $0.1 > 0.2 } ?? false, "fit + blur background fills the sides (\(String(describing: rgb(photo, 0.05, 0.5))))")
        p.background = .black
        check(near(rgb(await frame(p, 4.5), 0.05, 0.5), 0, 0, 0, 0.05), "fit + black background")

        p.clips[0].look = "invert"
        let inverted = rgb(await frame(p, 0.5))
        check(near(inverted, 0, 1, 1), "Easel look applies to video (invert red → cyan) \(String(describing: inverted))")
        p.clips[0].look = nil
        p.clips[0].adjustments.saturation = -100
        let gray = rgb(await frame(p, 0.5))
        check(gray.map { abs($0.0 - $0.1) < 0.05 } ?? false, "Easel adjustments apply to video")
        p.clips[0].adjustments = Adjustments()
        p.clips[0].fadeIn = 1
        check(near(rgb(await frame(p, 0.02)), 0, 0, 0, 0.1), "fade in starts black")

        var tp = p
        tp.titles = [TitleItem(text: "████", start: 0, duration: 2, style: .clean, animation: .none, position: .center)]
        tp.clips[0].fadeIn = 0
        let titled = await frame(tp, 1)
        check(near(rgb(titled), 1, 1, 1, 0.15), "title renders over video")
        if let titled, let png = Bitmap.png(titled) { try? png.write(to: out.appendingPathComponent("title.png")) }
        tp.graphics = [Graphic(mediaID: mSticker.id, start: 0, duration: 2, x: 0.8, y: 0.2, scale: 0.2, animation: .none)]
        check(near(rgb(await frame(tp, 1), 0.8, 0.8), 1, 1, 0), "graphic renders at its position")

        // MARK: Editing
        studio.project = p
        studio.project.clips[0].fadeIn = 0
        studio.checkpoint()
        studio.seek(to: 1)
        studio.split()
        check(studio.project.clips.count == 4 && abs(studio.project.clips[0].sourceDuration - 1) < 0.02 && abs(studio.project.clips[1].sourceStart - 1) < 0.02, "split at playhead")
        studio.undo()
        check(studio.project.clips.count == 3, "undo split")
        studio.selection = .clip(studio.project.clips[1].id)
        studio.deleteSelection()
        check(studio.project.clips.count == 2 && studio.project.clips[1].mediaID == mPortrait.id, "ripple delete")
        studio.undo()
        studio.moveClip(from: 2, to: 0)
        check(studio.project.clips[0].mediaID == mPortrait.id, "reorder clips")
        studio.undo()

        // Playback actually runs through the custom compositor in real time.
        studio.rebuild()
        studio.seek(to: 0)
        try? await Task.sleep(for: .milliseconds(300))
        studio.play()
        try? await Task.sleep(for: .seconds(1.2))
        let played = studio.playback.time
        studio.pause()
        print("  played to \(played)")
        check(played > 0.8, "real-time playback advances (\(played)s)")

        // MARK: Scene detection
        studio.project.clips = [Clip(mediaID: mScenes.id, sourceDuration: mScenes.duration)]
        studio.selection = .clip(studio.project.clips[0].id)
        let cuts = await ReelAI.sceneCuts(in: mScenes, from: 0, length: mScenes.duration, library: lib)
        print("  scene cuts \(cuts)")
        check(cuts.count == 2 && abs(cuts[0] - 1.5) < 0.3 && abs(cuts[1] - 3) < 0.3, "scene detection finds both cuts")

        // MARK: Captions grouping
        let words = ["Hello", "there", "this", "is", "Reel.", "It", "makes", "captions", "automatically", "for", "you"]
            .enumerated().map { ReelAI.Word(text: $1, start: Double($0) * 0.4 + ($0 >= 5 ? 1 : 0), duration: 0.3) }
        let lines = ReelAI.group(words)
        print("  captions \(lines.map(\.text))")
        check(lines.count >= 2 && lines[0].text == "Hello there this is Reel.", "captions break at sentences")
        check(zip(lines, lines.dropFirst()).allSatisfy { $0.start + $0.duration <= $1.start + 1e-9 }, "captions never overlap")

        // MARK: Auto enhance
        let specs = await ReelAI.autoEnhanceFilters(for: mPortrait, at: 0, library: lib)
        check(specs.allSatisfy { CIFilter(name: $0.name) != nil }, "auto enhance produces valid filters (\(specs.map(\.name)))")

        // MARK: Project file
        let projURL = out.appendingPathComponent("test.reel")
        try? JSONEncoder().encode(p).write(to: projURL)
        let decoded = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: projURL))
        check(decoded == p, "project round-trips through JSON")

        // MARK: Export
        var ep = p
        ep.clips = [Clip(mediaID: mRedAudio.id, sourceDuration: 2, transition: Transition(kind: .crossfade, duration: 0.5)),
                    Clip(mediaID: mBlue.id, sourceDuration: 2), Clip(mediaID: mPortrait.id, sourceDuration: 1)]
        ep.titles = [TitleItem(text: "Export test", start: 0.5, duration: 2)]
        ep.music = [MusicClip(mediaID: mTone.id, start: 0, duration: 4.5, volume: 0.3)]
        ep.aspect = .portrait
        for format in ExportSettings.Format.allCases {
            var settings = ExportSettings()
            settings.format = format
            settings.shortSide = 360
            let url = out.appendingPathComponent("export.\(format.fileExtension)")
            let started = Date()
            do {
                try await Exporter.export(ep, library: lib, filler: filler, autoFilters: [:], settings: settings, to: url) { _ in }
                let asset = AVURLAsset(url: url)
                let seconds = Date().timeIntervalSince(started)
                switch format {
                case .gif:
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil)
                    let count = src.map { CGImageSourceGetCount($0) } ?? 0
                    let first = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                    check(count > 40 && first?.width == 360, "export GIF: \(count) frames, \(first?.width ?? 0)×\(first?.height ?? 0)")
                case .audio:
                    let d = try await asset.load(.duration).seconds
                    check(abs(d - ep.duration) < 0.2, "export audio: \(d)s")
                default:
                    let d = try await asset.load(.duration).seconds
                    let v = try await asset.loadTracks(withMediaType: .video).first
                    let dims = try await v?.load(.naturalSize) ?? .zero
                    let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
                    check(abs(d - ep.duration) < 0.15 && dims == CGSize(width: 360, height: 640) && hasAudio,
                          "export \(format.rawValue): \(String(format: "%.2f", d))s \(Int(dims.width))×\(Int(dims.height)) audio:\(hasAudio) in \(String(format: "%.1f", seconds))s")
                    // The exported frames should match the timeline.
                    let g = AVAssetImageGenerator(asset: asset)
                    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                    let img = try? await g.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
                    check(near(rgb(img, 0.5, 0.2), 1, 0, 0, 0.15), "exported \(format.rawValue) starts red")
                }
            } catch {
                check(false, "export \(format.rawValue): \(error.localizedDescription)")
            }
        }

        // MARK: Easel link
        let fromEasel = AppLink.newToReelURL(named: "selftest")
        try? FileManager.default.copyItem(at: sticker, to: fromEasel)
        check(AppLink.isFromEasel(fromEasel) && !AppLink.isRoundTrip(fromEasel), "Easel → Reel folder detection")
        studio.project = Project()
        await studio.importAndPlace([fromEasel])
        check(studio.project.graphics.count == 1, "image from Easel with transparency lands on the graphics lane")
        try? FileManager.default.removeItem(at: fromEasel)
        let rt = AppLink.newRoundTripURL(named: "x.png")
        check(AppLink.isRoundTrip(rt), "round-trip folder detection")

        // Round trip: a photo edited in Easel updates here automatically.
        let rtFile = AppLink.newRoundTripURL(named: "rt.png")
        try? Bitmap.png(Bitmap.filled(CGSize(width: 320, height: 180), color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))?.write(to: rtFile)
        if let mRT = await lib.importMedia(rtFile) {
            var rp = Project()
            rp.media = [mRT]
            rp.clips = [Clip(mediaID: mRT.id, sourceDuration: 2)]
            studio.project = rp
            studio.editInEaselWatchOnly(mediaID: mRT.id)
            check(near(rgb(await frame(studio.project, 1)), 0, 0, 1), "round-trip photo starts blue")
            try? await Task.sleep(for: .milliseconds(1100))
            try? Bitmap.png(Bitmap.filled(CGSize(width: 320, height: 180), color: CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)))?.write(to: rtFile, options: .atomic)
            studio.toast = nil
            for _ in 0..<40 where studio.toast != "Updated from Easel" { try? await Task.sleep(for: .milliseconds(100)) }
            check(studio.toast == "Updated from Easel", "Reel notices the save from Easel")
            check(near(rgb(await frame(studio.project, 1)), 1, 0.5, 0), "clip shows Easel’s edit")
        }
        try? FileManager.default.removeItem(at: rtFile.deletingLastPathComponent())

        // Soundtrack round trip with Tone: a longer mix saved there updates the music here.
        let rtAudio = AppLink.newRoundTripURL(named: "song.wav")
        try? makeTone(rtAudio, seconds: 2)
        if let mSong = await lib.importMedia(rtAudio) {
            var sp = Project()
            sp.media = [mSong, mRed]
            sp.clips = [Clip(mediaID: mRed.id, sourceDuration: 2)]
            sp.music = [MusicClip(mediaID: mSong.id, start: 0, duration: 2)]
            studio.project = sp
            studio.editInEaselWatchOnly(mediaID: mSong.id)
            try? await Task.sleep(for: .milliseconds(1100))
            try? makeTone(rtAudio, seconds: 5, frequency: 220)
            studio.toast = nil
            for _ in 0..<50 where studio.toast != "Soundtrack updated from Tone" { try? await Task.sleep(for: .milliseconds(100)) }
            check(studio.toast == "Soundtrack updated from Tone" && abs((studio.project.media(mSong.id)?.duration ?? 0) - 5) < 0.05,
                  "Reel picks up a soundtrack saved in Tone")
        }
        try? FileManager.default.removeItem(at: rtAudio.deletingLastPathComponent())

        // MARK: Edge cases: nothing but the black backbone track.
        let empty = await frame(Project(), 0)
        check(empty != nil && near(rgb(empty), 0, 0, 0, 0.05), "empty project renders black")
        var titlesOnly = Project()
        titlesOnly.titles = [TitleItem(text: "████", start: 0, duration: 3, style: .clean, animation: .none)]
        let titleFrame = rgb(await frame(titlesOnly, 1.5))
        check(abs(titlesOnly.duration - 3) < 0.01 && near(titleFrame, 1, 1, 1, 0.15), "titles-only project (no video) renders")
        var slideshow = Project()
        slideshow.media = [mPortrait, mSticker]
        slideshow.clips = [Clip(mediaID: mPortrait.id, sourceDuration: 2, motion: .zoomIn, transition: Transition(kind: .crossfade, duration: 0.5)),
                           Clip(mediaID: mSticker.id, sourceDuration: 2, fit: .fit)]
        slideshow.background = .white
        let s1 = await frame(slideshow, 0.5), s2 = await frame(slideshow, 3.2)
        check(near(rgb(s1), 0, 0.8, 0) && near(rgb(s2), 1, 1, 0) && near(rgb(s2, 0.05, 0.5), 1, 1, 1, 0.05),
              "photo-only slideshow with transition \(String(describing: rgb(s2, 0.05, 0.5)))")

        // MARK: Performance: render a busy 1080p timeline as fast as possible.
        do {
            var perf = Project()
            perf.media = [mRedAudio, mScenes, mPortrait, mSticker, mTone]
            perf.clips = [Clip(mediaID: mRedAudio.id, sourceDuration: 2, look: "CIPhotoEffectChrome", transition: Transition(kind: .pageCurl, duration: 1)),
                          Clip(mediaID: mScenes.id, sourceDuration: 4.5, speed: 1.5, adjustments: { var a = Adjustments(); a.contrast = 30; a.vignette = 40; return a }(),
                               transition: Transition(kind: .zoom, duration: 1)),
                          Clip(mediaID: mPortrait.id, sourceDuration: 3, fit: .fit, motion: .zoomIn)]
            perf.titles = [TitleItem(text: "Performance", start: 0, duration: 5), TitleItem(text: "Lower third", start: 2, duration: 4, style: .lowerThird, position: .lowerThird)]
            perf.graphics = [Graphic(mediaID: mSticker.id, start: 0, duration: 6, x: 0.85, y: 0.2, scale: 0.15)]
            perf.music = [MusicClip(mediaID: mTone.id, start: 0, duration: 6)]
            let built = try TimelineBuilder.build(perf, library: lib, filler: filler, renderSize: CGSize(width: 1920, height: 1080))
            let reader = try AVAssetReader(asset: built.composition)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                             videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = built.videoComposition
            reader.add(output)
            reader.startReading()
            let start = Date()
            var frames = 0
            while output.copyNextSampleBuffer() != nil { frames += 1 }
            let fps = Double(frames) / Date().timeIntervalSince(start)
            print("  rendered \(frames) frames at 1080p: \(Int(fps)) fps")
            check(fps > 60, "1080p render speed \(Int(fps)) fps (needs > 60 for smooth 30 fps playback with headroom)")
        } catch {
            check(false, "performance test: \(error)")
        }

        // MARK: UI snapshot with a real project loaded
        var demo = Project()
        demo.media = [mRedAudio, mBlue, mScenes, mPortrait, mSticker, mTone]
        demo.clips = [Clip(mediaID: mRedAudio.id, sourceDuration: 2, transition: Transition(kind: .pageCurl, duration: 0.8)),
                      Clip(mediaID: mScenes.id, sourceDuration: 4.5, speed: 1.5, look: "CIPhotoEffectChrome", transition: Transition(kind: .zoom)),
                      Clip(mediaID: mPortrait.id, sourceDuration: 3, fit: .fit, motion: .zoomIn),
                      Clip(mediaID: mBlue.id, sourceDuration: 2, fadeOut: 1)]
        demo.titles = [TitleItem(text: "Summer Trip", start: 0.3, duration: 2.5, style: .bold),
                       TitleItem(text: "Taeyang\nDirector", start: 3.2, duration: 3, style: .lowerThird, animation: .slideUp, position: .lowerThird,
                                 color: RGB(r: 1, g: 0.42, b: 0.2))]
        demo.graphics = [Graphic(mediaID: mSticker.id, start: 1, duration: 3, x: 0.85, y: 0.2, scale: 0.15)]
        demo.music = [MusicClip(mediaID: mTone.id, start: 0, duration: 8, volume: 0.4)]
        studio.project = demo
        studio.selection = .clip(demo.clips[1].id)
        studio.timelineZoom = 90
        try? await Task.sleep(for: .milliseconds(500))
        studio.seek(to: 1.0)
        try? await Task.sleep(for: .seconds(2.5))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) {
            let shot = out.appendingPathComponent("ui.png")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l\(window.windowNumber)", shot.path]
            try? task.run()
            task.waitUntilExit()
            check(FileManager.default.fileExists(atPath: shot.path), "UI screenshot")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("DONE")
        studio.isDirty = false
        NSApp.terminate(nil)
    }

    // MARK: Media generators

    static func makeVideo(_ url: URL, segments: [(CGColor, Double)], size: CGSize = CGSize(width: 320, height: 180), fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var frame: Int64 = 0
        for (color, seconds) in segments {
            let comps = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            for _ in 0..<Int(seconds * Double(fps)) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                guard let buffer else { continue }
                CVPixelBufferLockBaseAddress(buffer, [])
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<Int(size.height) {
                    for x in 0..<Int(size.width) {
                        let o = y * bpr + x * 4
                        base[o] = UInt8(comps[2] * 255); base[o + 1] = UInt8(comps[1] * 255)
                        base[o + 2] = UInt8(comps[0] * 255); base[o + 3] = 255
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps))
                frame += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func makeTone(_ url: URL, seconds: Double, frequency: Double = 440) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = AVAudioFrameCount(seconds * 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(count) { data[i] = Float(sin(2 * .pi * frequency * Double(i) / 44100) * 0.5) }
        try file.write(from: buffer)
    }

    static func mux(video: URL, audio: URL, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        let vd = try await v.load(.duration)
        let vt = try await v.loadTracks(withMediaType: .video)[0], at = try await a.loadTracks(withMediaType: .audio)[0]
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: at, at: .zero)
        let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        try await session.export(to: url, as: .mov)
    }
}
#endif
