import Foundation

/// Plain-language edits that work without Apple Intelligence ("warmer", "a bit brighter", "moody").
public enum KeywordEdits {
    public static func key(for path: WritableKeyPath<Adjustments, Double>) -> String {
        Adjustments.groups.flatMap(\.controls).first { $0.id == path }.map { title in
            switch title.title {
            case "Warmth": return "temperature"
            case "Sharpen": return "sharpness"
            default: return title.title.lowercased()
            }
        } ?? "unknown"
    }

    public static func path(for key: String) -> WritableKeyPath<Adjustments, Double>? {
        Adjustments.groups.flatMap(\.controls).first { self.key(for: $0.id) == key.lowercased() }?.id
    }

    private static let phrases: [(words: [String], changes: [String: Double])] = [
        (["black and white", "black & white", "b&w", "monochrome", "grayscale", "greyscale"], ["saturation": -100]),
        (["vintage", "retro", "old photo", "film"], ["temperature": 25, "contrast": -15, "saturation": -25, "grain": 35, "vignette": 30]),
        (["moody", "dark and moody", "cinematic"], ["exposure": -15, "contrast": 25, "saturation": -25, "shadows": -20, "vignette": 35]),
        (["dramatic", "punchy"], ["contrast": 40, "clarity": 40, "vignette": 25]),
        (["dreamy", "soft", "softer", "glow"], ["blur": 8, "highlights": 20, "contrast": -15]),
        (["vivid", "pop", "vibrant", "colorful", "colourful"], ["vibrance": 40, "saturation": 15, "contrast": 10]),
        (["muted", "faded", "matte", "washed out"], ["saturation": -35, "contrast": -25, "shadows": 25]),
        (["warmer", "warm", "golden", "sunset"], ["temperature": 30]),
        (["cooler", "cool", "colder", "cold", "blue"], ["temperature": -30]),
        (["brighter", "bright", "lighter", "lighten"], ["exposure": 25]),
        (["darker", "dark", "darken"], ["exposure": -25]),
        (["more contrast", "contrast"], ["contrast": 30]),
        (["less contrast", "flat"], ["contrast": -30]),
        (["sharper", "sharpen", "crisp", "crisper", "detail"], ["sharpness": 40, "clarity": 20]),
        (["blurry", "blur"], ["blur": 20]),
        (["saturated", "more color", "more colour"], ["saturation": 30]),
        (["desaturate", "less color", "less colour"], ["saturation": -30]),
        (["recover highlights", "less highlights", "brighter sky", "sky"], ["highlights": -35]),
        (["lift shadows", "brighter shadows", "shadow detail"], ["shadows": 35]),
        (["vignette"], ["vignette": 40]),
        (["grain", "grainy", "noise"], ["grain": 40]),
        (["green"], ["tint": -25]),
        (["magenta", "pink"], ["tint": 25]),
    ]

    /// Returns slider changes for the recognised phrases, longest phrases first so "less contrast"
    /// beats "contrast". Words like "slightly" or "very" scale the result.
    public static func parse(_ text: String) -> [String: Double] {
        var remaining = " " + text.lowercased().replacingOccurrences(of: ",", with: " ") + " "
        var result: [String: Double] = [:]
        let ordered = phrases.flatMap { p in p.words.map { ($0, p.changes) } }.sorted { $0.0.count > $1.0.count }
        for (phrase, changes) in ordered where remaining.contains(" \(phrase) ") {
            remaining = remaining.replacingOccurrences(of: " \(phrase) ", with: " ")
            for (k, v) in changes { result[k, default: 0] += v }
        }
        let t = text.lowercased()
        let factor: Double = ["slightly", "a bit", "a little", "subtle", "touch"].contains { t.contains($0) } ? 0.5
            : (["very", "much", "lot", "really", "super", "way"].contains { t.contains($0) } ? 1.7 : 1)
        return result.mapValues { $0 * factor }
    }
}
