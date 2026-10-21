import EaselKit
#if DEBUG
import SwiftUI

/// Debug-only smoke test: `EASEL_SELFTEST=/out/dir .build/debug/Easel`
@MainActor
enum SelfTest {
    static func runIfRequested(_ editor: Editor) async {
        guard let dir = ProcessInfo.processInfo.environment["EASEL_SELFTEST"] else { return }
        let out = URL(fileURLWithPath: dir)
        func check(_ ok: Bool, _ name: String) { print(ok ? "PASS" : "FAIL", name) }
        func px(_ p: CGPoint) -> NSColor? { ImageOps.color(in: editor.composite(), at: p) }
        func near(_ c: NSColor?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
            guard let c else { return false }
            return abs(c.redComponent - r) < 0.05 && abs(c.greenComponent - g) < 0.05 && abs(c.blueComponent - b) < 0.05
        }

        editor.newDocument(size: CGSize(width: 400, height: 300), background: .white)
        check(editor.layers.count == 1 && near(px(CGPoint(x: 10, y: 10)), 1, 1, 1), "new white canvas")

        editor.primaryColor = Color(red: 1, green: 0, blue: 0)
        let red = editor.primaryCG
        editor.commitActive { ctx, img, rect in
            ctx.draw(img, in: rect)
            ctx.setStrokeColor(red); ctx.setLineWidth(20); ctx.setLineCap(.round)
            ctx.strokeLineSegments(between: [CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)])
        }
        check(near(px(CGPoint(x: 200, y: 150)), 1, 0, 0), "brush stroke commit")

        editor.undo()
        check(near(px(CGPoint(x: 200, y: 150)), 1, 1, 1), "undo")
        editor.redo()
        check(near(px(CGPoint(x: 200, y: 150)), 1, 0, 0), "redo")

        editor.primaryColor = Color(red: 0, green: 0, blue: 1)
        editor.floodFill(at: CGPoint(x: 10, y: 10))
        check(near(px(CGPoint(x: 10, y: 10)), 0, 0, 1) && near(px(CGPoint(x: 200, y: 150)), 1, 0, 0), "flood fill stops at stroke")

        editor.addEmptyLayer()
        editor.selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        editor.primaryColor = Color(red: 0, green: 1, blue: 0)
        editor.fillSelection()
        check(near(px(CGPoint(x: 50, y: 50)), 0, 1, 0) && near(px(CGPoint(x: 150, y: 50)), 0, 0, 1), "fill selection on new layer")
        editor.updateLayer(editor.activeLayerID!) { $0.blendMode = .multiply }
        check(near(px(CGPoint(x: 50, y: 50)), 0, 0, 0), "multiply blend")
        editor.updateLayer(editor.activeLayerID!) { $0.blendMode = .normal }
        editor.deselect()

        editor.mergeDown()
        check(editor.layers.count == 1, "merge down")

        editor.rotate(clockwise: true)
        check(editor.canvasSize == CGSize(width: 300, height: 400), "rotate size")
        // Green square was bottom-left; after clockwise rotation it is top-left.
        check(near(px(CGPoint(x: 50, y: 350)), 0, 1, 0), "rotate content")
        editor.rotate(clockwise: false)
        check(near(px(CGPoint(x: 50, y: 50)), 0, 1, 0), "rotate back")

        editor.flip(horizontal: true)
        check(near(px(CGPoint(x: 350, y: 50)), 0, 1, 0), "flip horizontal")
        editor.flip(horizontal: true)

