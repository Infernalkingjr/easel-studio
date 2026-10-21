import EaselKit
import SwiftUI

@main
struct EaselApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Easel", id: "main") {
            ContentView(editor: appDelegate.editor)
        }
        .defaultSize(width: 1400, height: 900)
        .commands { EaselCommands(editor: appDelegate.editor) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = Editor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        Task { await SelfTest.runIfRequested(self.editor) }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, editor.confirmDiscard() else { return }
        editor.openFile(url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Standard edit commands go to a focused text field first, then to the editor.
@MainActor
private func textAction(_ selector: Selector) -> Bool {
    guard let responder = NSApp.keyWindow?.firstResponder as? NSText else { return false }
    return NSApp.sendAction(selector, to: responder, from: nil)
}

struct EaselCommands: Commands {
    let editor: Editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Canvas…") { if editor.confirmDiscard() { editor.showNewSheet = true } }
                .keyboardShortcut("n")
            Button("Open…") { editor.openPanel() }
                .keyboardShortcut("o")
            Button("Add Image as Layer…") { editor.placePanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!editor.hasDocument)
            Button("Generate Image…") { editor.showGenerateSheet = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button("New from Clipboard") { if editor.confirmDiscard() { editor.hasDocument = false; editor.paste() } }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Close Image") { editor.closeDocument() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!editor.hasDocument)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { editor.save() }
                .keyboardShortcut("s")
                .disabled(!editor.hasDocument)
            Button("Save As…") { editor.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!editor.hasDocument)
            Button("Send to Reel") { editor.send(to: .reel) }
                .disabled(!editor.hasDocument)
            Button("Send to Flip") { editor.send(to: .flip) }
                .disabled(!editor.hasDocument)
            Button("Send to Quill") { editor.send(to: .quill) }
                .disabled(!editor.hasDocument)
            Button("Send to Folio") { editor.send(to: .folio) }
                .disabled(!editor.hasDocument)
            Button("Export as PNG, JPEG…") { editor.showExportSheet = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!editor.hasDocument)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if !textAction(Selector(("undo:"))) { editor.undo() } }
                .keyboardShortcut("z")
            Button("Redo") { if !textAction(Selector(("redo:"))) { editor.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { if !textAction(#selector(NSText.cut(_:))) { editor.cut() } }
                .keyboardShortcut("x")
            Button("Copy") { if !textAction(#selector(NSText.copy(_:))) { editor.copy() } }
                .keyboardShortcut("c")
            Button("Copy Merged") { editor.copy(merged: true) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste") { if !textAction(#selector(NSText.paste(_:))) { editor.paste() } }
                .keyboardShortcut("v")
            Divider()
            Button("Select All") { if !textAction(#selector(NSText.selectAll(_:))) { editor.selectAll() } }
                .keyboardShortcut("a")
            Button("Deselect") { editor.deselect() }
                .keyboardShortcut("d")
            Divider()
            Button("Fill with Primary Color") { if !textAction(#selector(NSResponder.deleteWordBackward(_:))) { editor.fillSelection() } }
                .keyboardShortcut(.delete, modifiers: .option)
            Button("Fill with Secondary Color") { if !textAction(#selector(NSResponder.deleteToBeginningOfLine(_:))) { editor.fillSelection(secondary: true) } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Clear") { editor.clearSelection() }
        }
        CommandMenu("Image") {
            Button("Resize Image…") { editor.showResizeSheet = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Canvas Size…") { editor.showCanvasSheet = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            Button("Rotate Right") { editor.rotate(clockwise: true) }
                .keyboardShortcut("r")
            Button("Rotate Left") { editor.rotate(clockwise: false) }
                .keyboardShortcut("l")
            Button("Flip Horizontal") { editor.flip(horizontal: true) }
            Button("Flip Vertical") { editor.flip(horizontal: false) }
            Divider()
            Button("Crop to Selection") { editor.cropToSelection() }
                .disabled(editor.selection == nil)
            Button("Trim Transparent Edges") { editor.trim() }
            Divider()
            Button("Auto Fix") { if let e = Effect.all.first(where: { $0.id == "auto" }) { editor.applyEffect(e) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Menu("AI") {
                Button("Remove Background") { editor.removeBackground() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Lift Subject to New Layer") { editor.liftSubject() }
                Button("Select Subject") { editor.selectSubject() }
                Button("Blur Background") { editor.blurBackground() }
                Button("Replace Background with Secondary Color") { editor.colorBackground() }
                Divider()
                Button("Straighten") { editor.straighten() }
                Button("Smart Crop") { editor.smartCrop() }
                Button("Smooth Skin") { editor.smoothSkin() }
                Button("Fix Red Eye") { editor.fixRedEye() }
                Divider()
                Button("Erase Selected Object") { editor.eraseObject() }
                    .disabled(editor.selection == nil)
                Button("Hide Faces") { editor.hideFaces() }
                Button("Copy Text from Image") { editor.copyText() }
            }
            Button("Invert Colors") { if let e = Effect.all.first(where: { $0.id == "invert" }) { editor.applyEffect(e) } }
                .keyboardShortcut("i")
        }
        CommandMenu("Layer") {
            Button("New Layer") { editor.addEmptyLayer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Duplicate Layer") { editor.duplicateLayer() }
                .keyboardShortcut("j")
            Button("Delete Layer") { editor.deleteLayer() }
            Button("Rename Layer…") { editor.renamingLayerID = editor.activeLayerID }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!editor.hasDocument)
            Divider()
            Button("Resize Layer…") { editor.tool = .move; editor.showLayerResizeSheet = true }
                .keyboardShortcut("t")
                .disabled(!editor.hasDocument)
            Button("Fit Layer to Canvas") { editor.fitActiveLayerToCanvas() }
                .disabled(!editor.hasDocument)
            Button("Rotate Layer 90° Left") { editor.rotateActiveLayer(by: .pi / 2) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!editor.hasDocument)
            Button("Rotate Layer 90° Right") { editor.rotateActiveLayer(by: -.pi / 2) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!editor.hasDocument)
            Divider()
            Button("Bring Forward") { editor.moveLayer(1) }
                .keyboardShortcut("]")
            Button("Send Backward") { editor.moveLayer(-1) }
                .keyboardShortcut("[")
            Divider()
            Button("Flip Layer Horizontal") { editor.flip(horizontal: true, layerOnly: true) }
            Button("Flip Layer Vertical") { editor.flip(horizontal: false, layerOnly: true) }
            Divider()
            Button("Merge Down") { editor.mergeDown() }
                .keyboardShortcut("e")
            Button("Flatten Image") { editor.flatten() }
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { editor.zoom(in: true) }
                .keyboardShortcut("=")
            Button("Zoom Out") { editor.zoom(in: false) }
                .keyboardShortcut("-")
            Button("Fit on Screen") { editor.zoomToFit() }
                .keyboardShortcut("0")
            Button("Actual Size") { editor.actualSize() }
                .keyboardShortcut("1")
            Divider()
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                Button(tool.title) { editor.tool = tool }
            }
        }
    }
}
