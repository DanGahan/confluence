import SwiftUI
import AppKit

/// User-configurable font for post bodies (Settings → Fonts & Colors), persisted in
/// UserDefaults and read via @AppStorage at each render site so changes apply live.
enum PostAppearance {
    static let fontNameKey = "postFontName"
    static let fontSizeKey = "postFontSize"
    static let linkColorKey = "postLinkColorHex"
    static let defaultName = "System"
    static let defaultSize = 13.0
    static let minSize = 10.0
    static let maxSize = 22.0
    /// Empty means "use the system accent colour".
    static let defaultLinkColorHex = ""

    // MARK: Link colour

    static func linkColor(hex: String) -> Color {
        nsColor(hex: hex).map(Color.init) ?? .accentColor
    }

    static func nsLinkColor(hex: String) -> NSColor {
        nsColor(hex: hex) ?? .controlAccentColor
    }

    static func hex(_ color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }

    private static func nsColor(hex: String) -> NSColor? {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#"), s.count == 7, let v = Int(s.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Picker choices. The first four are system designs (always resolve); the rest are named
    /// families with a system fallback.
    static let choices = ["System", "Serif", "Rounded", "Monospaced", "Georgia", "Helvetica Neue", "Menlo"]

    private static func design(_ name: String) -> NSFontDescriptor.SystemDesign? {
        switch name {
        case "System": .default
        case "Serif": .serif
        case "Rounded": .rounded
        case "Monospaced": .monospaced
        default: nil
        }
    }

    static func nsFont(name: String, size: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let design = design(name) {
            if let d = base.fontDescriptor.withDesign(design) { return NSFont(descriptor: d, size: size) ?? base }
            return base
        }
        return NSFont(name: name, size: size) ?? base
    }

    static func font(name: String, size: Double) -> Font {
        switch name {
        case "System": .system(size: size)
        case "Serif": .system(size: size, design: .serif)
        case "Rounded": .system(size: size, design: .rounded)
        case "Monospaced": .system(size: size, design: .monospaced)
        default: .custom(name, size: size)
        }
    }
}
