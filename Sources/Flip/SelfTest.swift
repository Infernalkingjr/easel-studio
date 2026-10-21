#if DEBUG
import AppKit
import AVFoundation
import EaselKit

/// Debug-only test: `FLIP_SELFTEST=/out/dir .build/debug/Flip`
@MainActor
enum FlipSelfTest {
    static func runIfRequested(_ studio: FlipStudio) async {
        guard let dir = ProcessInfo.processInfo.environment["FLIP_SELFTEST"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: dir).appendingPathComponent("flip", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }
        func render(_ f: Int) -> CGImage { FlipRenderer.image(studio.doc, frame: f, images: studio.images) }
        /// Color at a document point (y down).
        func px(_ img: CGImage, _ x: CGFloat, _ y: CGFloat) -> (Double, Double, Double, Double)? {
            let ctx = Bitmap.context(CGSize(width: 1, height: 1))
            ctx.draw(img, in: CGRect(x: -x, y: -(CGFloat(img.height) - y), width: CGFloat(img.width), height: CGFloat(img.height)))
            guard let d = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return nil }
            let a = Double(d[3]) / 255
            return a == 0 ? (0, 0, 0, 0) : (Double(d[0]) / 255 / a, Double(d[1]) / 255 / a, Double(d[2]) / 255 / a, a)
        }
        func isInk(_ c: (Double, Double, Double, Double)?) -> Bool { c.map { $0.0 < 0.3 && $0.1 < 0.3 && $0.2 < 0.3 && $0.3 > 0.5 } ?? false }
        func isWhite(_ c: (Double, Double, Double, Double)?) -> Bool { c.map { $0.0 > 0.9 && $0.1 > 0.9 && $0.2 > 0.9 } ?? false }
        /// Horizontal center of red pixels on row y.
        func redCenter(_ img: CGImage, y: CGFloat) -> CGFloat? {
            var xs: [CGFloat] = []
            for x in stride(from: CGFloat(0), to: CGFloat(img.width), by: 2) {
                if let c = px(img, x, y), c.0 > 0.8, c.1 < 0.3, c.2 < 0.3 { xs.append(x) }
            }
            return xs.isEmpty ? nil : (xs.min()! + xs.max()!) / 2
        }

        studio.newDocument(width: 640, height: 360, fps: 24, transparent: false)
        studio.doc.frameCount = 24

        // MARK: Drawing
        let line = Stroke(kind: .brush, points: (0...100).map { CGPoint(x: 100 + CGFloat($0) * 2, y: 60) }, color: .black, width: 8)
        studio.addStroke(line)
        check(isInk(px(render(0), 200, 60)) && isWhite(px(render(0), 200, 80)), "brush stroke renders")
        check(isInk(px(render(10), 200, 60)), "keyframe holds on later frames")

