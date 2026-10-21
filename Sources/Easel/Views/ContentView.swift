import EaselKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            ToolPalette(editor: editor)
            Divider()
            VStack(spacing: 0) {
                OptionsBar(editor: editor)
                Divider()
                if editor.linkedURL != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "film")
                        Text("Editing an image from Reel. Press ⌘S to update it there.")
                        Spacer()
                        Button("Update in Reel") { editor.save() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.accentColor.opacity(0.15))
                    Divider()
                }
                ZStack {
                    CanvasView(editor: editor)
                    if !editor.hasDocument { WelcomeView(editor: editor) }
                    Overlays(editor: editor)
                }
                .onDrop(of: [.fileURL, .image], isTargeted: nil, perform: handleDrop)
                Divider()
                StatusBar(editor: editor, viewport: editor.viewport)
            }
            Divider()
            Inspector(editor: editor)
                .frame(width: 280)
        }
        .frame(minWidth: 960, minHeight: 620)
        .toolbar { MainToolbar(editor: editor) }
        .navigationTitle(editor.hasDocument ? editor.documentName : "Easel")
        .navigationSubtitle(editor.hasDocument ? "\(Int(editor.canvasSize.width)) × \(Int(editor.canvasSize.height))\(editor.isDirty ? " — Edited" : "")" : "")
        .sheet(isPresented: $editor.showNewSheet) { NewDocumentSheet(editor: editor) }
        .sheet(isPresented: $editor.showResizeSheet) { ResizeSheet(editor: editor, canvasMode: false) }
        .sheet(isPresented: $editor.showCanvasSheet) { ResizeSheet(editor: editor, canvasMode: true) }
        .sheet(isPresented: $editor.showGenerateSheet) { GenerateSheet(editor: editor) }
        .sheet(isPresented: $editor.showLayerResizeSheet) { LayerResizeSheet(editor: editor) }
        .sheet(isPresented: $editor.showExportSheet) { ExportSheet(editor: editor) }
        .sheet(item: $editor.pendingText) { request in
            TextSheet(editor: editor, request: request)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in editor.placeFile(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let ns = obj as? NSImage else { return }
                    Task { @MainActor in
                        guard let img = Bitmap.cgImage(from: ns) else { return }
                        if editor.hasDocument { editor.addImageLayer(img, name: "Dropped") }
                        else { editor.open(image: img, name: "Dropped Image") }
                    }
                }
            }
        }
        return handled
    }
}

/// Busy spinner and transient messages over the canvas.
struct Overlays: View {
    let editor: Editor

    var body: some View {
        VStack {
            if let message = editor.busyMessage {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if let toast = editor.toast {
                Text(toast)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: editor.busyMessage)
        .animation(.easeOut(duration: 0.2), value: editor.toast)
        .allowsHitTesting(false)
    }
}

struct MainToolbar: ToolbarContent {
    let editor: Editor

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!editor.canUndo).help("Undo (⌘Z)")
            Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!editor.canRedo).help("Redo (⇧⌘Z)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { editor.zoom(in: false) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom Out (⌘−)")
            Button { editor.zoomToFit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit on Screen (⌘0)")
            Button { editor.zoom(in: true) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Zoom In (⌘+)")
            Menu {
                Button("Reel (video)") { editor.send(to: .reel) }
                Button("Flip (animation)") { editor.send(to: .flip) }
                Button("Quill (vector)") { editor.send(to: .quill) }
                Button("Folio (PDF)") { editor.send(to: .folio) }
            } label: { Label("Send to", systemImage: "arrow.up.forward.app") }
                .disabled(!editor.hasDocument)
                .help("Send this image to Reel (transparent images become overlays)")
            Button { editor.showExportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export as PNG, JPEG… (⇧⌘E)")
        }
    }
}

struct StatusBar: View {
    let editor: Editor
    let viewport: Viewport

    var body: some View {
        HStack(spacing: 16) {
            Text(editor.tool.hint)
                .lineLimit(1)
            Spacer()
            if let c = viewport.cursor, editor.hasDocument, editor.canvasRect.contains(c) {
                Text("X \(Int(c.x))  Y \(Int(editor.canvasSize.height - c.y))")
                    .monospacedDigit()
            }
            if editor.hasDocument {
                Menu("\(Int((viewport.zoom * 100).rounded()))%") {
                    Button("Fit on Screen") { editor.zoomToFit() }
                    Button("Actual Size") { editor.actualSize() }
                    Divider()
                    ForEach([25, 50, 100, 200, 400, 800], id: \.self) { pct in
                        Button("\(pct)%") { viewport.zoom = CGFloat(pct) / 100; viewport.offset = .zero }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }
}

struct WelcomeView: View {
    let editor: Editor

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Easel").font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Drop an image anywhere to get started.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                WelcomeButton(title: "New Canvas", symbol: "plus.square", shortcut: "⌘N") { editor.showNewSheet = true }
                WelcomeButton(title: "Open Image", symbol: "photo", shortcut: "⌘O") { editor.openPanel() }
                WelcomeButton(title: "Paste", symbol: "doc.on.clipboard", shortcut: "⌘V") { editor.paste() }
            }
            let recents = NSDocumentController.shared.recentDocumentURLs.prefix(5)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(recents), id: \.self) { url in
                        Button(url.lastPathComponent) { editor.openFile(url) }
                            .buttonStyle(.link)
                    }
                }
                .frame(width: 360, alignment: .leading)
            }
        }
        .padding(40)
    }
}

private struct WelcomeButton: View {
    let title: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 26))
                Text(title).font(.headline)
                Text(shortcut).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, height: 110)
            .background(RoundedRectangle(cornerRadius: 14).fill(hover ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
