#if DEBUG
import AppKit
import EaselKit

/// Debug-only test: `QUILL_SELFTEST=/out/dir .build/debug/Quill`
@MainActor
enum QuillSelfTest {
    static func runIfRequested(_ studio: QuillStudio) async {
        guard let dir = ProcessInfo.processInfo.environment["QUILL_SELFTEST"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: dir).appendingPathComponent("quill", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }
        func render() -> CGImage { QuillRenderer.image(studio.doc, images: studio.images) }
        /// Color at an artboard point (y down).
        func px(_ img: CGImage, _ x: CGFloat, _ y: CGFloat) -> (Double, Double, Double, Double) {
            let ctx = Bitmap.context(CGSize(width: 1, height: 1))
            ctx.draw(img, in: CGRect(x: -x, y: -(CGFloat(img.height) - y), width: CGFloat(img.width), height: CGFloat(img.height)))
            guard let d = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return (0, 0, 0, 0) }
            let a = Double(d[3]) / 255
            return a == 0 ? (0, 0, 0, 0) : (Double(d[0]) / 255 / a, Double(d[1]) / 255 / a, Double(d[2]) / 255 / a, a)
        }
        func near(_ c: (Double, Double, Double, Double), _ r: Double, _ g: Double, _ b: Double) -> Bool {
            abs(c.0 - r) < 0.08 && abs(c.1 - g) < 0.08 && abs(c.2 - b) < 0.08
        }
        func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.6) -> Bool {
            abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
        }
        let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)
        func shape(_ c: Contour, fill: RGBA?, stroke: RGBA? = nil) -> UUID {
            studio.fill = fill
            studio.stroke = stroke
            studio.addPath([c], name: "Shape")
            return studio.selection.first!
        }

        studio.newDocument(width: 400, height: 300, transparent: false)

        // MARK: Geometry
        let ellipse = Geo.ellipseContour(CGRect(x: 0, y: 0, width: 100, height: 60))
        check(ellipse.closed && ellipse.nodes.count == 4 && !ellipse.nodes[0].isCorner, "ellipse is 4 smooth points")
        let rt = Geo.contours(Geo.path([ellipse]))
        check(rt.count == 1 && rt[0].nodes.count == 4 && close(Geo.path(rt).boundingBoxOfPath, Geo.path([ellipse]).boundingBoxOfPath),
              "path ↔ contours round trip")
        let circlePts = (0..<200).map { k -> CGPoint in let a = CGFloat(k) / 200 * 2 * .pi; return CGPoint(x: 50 + 40 * cos(a), y: 50 + 40 * sin(a)) }
        let smooth = Geo.smoothContour(circlePts, tolerance: 1, closed: true)
        let sb = Geo.path([smooth]).boundingBoxOfPath
        print(String(format: "  pencil: 200 points → %d nodes, %.1f×%.1f", smooth.nodes.count, sb.width, sb.height))
        check(smooth.nodes.count < 40 && abs(sb.width - 80) < 3 && abs(sb.height - 80) < 3, "pencil smoothing simplifies and keeps the shape")
        let star = Geo.polygonContour(center: .zero, radius: 50, sides: 5, inner: 0.5)
        check(star.nodes.count == 10, "star has inner and outer points")

        // MARK: Drawing & rendering
        let a = shape(Geo.rectContour(CGRect(x: 40, y: 40, width: 100, height: 100)), fill: red)
        check(near(px(render(), 90, 90), 1, 0, 0) && near(px(render(), 200, 200), 1, 1, 1), "filled rectangle renders")
        let b = shape(Geo.rectContour(CGRect(x: 100, y: 100, width: 100, height: 100)), fill: blue)
        check(near(px(render(), 120, 120), 0, 0, 1), "later shapes draw on top")
        let line = shape(Contour(nodes: [Node(CGPoint(x: 250, y: 50)), Node(CGPoint(x: 350, y: 50))], closed: false), fill: nil, stroke: .black)
        studio.updateItem(line) { $0.strokeWidth = 8 }
        check(near(px(render(), 300, 50), 0, 0, 0) && near(px(render(), 300, 60), 1, 1, 1), "stroked line renders at its weight")

        // MARK: Transform
        studio.select([a])
        studio.setFrame(w: 200)
        check(close(studio.item(a)!.geometryBounds, CGRect(x: 40, y: 40, width: 200, height: 100)), "set width scales from the left edge")
        studio.updateItem(line) { $0.strokeWidth = 8 }
        studio.select([line])
        studio.setFrame(w: 50)
        check(studio.item(line)!.strokeWidth == 8, "scaling keeps stroke weight")
        studio.select([a])
        studio.rotateSelection(by: 90)
        let rb = studio.item(a)!.geometryBounds
        check(abs(rb.width - 100) < 0.5 && abs(rb.height - 200) < 0.5, "rotate 90° swaps width and height")
        studio.undo(); studio.undo(); studio.undo()
        check(close(studio.item(a)!.geometryBounds, CGRect(x: 40, y: 40, width: 100, height: 100)), "undo transforms")
        studio.redo()
        studio.undo()

        // MARK: Group & align
        studio.select([a, b])
        studio.group()
        studio.select([a])
        check(studio.selection == [a, b], "clicking one grouped object selects the group")
        studio.align(.left)
        check(abs(studio.item(a)!.geometryBounds.minX) < 0.5 && abs(studio.item(b)!.geometryBounds.minX - 60) < 0.5, "a lone group aligns to the artboard as one")
        studio.undo()
        studio.ungroup()
        studio.select([a, b])
        studio.align(.top)
        check(abs(studio.item(b)!.geometryBounds.minY - 40) < 0.5, "align tops of two objects")
        studio.undo()
        let c = shape(Geo.rectContour(CGRect(x: 300, y: 200, width: 20, height: 20)), fill: red)
        studio.select([a, b, c])
        studio.selection = [a, b, c]
        studio.distribute(horizontal: true)
        let mids = [a, b, c].map { studio.item($0)!.geometryBounds.midX }.sorted()
        check(abs((mids[1] - mids[0]) - (mids[2] - mids[1])) < 0.5, "distribute spaces centers evenly")
        studio.undo()
        studio.select([c]); studio.deleteSelection()

        // MARK: Pathfinder
        studio.select([a, b])
        studio.pathfinder(.unite)
        let united = studio.selectedItems
        check(united.count == 1 && close(united[0].geometryBounds, CGRect(x: 40, y: 40, width: 160, height: 160)) && united[0].fill == blue,
              "unite merges into one shape with the top style")
        check(near(px(render(), 60, 60), 0, 0, 1) && near(px(render(), 180, 180), 0, 0, 1) && near(px(render(), 60, 180), 1, 1, 1),
              "united shape fills both areas, not the gap")
        studio.undo()
        studio.select([a, b])
        studio.pathfinder(.minusFront)
        check(near(px(render(), 60, 60), 1, 0, 0) && near(px(render(), 120, 120), 1, 1, 1), "minus front cuts the overlap out")
        studio.undo()
        studio.select([a, b])
        studio.pathfinder(.intersect)
        check(close(studio.selectedItems[0].geometryBounds, CGRect(x: 100, y: 100, width: 40, height: 40)), "intersect keeps the overlap")
        studio.undo()
        studio.select([a, b])
        studio.pathfinder(.exclude)
        check(near(px(render(), 120, 120), 1, 1, 1) && !near(px(render(), 60, 60), 1, 1, 1), "exclude removes the overlap only")
        studio.undo()

        // MARK: Points
        studio.tool = .direct
        studio.select([a])
        studio.nodeSelection = [NodeRef(item: a, contour: 0, node: 2)]
        studio.nudge(20, 20)
        check(close(studio.item(a)!.geometryBounds, CGRect(x: 40, y: 40, width: 120, height: 120)), "moving one point reshapes the path")
        studio.deleteNodes()
        check(studio.item(a)?.contours?[0].nodes.count == 3, "delete a point")
        studio.undo(); studio.undo()
        studio.tool = .select

        // MARK: Text
        studio.select([])
        studio.fill = .black
        let tid = studio.addText(at: CGPoint(x: 40, y: 260))!
        studio.commitText(tid, "Quill")
        let text = studio.item(tid)!
        check(text.isText && text.geometryBounds.width > 80 && text.geometryBounds.height > 40, "type creates text")
        let tb = text.geometryBounds
        var dark = 0
        let img = render()
        for x in stride(from: tb.minX, to: tb.maxX, by: 3) {
            for y in stride(from: tb.minY, to: tb.maxY, by: 3) where near(px(img, x, y), 0, 0, 0) { dark += 1 }
        }
        check(dark > 30, "text renders")
        let undoBefore = studio.undoStack.count
        studio.select([tid])
        studio.createOutlines()
        let outlined = studio.item(tid)!
        let ob = outlined.geometryBounds
        print("  outlines: \(outlined.contours?.count ?? 0) contours, \(ob.integral) inside \(tb.integral)")
        check(!outlined.isText && (outlined.contours?.count ?? 0) >= 5 && tb.insetBy(dx: -2, dy: -2).contains(ob) && ob.width > tb.width * 0.8,
              "create outlines turns letters into shapes in place")
        check(studio.undoStack.count == undoBefore + 1, "create outlines is one undo step")
        studio.undo()

        // MARK: Gradient
        studio.select([a])
        studio.style { $0.gradient = FillGradient(from: .white, to: .black, angle: 0) }
        let gimg = render()
        check(px(gimg, 45, 70).0 > 0.85 && px(gimg, 135, 70).0 < 0.15, "linear gradient runs left to right")
        studio.undo()

        // MARK: Clipboard & duplicate
        studio.select([a])
        let count = studio.doc.allItems.count
        studio.copySelection()
        studio.paste()
        check(studio.doc.allItems.count == count + 1 && studio.selection.count == 1 && !studio.selection.contains(a), "copy and paste")
        check(NSPasteboard.general.data(forType: .pdf) != nil, "copy puts a PDF on the clipboard for other apps")
        studio.undo()
        studio.select([a])
        studio.duplicateSelection()
        check(studio.doc.allItems.count == count + 1, "duplicate")
        studio.undo()

        // MARK: Layers
        studio.addLayer()
        let l2 = studio.layerID
        studio.select([a])
        studio.moveSelection(toLayer: l2)
        check(studio.doc.layers.last!.items.contains { $0.id == a }, "move selection to another layer")
        studio.updateLayer(l2) { $0.visible = false }
        check(near(px(render(), 60, 60), 1, 1, 1), "hidden layers don’t render")
        studio.undo(); studio.undo(); studio.undo()

        // MARK: Files
        let url = out.appendingPathComponent("test.quill")
        try? JSONEncoder().encode(studio.doc).write(to: url)
        check((try? JSONDecoder().decode(ArtDocument.self, from: Data(contentsOf: url))) == studio.doc, "document round-trips through JSON")
        studio.select([a])
        studio.style { $0.gradient = FillGradient(from: red, to: blue, angle: 45) }
        studio.select([])
        let svg = String(data: studio.exportData(.svg)!, encoding: .utf8)!
        try? svg.write(to: out.appendingPathComponent("art.svg"), atomically: true, encoding: .utf8)
        let parser = XMLParser(data: svg.data(using: .utf8)!)
        check(parser.parse() && svg.contains("<path d=\"M") && svg.contains("<text") && svg.contains("linearGradient"), "SVG export is valid and vector")
        let pdf = studio.exportData(.pdf)!
        try? pdf.write(to: out.appendingPathComponent("art.pdf"))
        let pdfDoc = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)
        check(pdfDoc?.numberOfPages == 1 && pdfDoc?.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 400, height: 300), "PDF export")
        let png = studio.exportData(.png, scale: 2)!
        try? png.write(to: out.appendingPathComponent("art.png"))
        check(Bitmap.load(data: png).map { $0.width == 800 && $0.height == 600 } ?? false, "PNG export at 2×")
        check(studio.exportData(.jpeg) != nil, "JPEG export")

        // Placed images
        let swatch = out.appendingPathComponent("swatch.png")
        try? Bitmap.png(Bitmap.filled(CGSize(width: 50, height: 50), color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))?.write(to: swatch)
        studio.placeImages([swatch], at: CGPoint(x: 330, y: 230))
        check(near(px(render(), 330, 230), 0, 1, 0), "place an image")

        // MARK: UI snapshot
        studio.select([a])
        studio.fitRequest += 1
        try? await Task.sleep(for: .seconds(1.5))
        // Drawn from the window itself, so no screen-recording access is needed.
        if let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 })?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("ui.png"))
            check(true, "UI snapshot")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("DONE")
        studio.isDirty = false
        NSApp.terminate(nil)
    }
}
#endif
