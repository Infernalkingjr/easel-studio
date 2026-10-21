import AppKit
import CoreImage
import Observation
import PDFKit
import UniformTypeIdentifiers
import EaselKit

enum DisplayMode: String, CaseIterable, Identifiable {
    case single = "Single Page", continuous = "Continuous", twoUp = "Two Pages", twoUpContinuous = "Two Pages Continuous"
    var id: String { rawValue }

    var pdf: PDFDisplayMode {
        switch self {
        case .single: return .singlePage
        case .continuous: return .singlePageContinuous
        case .twoUp: return .twoUp
        case .twoUpContinuous: return .twoUpContinuous
        }
    }

    var symbol: String {
        switch self {
        case .single: return "doc"
        case .continuous: return "rectangle.split.1x2"
        case .twoUp: return "book"
        case .twoUpContinuous: return "rectangle.split.2x2"
        }
    }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case paper = "Paper", sepia = "Sepia", night = "Night"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .paper: return "sun.max"
        case .sepia: return "cup.and.saucer"
        case .night: return "moon"
        }
    }
}

/// What a drag across text (or a click, for notes) does.
enum Markup: String, CaseIterable, Identifiable {
    case select = "Select", highlight = "Highlight", underline = "Underline", strike = "Strikethrough", note = "Note"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "character.cursor.ibeam"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .note: return "note.text"
        }
    }

    var annotationType: PDFAnnotationSubtype? {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strike: return .strikeOut
        case .select, .note: return nil
        }
    }

    var hint: String {
        switch self {
        case .select: return "Select and copy text"
        case .highlight: return "Drag across text to highlight it"
        case .underline: return "Drag across text to underline it"
        case .strike: return "Drag across text to strike it out"
        case .note: return "Click on a page to add a note"
        }
    }
}

enum MarkupColor: String, CaseIterable, Identifiable {
    case yellow = "Yellow", green = "Green", blue = "Blue", pink = "Pink", purple = "Purple"
    var id: String { rawValue }

    var ns: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1, green: 0.86, blue: 0.2, alpha: 1)
        case .green: return NSColor(srgbRed: 0.45, green: 0.88, blue: 0.4, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.4, green: 0.7, blue: 1, alpha: 1)
        case .pink: return NSColor(srgbRed: 1, green: 0.5, blue: 0.7, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.7, green: 0.55, blue: 1, alpha: 1)
        }
    }

    /// For lines (underline, strikethrough), which need more contrast than a highlight.
    var strong: NSColor { ns.blended(withFraction: 0.35, of: .black) ?? ns }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case pages = "Pages", contents = "Contents", bookmarks = "Bookmarks", notes = "Annotations", search = "Search"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pages: return "square.grid.2x2"
        case .contents: return "list.bullet.indent"
        case .bookmarks: return "bookmark"
        case .notes: return "highlighter"
        case .search: return "magnifyingglass"
        }
    }
}

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let page: Int?
    let children: [OutlineItem]?
}

struct SearchHit: Identifiable {
    let id: Int
    let page: Int
    let snippet: AttributedString
    let selection: PDFSelection
}

struct NoteItem: Identifiable {
    let id: ObjectIdentifier
    let page: Int
    let kind: String
    let text: String
    let color: NSColor
    let annotation: PDFAnnotation
}

@Observable @MainActor
final class FolioReader {
    private(set) var document: PDFDocument?
    /// nil until saved, for documents made from pictures or sent by another app.
    private(set) var url: URL?
    private(set) var documentName = "Folio"
    private(set) var isDirty = false
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var zoom: CGFloat = 1
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var outline: [OutlineItem] = []
    private(set) var bookmarks: [Int] = []
    private(set) var searchHits: [SearchHit] = []
    private(set) var searchIndex: Int?
    private(set) var recents: [URL] = []
    /// Bumped whenever annotations or pages change, so lists that read the document refresh.
    private(set) var revision = 0

    var displayMode: DisplayMode = .continuous {
        didSet { applyDisplay(); UserDefaults.standard.set(displayMode.rawValue, forKey: "FolioDisplayMode") }
    }
    /// Two-page modes show the first page on its own, like a book cover.
    var coverPage = true { didSet { applyDisplay() } }
    var theme: ReadingTheme = .paper {
        didSet { applyTheme(); UserDefaults.standard.set(theme.rawValue, forKey: "FolioTheme") }
    }
    var markup: Markup = .select {
        didSet { if markup != oldValue, markup != .select { pdfView.clearSelection() } }
    }
    var markupColor: MarkupColor = .yellow
    var sidebar: SidebarMode = .pages
    var searchText = ""
    var toast: String?
    var showInfo = false
    var needsPassword = false
    /// Bumped to ask the views to focus the search field or the page number field.
    var findRequest = 0
    var pageFieldRequest = 0

