import AppKit
import CoreGraphics
import ImageIO

/// Helpers for creating and drawing 8-bit premultiplied sRGB bitmaps.
public enum Bitmap {
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func context(_ size: CGSize) -> CGContext {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        return ctx
    }

    public static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = context(size)
        draw(ctx)
        return ctx.makeImage()!
    }

    public static func blank(_ size: CGSize) -> CGImage { render(size) { _ in } }

    public static func filled(_ size: CGSize, color: CGColor) -> CGImage {
        render(size) { ctx in
            ctx.setFillColor(color)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Returns a copy of `image` placed on a canvas of `size`, keeping only `clip` (if any)
    /// from `edited` and everything else from `original`.
    public static func merge(original: CGImage, edited: CGImage, clip: CGRect?, size: CGSize) -> CGImage {
        guard let clip else { return edited }
        return render(size) { ctx in
            let full = CGRect(origin: .zero, size: size)
            ctx.draw(original, in: full)
            ctx.clip(to: clip)
            ctx.clear(clip)
            ctx.draw(edited, in: full)
        }
    }

    public static func load(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: src)
    }

    public static func load(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: src)
    }

    /// Decodes with EXIF orientation applied.
    private static func load(source: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if max(w, h) > 0, let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return img
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public static func cgImage(from nsImage: NSImage) -> CGImage? {
        if let tiff = nsImage.tiffRepresentation, let img = load(data: tiff) { return img }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
