import AppKit

/// Hit-testing + cursor-rect geometry over `.link` runs in a laid-out TextKit 1 container.
///
/// This is the logic that drives BOTH link clicks and the hover (pointing-hand) cursor in the
/// feed's NSTextView. It has regressed repeatedly when it lived in the view layer, so it's
/// extracted here and unit-tested — `RichTextLabel` is now a thin caller.
public enum LinkGeometry {
    /// The link URL at `point` (text-container coordinates), or nil if the point isn't on a
    /// linked glyph. `slop` gives a small hit tolerance around each glyph.
    public static func linkURL(at point: CGPoint,
                               layoutManager lm: NSLayoutManager,
                               textContainer tc: NSTextContainer,
                               textStorage ts: NSTextStorage,
                               slop: CGFloat = 2) -> URL? {
        guard ts.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let idx = lm.characterIndex(for: point, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard idx < ts.length else { return nil }
        // characterIndex clamps to the nearest glyph, so verify the point is actually inside it.
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: idx, length: 1), actualCharacterRange: nil)
        guard lm.boundingRect(forGlyphRange: glyphs, in: tc).insetBy(dx: -slop, dy: -slop).contains(point) else { return nil }
        let value = ts.attribute(.link, at: idx, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    /// Per-line bounding rects (container coordinates) of every `.link` run, for cursor rects.
    public static func linkRects(layoutManager lm: NSLayoutManager,
                                 textContainer tc: NSTextContainer,
                                 textStorage ts: NSTextStorage) -> [CGRect] {
        guard ts.length > 0 else { return [] }
        var rects: [CGRect] = []
        ts.enumerateAttribute(.link, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: tc) { rect, _ in rects.append(rect) }
        }
        return rects
    }
}
