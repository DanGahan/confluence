import SwiftUI
import ConfluenceKit

#if os(macOS)
import AppKit

/// Read-only, selectable post body backed by NSTextView.
///
/// SwiftUI's `Text` on macOS can't do clickable links inside the feed's scroll machinery —
/// link taps never fire there (verified; they do work in plain sheets). NSTextView gives
/// links, the pointing-hand hover cursor, and selection natively — but SwiftUI positions the
/// AppKit platform views unreliably inside the LazyVStack: some rows' clicks hit-test into
/// the wrong view, so links rendered fine yet never received the click (#69).
///
/// Fix: `LinkClickRouter`, a window-level event monitor that sees every left-click before
/// SwiftUI/AppKit dispatch. It asks each *registered, visible* text view directly whether the
/// click lands on one of its link glyphs (no hit-testing, so stale platform-view frames can't
/// misroute), opens the link, and consumes the event. Everything else passes through.
struct RichTextLabel: NSViewRepresentable {
    let attributed: AttributedString
    let openURL: OpenURLAction
    var fontName: String = PostAppearance.defaultName
    var fontSize: Double = PostAppearance.defaultSize
    var linkColorHex: String = PostAppearance.defaultLinkColorHex

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeNSView(context: Context) -> LinkTextView {
        LinkClickRouter.install()
        // Explicit TextKit 1 stack: NSTextView() alone may default to TextKit 2, where
        // `layoutManager`/`usedRect(for:)` are nil and sizeThatFits can't measure height.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = LinkTextView(frame: .zero, textContainer: container)
        tv.onOpenLink = { [weak coordinator = context.coordinator] url in coordinator?.openURL(url) }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.focusRingType = NSFocusRingType.none
        tv.textContainerInset = NSSize.zero
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.delegate = context.coordinator
        tv.linkTextAttributes = [
            NSAttributedString.Key.foregroundColor: NSColor.controlAccentColor,
            NSAttributedString.Key.cursor: NSCursor.pointingHand,
        ]
        LinkClickRouter.register(tv)
        return tv
    }

    func updateNSView(_ tv: LinkTextView, context: Context) {
        context.coordinator.openURL = openURL
        tv.linkTextAttributes = [
            NSAttributedString.Key.foregroundColor: PostAppearance.nsLinkColor(hex: linkColorHex),
            NSAttributedString.Key.cursor: NSCursor.pointingHand,
        ]
        tv.textStorage?.setAttributedString(Self.nsAttributed(attributed, font: PostAppearance.nsFont(name: fontName, size: fontSize)))
        tv.window?.invalidateCursorRects(for: tv) // rebuild link cursor rects for the new layout
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: LinkTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width != .infinity,
              let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(lm.usedRect(for: container).height))
    }

    private static func nsAttributed(_ attributed: AttributedString, font: NSFont) -> NSAttributedString {
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: ns.length)
        // Base style; link runs keep their `.link` and display via linkTextAttributes.
        ns.addAttribute(.font, value: font, range: full)
        ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        return ns
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }

        // Fallback: fires only when the router passed the event through and AppKit happened
        // to deliver the click to this view normally.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            openURL(url) // routed by .handleProfileLinks(): profile links -> sheet, else browser
            return true
        }
    }
}

/// NSTextView that can resolve which link (if any) sits at a point, and open it.
final class LinkTextView: NSTextView {
    var onOpenLink: ((URL) -> Void)?

    // Over a link, keep the native link menu (Open/Copy Link). Elsewhere return nil so the
    // right-click falls through to the enclosing SwiftUI row's post menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        link(at: convert(event.locationInWindow, from: nil)) != nil ? super.menu(for: event) : nil
    }

    // Rebuild cursor rects after every layout pass, so the pointing-hand rects use settled
    // geometry (computing them before layout gave empty/wrong rects — the recurring bug).
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    // Pointing-hand cursor over links via cursor rects (AppKit-managed; reliable). Geometry
    // comes from the unit-tested LinkGeometry so this can't silently regress.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let inset = CGSize(width: textContainerInset.width, height: textContainerInset.height)
        for rect in LinkGeometry.linkRects(layoutManager: lm, textContainer: tc, textStorage: ts) {
            addCursorRect(rect.offsetBy(dx: inset.width, dy: inset.height), cursor: .pointingHand)
        }
    }

    /// The link at `point` (view coordinates), or nil. Delegates to the tested geometry.
    func link(at point: NSPoint) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return nil }
        let p = CGPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height)
        return LinkGeometry.linkURL(at: p, layoutManager: lm, textContainer: tc, textStorage: ts)
    }
}

/// Window-level router for link clicks — see RichTextLabel's doc comment for why.
@MainActor
enum LinkClickRouter {
    private static let views = NSHashTable<LinkTextView>.weakObjects()
    private static var installed = false

    static func register(_ tv: LinkTextView) { views.add(tv) }

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let window = event.window else { return event }
            // Clicks in window chrome (titlebar / tab bar / toolbar) must never reach post
            // content drawn beneath it — otherwise closing a tab opens a link underneath (#93).
            // contentLayoutRect excludes that chrome; a click outside it isn't a post click.
            // Skip the check if the rect is degenerate so we never suppress real link clicks.
            let contentRect = window.contentLayoutRect
            if let content = window.contentView, !contentRect.isEmpty,
               !contentRect.contains(content.convert(event.locationInWindow, from: nil)) {
                return event
            }
            for tv in views.allObjects {
                guard tv.window === window, !tv.isHiddenOrHasHiddenAncestor,
                      !tv.visibleRect.isEmpty else { continue }
                let p = tv.convert(event.locationInWindow, from: nil)
                guard tv.bounds.contains(p), let url = tv.link(at: p) else { continue }
                tv.onOpenLink?(url)
                // ponytail: consuming here means a drag-select can't *start* on a link
                // glyph; selection anywhere else is unaffected. Fine trade for working links.
                return nil
            }
            return event
        }
    }
}

#else
/// iOS post body. The macOS NSTextView apparatus (LinkClickRouter et al.) exists to patch
/// macOS-only SwiftUI bugs; on iOS plain `Text` renders `.link` runs with working taps, so this
/// is the whole implementation. ponytail: revisit under the #163 rich-text spike if links or
/// selection misbehave in the feed's LazyVStack.
struct RichTextLabel: View {
    let attributed: AttributedString
    let openURL: OpenURLAction
    var fontName: String = PostAppearance.defaultName
    var fontSize: Double = PostAppearance.defaultSize
    var linkColorHex: String = PostAppearance.defaultLinkColorHex

    var body: some View {
        // No .textSelection here: on iOS selectable Text swallows the tap that should fall
        // through to the row's tap-to-reply gesture (and long-press → the post context menu).
        // Link runs still tap through to openURL. Selection is a macOS-only affordance.
        Text(attributed)
            .font(PostAppearance.font(name: fontName, size: fontSize))
            .tint(PostAppearance.linkColor(hex: linkColorHex))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, openURL)
    }
}
#endif
