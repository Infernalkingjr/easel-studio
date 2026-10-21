import SwiftUI
import PDFKit
import EaselKit

struct ContentView: View {
    @Bindable var reader: FolioReader
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if reader.document == nil {
                WelcomeView(reader: reader)
                    .dropDestination(for: URL.self) { urls, _ in
                        reader.open(urls)
                        return true
                    }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar(reader: reader)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 380)
                } detail: {
                    PDFViewHost(view: reader.pdfView)
                        .overlay(alignment: .top) { MarkupBanner(reader: reader) }
                        .ignoresSafeArea(.container, edges: .bottom)
                }
                .toolbar { ReaderToolbar(reader: reader) }
            }
        }
        .overlay(alignment: .bottom) { Toast(text: reader.toast) }
        .animation(.easeOut(duration: 0.2), value: reader.toast)
        .navigationTitle(reader.documentName)
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $reader.needsPassword, onDismiss: { reader.cancelUnlock() }) { PasswordSheet(reader: reader) }
        .sheet(isPresented: $reader.showInfo) { InfoSheet(reader: reader) }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var subtitle: String {
        guard reader.document != nil else { return "" }
        return "Page \(reader.pageIndex + 1) of \(reader.pageCount)\(reader.isDirty ? " — Edited" : "")"
    }
}

/// Hosts the reader's long-lived PDF view (it's shared with the thumbnails, so SwiftUI doesn't own it).
struct PDFViewHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct Toast: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// While a markup tool is on, a small banner says what dragging does and how to stop.
struct MarkupBanner: View {
    @Bindable var reader: FolioReader

    var body: some View {
        if reader.markup != .select {
            HStack(spacing: 8) {
                Image(systemName: reader.markup.symbol)
                Text(reader.markup.hint)
                Button("Done") { reader.markup = .select }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        }
    }
}

// MARK: - Toolbar

struct ReaderToolbar: ToolbarContent {
    @Bindable var reader: FolioReader

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { reader.goBack() } label: { Image(systemName: "chevron.backward") }
                    .help("Back")
                    .disabled(!reader.canGoBack)
                Button { reader.goForward() } label: { Image(systemName: "chevron.forward") }
                    .help("Forward")
                    .disabled(!reader.canGoForward)
            }
        }
        ToolbarItem(placement: .principal) { PageField(reader: reader) }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { reader.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                Menu("\(Int((reader.zoom * 100).rounded()))%") {
                    Button("Fit Width") { reader.zoomToFit() }
                    Button("Fit Page") { reader.zoomToFitPage() }
                    Divider()
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { z in
                        Button("\(Int(z * 100))%") { reader.setZoom(z) }
                    }
                }
                .frame(width: 70)
                Button { reader.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
            }
            Menu {
                Picker("Layout", selection: $reader.displayMode) {
                    ForEach(DisplayMode.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Show Cover Page Alone", isOn: $reader.coverPage)
                Divider()
                Picker("Reading Theme", selection: $reader.theme) {
                    ForEach(ReadingTheme.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: reader.displayMode.symbol)
            }
            .help("Layout and reading theme")

            Picker("Markup", selection: $reader.markup) {
                ForEach(Markup.allCases) { m in
                    Image(systemName: m.symbol).help(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .help("Markup tools")
            ColorDots(reader: reader)

            Button { reader.toggleBookmark() } label: {
                Image(systemName: reader.isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .help(reader.isBookmarked ? "Remove Bookmark (⌘D)" : "Bookmark This Page (⌘D)")

            Menu {
                Button("Send Page to Easel") { reader.sendPage(to: .easel) }
                Button("Send Page to Reel") { reader.sendPage(to: .reel) }
                Divider()
                Button("Copy Page as Picture") { reader.copyPageImage() }
                Button("Export Page as PNG…") { reader.exportPageImage() }
                Button("Extract Page as PDF…") { reader.extractPage() }
                Divider()
                Button("Print…") { reader.printDocument() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share and send")
        }
    }
}

struct PageField: View {
    @Bindable var reader: FolioReader
    @State private var text = "1"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Page", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 48)
                .focused($focused)
                .onSubmit {
                    if let n = Int(text.trimmingCharacters(in: .whitespaces)) { reader.goTo(page: n - 1) }
                    text = "\(reader.pageIndex + 1)"
                    focused = false
                }
            Text("of \(reader.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onAppear { text = "\(reader.pageIndex + 1)" }
        .onChange(of: reader.pageIndex) { if !focused { text = "\(reader.pageIndex + 1)" } }
        .onChange(of: reader.pageFieldRequest) { focused = true }
        .help("Go to page (⌥⌘G)")
    }
}

/// The markup color, as a dot that opens a row of choices.
struct ColorDots: View {
    @Bindable var reader: FolioReader
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Circle().fill(Color(nsColor: reader.markupColor.ns)).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.black.opacity(0.2)))
        }
        .help("Markup color: \(reader.markupColor.rawValue)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                ForEach(MarkupColor.allCases) { c in
                    Button {
                        reader.markupColor = c
                        open = false
                    } label: {
                        Circle().fill(Color(nsColor: c.ns)).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: reader.markupColor == c ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(c.rawValue)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Bindable var reader: FolioReader

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(LinearGradient(colors: [Color(red: 0.95, green: 0.2, blue: 0.45), Color(red: 0.6, green: 0.15, blue: 0.75),
                                                        Color(red: 0.2, green: 0.25, blue: 0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                Text("Folio").font(.system(size: 34, weight: .bold))
                Text("Read, search and mark up PDFs.").foregroundStyle(.secondary)
                Button {
                    reader.openPanel()
                } label: {
                    Label("Open a PDF…", systemImage: "folder").frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
                .padding(.top, 6)
                Text("Or drop a PDF or pictures here.").font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            if !reader.recents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Recent").font(.headline)
                        Spacer()
                        Button("Clear") { reader.clearRecents() }.buttonStyle(.borderless).font(.callout)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                    List(reader.recents, id: \.self) { url in
                        Button { reader.open([url]) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .frame(width: 300)
                .background(.background.secondary)
            }
        }
    }
}

// MARK: - Sheets

struct PasswordSheet: View {
    @Bindable var reader: FolioReader
    @State private var password = ""
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("“\(reader.lockedFileName)” is locked", systemImage: "lock.fill").font(.headline)
            Text("Enter its password to open it.").foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlock)
            if wrong { Text("That password didn’t work.").font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { reader.cancelUnlock() }.keyboardShortcut(.cancelAction)
                Button("Open", action: unlock).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func unlock() {
        wrong = !reader.unlock(password)
        if wrong { password = "" }
    }
}

struct InfoSheet: View {
    @Bindable var reader: FolioReader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(reader.documentName).font(.title3.weight(.semibold)).lineLimit(2)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(reader.info, id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.value).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
            HStack {
                if reader.url != nil { Button("Show in Finder") { reader.showInFinder() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
