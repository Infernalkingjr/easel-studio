import EaselKit
import SwiftUI

struct AIPanel: View {
    let editor: Editor
    @State private var request = ""

    private let examples = ["Warmer", "Moody", "Vintage", "Black & white", "Brighter", "Vivid"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("EDIT WITH WORDS")
                HStack(spacing: 6) {
                    TextField("e.g. warmer and a bit brighter", text: $request)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Apply")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(examples, id: \.self) { example in
                        Button(example) { request = example; submit() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Text(AIOps.languageModelAvailable
                     ? "Using Apple Intelligence. Describe any look you want."
                     : "\(AIOps.languageModelStatus). Simple words like the ones above work now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SectionTitle("SUBJECT")
                ToolGrid {
                    AITile("Remove BG", "person.crop.rectangle", "Make everything but the subject transparent") { editor.removeBackground() }
                    AITile("Lift Subject", "square.3.layers.3d.top.filled", "Copy the subject onto a new layer") { editor.liftSubject() }
                    AITile("Select Subject", "person.crop.square.badge.camera", "Select the area around the subject") { editor.selectSubject() }
                    AITile("Blur BG", "camera.filters", "Portrait look: sharp subject, blurred background") { editor.blurBackground() }
                    AITile("Color BG", "paintpalette", "Put the secondary color behind the subject") { editor.colorBackground() }
                }

                SectionTitle("PHOTO")
                ToolGrid {
                    AITile("Auto Fix", "wand.and.stars", "Improve color and light automatically") {
                        if let auto = Effect.all.first(where: { $0.id == "auto" }) { editor.applyEffect(auto) }
                    }
                    AITile("Straighten", "level", "Level a tilted horizon") { editor.straighten() }
                    AITile("Smart Crop", "crop", "Suggest a crop around the most interesting part") { editor.smartCrop() }
                    AITile("Smooth Skin", "face.smiling", "Gently soften skin on faces") { editor.smoothSkin() }
                    AITile("Red Eye", "eye", "Remove red-eye from flash photos") { editor.fixRedEye() }
                }

                SectionTitle("TOOLS")
                ToolGrid {
                    AITile("Erase Object", "eraser.line.dashed", "Select something, then fill it in from its surroundings") { editor.eraseObject() }
                    AITile("Hide Faces", "eye.slash", "Pixelate every face for privacy") { editor.hideFaces() }
                    AITile("Copy Text", "text.viewfinder", "Copy any text in the image to the clipboard") { editor.copyText() }
                    AITile("Generate", "sparkles", "Create a new image from a description") { editor.showGenerateSheet = true }
                }

                Label("Everything runs on your Mac. Nothing is uploaded.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private func submit() {
        editor.editWithWords(request)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

private struct ToolGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            content
        }
    }
}

private struct AITile: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, _ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17))
                    .frame(height: 20)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct GenerateSheet: View {
    let editor: Editor
    @State private var prompt = ""
    @AppStorage("generateStyle") private var style = "Animation"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Generate Image", systemImage: "sparkles").font(.title2.weight(.semibold))
            TextField("Describe what you want, e.g. a cat astronaut on the moon", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Picker("Style", selection: $style) {
                ForEach(["Animation", "Illustration", "Sketch"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(AIOps.languageModelAvailable
                 ? "Made on your Mac with Image Playground. It’s added as a new layer."
                 : "Needs Apple Intelligence (System Settings → Apple Intelligence & Siri). \(AIOps.languageModelStatus).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    editor.generateImage(prompt: prompt, style: style)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}
