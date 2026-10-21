import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit

/// All slider adjustments. Every value is in -100...100 (or 0...100) where 0 means "no change".
public struct Adjustments: Equatable, Codable {
    public init() {}

    public var exposure: Double = 0
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var hue: Double = 0
    public var clarity: Double = 0
    public var sharpness: Double = 0
    public var blur: Double = 0
    public var vignette: Double = 0
    public var grain: Double = 0

    public var isIdentity: Bool { self == Adjustments() }

    public struct Control: Identifiable {
        public let id: WritableKeyPath<Adjustments, Double>
        public let title: String
        public let symbol: String
        public let range: ClosedRange<Double>
    }

    public struct Group: Identifiable {
        public let id: String
        public let controls: [Control]
    }

    public static let groups: [Group] = [
        Group(id: "Light", controls: [
            Control(id: \.exposure, title: "Exposure", symbol: "plusminus.circle", range: -100...100),
            Control(id: \.brightness, title: "Brightness", symbol: "sun.max", range: -100...100),
            Control(id: \.contrast, title: "Contrast", symbol: "circle.lefthalf.filled", range: -100...100),
            Control(id: \.highlights, title: "Highlights", symbol: "sun.max.circle", range: -100...100),
            Control(id: \.shadows, title: "Shadows", symbol: "moon", range: -100...100),
        ]),
        Group(id: "Color", controls: [
            Control(id: \.saturation, title: "Saturation", symbol: "drop.halffull", range: -100...100),
            Control(id: \.vibrance, title: "Vibrance", symbol: "sparkles", range: -100...100),
            Control(id: \.temperature, title: "Warmth", symbol: "thermometer.medium", range: -100...100),
            Control(id: \.tint, title: "Tint", symbol: "paintpalette", range: -100...100),
            Control(id: \.hue, title: "Hue", symbol: "circle.hexagongrid", range: -100...100),
        ]),
        Group(id: "Detail", controls: [
            Control(id: \.clarity, title: "Clarity", symbol: "camera.aperture", range: 0...100),
            Control(id: \.sharpness, title: "Sharpen", symbol: "triangle", range: 0...100),
            Control(id: \.blur, title: "Blur", symbol: "drop", range: 0...100),
            Control(id: \.vignette, title: "Vignette", symbol: "circle.dashed", range: -100...100),
            Control(id: \.grain, title: "Grain", symbol: "circle.grid.3x3", range: 0...100),
        ]),
    ]

    public func apply(to input: CIImage) -> CIImage {
        let extent = input.extent
        var img = input
        if exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(exposure / 100 * 2); img = f.outputImage!
        }
        if temperature != 0 || tint != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500 + temperature * 35, y: tint * 1.0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage!
        }
        if brightness != 0 || contrast != 0 || saturation != 0 {
            let f = CIFilter.colorControls(); f.inputImage = img
            f.brightness = Float(brightness / 100 * 0.35)
            f.contrast = Float(1 + contrast / 100 * 0.5)
            f.saturation = Float(1 + saturation / 100)
            img = f.outputImage!
        }
        if highlights != 0 || shadows != 0 {
            let f = CIFilter.toneCurve(); f.inputImage = img
            let s = shadows / 100 * 0.15, h = highlights / 100 * 0.15
            f.point0 = CGPoint(x: 0, y: 0)
            f.point1 = CGPoint(x: 0.25, y: 0.25 + s)
            f.point2 = CGPoint(x: 0.5, y: 0.5 + (s + h) / 4)
            f.point3 = CGPoint(x: 0.75, y: 0.75 + h)
            f.point4 = CGPoint(x: 1, y: 1)
            img = f.outputImage!
        }
        if vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(vibrance / 100); img = f.outputImage!
        }
        if hue != 0 {
            let f = CIFilter.hueAdjust(); f.inputImage = img; f.angle = Float(hue / 100 * .pi); img = f.outputImage!
        }
        let scale = max(extent.width, extent.height) / 2000
        if clarity > 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = img
            f.radius = Float(max(4, 20 * scale)); f.intensity = Float(clarity / 100 * 0.8)
            img = f.outputImage!
        }
        if sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = img
            f.sharpness = Float(sharpness / 100 * 2); f.radius = Float(max(1.5, 2.5 * scale))
            img = f.outputImage!
        }
        if blur > 0 {
            img = img.clampedToExtent().applyingGaussianBlur(sigma: blur / 100 * 30 * max(0.5, scale)).cropped(to: extent)
        }
        if vignette != 0 {
            let f = CIFilter.vignetteEffect(); f.inputImage = img
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(max(extent.width, extent.height) * 0.6)
            f.intensity = Float(vignette / 100)
            f.falloff = 0.6
            img = f.outputImage!
        }
        if grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage!
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(grain / 100 * 0.25)),
                ])
                .cropped(to: extent)
            let blend = CIFilter.softLightBlendMode(); blend.inputImage = noise; blend.backgroundImage = img
            img = blend.outputImage!
        }
        return img.cropped(to: extent)
    }
}

