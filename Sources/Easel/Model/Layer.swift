import EaselKit
import AppKit
import CoreGraphics

enum BlendMode: String, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, darken, lighten
    case colorDodge, colorBurn, softLight, hardLight, difference, exclusion
    case hue, saturation, color, luminosity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorDodge: return "Color Dodge"
        case .colorBurn: return "Color Burn"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        default: return rawValue.capitalized
        }
    }

    var cg: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }
}

/// A raster layer. Images are immutable `CGImage`s the size of the canvas, so
/// undo snapshots share pixel memory with the live document for free.
struct Layer: Identifiable {
    private static var revisionCounter = 0
    private static func nextRevision() -> Int { revisionCounter += 1; return revisionCounter }

    let id: UUID
    var name: String
    /// Replacing pixels makes text non-editable; callers that only move text restore `text` afterwards.
    var image: CGImage { didSet { revision = Layer.nextRevision(); text = nil } }
    var isVisible = true
    var opacity: Double = 1
    var blendMode: BlendMode = .normal
    /// Present while the layer is still editable text.
    var text: TextInfo?
    private(set) var revision: Int

    init(name: String, image: CGImage, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.image = image
        self.revision = Layer.nextRevision()
        self.text = nil
    }
}

/// The recipe for a text layer, so it can be re-edited after placement.
struct TextInfo: Codable, Equatable {
    var string: String
    var x: Double
    var y: Double
    var font: String
    var size: Double
    var bold: Bool
    var red: Double, green: Double, blue: Double
    /// Radians, counter-clockwise, around the text's center. Optional so older files still load.
    var rotation: Double?

    var nsFont: NSFont {
        let font = NSFont(name: font, size: size) ?? .systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    var attributed: NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: nsFont,
            .foregroundColor: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1),
        ])
    }

    func offsetBy(_ d: CGPoint) -> TextInfo {
        var t = self
        t.x += d.x
        t.y += d.y
        return t
    }

    /// Unrotated layout box in canvas space; `(x, y)` is its top-left corner.
    var bounds: CGRect {
        let size = attributed.size()
        return CGRect(x: x, y: y - size.height, width: size.width, height: size.height)
    }

    private var rotationTransform: CGAffineTransform {
        let b = bounds, angle = rotation ?? 0
        return CGAffineTransform(translationX: b.midX, y: b.midY).rotated(by: angle).translatedBy(x: -b.midX, y: -b.midY)
    }

    /// The area the text covers on the canvas, including rotation.
    var coveredBounds: CGRect { bounds.applying(rotationTransform) }

    /// Hit test that follows the rotated text, not just its outer box.
    func contains(_ p: CGPoint) -> Bool {
        bounds.contains(p.applying(rotationTransform.inverted()))
    }

    func render(canvas: CGSize) -> CGImage {
        let attr = attributed, origin = bounds.origin, t = rotationTransform
        return Bitmap.render(canvas) { ctx in
            ctx.concatenate(t)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            attr.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Small cached thumbnails keyed by layer revision.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 200 }

    func thumbnail(for layer: Layer, maxSide: CGFloat = 80) -> NSImage {
        let key = "\(layer.id)-\(layer.revision)-\(Int(maxSide))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = layer.image
        let scale = min(1, maxSide / CGFloat(max(img.width, img.height)))
        let size = CGSize(width: max(1, CGFloat(img.width) * scale), height: max(1, CGFloat(img.height) * scale))
        let thumb = Bitmap.render(size) { ctx in
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
        }
        let ns = NSImage(cgImage: thumb, size: size)
        cache.setObject(ns, forKey: key)
        return ns
    }
}
