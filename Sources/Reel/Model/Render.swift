import AVFoundation
import AppKit
import CoreImage
import EaselKit

/// Parameters for one auto-enhance filter, captured from a sample frame so every frame of the
/// clip gets the same correction (no flicker).
struct FilterSpec: @unchecked Sendable {
    let name: String
    let parameters: [String: Any]
}

/// Everything needed to draw any frame of the movie. Immutable, so the render thread can use it
/// while the user keeps editing; a new plan is made after each change.
final class RenderPlan: @unchecked Sendable {
    struct ClipRender {
        let clip: Clip
        let start: Double
        let end: Double
        let trackID: CMPersistentTrackID?
        let photo: CIImage?
        let orientation: Int32
        let autoFilters: [FilterSpec]
    }

    struct Overlay {
        let start: Double
        let end: Double
        let image: CIImage
        /// Where the image's center goes, in render pixels (y up).
        let center: CGPoint
        let animation: TitleAnimation
        let opacity: Double
    }

    let size: CGSize
    let background: Background
    let clips: [ClipRender]
    let overlays: [Overlay]
    private let black: CIImage
    private let white: CIImage
    private let shading: CIImage

    init(size: CGSize, background: Background, clips: [ClipRender], overlays: [Overlay]) {
        self.size = size
        self.background = background
        self.clips = clips
        self.overlays = overlays
        let rect = CGRect(origin: .zero, size: size)
        black = CIImage(color: .black).cropped(to: rect)
        white = CIImage(color: .white).cropped(to: rect)
        shading = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.35)).cropped(to: rect)
    }

    var rect: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Frame

    /// Draws the movie at time `t`. `source` returns the decoded video frame for a track.
    func frame(at t: Double, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let active = clips.filter { $0.start - 1e-6 <= t && t < $0.end }
        var image: CIImage
        switch active.count {
        case 0:
            image = black
        case 1:
            image = clipFrame(active[0], at: t, source: source)
        default:
            let a = active[0], b = active[1]
            let p = min(1, max(0, (t - b.start) / max(0.001, a.end - b.start)))
            image = transition(a.clip.transition?.kind ?? .crossfade,
                               from: clipFrame(a, at: t, source: source),
                               to: clipFrame(b, at: t, source: source), progress: p)
        }
        for overlay in overlays where overlay.start <= t && t < overlay.end {
            image = place(overlay, at: t).composited(over: image)
        }
        return image.cropped(to: rect)
    }

    private func clipFrame(_ c: ClipRender, at t: Double, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let clip = c.clip
        let local = t - c.start, length = max(0.001, c.end - c.start)
        let p = min(1, max(0, local / length))
        guard var src = c.trackID.flatMap(source) ?? c.photo else { return black }

        if c.trackID != nil, c.orientation != 1,
           let o = CGImagePropertyOrientation(rawValue: UInt32(c.orientation)) {
            src = src.oriented(o)
        }
        switch ((clip.quarterTurns % 4) + 4) % 4 {
        case 1: src = src.oriented(.right)
        case 2: src = src.oriented(.down)
        case 3: src = src.oriented(.left)
        default: break
        }
        if clip.flipped { src = src.oriented(.upMirrored) }
        src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))

        let w = max(1, src.extent.width), h = max(1, src.extent.height)
        var scale = clip.fit == .fill ? max(size.width / w, size.height / h) : min(size.width / w, size.height / h)
        var dx: CGFloat = 0
        let e = Self.ease(p)
        switch clip.motion {
        case .none: break
        case .zoomIn: scale *= 1 + 0.18 * e
        case .zoomOut: scale *= 1.18 - 0.18 * e
        case .panLeft, .panRight:
            scale *= 1.15
            let travel = max(0, (w * scale - size.width) / 2)
            dx = (clip.motion == .panLeft ? 1 - 2 * e : 2 * e - 1) * travel
        }
        let placed = src.transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: (size.width - w * scale) / 2 + dx, ty: (size.height - h * scale) / 2))

        var frame = placed
        if !placed.extent.insetBy(dx: 1, dy: 1).contains(rect.insetBy(dx: 1, dy: 1)) {
            frame = placed.composited(over: backdrop(for: src))
        }
        frame = frame.cropped(to: rect)

        for spec in c.autoFilters {
            if let f = CIFilter(name: spec.name, parameters: spec.parameters) {
                f.setValue(frame, forKey: kCIInputImageKey)
                frame = f.outputImage ?? frame
            }
        }
        if !clip.adjustments.isIdentity { frame = clip.adjustments.apply(to: frame) }
        if let look = clip.look, let effect = Effect.all.first(where: { $0.id == look }) {
            frame = effect.apply(frame)
        }
        frame = frame.cropped(to: rect)

        // Fades to and from black.
        var fade = 1.0
        if clip.fadeIn > 0 { fade = min(fade, local / clip.fadeIn) }
        if clip.fadeOut > 0 { fade = min(fade, (length - local) / clip.fadeOut) }
        if fade < 1 { frame = Self.mix(black, frame, max(0, fade)) }
        return frame
    }

    /// What shows behind a clip that doesn't fill the frame.
    private func backdrop(for src: CIImage) -> CIImage {
        switch background {
        case .black: return black
        case .white: return white
        case .blur:
            // Blur a small copy and scale it up: looks the same, a fraction of the cost.
            let w = src.extent.width, h = src.extent.height
            let fill = max(size.width / w, size.height / h)
            let down: CGFloat = 1.0 / 10
            let small = src.transformed(by: CGAffineTransform(scaleX: fill * down, y: fill * down))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: small.extent)
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            let centered = blurred.transformed(by: CGAffineTransform(
                translationX: (size.width - blurred.extent.width) / 2 - blurred.extent.minX,
                y: (size.height - blurred.extent.height) / 2 - blurred.extent.minY))
            return centered.applyingFilter("CIColorControls", parameters: ["inputBrightness": -0.08, "inputSaturation": 1.2])
                .composited(over: black)
                .cropped(to: rect)
        }
    }

    // MARK: Transitions

    private func transition(_ kind: TransitionKind, from a: CIImage, to b: CIImage, progress p: Double) -> CIImage {
        let e = Self.ease(p)
        let r = rect
        switch kind {
        case .crossfade:
            return Self.mix(a, b, p)
        case .dipBlack, .dipWhite:
            let mid = kind == .dipBlack ? black : white
            return p < 0.5 ? Self.mix(a, mid, p * 2) : Self.mix(mid, b, p * 2 - 1)
        case .slide:
            return b.transformed(by: CGAffineTransform(translationX: r.width * (1 - e), y: 0)).composited(over: a).cropped(to: r)
        case .push:
            return b.transformed(by: CGAffineTransform(translationX: r.width * (1 - e), y: 0))
                .composited(over: a.transformed(by: CGAffineTransform(translationX: -r.width * e, y: 0)))
                .composited(over: black).cropped(to: r)
        case .zoom:
            let grown = Self.scaled(a, by: 1 + 0.8 * e, in: r)
            // The incoming clip settles in from slightly larger, so no edges ever show.
            let arriving = Self.scaled(b, by: 1.3 - 0.3 * e, in: r)
            return Self.mix(grown, arriving, e)
        case .spin:
            let turn = CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: .pi * e).scaledBy(x: 1 - 0.6 * e, y: 1 - 0.6 * e).translatedBy(x: -r.midX, y: -r.midY)
            let spun = a.transformed(by: turn).composited(over: black).cropped(to: r)
            return Self.mix(spun, b, e)
        case .wipe:
            return CIFilter(name: "CISwipeTransition", parameters: [
                kCIInputImageKey: a, kCIInputTargetImageKey: b, kCIInputExtentKey: CIVector(cgRect: r),
                kCIInputColorKey: CIColor.white, kCIInputTimeKey: p, kCIInputAngleKey: 0,
                kCIInputWidthKey: r.width * 0.15, "inputOpacity": 0,
            ])?.outputImage?.cropped(to: r) ?? Self.mix(a, b, p)
        case .flash:
            return CIFilter(name: "CIFlashTransition", parameters: [
                kCIInputImageKey: a, kCIInputTargetImageKey: b, kCIInputCenterKey: CIVector(x: r.midX, y: r.midY),
                kCIInputExtentKey: CIVector(cgRect: r), kCIInputColorKey: CIColor(red: 1, green: 0.95, blue: 0.8),
                kCIInputTimeKey: p, "inputMaxStriationRadius": 2.58, "inputStriationStrength": 0.5,
                "inputStriationContrast": 1.375, "inputFadeThreshold": 0.85,
            ])?.outputImage?.cropped(to: r) ?? Self.mix(a, b, p)
        case .bars:
            return CIFilter(name: "CIBarsSwipeTransition", parameters: [
                kCIInputImageKey: a, kCIInputTargetImageKey: b, kCIInputAngleKey: Double.pi,
                kCIInputWidthKey: r.width / 20, "inputBarOffset": 12, kCIInputTimeKey: p,
            ])?.outputImage?.cropped(to: r) ?? Self.mix(a, b, p)
        case .pageCurl:
            return CIFilter(name: "CIPageCurlTransition", parameters: [
                kCIInputImageKey: a, kCIInputTargetImageKey: b, "inputBacksideImage": a, kCIInputShadingImageKey: shading,
                kCIInputExtentKey: CIVector(cgRect: r), kCIInputTimeKey: p, kCIInputAngleKey: Double.pi * 0.85,
                kCIInputRadiusKey: r.width * 0.12,
            ])?.outputImage?.composited(over: black).cropped(to: r) ?? Self.mix(a, b, p)
        case .ripple:
            // Clamp so the wave never pulls in empty pixels from outside the frame.
            return CIFilter(name: "CIRippleTransition", parameters: [
                kCIInputImageKey: a.clampedToExtent(), kCIInputTargetImageKey: b.clampedToExtent(), kCIInputShadingImageKey: shading,
                kCIInputCenterKey: CIVector(x: r.midX, y: r.midY), kCIInputExtentKey: CIVector(cgRect: r),
                kCIInputTimeKey: p, kCIInputWidthKey: r.width / 12, kCIInputScaleKey: 40,
            ])?.outputImage?.cropped(to: r) ?? Self.mix(a, b, p)
        case .blur:
            let amount = (1 - abs(p * 2 - 1)) * r.width / 60
            let soft = { (img: CIImage) in img.clampedToExtent().applyingGaussianBlur(sigma: amount).cropped(to: r) }
            return Self.mix(soft(a), soft(b), e)
        }
    }

    // MARK: Overlays

    private func place(_ o: Overlay, at t: Double) -> CIImage {
        let inP = min(1, max(0, (t - o.start) / 0.45))
        let outP = min(1, max(0, (o.end - t) / 0.35))
        var scale = 1.0, dy = 0.0, opacity = o.opacity
        var image = o.image
        switch o.animation {
        case .none: break
        case .fade: opacity *= Self.ease(min(inP, outP))
        case .pop:
            scale = 0.55 + 0.45 * Self.backEase(inP)
            opacity *= min(1, inP * 3) * Self.ease(outP)
        case .slideUp:
            dy = -size.height * 0.06 * (1 - Self.ease(inP))
            opacity *= Self.ease(min(inP, outP))
        case .zoom:
            scale = 1.35 - 0.35 * Self.ease(inP)
            opacity *= Self.ease(min(inP, outP))
        case .bounce:
            let b = inP >= 1 ? 0 : exp(-5 * inP) * cos(inP * 4 * .pi)
            dy = size.height * 0.12 * b
            opacity *= min(1, inP * 4) * Self.ease(outP)
        case .reveal:
            let shown = image.extent.width * Self.ease(min(1, (t - o.start) / 0.8))
            image = image.cropped(to: CGRect(x: image.extent.minX, y: image.extent.minY, width: shown, height: image.extent.height))
            opacity *= Self.ease(outP)
        }
        let full = o.image.extent
        let move = CGAffineTransform(translationX: o.center.x, y: o.center.y + dy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -full.midX, y: -full.midY)
        return Self.fade(image.transformed(by: move), opacity)
    }

    // MARK: Helpers

    static func ease(_ p: Double) -> Double { let x = min(1, max(0, p)); return x * x * (3 - 2 * x) }

    static func backEase(_ p: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1, x = min(1, max(0, p)) - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }

    static func mix(_ a: CIImage, _ b: CIImage, _ p: Double) -> CIImage {
        if p <= 0 { return a }
        if p >= 1 { return b }
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p])
    }

    static func fade(_ image: CIImage, _ opacity: Double) -> CIImage {
        if opacity >= 0.999 { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
    }

    static func scaled(_ image: CIImage, by s: CGFloat, in r: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: r.midX, y: r.midY).scaledBy(x: s, y: s).translatedBy(x: -r.midX, y: -r.midY))
            .cropped(to: r)
    }
}

// MARK: - Compositor

final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: RenderPlan

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], plan: RenderPlan) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs.map { NSNumber(value: $0) }
        self.plan = plan
    }
}

/// AVFoundation calls this for every frame during playback, scrubbing, thumbnails and export.
final class ReelCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = ReelCompositor.pixelAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = ReelCompositor.pixelAttributes

    static let context: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let options: [CIContextOption: Any] = [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "reel.compositor", qos: .userInteractive)
    private var cancelled = false

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelled {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? ReelInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                #if DEBUG
                print("compositor: no instruction/buffer at \(request.compositionTime.seconds)")
                #endif
                request.finish(with: NSError(domain: "Reel", code: 1))
                return
            }
            let plan = instruction.plan
            let image = plan.frame(at: request.compositionTime.seconds) { id in
                request.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0) }
            }
            // The render context may be a different size than the plan (e.g. a scaled-down preview).
            let size = request.renderContext.size
            let fitted = size == plan.size ? image : image.transformed(by: CGAffineTransform(
                scaleX: size.width / plan.size.width, y: size.height / plan.size.height))
            Self.context.render(fitted, to: output, bounds: CGRect(origin: .zero, size: size),
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async(flags: .barrier) { self.cancelled = false }
    }
}