/// One-click looks and effects.
public struct Effect: Identifiable {
    public let id: String
    public let name: String
    public let apply: (CIImage) -> CIImage

    public static func photoEffect(_ name: String, _ title: String) -> Effect {
        Effect(id: name, name: title) { $0.applyingFilter(name) }
    }

    public static let all: [Effect] = [
        Effect(id: "auto", name: "Auto") { img in
            img.autoAdjustmentFilters(options: [.redEye: false]).reduce(img) { acc, f in
                f.setValue(acc, forKey: kCIInputImageKey); return f.outputImage ?? acc
            }
        },
        Effect(id: "vivid", name: "Vivid") { img in
            img.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.12, "inputSaturation": 1.15])
        },
        Effect(id: "warm", name: "Warm") { img in
            img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 7800, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        },
        Effect(id: "cool", name: "Cool") { img in
            img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 5200, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        },
        Effect(id: "dramatic", name: "Dramatic") { img in
            img.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.35, "inputSaturation": 0.8, "inputBrightness": -0.04])
                .applyingFilter("CIVignette", parameters: ["inputIntensity": 1.0, "inputRadius": 2.0])
        },
        photoEffect("CIPhotoEffectMono", "Mono"),
        photoEffect("CIPhotoEffectNoir", "Noir"),
        photoEffect("CIPhotoEffectTonal", "Silver"),
        photoEffect("CIPhotoEffectChrome", "Chrome"),
        photoEffect("CIPhotoEffectFade", "Fade"),
        photoEffect("CIPhotoEffectInstant", "Instant"),
        photoEffect("CIPhotoEffectProcess", "Process"),
        photoEffect("CIPhotoEffectTransfer", "Transfer"),
        Effect(id: "sepia", name: "Sepia") { $0.applyingFilter("CISepiaTone", parameters: ["inputIntensity": 0.9]) },
        Effect(id: "vintage", name: "Vintage") { img in
            img.applyingFilter("CISepiaTone", parameters: ["inputIntensity": 0.45])
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 0.9, "inputSaturation": 0.85])
                .applyingFilter("CIVignette", parameters: ["inputIntensity": 1.2, "inputRadius": 1.8])
        },
        Effect(id: "bloom", name: "Glow") { img in
            img.clampedToExtent().applyingFilter("CIBloom", parameters: ["inputRadius": max(img.extent.width, img.extent.height) / 100, "inputIntensity": 0.8]).cropped(to: img.extent)
        },
        Effect(id: "invert", name: "Invert") { $0.applyingFilter("CIColorInvert") },
        Effect(id: "posterize", name: "Poster") { $0.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 5]) },
        Effect(id: "comic", name: "Comic") { $0.applyingFilter("CIComicEffect") },
        Effect(id: "sketch", name: "Sketch") { img in
            img.applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CILineOverlay", parameters: ["inputEdgeIntensity": 1.0, "inputThreshold": 0.1])
                .composited(over: CIImage(color: .white).cropped(to: img.extent))
        },
        Effect(id: "pixelate", name: "Pixelate") { img in
            let s = max(img.extent.width, img.extent.height) / 60
            return img.applyingFilter("CIPixellate", parameters: ["inputScale": max(4, s), "inputCenter": CIVector(x: 0, y: 0)]).cropped(to: img.extent)
        },
        Effect(id: "crystal", name: "Crystal") { img in
            let s = max(img.extent.width, img.extent.height) / 80
            return img.clampedToExtent().applyingFilter("CICrystallize", parameters: ["inputRadius": max(4, s)]).cropped(to: img.extent)
        },
        Effect(id: "blur", name: "Soft Blur") { img in
            img.clampedToExtent().applyingGaussianBlur(sigma: max(img.extent.width, img.extent.height) / 200).cropped(to: img.extent)
        },
        Effect(id: "sharpen", name: "Sharpen") { $0.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 1.2]) },
    ]
}

public enum ImageOps {
    /// Shared GPU-backed context; Core Image picks Metal automatically.
    public static let ciContext = CIContext(options: [
        .workingColorSpace: Bitmap.colorSpace,
        .outputColorSpace: Bitmap.colorSpace,
        .cacheIntermediates: false,
    ])

