import EaselKit
import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case move, select, crop, brush, eraser, fill, gradient, shape, text, eyedropper, hand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return "Move"
        case .select: return "Select"
        case .crop: return "Crop"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .gradient: return "Gradient"
        case .shape: return "Shapes"
        case .text: return "Text"
        case .eyedropper: return "Color Picker"
        case .hand: return "Hand"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .select: return "rectangle.dashed"
        case .crop: return "crop"
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .fill: return "drop.fill"
        case .gradient: return "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .shape: return "square.on.circle"
        case .text: return "textformat"
        case .eyedropper: return "eyedropper"
        case .hand: return "hand.raised.fill"
        }
    }

    /// Single-key shortcut, Photoshop-compatible where it makes sense.
    var key: Character {
        switch self {
        case .move: return "v"
        case .select: return "m"
        case .crop: return "c"
        case .brush: return "b"
        case .eraser: return "e"
        case .fill: return "f"
        case .gradient: return "g"
        case .shape: return "u"
        case .text: return "t"
        case .eyedropper: return "i"
        case .hand: return "h"
        }
    }

    var hint: String {
        switch self {
        case .move: return "Drag to move. Corner handles resize; the round handle (or just outside a corner) rotates. ⇧ snaps to 15°."
        case .select: return "Drag to select an area. Edits stay inside the selection."
        case .crop: return "Drag a box, then press Return to crop."
        case .brush: return "Paint. Hold ⌥ to pick a color, ⇧ for straight lines."
        case .eraser: return "Erase to transparency."
        case .fill: return "Click to fill an area with the color."
        case .gradient: return "Drag to draw a gradient between your two colors."
        case .shape: return "Drag to draw a shape. Hold ⇧ to keep it even."
        case .text: return "Click where you want text."
        case .eyedropper: return "Click to pick a color from the image."
        case .hand: return "Drag to pan. Pinch or ⌘-scroll to zoom."
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case rectangle, rounded, ellipse, line, arrow, star
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .rounded: return "app"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .star: return "star"
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9", nineSixteen = "9:16"
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        }
    }
}
