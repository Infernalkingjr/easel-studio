import Foundation
import CoreGraphics

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 1, g: 1, b: 1)
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum StrokeKind: String, Codable {
    case brush, line, rect, ellipse, image
}

/// One vector mark. Points are in document coordinates (origin top-left, y down).
struct Stroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: StrokeKind
    var points: [CGPoint]
    /// 0…1 per point, brush only.
    var pressures: [Float] = []
    var color: RGBA = .black
    var width: Double = 6
    var fill: RGBA?
    /// For `.image`: which imported image, drawn in the rect spanned by points[0] and points[1].
    var imageID: UUID?

    var bounds: CGRect {
        guard let first = points.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        let pad = kind == .image ? 0 : width / 2
        return r.insetBy(dx: -pad, dy: -pad)
    }

    /// Brush strokes that end near where they started count as closed (fillable) shapes.
    var isClosed: Bool {
        switch kind {
        case .rect, .ellipse: return true
        case .brush:
            guard points.count > 8, let a = points.first, let b = points.last else { return false }
            return hypot(a.x - b.x, a.y - b.y) < max(14, width * 2)
        case .line, .image: return false
        }
    }
}

struct Drawing: Codable, Equatable {
    var strokes: [Stroke] = []

    var bounds: CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.bounds) }
    }
}

enum Ease: String, Codable, CaseIterable, Identifiable {
    case linear = "Linear", easeIn = "Ease In", easeOut = "Ease Out", easeInOut = "Ease In & Out"
    case bounce = "Bounce", elastic = "Elastic", back = "Overshoot"
    var id: String { rawValue }

    func apply(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .bounce:
            let n = 7.5625, d = 2.75
            var v = x
            if v < 1 / d { return n * v * v }
            if v < 2 / d { v -= 1.5 / d; return n * v * v + 0.75 }
            if v < 2.5 / d { v -= 2.25 / d; return n * v * v + 0.9375 }
            v -= 2.625 / d
            return n * v * v + 0.984375
        case .elastic:
            if x == 0 || x == 1 { return x }
            return pow(2, -10 * x) * sin((x * 10 - 0.75) * (2 * .pi / 3)) + 1
        case .back:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        }
    }
}

/// How a keyframe's drawing is placed. Rotation and scale pivot on the drawing's center.
struct Placement: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
    var rotation: Double = 0   // degrees
    var opacity: Double = 1

    static func lerp(_ a: Placement, _ b: Placement, _ t: Double) -> Placement {
        Placement(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, scale: a.scale + (b.scale - a.scale) * t,
                  rotation: a.rotation + (b.rotation - a.rotation) * t, opacity: a.opacity + (b.opacity - a.opacity) * t)
    }

    func transform(pivot: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: pivot.x + x, y: pivot.y + y)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -pivot.x, y: -pivot.y)
    }
}

struct Keyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var frame: Int
    var drawing = Drawing()
    var placement = Placement()
    /// Animate placement from this key to the next one.
    var tween = false
    var ease: Ease = .easeInOut
}

struct AnimLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var visible = true
    var locked = false
    var colorIndex = 0
    /// Sorted by frame.
    var keyframes: [Keyframe] = [Keyframe(frame: 0)]

    func keyIndex(at frame: Int) -> Int? { keyframes.lastIndex { $0.frame <= frame } }

    /// What this layer shows on `frame`: the drawing and where it sits.
    func pose(at frame: Int) -> (drawing: Drawing, placement: Placement, key: Keyframe)? {
        guard let i = keyIndex(at: frame) else { return nil }
        let key = keyframes[i]
        if key.tween, i + 1 < keyframes.count {
            let next = keyframes[i + 1]
            let t = Double(frame - key.frame) / Double(max(1, next.frame - key.frame))
            return (key.drawing, Placement.lerp(key.placement, next.placement, key.ease.apply(t)), key)
        }
        return (key.drawing, key.placement, key)
    }

    mutating func sortKeys() { keyframes.sort { $0.frame < $1.frame } }
}

struct ImageAsset: Codable, Equatable, Identifiable {
    var id = UUID()
    var url: URL
    var size: CGSize
}

struct FlipDocument: Codable, Equatable {
    var version = 1
    var width: Double = 1280
    var height: Double = 720
    var fps = 24
    var frameCount = 48
    /// nil = transparent.
    var background: RGBA? = .white
    var layers: [AnimLayer] = [AnimLayer(name: "Layer 1")]
    var images: [ImageAsset] = []

    var size: CGSize { CGSize(width: width, height: height) }
    var duration: Double { Double(frameCount) / Double(fps) }

    /// The last frame any layer changes on, plus one (at least `frameCount`).
    var usedFrames: Int {
        max(frameCount, (layers.flatMap(\.keyframes).map(\.frame).max() ?? 0) + 1)
    }

    static let presets: [(String, Double, Double)] = [
        ("HD 1280×720", 1280, 720), ("Full HD 1920×1080", 1920, 1080), ("Square 1080", 1080, 1080),
        ("Vertical 1080×1920", 1080, 1920), ("GIF 640×480", 640, 480),
    ]
}

extension Drawing {
    /// Pivot used for rotation/scale: the drawing's center, or the canvas center when empty.
    func pivot(in size: CGSize) -> CGPoint {
        let b = bounds
        return b.isNull ? CGPoint(x: size.width / 2, y: size.height / 2) : CGPoint(x: b.midX, y: b.midY)
    }
}
