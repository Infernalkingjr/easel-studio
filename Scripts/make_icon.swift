import AppKit

// Renders a 1024px app icon: make_icon.swift <out.png> [easel|reel|tone|flip|quill|folio]
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "easel"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Easel runs purple → orange; Reel is its sibling, running orange → purple through deep blue.
    let colors = style == "quill"
        ? [NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1), NSColor(srgbRed: 0.95, green: 0.25, blue: 0.3, alpha: 1),
           NSColor(srgbRed: 0.55, green: 0.15, blue: 0.6, alpha: 1)]
        : style == "folio"
        ? [NSColor(srgbRed: 0.95, green: 0.2, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.6, green: 0.15, blue: 0.75, alpha: 1),
           NSColor(srgbRed: 0.2, green: 0.25, blue: 0.75, alpha: 1)]
        : style == "flip"
        ? [NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1), NSColor(srgbRed: 1, green: 0.42, blue: 0.3, alpha: 1),
           NSColor(srgbRed: 0.85, green: 0.2, blue: 0.55, alpha: 1)]
        : style == "tone"
        ? [NSColor(srgbRed: 0.1, green: 0.8, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1),
           NSColor(srgbRed: 0.45, green: 0.2, blue: 0.85, alpha: 1)]
        : style == "reel"
        ? [NSColor(srgbRed: 1.00, green: 0.45, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.90, green: 0.20, blue: 0.50, alpha: 1),
           NSColor(srgbRed: 0.22, green: 0.20, blue: 0.85, alpha: 1)]
        : [NSColor(srgbRed: 0.42, green: 0.27, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.93, green: 0.30, blue: 0.62, alpha: 1),
           NSColor(srgbRed: 1.00, green: 0.62, blue: 0.25, alpha: 1)]
    NSGradient(colors: colors)!.draw(in: shape, angle: -55)

    let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let symbols = ["reel": "movieclapper.fill", "tone": "waveform", "flip": "figure.run", "quill": "pencil.tip.crop.circle", "folio": "book.pages.fill"]
    if let symbol = NSImage(systemSymbolName: symbols[style] ?? "paintbrush.pointed.fill",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
