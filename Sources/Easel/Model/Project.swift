import EaselKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Layered Easel document. Declared in the app's Info.plist.
    static let easelProject = UTType(exportedAs: "app.easel.project", conformingTo: .data)
}

/// On-disk layered document: a binary property list with one PNG per layer.
struct ProjectFile: Codable {
    struct LayerData: Codable {
        var name: String
        var png: Data
        var visible: Bool
        var opacity: Double
        var blend: String
        var text: TextInfo?
    }

    var version = 1
    var width: Double
    var height: Double
    var activeIndex: Int
    var layers: [LayerData]

    init(canvasSize: CGSize, layers: [Layer], activeIndex: Int) throws {
        width = canvasSize.width
        height = canvasSize.height
        self.activeIndex = activeIndex
        // Layers encode independently, so do them in parallel.
        var encoded = [Data?](repeating: nil, count: layers.count)
        encoded.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: layers.count) { i in
                out[i] = Bitmap.png(layers[i].image)
            }
        }
        self.layers = try layers.enumerated().map { i, l in
            guard let png = encoded[i] else { throw CocoaError(.fileWriteUnknown) }
            return LayerData(name: l.name, png: png, visible: l.isVisible, opacity: l.opacity, blend: l.blendMode.rawValue, text: l.text)
        }
    }

    func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ProjectFile {
        try PropertyListDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
    }

    func makeLayers() throws -> [Layer] {
        let size = CGSize(width: width, height: height)
        return try layers.map { d in
            guard let decoded = Bitmap.load(data: d.png) else { throw CocoaError(.fileReadCorruptFile) }
            // Re-draw onto a canvas-sized bitmap in case the stored image differs in size or format.
            let image = Bitmap.render(size) { $0.draw(decoded, in: CGRect(origin: .zero, size: size)) }
            var layer = Layer(name: d.name, image: image)
            layer.isVisible = d.visible
            layer.opacity = d.opacity
            layer.blendMode = BlendMode(rawValue: d.blend) ?? .normal
            layer.text = d.text
            return layer
        }
    }
}
