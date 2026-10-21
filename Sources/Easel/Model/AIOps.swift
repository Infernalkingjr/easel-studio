import EaselKit
import AppKit
import CoreImage
import Vision
import FoundationModels
import ImagePlayground

/// On-device AI helpers built on Vision, Core Image, and (when enabled) Apple Intelligence.
enum AIOps {
    // MARK: Vision

    /// Rotation in radians (counter-clockwise positive) that levels the horizon, or nil if none was found.
    static func horizonAngle(_ image: CGImage) throws -> CGFloat? {
        let request = VNDetectHorizonRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first.map { CGFloat($0.angle) }
    }

    /// The most eye-catching region in canvas coordinates (Vision uses a bottom-left origin too).
    static func salientRect(_ image: CGImage) throws -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let objects = request.results?.first?.salientObjects, let first = objects.first else { return nil }
        let unit = objects.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
        return VNImageRectForNormalizedRect(unit, image.width, image.height)
    }

    static func faceRects(_ image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map { VNImageRectForNormalizedRect($0.boundingBox, image.width, image.height) }
    }

    static func recognizeText(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Bounds of the detected subject, for "Select Subject".
    static func subjectBounds(_ image: CGImage) throws -> CGRect? {
        guard let mask = try ImageOps.subjectMask(image) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        // Turn the grayscale mask into alpha so the shared bounds scanner can read it.
        let alpha = mask.applyingFilter("CIMaskToAlpha")
        guard let rendered = ImageOps.render(alpha, size: size) else { return nil }
        return ImageOps.opaqueBounds(rendered)
    }

    // MARK: Retouching

    static func fixRedEye(_ image: CGImage) -> CGImage? {
        ImageOps.process(image) { img in
            img.autoAdjustmentFilters(options: [.enhance: false, .redEye: true]).reduce(img) { acc, f in
                f.setValue(acc, forKey: kCIInputImageKey)
                return f.outputImage ?? acc
            }
        }
    }

    /// Softens skin inside each detected face with a feathered oval mask.
    static func smoothSkin(_ image: CGImage) throws -> CGImage? {
        let faces = try faceRects(image)
        guard !faces.isEmpty else { return nil }
        let input = CIImage(cgImage: image)
        var output = input
        for face in faces {
            let r = face.insetBy(dx: -face.width * 0.1, dy: -face.height * 0.15)
            let smooth = input.clampedToExtent()
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.04, "inputSharpness": 0.2])
                .applyingGaussianBlur(sigma: face.width / 70)
                .cropped(to: input.extent)
            // Keep some original texture so skin doesn't look plastic.
            let blended = smooth.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: input, "inputTime": 0.35,
            ])
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: r.midX, y: r.midY),
                "inputRadius0": min(r.width, r.height) * 0.3,
                "inputRadius1": min(r.width, r.height) * 0.55,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!
                .transformed(by: CGAffineTransform(translationX: r.midX, y: r.midY)
                    .scaledBy(x: 1, y: r.height / r.width)
                    .translatedBy(x: -r.midX, y: -r.midY))
                .cropped(to: input.extent)
            output = blended.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output, kCIInputMaskImageKey: mask,
            ])
        }
        return ImageOps.render(output, size: CGSize(width: image.width, height: image.height))
    }

    /// Pixelates every detected face, for privacy.
    static func hideFaces(_ image: CGImage) throws -> CGImage? {
        let faces = try faceRects(image)
        guard !faces.isEmpty else { return nil }
        let input = CIImage(cgImage: image)
        var output = input
        for face in faces {
            let r = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.25).intersection(input.extent)
            let pixels = input.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: ["inputScale": max(6, face.width / 9), "inputCenter": CIVector(x: r.midX, y: r.midY)])
                .cropped(to: r)
            output = pixels.composited(over: output)
        }
        return ImageOps.render(output, size: CGSize(width: image.width, height: image.height))
    }

    // MARK: Erase object (push–pull smart fill)

    /// Fills `hole` from the surrounding pixels using a push–pull pyramid, which blends smoothly
    /// from all edges. Works best on small objects over simple backgrounds.
    static func fill(_ image: CGImage, hole: CGRect) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let hole = hole.integral.intersection(full)
        guard !hole.isEmpty else { return nil }
        let margin = max(16, max(hole.width, hole.height) * 0.5)
        let region = hole.insetBy(dx: -margin, dy: -margin).integral.intersection(full)
        let w = Int(region.width), h = Int(region.height)

        // Read the region as premultiplied RGBA floats (row 0 = bottom).
        let ctx = Bitmap.context(region.size)
        ctx.draw(image, in: full.offsetBy(dx: -region.minX, dy: -region.minY))
        guard let raw = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h) else { return nil }
        let bpr = ctx.bytesPerRow
        var color = [Float](repeating: 0, count: w * h * 4)
        var weight = [Float](repeating: 0, count: w * h)
        let hx0 = Int(hole.minX - region.minX), hy0 = Int(hole.minY - region.minY)
        let hx1 = hx0 + Int(hole.width), hy1 = hy0 + Int(hole.height)
        for y in 0..<h {
            let row = (h - 1 - y) * bpr
            for x in 0..<w {
                let inHole = x >= hx0 && x < hx1 && y >= hy0 && y < hy1
                guard !inHole else { continue }
                let i = (y * w + x)
                for c in 0..<4 { color[i * 4 + c] = Float(raw[row + x * 4 + c]) }
                weight[i] = 1
            }
        }

        // Push: build coarser levels from weighted averages.
        var levels: [(w: Int, h: Int, color: [Float], weight: [Float])] = [(w, h, color, weight)]
        while let top = levels.last, top.w > 1 || top.h > 1 {
            let cw = max(1, (top.w + 1) / 2), ch = max(1, (top.h + 1) / 2)
            var cc = [Float](repeating: 0, count: cw * ch * 4)
            var cwt = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch {
                for x in 0..<cw {
                    var sum: (Float, Float, Float, Float) = (0, 0, 0, 0), sw: Float = 0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let fx = x * 2 + dx, fy = y * 2 + dy
                            guard fx < top.w, fy < top.h else { continue }
                            let fi = fy * top.w + fx, wt = top.weight[fi]
                            guard wt > 0 else { continue }
                            sum.0 += top.color[fi * 4] * wt; sum.1 += top.color[fi * 4 + 1] * wt
                            sum.2 += top.color[fi * 4 + 2] * wt; sum.3 += top.color[fi * 4 + 3] * wt
                            sw += wt
                        }
                    }
                    let ci = y * cw + x
                    if sw > 0 {
                        cc[ci * 4] = sum.0 / sw; cc[ci * 4 + 1] = sum.1 / sw
                        cc[ci * 4 + 2] = sum.2 / sw; cc[ci * 4 + 3] = sum.3 / sw
                    }
                    cwt[ci] = min(1, sw)
                }
            }
            levels.append((cw, ch, cc, cwt))
        }

        // Pull: fill each level's gaps from the bilinearly upsampled level above.
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[li + 1]
            var fine = levels[li]
            for y in 0..<fine.h {
                for x in 0..<fine.w {
                    let fi = y * fine.w + x, wt = fine.weight[fi]
                    guard wt < 1 else { continue }
                    let cx = min(max(Float(x) / 2 - 0.25, 0), Float(coarse.w - 1))
                    let cy = min(max(Float(y) / 2 - 0.25, 0), Float(coarse.h - 1))
                    let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, coarse.w - 1), y1 = min(y0 + 1, coarse.h - 1)
                    let tx = cx - Float(x0), ty = cy - Float(y0)
                    for c in 0..<4 {
                        let a = coarse.color[(y0 * coarse.w + x0) * 4 + c], b = coarse.color[(y0 * coarse.w + x1) * 4 + c]
                        let d = coarse.color[(y1 * coarse.w + x0) * 4 + c], e = coarse.color[(y1 * coarse.w + x1) * 4 + c]
                        let up = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
                        fine.color[fi * 4 + c] = fine.color[fi * 4 + c] * wt + up * (1 - wt)
                    }
                    fine.weight[fi] = 1
                }
            }
            levels[li] = fine
        }

        let filled = levels[0].color
        for y in hy0..<hy1 {
            let row = (h - 1 - y) * bpr
            for x in hx0..<hx1 {
                let i = y * w + x
                for c in 0..<4 { raw[row + x * 4 + c] = UInt8(min(255, max(0, filled[i * 4 + c].rounded()))) }
            }
        }
        guard let patch = ctx.makeImage() else { return nil }
        return Bitmap.render(full.size) { out in
            out.draw(image, in: full)
            out.clip(to: hole)
            out.clear(hole)
            out.draw(patch, in: region)
        }
    }

    // MARK: Apple Intelligence

    static var languageModelAvailable: Bool {
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    static var languageModelStatus: String {
        guard #available(macOS 26.0, *) else { return "Needs macOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings for smarter edits"
        case .unavailable(.deviceNotEligible): return "This Mac doesn’t support Apple Intelligence"
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading"
        default: return "Apple Intelligence unavailable"
        }
    }

    /// Asks the on-device language model to turn a request into slider changes.
    static func adjustmentsFromModel(_ request: String) async throws -> [String: Double] {
        guard #available(macOS 26.0, *) else { return [:] }
        let keys = Adjustments.groups.flatMap(\.controls).map { "\(KeywordEdits.key(for: $0.id)) (\(Int($0.range.lowerBound))…\(Int($0.range.upperBound)))" }
        let session = LanguageModelSession(instructions: """
            You are the photo-editing assistant in an image editor. Turn the user's request into \
            changes to these sliders: \(keys.joined(separator: ", ")). Values are amounts to ADD to the \
            current slider value; typical changes are 10–40, use up to 100 only for strong requests. \
            Reply with ONLY a JSON object of slider names to numbers, e.g. {"temperature": 25, "contrast": 15}.
            """)
        let reply = try await session.respond(to: request).content
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let data = String(reply[start...end]).data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    static var imageGenerationAvailable: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    /// Generates an image with Image Playground. Throws if Apple Intelligence isn't available.
    static func generateImage(prompt: String, style: String) async throws -> CGImage? {
        guard #available(macOS 15.4, *) else { return nil }
        let creator = try await ImageCreator()
        let wanted: ImagePlaygroundStyle = switch style {
        case "Illustration": .illustration
        case "Sketch": .sketch
        default: .animation
        }
        let chosen = creator.availableStyles.contains(wanted) ? wanted : (creator.availableStyles.first ?? wanted)
        for try await image in creator.images(for: [.text(prompt)], style: chosen, limit: 1) {
            return image.cgImage
        }
        return nil
    }
}