        editor.crop(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        check(editor.canvasSize == CGSize(width: 100, height: 100) && near(px(CGPoint(x: 50, y: 50)), 0, 1, 0), "crop")
        editor.undo()

        editor.applyEffect(Effect.all.first { $0.id == "invert" }!)
        func waitBusy() async { for _ in 0..<1200 where editor.busyMessage != nil { try? await Task.sleep(for: .milliseconds(50)) } }
        await waitBusy()
        check(near(px(CGPoint(x: 50, y: 50)), 1, 0, 1), "invert effect")
        editor.undo()

        editor.adjustments.saturation = -100
        editor.applyAdjustments()
        let g = px(CGPoint(x: 200, y: 150))
        check(g.map { abs($0.redComponent - $0.greenComponent) < 0.05 } ?? false, "desaturate adjustment")
        editor.undo()

        for e in Effect.all { check(ImageOps.process(editor.composite()) { e.apply($0) } != nil, "effect \(e.name)") }

        editor.primaryColor = .black
        editor.commitText(TextRequest(point: CGPoint(x: 20, y: 280)), string: "Hello")
        check(editor.layers.count == 2 && editor.activeLayer?.text?.string == "Hello", "text layer")
        let tid = editor.activeLayerID!
        editor.commitActive(moving: CGPoint(x: 10, y: -5)) { ctx, img, r in ctx.draw(img, in: r.offsetBy(dx: 10, dy: -5)) }
        check(editor.activeLayer?.text?.x == 30 && editor.activeLayer?.text?.y == 275, "text stays editable after move")
        editor.textClick(at: CGPoint(x: editor.activeLayer!.text!.bounds.midX, y: editor.activeLayer!.text!.bounds.midY))
        check(editor.pendingText?.layerID == tid && editor.pendingText?.string == "Hello", "text click opens editor")
        editor.commitText(editor.pendingText!, string: "World")
        editor.pendingText = nil
        check(editor.activeLayer?.text?.string == "World" && editor.layers.count == 2, "text re-edit")
        editor.flip(horizontal: true, layerOnly: true)
        check(editor.activeLayer?.text == nil, "painting over text rasterizes it")
        editor.undo()
        check(editor.activeLayer?.text?.string == "World", "undo restores editable text")

        let proj = out.appendingPathComponent("selftest.easel")
        editor.updateLayer(tid) { $0.opacity = 0.5; $0.blendMode = .screen }
        let layersBefore = editor.layers
        if let file = try? ProjectFile(canvasSize: editor.canvasSize, layers: editor.layers, activeIndex: 1) {
            try? file.write(to: proj)
        }
        editor.openFile(proj)
        editor.save()
        check(!editor.isDirty && editor.toast == "Saved", "save to existing project")
        check(editor.layers.count == layersBefore.count && editor.documentURL == proj, "project reopen")
        check(editor.layers[1].opacity == 0.5 && editor.layers[1].blendMode == .screen && editor.layers[1].text?.string == "World", "project keeps layer settings and text")

        editor.resizeImage(to: CGSize(width: 200, height: 150))
        check(editor.canvasSize == CGSize(width: 200, height: 150), "resize")

        // Every format must write, reopen at the right size, and keep its colors.
        let reference = editor.composite(background: .white)
        for f in ExportFormat.allCases {
            let data = editor.exportData(format: f, quality: 0.9, scale: 1)
            let ext = f.type.preferredFilenameExtension ?? f.rawValue.lowercased()
            if let data { try? data.write(to: out.appendingPathComponent("selftest.\(ext)")) }
            if f == .pdf, let data, let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!), let page = doc.page(at: 1) {
                let box = page.getBoxRect(.mediaBox)
                let ctx = Bitmap.context(box.size)
                ctx.setFillColor(.white); ctx.fill(box); ctx.drawPDFPage(page)
                let rendered = ctx.makeImage()!
                let ok = box.size == editor.canvasSize
                    && near(ImageOps.color(in: rendered, at: CGPoint(x: 100, y: 75)), 1, 0, 0) == near(ImageOps.color(in: reference, at: CGPoint(x: 100, y: 75)), 1, 0, 0)
                check(ok && doc.numberOfPages == 1, "export PDF: \(Int(box.width))×\(Int(box.height)) pt, renders")
                try? data.write(to: out.appendingPathComponent("selftest.pdf"))
                continue
            }
            guard let data, data.count > 100, let back = Bitmap.load(data: data) else {
                check(false, "export \(f.rawValue) (\(data?.count ?? 0) bytes)")
                continue
            }
            let want = editor.exportSize(format: f, scale: 1)
            let sizeOK = back.width == Int(want.width) && back.height == Int(want.height)
            var colorOK = true
            if f.fixedSide == nil {
                // Compare a red pixel from the stroke against the original, over white.
                let flat = Bitmap.render(CGSize(width: back.width, height: back.height)) { ctx in
                    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: back.width, height: back.height))
                    ctx.draw(back, in: CGRect(x: 0, y: 0, width: back.width, height: back.height))
                }
                for probe in [CGPoint(x: 100, y: 75), CGPoint(x: 10, y: 140)] {
                    if let a = ImageOps.color(in: reference, at: probe), let b = ImageOps.color(in: flat, at: probe) {
                        let tol: CGFloat = f == .webSafeGIF ? 0.12 : 0.06
                        if abs(a.redComponent - b.redComponent) > tol || abs(a.greenComponent - b.greenComponent) > tol || abs(a.blueComponent - b.blueComponent) > tol {
                            colorOK = false
                            print("  \(f.rawValue) color at \(probe): \(a) vs \(b)")
                        }
                    }
                }
            }
            check(sizeOK && colorOK, "export \(f.rawValue): \(back.width)×\(back.height), \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        }
        editor.updateLayer(editor.activeLayerID!, checkpoint: true) { $0.name = "Renamed" }
        check(editor.activeLayer?.name == "Renamed", "rename layer")
        editor.undo()
        check(editor.activeLayer?.name != "Renamed", "undo rename")

        editor.open(image: Bitmap.load(url: out.appendingPathComponent("test.png"))!, name: "t")
        let alphaAt = { (p: CGPoint) -> Int in
            let c = Bitmap.context(CGSize(width: 1, height: 1)); c.draw(editor.composite(), in: CGRect(x: -p.x, y: -p.y, width: 1024, height: 1024))
            return Int(c.data!.load(fromByteOffset: 3, as: UInt8.self)) }
        let probes = [CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 300), CGPoint(x: 512, y: 512)]
        let before = probes.map(alphaAt)
        editor.toast = nil
        let started = Date()
        editor.removeBackground(); await waitBusy()
        print("remove background took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        let after = probes.map(alphaAt)
        print("alpha before \(before) after \(after)")
        check(editor.toast == nil && editor.canUndo, "remove background (\(editor.toast ?? "ok"))")
        editor.undo()
        check(probes.map(alphaAt) == before, "undo restores background")
        editor.liftSubject(); await waitBusy()
        check(editor.layers.count == 2 && editor.activeLayer?.name.contains("subject") == true, "lift subject to new layer")
        editor.undo()
        editor.toast = nil
        editor.blurBackground(); await waitBusy()
        check(editor.toast == nil && editor.canUndo, "blur background")
        editor.secondaryColor = Color(red: 0, green: 1, blue: 0)
        editor.undo(); editor.colorBackground(); await waitBusy()
        check(near(ImageOps.color(in: editor.composite(), at: CGPoint(x: 150, y: 150)), 0, 1, 0), "color background")
        // MARK: AI features
        let kw = KeywordEdits.parse("much warmer")
        check(kw["temperature"].map { $0 > 40 } ?? false, "keywords: much warmer \(kw)")
        check(KeywordEdits.parse("less contrast")["contrast"] == -30, "keywords: less contrast beats contrast")
        check(KeywordEdits.parse("Black & white")["saturation"] == -100, "keywords: black & white")
        check(KeywordEdits.parse("slightly brighter")["exposure"] == 12.5, "keywords: slightly brighter")
        check(KeywordEdits.parse("make it moody").count >= 4, "keywords: moody preset")
        check(KeywordEdits.parse("asdf qwerty").isEmpty, "keywords: nonsense does nothing")

        editor.newDocument(size: CGSize(width: 400, height: 300), background: .white)
        editor.primaryColor = Color(red: 1, green: 0.2, blue: 0.1)
        editor.selection = CGRect(x: 50, y: 50, width: 100, height: 100); editor.fillSelection(); editor.deselect()
        editor.editWithWords("black and white"); await waitBusy()
        check(editor.adjustments.saturation == -100, "edit with words sets sliders (fallback, AI available: \(AIOps.languageModelAvailable))")
        editor.applyAdjustments()
        check(px(CGPoint(x: 100, y: 100)).map { abs($0.redComponent - $0.greenComponent) < 0.03 } ?? false, "edit with words result is gray")

        // Erase object over a gradient: the fill should match the surrounding gradient.
        editor.newDocument(size: CGSize(width: 400, height: 300), background: .white)
        editor.commitActive { ctx, _, r in
            ShapeDrawer.gradient(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 0), colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)], in: ctx)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 180, y: 130, width: 40, height: 40))
        }
        editor.selection = CGRect(x: 175, y: 125, width: 50, height: 50)
        editor.eraseObject(); await waitBusy()
        let filled = px(CGPoint(x: 200, y: 150))
        print("erase object center: \(String(describing: filled))")
        check(filled.map { abs($0.redComponent - $0.greenComponent) < 0.05 && abs($0.redComponent - 0.5) < 0.1 } ?? false, "erase object fills from surroundings")
        check(near(px(CGPoint(x: 20, y: 150)), 0.05, 0.05, 0.05) || (px(CGPoint(x: 20, y: 150)).map { $0.redComponent < 0.1 } ?? false), "erase object leaves the rest alone")
        editor.deselect()

        // Text recognition.
        editor.newDocument(size: CGSize(width: 800, height: 200), background: .white)
        editor.primaryColor = .black; editor.textSize = 90; editor.textBold = true
        editor.commitText(TextRequest(point: CGPoint(x: 30, y: 170)), string: "Hello Easel")
        let lines = (try? AIOps.recognizeText(editor.composite(background: .white))) ?? []
        check(lines.joined(separator: " ").lowercased().contains("hello easel"), "copy text recognizes \(lines)")

        // Straighten: a horizon tilted by 6 degrees.
        editor.newDocument(size: CGSize(width: 800, height: 500), background: .white)
        editor.commitActive { ctx, _, r in
            ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.65, blue: 0.95, alpha: 1)); ctx.fill(r)
            ctx.translateBy(x: 400, y: 250); ctx.rotate(by: 6 * .pi / 180)
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: -1000, y: -1000, width: 2000, height: 1000))
        }
        let tilt = (try? AIOps.horizonAngle(editor.composite())) ?? nil
        print("horizon angle: \(tilt.map { $0 * 180 / .pi } ?? .nan)°")
        if let tilt {
            check(abs(abs(tilt * 180 / .pi) - 6) < 1.5, "straighten detects tilt")
            editor.straighten(); await waitBusy()
            let after = (try? AIOps.horizonAngle(editor.composite())) ?? nil
            print("after straighten: \(after.map { $0 * 180 / .pi } ?? .nan)°")
            // Measure where ground meets sky on the left and right; level means the same height.
            let flat = editor.composite()
            func horizonY(_ x: CGFloat) -> CGFloat? {
                (0..<500).first { y in
                    ImageOps.color(in: flat, at: CGPoint(x: x, y: CGFloat(y))).map { $0.blueComponent > 0.7 } ?? false
                }.map { CGFloat($0) }
            }
            let left = horizonY(150), right = horizonY(650)
            print("horizon after straighten: left \(left ?? -1) right \(right ?? -1)")
            check(left != nil && right != nil && abs(left! - right!) <= 6, "straighten levels the horizon (measured)")
            check(ImageOps.opaqueBounds(editor.composite()) == editor.canvasRect, "straighten leaves no empty corners")
        } else {
            check(false, "straighten detects tilt (no horizon found)")
        }

        // Smart crop around a single bright object.
        editor.newDocument(size: CGSize(width: 800, height: 500), background: .white)
        editor.primaryColor = Color(red: 0.9, green: 0.1, blue: 0.2)
        editor.commitActive { ctx, img, r in ctx.draw(img, in: r); ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 560, y: 120, width: 140, height: 140)) }
        editor.cropAspect = .square
        editor.smartCrop(); await waitBusy()
        print("smart crop: \(String(describing: editor.cropRect))")
        check(editor.tool == .crop && (editor.cropRect.map { $0.contains(CGPoint(x: 630, y: 190)) && abs($0.width - $0.height) <= 1 && $0.width < 700 } ?? false), "smart crop frames the subject at 1:1")
        editor.cropRect = nil; editor.cropAspect = .free; editor.tool = .brush

        // Faces: these test images have none, so the tools should say so rather than fail.
        editor.toast = nil
        editor.smoothSkin(); await waitBusy()
        check(editor.toast == "No faces found", "smooth skin with no faces (\(editor.toast ?? "nil"))")
        editor.toast = nil
        editor.hideFaces(); await waitBusy()
        check(editor.toast == "No faces found", "hide faces with no faces")
        editor.toast = nil
        editor.fixRedEye(); await waitBusy()
        check(editor.toast == nil || editor.toast == "No red eyes found", "red eye runs (\(editor.toast ?? "ok"))")

        // Select subject on the icon.
        editor.open(image: Bitmap.load(url: out.appendingPathComponent("test.png"))!, name: "t")
        editor.toast = nil
        editor.selectSubject(); await waitBusy()
        print("subject selection: \(String(describing: editor.selection))")
        check(editor.selection.map { $0.width > 600 && $0.width < 1000 && $0.contains(CGPoint(x: 512, y: 512)) } ?? false, "select subject")
        editor.deselect()

        // Image generation without Apple Intelligence must fail politely.
        do {
            let img = try await AIOps.generateImage(prompt: "a red apple", style: "Animation")
            check(img != nil, "generate image (Apple Intelligence on)")
        } catch {
            print("generate image error: \(error.localizedDescription)")
            check(!AIOps.languageModelAvailable, "generate image reports an error when Apple Intelligence is off")
        }

        // Looks grid must not overflow with landscape thumbnails.
        let wide = NSImage(cgImage: Bitmap.filled(CGSize(width: 180, height: 60), color: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)), size: CGSize(width: 180, height: 60))
        let thumbs = Dictionary(uniqueKeysWithValues: Effect.all.map { ($0.id, wide) })
        let renderer = ImageRenderer(content: LooksGrid(effects: Array(Effect.all.prefix(9)), thumbnails: thumbs) { _ in }
            .frame(width: 252).padding(10).background(Color.white))
        renderer.scale = 2
        if let ns = renderer.nsImage, let cg = Bitmap.cgImage(from: ns), let png = Bitmap.png(cg) {
            try? png.write(to: out.appendingPathComponent("looks-grid.png"))
            check(cg.width <= 2 * 272 + 2, "looks grid stays inside the panel (\(cg.width)px)")
        }

        // Snapshot panels in an off-screen window (real AppKit controls, nothing shown on screen).
        func snapshot<V: View>(_ view: V, size: CGSize, name: String) async {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            let win = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            }
            win.orderOut(nil)
        }
        await snapshot(AIPanel(editor: editor).background(.bar), size: CGSize(width: 280, height: 640), name: "ai-panel.png")
        editor.effectThumbnails = thumbs
        await snapshot(EffectsPanel(editor: editor).background(.bar), size: CGSize(width: 280, height: 420), name: "effects-panel.png")
        await snapshot(ExportSheet(editor: editor).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 440, height: 640), name: "export-sheet.png")

        // Drive the real canvas with synthetic mouse events.
        func findCanvas(_ v: NSView) -> CanvasNSView? {
            if let c = v as? CanvasNSView { return c }
            for sub in v.subviews { if let c = findCanvas(sub) { return c } }
            return nil
        }
        if let window = NSApp.windows.first(where: { $0.contentView.flatMap(findCanvas) != nil }),
           let canvas = window.contentView.flatMap(findCanvas) {
            editor.newDocument(size: CGSize(width: 400, height: 300), background: .white)
            editor.actualSize()
            canvas.layoutSubtreeIfNeeded()
            func viewPoint(_ c: CGPoint) -> CGPoint {
                let z = editor.viewport.zoom, b = canvas.bounds
                let o = CGPoint(x: (b.width - 400 * z) / 2 + editor.viewport.offset.x, y: (b.height - 300 * z) / 2 + editor.viewport.offset.y)
                return canvas.convert(CGPoint(x: o.x + c.x * z, y: o.y + c.y * z), to: nil)
            }
            func ev(_ type: NSEvent.EventType, _ c: CGPoint, mods: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: viewPoint(c), modifierFlags: mods, timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func drag(_ a: CGPoint, _ b: CGPoint) {
                canvas.mouseDown(with: ev(.leftMouseDown, a))
                for i in 1...20 {
                    let f = CGFloat(i) / 20
                    canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)))
                }
                canvas.mouseUp(with: ev(.leftMouseUp, b))
            }
            editor.tool = .brush
            editor.brushSize = 20; editor.brushOpacity = 1; editor.brushHardness = 1
            editor.primaryColor = Color(red: 1, green: 0, blue: 0)
            drag(CGPoint(x: 50, y: 250), CGPoint(x: 350, y: 250))
            check(near(px(CGPoint(x: 200, y: 250)), 1, 0, 0) && near(px(CGPoint(x: 200, y: 270)), 1, 1, 1), "hard brush via mouse")

            editor.brushHardness = 0; editor.brushSize = 40
            editor.primaryColor = Color(red: 0, green: 0, blue: 1)
            drag(CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150))
            let center = px(CGPoint(x: 200, y: 150)), edge = px(CGPoint(x: 200, y: 165))
            print("soft center \(String(describing: center)) edge \(String(describing: edge))")
            check(center.map { $0.blueComponent > 0.9 && $0.redComponent < 0.3 } ?? false, "soft brush center solid")
            check(edge.map { $0.redComponent > 0.3 && $0.redComponent < 0.95 } ?? false, "soft brush edge feathered")
            check(near(px(CGPoint(x: 200, y: 200)), 1, 1, 1), "soft brush stays local")

            editor.brushOpacity = 0.5; editor.brushHardness = 1; editor.brushSize = 30
            editor.primaryColor = .black
            drag(CGPoint(x: 50, y: 60), CGPoint(x: 350, y: 60))
            drag(CGPoint(x: 200, y: 20), CGPoint(x: 200, y: 100))
            let single = px(CGPoint(x: 100, y: 60)), crossing = px(CGPoint(x: 200, y: 60))
            check(single.map { abs($0.redComponent - 0.5) < 0.06 } ?? false, "50% stroke doesn't build up within itself")
            check(crossing.map { abs($0.redComponent - 0.25) < 0.06 } ?? false, "separate strokes stack")

            editor.tool = .eraser; editor.eraserSize = 30; editor.brushOpacity = 1; editor.brushHardness = 1
            drag(CGPoint(x: 100, y: 250), CGPoint(x: 120, y: 250))
            check(ImageOps.color(in: editor.composite(), at: CGPoint(x: 110, y: 250)).map { _ in true } ?? false, "eraser ran")
            let erasedAlpha: Int = {
                let c = Bitmap.context(CGSize(width: 1, height: 1)); c.draw(editor.composite(), in: CGRect(x: -110, y: -250, width: 400, height: 300))
                return Int(c.data!.load(fromByteOffset: 3, as: UInt8.self)) }()
            check(erasedAlpha == 0, "eraser makes pixels transparent")

            editor.tool = .move
            editor.addEmptyLayer(); editor.selection = CGRect(x: 0, y: 0, width: 10, height: 10); editor.fillSelection(); editor.deselect()
            drag(CGPoint(x: 5, y: 5), CGPoint(x: 105, y: 5))
            check(editor.activeLayer.map { ImageOps.color(in: $0.image, at: CGPoint(x: 105, y: 5)) != nil } ?? false, "move tool via mouse")
            let movedAlpha: Int = {
                let c = Bitmap.context(CGSize(width: 1, height: 1)); c.draw(editor.activeLayer!.image, in: CGRect(x: -5, y: -5, width: 400, height: 300))
                return Int(c.data!.load(fromByteOffset: 3, as: UInt8.self)) }()
            check(movedAlpha == 0, "moved content left its old spot")

            // Resize handles
            func bounds() -> CGRect? { editor.activeLayer.flatMap { editor.contentBounds($0) } }
            editor.addEmptyLayer()
            editor.selection = CGRect(x: 100, y: 100, width: 50, height: 50); editor.fillSelection(); editor.deselect()
            editor.tool = .move
            check(bounds() == CGRect(x: 100, y: 100, width: 50, height: 50), "content bounds")
            drag(CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 170))
            print("corner drag -> \(String(describing: bounds()))")
            check(bounds().map { abs($0.width - 100) <= 3 && abs($0.height - 100) <= 3 && abs($0.minX - 100) <= 3 && abs($0.minY - 100) <= 3 } ?? false, "corner handle resizes proportionally")
            drag(CGPoint(x: 200, y: 150), CGPoint(x: 250, y: 150))
            print("edge drag -> \(String(describing: bounds()))")
            check(bounds().map { abs($0.width - 150) <= 3 && abs($0.height - 100) <= 3 } ?? false, "edge handle stretches one side")
            editor.undo()
            check(bounds().map { abs($0.width - 100) <= 3 } ?? false, "undo resize")
            editor.resizeActiveLayer(to: CGSize(width: 60, height: 30))
            check(bounds().map { abs($0.width - 60) <= 3 && abs($0.height - 30) <= 3 && abs($0.midX - 150) <= 3 } ?? false, "resize layer to exact size")
            editor.fitActiveLayerToCanvas()
            print("fit -> \(String(describing: bounds()))")
            check(bounds().map { abs($0.width - 400) <= 3 && abs($0.midX - 200) <= 3 && abs($0.midY - 150) <= 3 } ?? false, "fit layer to canvas")

            editor.primaryColor = .black
            editor.textSize = 40
            editor.commitText(TextRequest(point: CGPoint(x: 50, y: 250)), string: "Hi")
            if let tb = bounds() {
                drag(CGPoint(x: tb.maxX, y: tb.minY), CGPoint(x: tb.minX + tb.width * 2, y: tb.minY))
                check(editor.activeLayer?.text.map { abs($0.size - 80) < 2 } ?? false, "scaling text keeps it editable at a bigger font (\(editor.activeLayer?.text?.size ?? -1))")
            } else { check(false, "text bounds") }

            // Rotation
            func near3(_ r: CGRect?, _ w: CGFloat, _ h: CGFloat, _ c: CGPoint) -> Bool {
                guard let r else { return false }
                return abs(r.width - w) <= 4 && abs(r.height - h) <= 4 && abs(r.midX - c.x) <= 3 && abs(r.midY - c.y) <= 3
            }
            func bar() {
                editor.newDocument(size: CGSize(width: 400, height: 300), background: .transparent)
                editor.actualSize()
                editor.selection = CGRect(x: 150, y: 140, width: 100, height: 20); editor.fillSelection(); editor.deselect()
                editor.tool = .move
            }
            func dragWith(_ mods: NSEvent.ModifierFlags, _ a: CGPoint, _ b: CGPoint) {
                canvas.mouseDown(with: ev(.leftMouseDown, a, mods: mods))
                for i in 1...12 {
                    let f = CGFloat(i) / 12
                    canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), mods: mods))
                }
                canvas.mouseUp(with: ev(.leftMouseUp, b, mods: mods))
            }
            bar()
            editor.rotateActiveLayer(by: -.pi / 2)
            print("rotate 90 -> \(String(describing: bounds()))")
            check(near3(bounds(), 20, 100, CGPoint(x: 200, y: 150)), "rotate layer 90° around its center")
            editor.undo()
            check(near3(bounds(), 100, 20, CGPoint(x: 200, y: 150)), "undo rotation")

            // Round handle sits 26pt above the top edge at zoom 100%.
            dragWith([], CGPoint(x: 200, y: 186), CGPoint(x: 260, y: 150))
            print("handle drag -> \(String(describing: bounds()))")
            check(near3(bounds(), 20, 100, CGPoint(x: 200, y: 150)), "drag rotate handle")

            bar()
            // Aim at ~44° from the start direction; ⇧ should snap to 45°.
            let target = CGPoint(x: 200 + 60 * cos(.pi / 2 - 0.77), y: 150 + 60 * sin(.pi / 2 - 0.77))
            dragWith(.shift, CGPoint(x: 200, y: 186), target)
            let diag = (100 + 20) / CGFloat(2).squareRoot()
            print("shift snap -> \(String(describing: bounds()))  expected ≈\(diag)")
            check(near3(bounds(), diag, diag, CGPoint(x: 200, y: 150)), "⇧ snaps rotation to 45°")

            bar()
            // Just outside the top-right corner (250,160) also rotates.
            dragWith([], CGPoint(x: 262, y: 172), CGPoint(x: 200 + 30, y: 150 - 90))
            print("corner-zone drag -> \(String(describing: bounds()))")
            check(bounds().map { $0.height > 40 } ?? false, "dragging just outside a corner rotates")

            // Snapshots of the handles and of a rotation in progress.
            func shoot(_ name: String) {
                canvas.display()
                if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                    canvas.cacheDisplay(in: canvas.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
                }
            }
            bar()
            shoot("rotate-idle.png")
            canvas.mouseDown(with: ev(.leftMouseDown, CGPoint(x: 200, y: 186)))
            canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: 240, y: 180)))
            canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: 250, y: 175)))
            shoot("rotate-drag.png")
            canvas.mouseUp(with: ev(.leftMouseUp, CGPoint(x: 250, y: 175)))

            // Rotated text stays editable and survives save/reopen.
            editor.newDocument(size: CGSize(width: 400, height: 300), background: .white)
            editor.primaryColor = .black; editor.textSize = 40
            editor.commitText(TextRequest(point: CGPoint(x: 120, y: 180)), string: "Spin")
            let textID = editor.activeLayerID!
            editor.rotateActiveLayer(by: .pi / 2)
            let rotated = editor.activeLayer?.text
            check(rotated.map { abs(($0.rotation ?? 0) - .pi / 2) < 0.01 } ?? false, "rotating text keeps it editable (\(rotated?.rotation ?? -1))")
            if let rotated {
                let c = CGPoint(x: rotated.bounds.midX, y: rotated.bounds.midY)
                editor.textClick(at: c)
                check(editor.pendingText?.layerID == textID, "click rotated text to edit it")
                editor.commitText(editor.pendingText!, string: "Spun")
                editor.pendingText = nil
                let after = editor.activeLayer?.text
                check(after?.string == "Spun" && abs((after?.rotation ?? 0) - .pi / 2) < 0.01 &&
                      abs((after?.bounds.midX ?? 0) - c.x) < 1 && abs((after?.bounds.midY ?? 0) - c.y) < 1,
                      "re-editing rotated text keeps its angle and center")
                if let b = bounds() { check(b.height > b.width, "rotated text renders sideways (\(b))") }
                let proj = out.appendingPathComponent("rotate.easel")
                try? ProjectFile(canvasSize: editor.canvasSize, layers: editor.layers, activeIndex: 1).write(to: proj)
                editor.isDirty = false
                editor.openFile(proj)
                check(editor.layers.last?.text.map { abs(($0.rotation ?? 0) - .pi / 2) < 0.01 } ?? false, "project keeps text rotation")
            }
            // A project saved before rotation existed must still open.
            let legacy = #"{"string":"Old","x":1,"y":2,"font":"Helvetica","size":12,"bold":false,"red":0,"green":0,"blue":0}"#
            check((try? JSONDecoder().decode(TextInfo.self, from: Data(legacy.utf8)))?.rotation == nil, "older text without rotation still loads")
        } else {
            check(false, "canvas view found")
        }

        // Reel round trip: a file from Reel's round-trip folder saves straight back on ⌘S.
        let rt = AppLink.newRoundTripURL(named: "from-reel.png")
        try? Bitmap.png(Bitmap.filled(CGSize(width: 64, height: 64), color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))?.write(to: rt)
        editor.isDirty = false
        editor.openFile(rt)
        check(editor.linkedURL == rt, "file from Reel opens linked")
        editor.primaryColor = Color(red: 1, green: 0, blue: 0)
        editor.fillSelection()
        check(editor.save(), "⌘S saves back to Reel")
        let back = Bitmap.load(url: rt)
        check(back.flatMap { ImageOps.color(in: $0, at: CGPoint(x: 32, y: 32)) }.map { $0.redComponent > 0.9 && $0.blueComponent < 0.1 } ?? false,
              "edit is written to Reel's file")
        try? FileManager.default.removeItem(at: rt.deletingLastPathComponent())
        editor.newDocument(size: CGSize(width: 10, height: 10), background: .white)
        check(editor.linkedURL == nil, "new document is no longer linked")

        editor.toast = nil
        print("DONE")
        editor.isDirty = false
        NSApp.terminate(nil)
    }
}
#endif
