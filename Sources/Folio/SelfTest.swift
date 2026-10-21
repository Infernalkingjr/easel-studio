#if DEBUG
import AppKit
import CoreText
import PDFKit
import EaselKit

/// Debug-only test: `FOLIO_SELFTEST=/out/dir .build/debug/Folio`
@MainActor
enum FolioSelfTest {
    static func runIfRequested(_ reader: FolioReader) async {
        guard let dir = ProcessInfo.processInfo.environment["FOLIO_SELFTEST"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: dir).appendingPathComponent("folio", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        reader.noteProvider = { _ in "Remember this" }
        UserDefaults.standard.removeObject(forKey: "FolioBookmarks")
        UserDefaults.standard.removeObject(forKey: "FolioLastPage")

        // A three-page PDF with real text, an outline-free layout and a word only on page 2.
        let source = out.appendingPathComponent("sample.pdf")
        makeSamplePDF(source, pages: [
            "Chapter One\nThe quick brown fox jumps over the lazy dog.",
            "Chapter Two\nA zebra wanders past the quick brown fox. Zebra stripes are unique.",
            "Chapter Three\nThe end of the quick brown fox story.",
        ])
        reader.open([source])
        await settle()
        check(reader.document?.pageCount == 3 && reader.pageCount == 3, "opens a PDF")
        check(reader.documentName == "sample" && !reader.isDirty, "name and clean state")

        reader.goTo(page: 2)
        await settle()
        check(reader.pageIndex == 2, "goes to a page")

        reader.searchText = "zebra"
        reader.search()
        check(reader.searchHits.count == 2 && reader.searchHits.allSatisfy { $0.page == 1 }, "search finds both hits on page 2")
        check(reader.pageIndex == 1, "search jumps to the first hit")
        check(String(reader.searchHits[0].snippet.characters).lowercased().contains("zebra"), "search snippet shows the match")
        reader.nextHit()
        check(reader.searchIndex == 1, "next hit")
        reader.nextHit()
        check(reader.searchIndex == 0, "next hit wraps around")

        // Highlight the selected hit, as a drag with the highlighter would.
        reader.markup = .highlight
        reader.pdfView.setCurrentSelection(reader.searchHits[0].selection, animate: false)
        reader.applyMarkupToSelection()
        check(reader.notes.count == 1 && reader.notes[0].kind == "Highlight", "highlight adds an annotation")
        check(reader.notes.first?.text.lowercased().contains("zebra") == true, "highlight knows its text")
        check(reader.isDirty, "marking up makes the document edited")

        await settle() // separate undo steps, like separate clicks
        reader.markup = .note
        if let page = reader.document?.page(at: 0) { reader.addNote(on: page, at: CGPoint(x: 100, y: 700)) }
        check(reader.notes.count == 2 && reader.notes.contains { $0.kind == "Note" && $0.text == "Remember this" }, "adds a note")
        reader.markup = .select

        if let um = reader.pdfView.undoManager {
            um.undo()
            check(reader.notes.count == 1, "undo removes the note")
            if reader.notes.count != 1 { print("  after undo:", reader.notes.map(\.kind), um.undoActionName, um.groupingLevel) }
            um.redo()
            check(reader.notes.count == 2, "redo puts it back")
        } else {
            check(false, "undo manager available")
        }

        reader.toggleBookmark(1)
        check(reader.bookmarks == [1], "bookmarks a page")

        reader.goTo(page: 0)
        reader.rotate(by: 90)
        check(reader.document?.page(at: 0)?.rotation == 90, "rotates a page")
        if let page = reader.document?.page(at: 0) {
            let img = FolioReader.image(of: page, scale: 1)
            check(img.width == 792 && img.height == 612, "rotated page renders sideways")
        }
        reader.rotate(by: -90)

        // Pictures become pages.
        let picture = out.appendingPathComponent("picture.png")
        try? Bitmap.png(Bitmap.filled(CGSize(width: 400, height: 300), color: CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)))?.write(to: picture)
        reader.insertPages(from: [picture], at: 3)
        check(reader.document?.pageCount == 4, "inserts a picture as a page")
        let inserted = reader.document?.page(at: 3)
        reader.deletePage(at: 3)
        check(reader.document?.pageCount == 3 && inserted.map { reader.document?.index(for: $0) } == NSNotFound, "deletes a page")

        let saved = out.appendingPathComponent("saved.pdf")
        reader.saveForTest(to: saved)
        check(!reader.isDirty, "saves")
        let reopened = PDFDocument(url: saved)
        let kept = (0..<(reopened?.pageCount ?? 0)).flatMap { reopened?.page(at: $0)?.annotations ?? [] }.filter(FolioReader.isMarkup)
        check(reopened?.pageCount == 3 && kept.count == 2, "saved file keeps pages and annotations")
        if kept.count != 2 { print("  pages", reopened?.pageCount ?? -1, "annotations", (0..<(reopened?.pageCount ?? 0)).map { reopened?.page(at: $0)?.annotations.map { $0.type ?? "?" } ?? [] }) }

        // Opening a set of pictures makes a new, unsaved document.
        reader.closeDocument()
        check(reader.document == nil, "closes")
        reader.open([picture, picture])
        check(reader.document?.pageCount == 2 && reader.url == nil, "combines pictures into a new document")
        reader.saveForTest(to: out.appendingPathComponent("pictures.pdf"))

        let inbox = AppLink.newInboxURL(for: .folio, named: "Poster", ext: "pdf")
        check(FolioReader.displayName(inbox) == "Poster", "drops the timestamp from files other apps send")

        // UI snapshots, drawn from the window itself.
        reader.open([saved])
        await settle()
        for theme in [ReadingTheme.paper, .night] {
            reader.theme = theme
            reader.sidebar = theme == .paper ? .pages : .notes
            await settle()
            if let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 })?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("ui-\(theme.rawValue).png"))
            }
        }
        reader.theme = .paper
        UserDefaults.standard.removeObject(forKey: "FolioBookmarks")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("DONE")
        NSApp.terminate(nil)
    }

    static func makeSamplePDF(_ url: URL, pages: [String]) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 18) ?? .systemFont(ofSize: 18)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

extension FolioReader {
    /// Saves without the save panel.
    func saveForTest(to url: URL) {
        saveDocument(to: url)
    }
}
#endif