        studio.erase(along: [CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 70)], radius: 10)
        let strokes = studio.layer.keyframes[0].drawing.strokes
        check(strokes.count == 2 && isWhite(px(render(0), 200, 60)) && isInk(px(render(0), 120, 60)), "eraser splits a stroke in two")
        studio.undo()
        check(studio.layer.keyframes[0].drawing.strokes.count == 1, "undo erase")

        var loop = Stroke(kind: .brush, points: (0...40).map { k in
            let a = CGFloat(k) / 40 * 2 * .pi
            return CGPoint(x: 500 + 40 * cos(a), y: 250 + 40 * sin(a))
        }, color: .black, width: 4)
        loop.pressures = []
        studio.addStroke(loop)
        studio.fillColor = RGBA(r: 0, g: 0.5, b: 1)
        studio.fill(at: CGPoint(x: 500, y: 250))
        let filled = px(render(0), 500, 250)
        check(filled.map { $0.2 > 0.9 && $0.0 < 0.1 } ?? false, "paint bucket fills a closed brush loop")

        let pressureStroke = Stroke(kind: .brush, points: (0...50).map { CGPoint(x: 100 + CGFloat($0) * 4, y: 300) },
                                    pressures: (0...50).map { Float($0) / 50 }, color: .black, width: 20)
        studio.addStroke(pressureStroke)
        check(isInk(px(render(0), 290, 307)) && !isInk(px(render(0), 110, 307)), "pen pressure varies stroke width")

        // MARK: Keyframes & tweens
        studio.addLayer(name: "Ball")
        studio.addStroke(Stroke(kind: .ellipse, points: [CGPoint(x: 80, y: 160), CGPoint(x: 120, y: 200)],
                                color: RGBA(r: 1, g: 0, b: 0), width: 0, fill: RGBA(r: 1, g: 0, b: 0)))
        studio.go(to: 23)
        var target = studio.currentPlacement
        target.x = 400
        studio.setPlacement(target)
        let ball = studio.layer
        check(ball.keyframes.count == 2 && ball.keyframes[0].tween && ball.keyframes[1].frame == 23, "moving on a later frame makes a keyframe and a motion tween")
        studio.setEase(.linear)
        studio.go(to: 0)
        studio.setEase(.linear)
        let c0 = redCenter(render(0), y: 180), c12 = redCenter(render(12), y: 180), c23 = redCenter(render(23), y: 180)
        print("  ball centers: \(String(describing: c0)) \(String(describing: c12)) \(String(describing: c23))")
        check(c0.map { abs($0 - 100) < 4 } ?? false, "tween starts at the first keyframe")
        check(c12.map { abs($0 - (100 + 400 * 12 / 23)) < 5 } ?? false, "tween is halfway in the middle (linear)")
        check(c23.map { abs($0 - 500) < 4 } ?? false, "tween ends at the last keyframe")
        studio.setEase(.easeIn)
        let eased = redCenter(render(6), y: 180)
        check(eased.map { $0 < 100 + 400 * 6 / 23 - 20 } ?? false, "ease-in starts slow")
        check(abs(Ease.bounce.apply(1) - 1) < 1e-9 && abs(Ease.elastic.apply(0)) < 1e-9 && Ease.back.apply(0.8) > 1, "easing curves")

        // Drawing on a tweened frame lands in the object's own space and stays with it at both ends.
        studio.setEase(.linear)
        studio.go(to: 12)
        let mid = CGFloat(400 * 12) / 23
        studio.addStroke(Stroke(kind: .rect, points: [CGPoint(x: 100 + mid - 10, y: 120), CGPoint(x: 100 + mid + 10, y: 130)], color: .black, width: 0,
                                fill: RGBA(r: 0, g: 0, b: 0)))
        check(isInk(px(render(12), 100 + mid, 125)) && isInk(px(render(0), 100, 125)) && isInk(px(render(23), 500, 125)),
              "strokes drawn mid-tween move with the object, start to end")

        var spun = studio.currentPlacement
        spun.rotation = 90
        studio.setPlacement(spun)
        let rotated = render(23)
        check(redCenter(rotated, y: 180) != nil, "rotation renders")

        // Blank keyframe hides the layer from there on.
        studio.layerID = studio.doc.layers[1].id
        studio.go(to: 15)
        studio.insertKeyframe(blank: true)
        check(!isInk(px(render(16), 200, 60)) && isInk(px(render(14), 200, 60)), "blank keyframe clears the layer")
        studio.undo()

        studio.go(to: 5)
        studio.layerID = studio.doc.layers[0].id
        let before = studio.layer.keyframes.map(\.frame)
        studio.insertFrame()
        check(studio.layer.keyframes.map(\.frame) == before.map { $0 > 5 ? $0 + 1 : $0 }, "insert frame pushes later keyframes")
        studio.removeFrame()
        check(studio.layer.keyframes.map(\.frame) == before, "remove frame pulls them back")
        studio.moveKeyframe(layer: studio.layerID, from: 23, to: 20)
        check(studio.layer.keyframes.last?.frame == 20, "drag a keyframe to retime")
        studio.undo()

        // Onion skin shows neighbouring frames tinted.
        let onion = Bitmap.render(studio.doc.size) { ctx in
            ctx.translateBy(x: 0, y: studio.doc.height); ctx.scaleBy(x: 1, y: -1)
            FlipRenderer.draw(studio.doc, frame: 12, in: ctx, images: studio.images, onion: .init())
        }
        let ghost = px(onion, CGFloat(100 + 400 * 10 / 23), 180)
        check(ghost.map { $0.0 > 0.6 && $0.3 > 0.1 } ?? false, "onion skin shows the previous frames")

        // MARK: Images
        let sticker = out.appendingPathComponent("sticker.png")
        try? Bitmap.png(Bitmap.render(CGSize(width: 100, height: 100)) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        })?.write(to: sticker)
        let layersBefore = studio.doc.layers.count
        studio.go(to: 0)
        studio.importImages([sticker])
        let topHalf = px(render(0), 320, 180 - 40), bottomHalf = px(render(0), 320, 180 + 40)
        check(studio.doc.layers.count == layersBefore + 1, "imported image gets its own layer")
        check((topHalf.map { $0.0 > 0.9 && $0.1 > 0.9 } ?? false) && (bottomHalf.map { $0.1 > 0.7 && $0.0 < 0.2 } ?? false), "imported image is upright")

        // MARK: Files
        let projURL = out.appendingPathComponent("test.flip")
        try? JSONEncoder().encode(studio.doc).write(to: projURL)
        check((try? JSONDecoder().decode(FlipDocument.self, from: Data(contentsOf: projURL))) == studio.doc, "animation round-trips through JSON")

        // MARK: Performance
        let start = Date()
        for f in 0..<48 { _ = render(f % 24) }
        let fps = 48 / Date().timeIntervalSince(start)
        print(String(format: "  render speed %.0f fps", fps))
        check(fps > 60, "frames render faster than playback")

        // MARK: Export
        for format in FlipExporter.Format.allCases {
            var doc = studio.doc
            if format == .movAlpha { doc.background = nil }
            let url = out.appendingPathComponent("export" + (format.ext.isEmpty ? "-frames" : ".\(format.ext)"))
            try? FileManager.default.removeItem(at: url)
            do {
                try await FlipExporter.export(doc, images: studio.images, format: format, to: url) { _ in }
                switch format {
                case .pngSequence:
                    let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
                    check(n == doc.usedFrames, "export PNG sequence: \(n) frames")
                case .gif:
                    let n = CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                    check(n == doc.usedFrames, "export GIF: \(n) frames")
                case .mp4, .movAlpha:
                    let asset = AVURLAsset(url: url)
                    let d = try await asset.load(.duration).seconds
                    let track = try await asset.loadTracks(withMediaType: .video).first
                    let size = try await track?.load(.naturalSize) ?? .zero
                    let g = AVAssetImageGenerator(asset: asset)
                    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                    let frame = try await g.image(at: CMTime(value: 1, timescale: 24)).image
                    let corner = px(frame, 5, 5)
                    var ok = abs(d - Double(doc.usedFrames) / 24) < 0.1 && size == CGSize(width: 640, height: 360)
                    if format == .movAlpha { ok = ok && (corner.map { $0.3 < 0.1 } ?? false) } else { ok = ok && isWhite(corner) }
                    check(ok, "export \(format.rawValue): \(String(format: "%.2f", d))s \(Int(size.width))×\(Int(size.height)) corner alpha \(corner?.3 ?? -1)")
                }
            } catch {
                check(false, "export \(format.rawValue): \(error)")
            }
        }

        // MARK: UI snapshot
        studio.tool = .select
        studio.layerID = studio.doc.layers[1].id
        studio.go(to: 9)
        studio.fitRequest += 1
        try? await Task.sleep(for: .seconds(2))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l\(window.windowNumber)", out.appendingPathComponent("ui.png").path]
            try? task.run()
            task.waitUntilExit()
            // If the display is asleep, draw the window contents directly instead.
            let shot = out.appendingPathComponent("ui.png")
            if !FileManager.default.fileExists(atPath: shot.path), let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: shot)
            }
            check(FileManager.default.fileExists(atPath: shot.path), "UI screenshot")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("DONE")
        studio.isDirty = false
        NSApp.terminate(nil)
    }
}
#endif
