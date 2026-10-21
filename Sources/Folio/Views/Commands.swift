import SwiftUI

struct FolioCommands: Commands {
    let reader: FolioReader

    private var noDocument: Bool { reader.document == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { reader.openPanel() }.keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(reader.recents, id: \.self) { url in
                    Button(url.lastPathComponent) { reader.open([url]) }
                }
                Divider()
                Button("Clear Menu") { reader.clearRecents() }.disabled(reader.recents.isEmpty)
            }
            Divider()
            Button("Close Document") { reader.closeDocument() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(noDocument)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { reader.save() }.keyboardShortcut("s").disabled(noDocument)
            Button("Save As…") { reader.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(noDocument)
            Button("Show in Finder") { reader.showInFinder() }.disabled(reader.url == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Insert Pages from File…") { reader.insertPagesPanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Export Page as PNG…") { reader.exportPageImage() }
            Button("Extract Page as PDF…") { reader.extractPage() }
            Menu("Send Page To") {
                Button("Easel") { reader.sendPage(to: .easel) }
                Button("Reel") { reader.sendPage(to: .reel) }
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { reader.printDocument() }.keyboardShortcut("p").disabled(noDocument)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") {
                reader.sidebar = .search
                reader.findRequest += 1
            }
            .keyboardShortcut("f")
            .disabled(noDocument)
            Button("Find Next") { reader.nextHit() }.keyboardShortcut("g").disabled(noDocument)
            Button("Find Previous") { reader.nextHit(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(noDocument)
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { reader.zoomIn() }.keyboardShortcut("=").disabled(noDocument)
            Button("Zoom Out") { reader.zoomOut() }.keyboardShortcut("-").disabled(noDocument)
            Button("Actual Size") { reader.setZoom(1) }.keyboardShortcut("0").disabled(noDocument)
            Button("Fit Width") { reader.zoomToFit() }.keyboardShortcut("9").disabled(noDocument)
            Button("Fit Page") { reader.zoomToFitPage() }.keyboardShortcut("9", modifiers: [.command, .option]).disabled(noDocument)
            Divider()
            ForEach(Array(DisplayMode.allCases.enumerated()), id: \.element) { i, m in
                Button { reader.displayMode = m } label: {
                    if reader.displayMode == m { Label(m.rawValue, systemImage: "checkmark") } else { Text(m.rawValue) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Toggle("Show Cover Page Alone", isOn: Binding(get: { reader.coverPage }, set: { reader.coverPage = $0 }))
            Divider()
            Picker("Reading Theme", selection: Binding(get: { reader.theme }, set: { reader.theme = $0 })) {
                ForEach(ReadingTheme.allCases) { Text($0.rawValue).tag($0) }
            }
            Button("Document Info") { reader.showInfo = true }.keyboardShortcut("i").disabled(noDocument)
            Divider()
        }
        CommandMenu("Go") {
            Group {
                Button("Previous Page") { reader.previousPage() }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Page") { reader.nextPage() }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("First Page") { reader.firstPage() }
                Button("Last Page") { reader.lastPage() }
                Button("Go to Page…") { reader.pageFieldRequest += 1 }.keyboardShortcut("g", modifiers: [.command, .option])
                Divider()
                Button("Back") { reader.goBack() }.keyboardShortcut("[").disabled(!reader.canGoBack)
                Button("Forward") { reader.goForward() }.keyboardShortcut("]").disabled(!reader.canGoForward)
                Divider()
                Button(reader.isBookmarked ? "Remove Bookmark" : "Bookmark This Page") { reader.toggleBookmark() }
                    .keyboardShortcut("d")
            }
            .disabled(noDocument)
        }
        CommandMenu("Markup") {
            Group {
                ForEach(Array(Markup.allCases.enumerated()), id: \.element) { i, m in
                    Button { reader.markup = m } label: {
                        if reader.markup == m { Label(m.rawValue, systemImage: "checkmark") } else { Text(m.rawValue) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
                Divider()
                Picker("Color", selection: Binding(get: { reader.markupColor }, set: { reader.markupColor = $0 })) {
                    ForEach(MarkupColor.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Remove All Annotations") { reader.removeAllAnnotations() }
            }
            .disabled(noDocument)
        }
        CommandMenu("Pages") {
            Group {
                Button("Rotate Left") { reader.rotate(by: -90) }.keyboardShortcut("l")
                Button("Rotate Right") { reader.rotate(by: 90) }.keyboardShortcut("r")
                Divider()
                Button("Insert Pages from File…") { reader.insertPagesPanel() }
                Button("Delete Page") { reader.deleteCurrentPage() }.keyboardShortcut(.delete, modifiers: [.command, .option])
                Divider()
                Button("Copy Page as Picture") { reader.copyPageImage() }.keyboardShortcut("c", modifiers: [.command, .option])
            }
            .disabled(noDocument)
        }
    }
}
