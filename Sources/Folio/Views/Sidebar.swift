import SwiftUI
import PDFKit

struct Sidebar: View {
    @Bindable var reader: FolioReader

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $reader.sidebar) {
                ForEach(SidebarMode.allCases) { m in
                    Image(systemName: m.symbol).help(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            switch reader.sidebar {
            case .pages: ThumbnailHost(view: reader.thumbnails)
            case .contents: ContentsPane(reader: reader)
            case .bookmarks: BookmarksPane(reader: reader)
            case .notes: NotesPane(reader: reader)
            case .search: SearchPane(reader: reader)
            }
        }
    }
}

struct ThumbnailHost: NSViewRepresentable {
    let view: PDFThumbnailView
    func makeNSView(context: Context) -> PDFThumbnailView { view }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}

struct ContentsPane: View {
    @Bindable var reader: FolioReader

    var body: some View {
        if reader.outline.isEmpty {
            ContentUnavailableView("No Contents", systemImage: "list.bullet.indent",
                                   description: Text("This PDF doesn’t have a table of contents. Try Pages or Search."))
        } else {
            List {
                OutlineGroup(reader.outline, children: \.children) { item in
                    Button { if let p = item.page { reader.goTo(page: p) } } label: {
                        HStack {
                            Text(item.title).lineLimit(2)
                            Spacer(minLength: 6)
                            if let p = item.page { Text("\(p + 1)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct BookmarksPane: View {
    @Bindable var reader: FolioReader

    var body: some View {
        VStack(spacing: 0) {
            if reader.bookmarks.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                                       description: Text("Press ⌘D to bookmark the page you’re on."))
            } else {
                List(reader.bookmarks, id: \.self) { page in
                    Button { reader.goTo(page: page) } label: {
                        Label(reader.pageLabel(page), systemImage: page == reader.pageIndex ? "bookmark.fill" : "bookmark")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove Bookmark") { reader.toggleBookmark(page) } }
                }
                .listStyle(.sidebar)
            }
            Divider()
            Button(reader.isBookmarked ? "Remove Bookmark" : "Bookmark This Page") { reader.toggleBookmark() }
                .buttonStyle(.borderless)
                .padding(10)
        }
    }
}

struct NotesPane: View {
    @Bindable var reader: FolioReader

    var body: some View {
        let notes = reader.notes
        VStack(spacing: 0) {
            if notes.isEmpty {
                ContentUnavailableView("No Annotations", systemImage: "highlighter",
                                       description: Text("Pick Highlight, Underline or Note in the toolbar, then drag across text or click a page."))
            } else {
                List(notes) { note in
                    Button { reader.reveal(note) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: note.color.withAlphaComponent(1))).frame(width: 4)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(note.kind) · Page \(note.page + 1)").font(.caption).foregroundStyle(.secondary)
                                Text(note.text.isEmpty ? "—" : note.text).lineLimit(4)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .contextMenu {
                        if note.annotation.type == "Text" { Button("Edit Note…") { reader.editNote(note.annotation) } }
                        Button("Remove \(note.kind)") { reader.remove(note.annotation) }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Text("\(notes.count) annotation\(notes.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove All") { reader.removeAllAnnotations() }.buttonStyle(.borderless)
                }
                .padding(10)
            }
        }
    }
}

struct SearchPane: View {
    @Bindable var reader: FolioReader
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this document", text: $reader.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { reader.nextHit() }
                if !reader.searchText.isEmpty {
                    Button { reader.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            .padding(10)

            if !reader.searchHits.isEmpty {
                HStack {
                    Text("\((reader.searchIndex ?? 0) + 1) of \(reader.searchHits.count)\(reader.searchHits.count == 2000 ? "+" : "")")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    ControlGroup {
                        Button { reader.nextHit(-1) } label: { Image(systemName: "chevron.up") }.help("Previous (⇧⌘G)")
                        Button { reader.nextHit() } label: { Image(systemName: "chevron.down") }.help("Next (⌘G)")
                    }
                    .frame(width: 70)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            Divider()
            results
        }
        .task(id: reader.searchText) {
            // Search as you type, once typing pauses.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reader.search()
        }
        .onAppear { focused = true }
        .onChange(of: reader.findRequest) { focused = true }
    }

    @ViewBuilder private var results: some View {
        if reader.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text("Find words anywhere in the document."))
        } else if reader.searchHits.isEmpty {
            ContentUnavailableView.search(text: reader.searchText)
        } else {
            ScrollViewReader { proxy in
                List(reader.searchHits) { hit in
                    Button { reader.showHit(hit.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Page \(hit.page + 1)").font(.caption).foregroundStyle(.secondary)
                            Text(hit.snippet).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hit.id == reader.searchIndex ? Color.accentColor.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(hit.id)
                }
                .listStyle(.sidebar)
                .onChange(of: reader.searchIndex) { if let i = reader.searchIndex { proxy.scrollTo(i) } }
            }
        }
    }
}
