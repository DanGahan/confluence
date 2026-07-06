import Testing
import AppKit
@testable import ConfluenceKit

@MainActor
struct LinkGeometryTests {
    /// Build a laid-out TextKit 1 stack for an attributed string, mirroring RichTextLabel.
    private func laidOut(_ attr: NSAttributedString, width: CGFloat = 300)
        -> (NSLayoutManager, NSTextContainer, NSTextStorage) {
        let ts = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager(); ts.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return (lm, tc, ts)
    }

    private func sample() -> NSMutableAttributedString {
        let s = NSMutableAttributedString(string: "see https://example.com now")
        s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: s.length))
        let range = (s.string as NSString).range(of: "https://example.com")
        s.addAttribute(.link, value: URL(string: "https://example.com")!, range: range)
        return s
    }

    @Test func linkRectsCoverTheLink() {
        let (lm, tc, ts) = laidOut(sample())
        let rects = LinkGeometry.linkRects(layoutManager: lm, textContainer: tc, textStorage: ts)
        #expect(!rects.isEmpty)          // regression guard: cursor rects must exist over links
        #expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    @Test func pointOverLinkResolvesURL() {
        let (lm, tc, ts) = laidOut(sample())
        let rect = LinkGeometry.linkRects(layoutManager: lm, textContainer: tc, textStorage: ts)[0]
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        #expect(LinkGeometry.linkURL(at: mid, layoutManager: lm, textContainer: tc, textStorage: ts)?
            .absoluteString == "https://example.com")
    }

    @Test func pointOnPlainTextIsNotALink() {
        let (lm, tc, ts) = laidOut(sample())
        let y = LinkGeometry.linkRects(layoutManager: lm, textContainer: tc, textStorage: ts)[0].midY
        // The leading "see " is at x≈1 — not linked.
        #expect(LinkGeometry.linkURL(at: CGPoint(x: 1, y: y), layoutManager: lm, textContainer: tc, textStorage: ts) == nil)
    }

    @Test func noLinkNoRects() {
        let plain = NSAttributedString(string: "just text", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let (lm, tc, ts) = laidOut(plain)
        #expect(LinkGeometry.linkRects(layoutManager: lm, textContainer: tc, textStorage: ts).isEmpty)
        #expect(LinkGeometry.linkURL(at: CGPoint(x: 5, y: 5), layoutManager: lm, textContainer: tc, textStorage: ts) == nil)
    }
}