    @ObservationIgnored let pdfView = ReaderPDFView()
    @ObservationIgnored let thumbnails = PDFThumbnailView()
    /// A locked file waiting for its password.
    @ObservationIgnored private var locked: (doc: PDFDocument, url: URL)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        pdfView.reader = self
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = CGSize(width: 120, height: 156)
        thumbnails.backgroundColor = .clear
        thumbnails.allowsDragging = false
        thumbnails.allowsMultipleSelection = false
        if let raw = UserDefaults.standard.string(forKey: "FolioDisplayMode"), let m = DisplayMode(rawValue: raw) { displayMode = m }
        if let raw = UserDefaults.standard.string(forKey: "FolioTheme"), let t = ReadingTheme(rawValue: raw) { theme = t }
        recents = Self.storedRecents()
        applyDisplay()
        applyTheme()

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewChangedHistory, .PDFViewDocumentChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncView() }
            })
        }
    }

    private func syncView() {
        guard let document else { pageIndex = 0; pageCount = 0; return }
        pageCount = document.pageCount
        if let page = pdfView.currentPage { pageIndex = document.index(for: page) }
        zoom = pdfView.scaleFactor
        canGoBack = pdfView.canGoBack
        canGoForward = pdfView.canGoForward
    }

    // MARK: Opening

    static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || pictureTypes.contains(ext)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose a PDF, or several pictures to combine into one document."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    /// Opens a PDF, or combines pictures (and PDFs) into a new document. Files another app sent can join the open document.
    func open(_ urls: [URL]) {
        let urls = urls.filter(Self.canOpen)
        guard !urls.isEmpty else { return flash("Folio opens PDFs and pictures") }
        if document != nil, urls.allSatisfy({ AppLink.isInInbox($0, of: .folio) }) {
            let from = urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" } ? "Quill" : "Easel"
            let alert = NSAlert()
            alert.messageText = "Add to “\(documentName)”?"
            alert.informativeText = "\(from) sent \(urls.count == 1 ? "a file" : "\(urls.count) files"). Add \(urls.count == 1 ? "it" : "them") as pages after page \(pageIndex + 1), or open on \(urls.count == 1 ? "its" : "their") own."
            alert.addButton(withTitle: "Add Pages")
            alert.addButton(withTitle: "Open Separately")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: insertPages(from: urls, at: pageIndex + 1); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        guard confirmDiscard() else { return }
        if urls.count == 1, urls[0].pathExtension.lowercased() == "pdf" {
            let url = urls[0]
            guard let doc = PDFDocument(url: url) else { return flash("Couldn’t open “\(url.lastPathComponent)”") }
            if doc.isLocked {
                locked = (doc, url)
                needsPassword = true
                return
            }
            // Files sent by another app live in a shared inbox, so they're saved somewhere new.
            show(doc, url: AppLink.isInInbox(url, of: .folio) ? nil : url, name: Self.displayName(url))
            return
        }
        guard let doc = Self.combine(urls) else { return flash("Couldn’t read those files") }
        show(doc, url: nil, name: Self.displayName(urls[0]))
        isDirty = true
    }

    /// The file name without the timestamp other apps add to files they send.
    static func displayName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard AppLink.isInInbox(url, of: .folio), let dash = name.lastIndex(of: "-"),
              name[name.index(after: dash)...].allSatisfy(\.isNumber) else { return name }
        return String(name[..<dash])
    }

    var lockedFileName: String { locked?.url.lastPathComponent ?? "" }

    /// Returns false when the password is wrong.
    func unlock(_ password: String) -> Bool {
        guard let (doc, url) = locked else { return true }
        guard doc.unlock(withPassword: password) else { return false }
        locked = nil
        needsPassword = false
        show(doc, url: url, name: Self.displayName(url))
        return true
    }

    func cancelUnlock() {
        locked = nil
        needsPassword = false
    }

    /// A new document from PDFs and pictures, in order.
    static func combine(_ urls: [URL]) -> PDFDocument? {
        let out = PDFDocument()
        for url in urls {
            for page in pages(from: url) { out.insert(page, at: out.pageCount) }
        }
        return out.pageCount > 0 ? out : nil
    }

    static func pages(from url: URL) -> [PDFPage] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), !doc.isLocked else { return [] }
            return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.copy() as? PDFPage }
        }
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { return [] }
        return [page]
    }

    private func show(_ doc: PDFDocument, url: URL?, name: String) {
        rememberPosition()
        document = doc
        self.url = url
        documentName = name
        isDirty = false
        markup = .select
        pdfView.document = doc
        pdfView.autoScales = true
        applyDisplay()
        outline = Self.outline(doc)
        sidebar = outline.isEmpty ? (sidebar == .contents ? .pages : sidebar) : .contents
        bookmarks = url.map(Self.storedBookmarks) ?? []
        clearSearch()
        pdfView.undoManager?.removeAllActions()
        revision &+= 1
        syncView()
        if let url {
            addRecent(url)
            if let last = Self.lastPages[url.path], last > 0, last < doc.pageCount {
                // Let the view lay out first, or it ignores the jump.
                DispatchQueue.main.async { [weak self] in self?.goTo(page: last) }
            }
        }
    }

    func closeDocument() {
        guard document != nil, confirmDiscard() else { return }
        rememberPosition()
        pdfView.undoManager?.removeAllActions()
        pdfView.document = nil
        document = nil
        url = nil
        documentName = "Folio"
        isDirty = false
        outline = []
        bookmarks = []
        clearSearch()
        syncView()
    }

    static func outline(_ doc: PDFDocument) -> [OutlineItem] {
        func items(_ node: PDFOutline) -> [OutlineItem] {
            (0..<node.numberOfChildren).compactMap { i in
                guard let child = node.child(at: i) else { return nil }
                let kids = items(child)
                let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                return OutlineItem(title: child.label ?? "Untitled", page: dest?.page.map { doc.index(for: $0) },
                                   children: kids.isEmpty ? nil : kids)
            }
        }
        return doc.outlineRoot.map(items) ?? []
    }

    // MARK: Saving

    func save(as saveAs: Bool = false) {
        guard document != nil else { return }
        var target = url
        if target == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = documentName + ".pdf"
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            target = picked
        }
        if let target { saveDocument(to: target) }
    }

    func saveDocument(to target: URL) {
        guard let document else { return }
        // Write the whole file at once: PDFKit reads pages lazily from the original, so it can't be overwritten in place.
        guard let data = document.dataRepresentation() else { return flash("Couldn’t save this document") }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return flash("Couldn’t save: \(error.localizedDescription)")
        }
        url = target
        documentName = target.deletingPathExtension().lastPathComponent
        isDirty = false
        addRecent(target)
        flash("Saved")
    }

    func confirmDiscard() -> Bool {
        guard isDirty, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentName)”?"
        alert.informativeText = "Your highlights, notes and page changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !isDirty
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: Remembering

    private static var lastPages: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "FolioLastPage") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "FolioLastPage") }
    }

    /// Saves where you were, so the document reopens on the same page.
    func rememberPosition() {
        guard let url, document != nil else { return }
        Self.lastPages[url.path] = pageIndex
    }

    private static func storedRecents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "FolioRecents") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecent(_ url: URL) {
        recents = [url] + recents.filter { $0.standardizedFileURL != url.standardizedFileURL }
        recents = Array(recents.prefix(12))
        UserDefaults.standard.set(recents.map(\.path), forKey: "FolioRecents")
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: "FolioRecents")
    }

    // MARK: Navigation

    func goTo(page index: Int) {
        guard let document, let page = document.page(at: max(0, min(index, document.pageCount - 1))) else { return }
        pdfView.go(to: page)
        syncView()
    }

    func nextPage() { pdfView.canGoToNextPage ? pdfView.goToNextPage(nil) : NSSound.beep() }
    func previousPage() { pdfView.canGoToPreviousPage ? pdfView.goToPreviousPage(nil) : NSSound.beep() }
    func firstPage() { goTo(page: 0) }
    func lastPage() { goTo(page: pageCount - 1) }
    func goBack() { if pdfView.canGoBack { pdfView.goBack(nil) } }
    func goForward() { if pdfView.canGoForward { pdfView.goForward(nil) } }

    // MARK: View

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }

    func setZoom(_ scale: CGFloat) {
        pdfView.autoScales = false
        pdfView.scaleFactor = scale
    }

    /// Fits the page width (continuous) or the whole page (single page modes).
    func zoomToFit() { pdfView.autoScales = true }

    func zoomToFitPage() {
        pdfView.autoScales = false
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
    }

    private func applyDisplay() {
        pdfView.displayMode = displayMode.pdf
        pdfView.displaysAsBook = coverPage && (displayMode == .twoUp || displayMode == .twoUpContinuous)
        pdfView.layoutDocumentView()
    }

    private func applyTheme() {
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        switch theme {
        case .paper:
            pdfView.contentFilters = []
            pdfView.backgroundColor = .underPageBackgroundColor
        case .sepia:
            let sepia = CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.32])
            pdfView.contentFilters = sepia.map { [$0] } ?? []
            pdfView.backgroundColor = NSColor(srgbRed: 0.55, green: 0.5, blue: 0.44, alpha: 1)
        case .night:
            // Invert, then turn hues back around so pictures keep roughly their colors.
            let invert = CIFilter(name: "CIColorInvert")
            let hue = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            pdfView.contentFilters = [invert, hue].compactMap { $0 }
            pdfView.backgroundColor = NSColor(white: 0.88, alpha: 1)
        }
    }

    // MARK: Search

    func search() {
        guard let document else { return }
        pdfView.highlightedSelections = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clearSearch() }
        let found = Array(document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]).prefix(2000))
        searchHits = found.enumerated().compactMap { i, sel in
            guard let page = sel.pages.first else { return nil }
            return SearchHit(id: i, page: document.index(for: page), snippet: Self.snippet(sel, query: query), selection: sel)
        }
        for sel in found { sel.color = NSColor.systemYellow.withAlphaComponent(0.55) }
        pdfView.highlightedSelections = found
        sidebar = .search
        if searchHits.isEmpty { searchIndex = nil } else { showHit(0) }
    }

    func clearSearch() {
        searchHits = []
        searchIndex = nil
        pdfView.highlightedSelections = nil
    }

    func showHit(_ i: Int) {
        guard searchHits.indices.contains(i) else { return }
        searchIndex = i
        let sel = searchHits[i].selection
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
        syncView()
    }

    /// Steps through search results (wrapping around).
    func nextHit(_ step: Int = 1) {
        guard !searchHits.isEmpty else { return search() }
        let n = searchHits.count
        showHit((((searchIndex ?? -step) + step) % n + n) % n)
    }

    static func snippet(_ sel: PDFSelection, query: String) -> AttributedString {
        let line = sel.copy() as? PDFSelection ?? sel
        line.extendForLineBoundaries()
        var text = (line.string ?? query).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = text.index(r.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
            text = (start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
        }
        var out = AttributedString(text)
        if let r = out.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }

    // MARK: Bookmarks

    private static func storedBookmarks(_ url: URL) -> [Int] {
        (UserDefaults.standard.dictionary(forKey: "FolioBookmarks") as? [String: [Int]])?[url.path] ?? []
    }

    var isBookmarked: Bool { bookmarks.contains(pageIndex) }

    func toggleBookmark(_ page: Int? = nil) {
        let page = page ?? pageIndex
        if bookmarks.contains(page) { bookmarks.removeAll { $0 == page } } else { bookmarks = (bookmarks + [page]).sorted() }
        guard let url else { return }
        var all = UserDefaults.standard.dictionary(forKey: "FolioBookmarks") as? [String: [Int]] ?? [:]
        all[url.path] = bookmarks.isEmpty ? nil : bookmarks
        UserDefaults.standard.set(all, forKey: "FolioBookmarks")
    }

    func pageLabel(_ index: Int) -> String {
        guard let label = document?.page(at: index)?.label, label != "\(index + 1)" else { return "Page \(index + 1)" }
        return "Page \(index + 1) (\(label))"
    }

    // MARK: Annotations

    static let markupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Text", "FreeText", "Ink", "Square", "Circle", "Line"]

    static func isMarkup(_ a: PDFAnnotation) -> Bool { markupTypes.contains(a.type ?? "") }

    static func kindName(_ a: PDFAnnotation) -> String {
        switch a.type ?? "" {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strikethrough"
        case "Text", "FreeText": return "Note"
        case "Ink": return "Drawing"
        default: return "Annotation"
        }
    }

    /// Every highlight and note, in page order.
    var notes: [NoteItem] {
        _ = revision
        guard let document else { return [] }
        return (0..<document.pageCount).flatMap { i -> [NoteItem] in
            guard let page = document.page(at: i) else { return [] }
            return page.annotations.filter(Self.isMarkup).map { a in
                let isNote = a.type == "Text" || a.type == "FreeText"
                let text = isNote ? (a.contents ?? "") : (page.selection(for: a.bounds.insetBy(dx: 0.5, dy: 0.5))?.string ?? "")
                return NoteItem(id: ObjectIdentifier(a), page: i, kind: Self.kindName(a),
                                text: text.trimmingCharacters(in: .whitespacesAndNewlines), color: a.color, annotation: a)
            }
        }
    }

    /// Called on mouse-up: marks up whatever text was just selected.
    func applyMarkupToSelection() {
        guard let type = markup.annotationType, let sel = pdfView.currentSelection,
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var made: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5, b.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = markup == .highlight ? markupColor.ns.withAlphaComponent(0.5) : markupColor.strong
                a.userName = NSFullUserName()
                a.modificationDate = Date()
                made.append((page, a))
            }
        }
        guard !made.isEmpty else { return }
        pdfView.clearSelection()
        perform("Add \(markup.rawValue)") {
            for m in made { m.page.addAnnotation(m.annotation) }
        } undo: {
            for m in made { m.page.removeAnnotation(m.annotation) }
        }
    }

    func addNote(on page: PDFPage, at point: CGPoint) {
        guard let text = askForNote(""), !text.isEmpty else { return }
        let a = PDFAnnotation(bounds: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22), forType: .text, withProperties: nil)
        a.contents = text
        a.color = markupColor.ns
        a.iconType = .comment
        a.userName = NSFullUserName()
        a.modificationDate = Date()
        perform("Add Note") { page.addAnnotation(a) } undo: { page.removeAnnotation(a) }
    }

    func editNote(_ a: PDFAnnotation) {
        let old = a.contents ?? ""
        guard let new = askForNote(old), new != old else { return }
        perform("Edit Note") { a.contents = new } undo: { a.contents = old }
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        perform("Remove \(Self.kindName(a))") { page.removeAnnotation(a) } undo: { page.addAnnotation(a) }
    }

    func removeAllAnnotations() {
        let all = notes.compactMap { n in n.annotation.page.map { (page: $0, annotation: n.annotation) } }
        guard !all.isEmpty else { return }
        perform("Remove All Annotations") {
            for m in all { m.page.removeAnnotation(m.annotation) }
        } undo: {
            for m in all { m.page.addAnnotation(m.annotation) }
        }
    }

    func reveal(_ note: NoteItem) {
        guard let page = note.annotation.page else { return }
        pdfView.go(to: note.annotation.bounds, on: page)
        syncView()
    }

    /// The test hook replaces the prompt.
    @ObservationIgnored var noteProvider: ((String) -> String?)?

    private func askForNote(_ current: String) -> String? {
        if let noteProvider { return noteProvider(current) }
        let alert = NSAlert()
        alert.messageText = current.isEmpty ? "Add Note" : "Edit Note"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
        field.stringValue = current
        field.placeholderString = "Your note"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.addButton(withTitle: current.isEmpty ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Pages

    func rotate(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        let old = page.rotation
        perform("Rotate Page") { page.rotation = (old + degrees + 360) % 360 } undo: { page.rotation = old }
    }

    func deleteCurrentPage() {
        guard let document, let page = pdfView.currentPage else { return }
        deletePage(at: document.index(for: page))
    }

    func deletePage(at i: Int) {
        guard let document, document.pageCount > 1, let page = document.page(at: i) else {
            return flash("A document needs at least one page")
        }
        perform("Delete Page") {
            document.removePage(at: i)
        } undo: {
            document.insert(page, at: i)
        }
        bookmarks = bookmarks.compactMap { $0 == i ? nil : ($0 > i ? $0 - 1 : $0) }
    }

    func insertPagesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert"
        panel.message = "Pages are added after page \(pageIndex + 1)."
        guard panel.runModal() == .OK else { return }
        insertPages(from: panel.urls, at: pageIndex + 1)
    }

    func insertPages(from urls: [URL], at index: Int) {
        guard let document else { return }
        let pages = urls.flatMap(Self.pages(from:))
        guard !pages.isEmpty else { return flash("Couldn’t read those files") }
        let at = min(index, document.pageCount)
        perform("Insert Pages") {
            for (k, p) in pages.enumerated() { document.insert(p, at: at + k) }
        } undo: {
            for p in pages { document.removePage(at: document.index(for: p)) }
        }
        goTo(page: at)
        flash("Added \(pages.count) page\(pages.count == 1 ? "" : "s")")
    }

    /// Runs a change and registers its undo (which registers the redo).
    private func perform(_ name: String, _ change: @escaping () -> Void, undo revert: @escaping () -> Void) {
        change()
        changed()
        guard let um = pdfView.undoManager else { return }
        um.registerUndo(withTarget: self) { reader in
            MainActor.assumeIsolated { reader.perform(name, revert, undo: change) }
        }
        um.setActionName(name)
    }

    private func changed() {
        isDirty = true
        revision &+= 1
        pdfView.layoutDocumentView()
        pdfView.needsDisplay = true
        syncView()
    }

    // MARK: Output

    /// A page as a picture, at `scale` × its point size, with its annotations and rotation.
    static func image(of page: PDFPage, scale: CGFloat) -> CGImage {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = CGSize(width: (turned ? box.height : box.width) * scale, height: (turned ? box.width : box.height) * scale)
        return Bitmap.render(size) { ctx in
            ctx.setFillColor(.white)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            page.transform(ctx, for: .cropBox)
            page.draw(with: .cropBox, to: ctx)
        }
    }

    private var pageName: String { "\(documentName)-p\(pageIndex + 1)" }

    func exportPageImage() {
        guard let page = pdfView.currentPage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = pageName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Bitmap.png(Self.image(of: page, scale: 3))?.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            flash("Couldn’t export: \(error.localizedDescription)")
        }
    }

    /// Saves just the current page as its own PDF.
    func extractPage() {
        guard let page = pdfView.currentPage?.copy() as? PDFPage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pageName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let single = PDFDocument()
        single.insert(page, at: 0)
        guard single.write(to: url) else { return flash("Couldn’t save that page") }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPageImage() {
        guard let page = pdfView.currentPage else { return }
        let img = Self.image(of: page, scale: 2)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: img, size: NSSize(width: img.width / 2, height: img.height / 2))])
        flash("Copied page \(pageIndex + 1)")
    }

    /// Sends the current page as a picture to Easel or Reel.
    func sendPage(to app: AppLink.App) {
        guard let page = pdfView.currentPage else { return }
        let url = AppLink.newInboxURL(for: app, named: pageName, ext: "png")
        do {
            guard let png = Bitmap.png(Self.image(of: page, scale: 2)) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: url)
        } catch {
            return flash("Couldn’t send: \(error.localizedDescription)")
        }
        if AppLink.open(url, in: app) { flash("Sent page \(pageIndex + 1) to \(app.rawValue)") } else { flash("Couldn’t find \(app.rawValue). Build it with Scripts/build_app.sh") }
    }

    func printDocument() {
        guard let document else { return }
        guard let op = document.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.jobTitle = documentName
        if let w = NSApp.keyWindow { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    func showInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Title, author, dates, sizes: for the info sheet.
    var info: [(label: String, value: String)] {
        guard let document else { return [] }
        let attrs = document.documentAttributes ?? [:]
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        var rows: [(String, String)] = []
        func add(_ label: String, _ key: PDFDocumentAttribute) {
            if let v = attrs[key] as? String, !v.isEmpty { rows.append((label, v)) }
            else if let d = attrs[key] as? Date { rows.append((label, date.string(from: d))) }
            else if let a = attrs[key] as? [String], !a.isEmpty { rows.append((label, a.joined(separator: ", "))) }
        }
        add("Title", .titleAttribute)
        add("Author", .authorAttribute)
        add("Subject", .subjectAttribute)
        add("Keywords", .keywordsAttribute)
        add("Created", .creationDateAttribute)
        add("Modified", .modificationDateAttribute)
        add("Made with", .creatorAttribute)
        add("PDF producer", .producerAttribute)
        rows.append(("Pages", "\(document.pageCount)"))
        if let page = document.page(at: pageIndex) {
            let b = page.bounds(for: .mediaBox)
            rows.append(("Page size", String(format: "%.1f × %.1f in  (%.0f × %.0f mm)", b.width / 72, b.height / 72, b.width / 72 * 25.4, b.height / 72 * 25.4)))
        }
        rows.append(("PDF version", "\(document.majorVersion).\(document.minorVersion)"))
        rows.append(("Encrypted", document.isEncrypted ? "Yes" : "No"))
        if let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
            rows.append(("Location", url.deletingLastPathComponent().path))
        }
        return rows
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