    public static func render(_ image: CIImage, size: CGSize) -> CGImage? {
        ciContext.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: Bitmap.colorSpace)
    }

    public static func process(_ image: CGImage, _ transform: (CIImage) -> CIImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let size = CGSize(width: image.width, height: image.height)
        // Effects shouldn't paint into transparent areas, so re-apply the original alpha.
        let output = transform(input)
            .unpremultiplyingAlpha()
            .settingAlphaOne(in: input.extent)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: input,
            ])
        return render(output, size: size)
    }

    public static func downscaled(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return Bitmap.render(size) { ctx in
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    /// Bounds of visible pixels in canvas (bottom-up) coordinates, or nil if empty. Ignores the
    /// near-invisible fringe that resampling leaves so boxes don't creep outward on every resize.
    public static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = ctx.bytesPerRow
        var minX = w, maxX = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            let line = data + row * bpr
            var first = -1
            for x in 0..<w where line[x] > 3 { first = x; break }
            guard first >= 0 else { continue }
            var last = first
            for x in stride(from: w - 1, through: first, by: -1) where line[x] > 3 { last = x; break }
            minX = min(minX, first); maxX = max(maxX, last)
            minRow = min(minRow, row); maxRow = max(maxRow, row)
        }
        guard maxX >= 0 else { return nil }
        // Rows are top-down in memory.
        return CGRect(x: minX, y: h - 1 - maxRow, width: maxX - minX + 1, height: maxRow - minRow + 1)
    }

    // MARK: Flood fill

    /// Returns a grayscale mask (white = fill) of the contiguous region around `point`.
    public static func floodMask(_ image: CGImage, at point: CGPoint, tolerance: Double) -> CGImage? {
        let w = image.width, h = image.height
        let x0 = Int(point.x), y0 = Int(point.y)
        guard x0 >= 0, y0 >= 0, x0 < w, y0 < h else { return nil }
        let ctx = Bitmap.context(CGSize(width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)

        // Bitmap rows are stored top-down; canvas y is bottom-up.
        func offset(_ x: Int, _ y: Int) -> Int { (h - 1 - y) * bpr + x * 4 }
        let s = offset(x0, y0)
        let sr = Int(px[s]), sg = Int(px[s + 1]), sb = Int(px[s + 2]), sa = Int(px[s + 3])
        let tol = Int(tolerance * 2.55)

        var mask = [UInt8](repeating: 0, count: w * h)
        @inline(__always) func matches(_ x: Int, _ y: Int) -> Bool {
            let o = offset(x, y)
            return abs(Int(px[o]) - sr) <= tol && abs(Int(px[o + 1]) - sg) <= tol
                && abs(Int(px[o + 2]) - sb) <= tol && abs(Int(px[o + 3]) - sa) <= tol
        }

        var stack: [(Int, Int)] = [(x0, y0)]
        stack.reserveCapacity(1024)
        while let (sx, y) = stack.popLast() {
            var x = sx
            while x > 0 && mask[y * w + x - 1] == 0 && matches(x - 1, y) { x -= 1 }
            var spanUp = false, spanDown = false
            while x < w && mask[y * w + x] == 0 && matches(x, y) {
                mask[y * w + x] = 255
                if y + 1 < h {
                    let m = mask[(y + 1) * w + x] == 0 && matches(x, y + 1)
                    if m && !spanUp { stack.append((x, y + 1)) }
                    spanUp = m
                }
                if y > 0 {
                    let m = mask[(y - 1) * w + x] == 0 && matches(x, y - 1)
                    if m && !spanDown { stack.append((x, y - 1)) }
                    spanDown = m
                }
                x += 1
            }
        }

        // Flip rows so the mask is in the same top-down layout CGImage expects.
        var flipped = [UInt8](repeating: 0, count: w * h)
        mask.withUnsafeBufferPointer { src in
            flipped.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let from = src.baseAddress! + y * w
                    let to = dst.baseAddress! + (h - 1 - y) * w
                    to.update(from: from, count: w)
                }
            }
        }
        let provider = CGDataProvider(data: Data(flipped) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Reads one composited pixel.
    public static func color(in image: CGImage, at point: CGPoint) -> NSColor? {
        guard point.x >= 0, point.y >= 0, Int(point.x) < image.width, Int(point.y) < image.height else { return nil }
        let ctx = Bitmap.context(CGSize(width: 1, height: 1))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -floor(point.x), y: -floor(point.y), width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return nil }
        let a = CGFloat(p[3]) / 255
        guard a > 0 else { return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        return NSColor(srgbRed: CGFloat(p[0]) / 255 / a, green: CGFloat(p[1]) / 255 / a, blue: CGFloat(p[2]) / 255 / a, alpha: 1)
    }

    // MARK: Background removal

    /// On-device Vision subject detection. Returns a soft mask (white = subject), or nil if no subject.
    public static func subjectMask(_ image: CGImage) throws -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: mask)
    }

    /// Keeps the subject and puts `background(original)` behind it.
    public static func replaceBackground(_ image: CGImage, with background: (CIImage) -> CIImage) throws -> CGImage? {
        guard let mask = try subjectMask(image) else { return nil }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background(input),
            kCIInputMaskImageKey: mask,
        ])
        return render(output, size: CGSize(width: image.width, height: image.height))
    }

    public static func removeBackground(_ image: CGImage) throws -> CGImage? {
        try replaceBackground(image) { _ in CIImage.empty() }
    }

    public static func blurBackground(_ image: CGImage) throws -> CGImage? {
        try replaceBackground(image) { input in
            let sigma = max(input.extent.width, input.extent.height) / 90
            return input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        }
    }

    public static func colorBackground(_ image: CGImage, color: CGColor) throws -> CGImage? {
        try replaceBackground(image) { input in
            CIImage(color: CIColor(cgColor: color)).cropped(to: input.extent)
        }
    }
}
