import AppKit
import PDFKit

/// PDFKit's view, plus markup on mouse-up, click-to-place notes, file drops and an annotation context menu.
final class ReaderPDFView: PDFView {
    weak var reader: FolioReader?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        if let reader, reader.markup == .note {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false) {
                reader.addNote(on: page, at: convert(point, to: page))
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        reader?.applyMarkupToSelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)),
              FolioReader.isMarkup(annotation) else { return menu }
        menu.insertItem(.separator(), at: 0)
        if annotation.type == "Text" {
            let edit = NSMenuItem(title: "Edit Note…", action: #selector(editAnnotation(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = annotation
            menu.insertItem(edit, at: 0)
        }
        let remove = NSMenuItem(title: "Remove \(FolioReader.kindName(annotation))", action: #selector(removeAnnotation(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = annotation
        menu.insertItem(remove, at: 0)
        return menu
    }

    @objc private func removeAnnotation(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? PDFAnnotation else { return }
        reader?.remove(a)
    }

    @objc private func editAnnotation(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? PDFAnnotation else { return }
        reader?.editNote(a)
    }

    // MARK: Dropping files

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FolioReader.canOpen($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        reader?.open(urls)
        return true
    }
}
