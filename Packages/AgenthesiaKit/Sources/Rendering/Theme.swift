public import AppKit

/// Colors and fonts for rendered text. Colors are dynamic: they resolve for the current appearance.
public struct Theme: Sendable {
    /// The default theme, following the system appearance.
    public static let standard = Theme()

    /// The point size of body text; code is one point smaller.
    public var fontSize: CGFloat

    public init(fontSize: CGFloat = NSFont.systemFontSize) {
        self.fontSize = fontSize
    }

    public var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    public var codeFont: NSFont { .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) }

    /// The font for a heading of `level` (1 is the largest).
    public func headingFont(level: Int) -> NSFont {
        let scale: CGFloat =
            switch level {
            case 1: 1.6
            case 2: 1.35
            case 3: 1.15
            default: 1
            }
        return .systemFont(ofSize: (fontSize * scale).rounded(), weight: level <= 3 ? .bold : .semibold)
    }

    /// The space after a paragraph or block.
    public var blockSpacing: CGFloat { (fontSize * 0.6).rounded() }
    /// The space after a list item.
    public var itemSpacing: CGFloat { (fontSize * 0.2).rounded() }
    /// The indentation of a nested level: a list or a quote.
    public var indent: CGFloat { (fontSize * 1.6).rounded() }

    public var textColor: NSColor { .labelColor }
    public var secondaryTextColor: NSColor { .secondaryLabelColor }
    public var linkColor: NSColor { .linkColor }
    public var codeBackgroundColor: NSColor { .quaternarySystemFill }
    public var quoteBarColor: NSColor { .tertiaryLabelColor }

    /// The color for a tree-sitter highlight capture such as `keyword.function` or `string.special`.
    ///
    /// The most specific known prefix wins: `keyword.function` falls back to `keyword`.
    public func color(forCapture name: String) -> NSColor? {
        var components = name.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let color = Self.captureColors[components.joined(separator: ".")] {
                return color
            }
            components.removeLast()
        }
        return nil
    }

    /// Capture names and their colors, modeled on Xcode's default theme.
    static let captureColors: [String: NSColor] = [
        "keyword": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "conditional": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "repeat": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "include": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "exception": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "boolean": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "string": .dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        "character": .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        "string.escape": .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        "string.regex": .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        "escape": .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        "comment": .dynamic(light: 0x5D6C79, dark: 0x6C7986),
        "number": .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        "float": .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        "constant": .dynamic(light: 0x326D74, dark: 0x67B7A4),
        "constant.builtin": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "type": .dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        "type.builtin": .dynamic(light: 0x3900A0, dark: 0xD0A8FF),
        "constructor": .dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        "function": .dynamic(light: 0x326D74, dark: 0x67B7A4),
        "method": .dynamic(light: 0x326D74, dark: 0x67B7A4),
        "function.builtin": .dynamic(light: 0x6C36A9, dark: 0xA167E6),
        "property": .dynamic(light: 0x326D74, dark: 0x67B7A4),
        "attribute": .dynamic(light: 0x643820, dark: 0xBF8555),
        "label": .dynamic(light: 0x643820, dark: 0xBF8555),
        "tag": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "namespace": .dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        "module": .dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        "variable.builtin": .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        "punctuation.special": .dynamic(light: 0x643820, dark: 0xBF8555),
        "text.title": .dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        "text.literal": .dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        "text.uri": .dynamic(light: 0x0E0EFF, dark: 0x6699FF),
        "markup.heading": .dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        "markup.raw": .dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        "markup.link": .dynamic(light: 0x0E0EFF, dark: 0x6699FF),
    ]
}

extension NSColor {
    /// A color that resolves to `light` or `dark` (0xRRGGBB) for the current appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }

    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
