import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

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

    // MARK: Link colour (platform-neutral)

    /// Parse "#RRGGBB" → Color; empty/invalid falls back to the accent colour.
    static func linkColor(hex: String) -> Color {
        guard let rgb = rgb(fromHex: hex) else { return .accentColor }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Serialize a Color to "#RRGGBB" (empty if it can't be resolved to sRGB).
    static func hex(_ color: Color) -> String {
        #if canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return format(ns.redComponent, ns.greenComponent, ns.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "" }
        return format(r, g, b)
        #endif
    }

    private static func format(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private static func rgb(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#"), s.count == 7, let v = Int(s.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    // MARK: Fonts

    /// Picker choices. The first four are system designs (always resolve); the rest are named
    /// families with a system fallback.
    static let choices = ["System", "Serif", "Rounded", "Monospaced", "Georgia", "Helvetica Neue", "Menlo"]

    static func font(name: String, size: Double) -> Font {
        switch name {
        case "System": .system(size: size)
        case "Serif": .system(size: size, design: .serif)
        case "Rounded": .system(size: size, design: .rounded)
        case "Monospaced": .system(size: size, design: .monospaced)
        default: .custom(name, size: size)
        }
    }

    #if os(macOS)
    // NSColor/NSFont variants for the AppKit NSTextView post body (RichTextLabel, macOS only).
    static func nsLinkColor(hex: String) -> NSColor {
        guard let rgb = rgb(fromHex: hex) else { return .controlAccentColor }
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

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
    #endif
}
