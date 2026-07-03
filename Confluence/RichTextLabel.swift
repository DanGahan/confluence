import SwiftUI
import AppKit

/// Read-only, selectable post body backed by NSTextView.
///
/// SwiftUI's `Text` on macOS can't do clickable links and text selection at the same time —
/// `.textSelection(.enabled)` swallows the click, so links need a double-click and then only
/// select. NSTextView does links, the pointing-hand hover cursor, and selection natively.
/// Link taps route through the SwiftUI `openURL` environment so confluence-profile:// mentions
/// still open ProfileView while web links open in the browser.
struct RichTextLabel: NSViewRepresentable {
    let attributed: AttributedString
    let openURL: OpenURLAction

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeNSView(context: Context) -> NSTextView {
        // Explicit TextKit 1 stack: NSTextView() alone may default to TextKit 2, where
        // `layoutManager`/`usedRect(for:)` are nil and sizeThatFits can't measure height.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
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
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.openURL = openURL
        tv.textStorage?.setAttributedString(Self.nsAttributed(attributed))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width != .infinity,
              let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(lm.usedRect(for: container).height))
    }

    private static func nsAttributed(_ attributed: AttributedString) -> NSAttributedString {
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: ns.length)
        // Base style; link runs keep their `.link` and display via linkTextAttributes.
        ns.addAttribute(.font, value: NSFont.preferredFont(forTextStyle: .body), range: full)
        ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        return ns
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            openURL(url) // routed by .handleProfileLinks(): profile links -> sheet, else browser
            return true
        }
    }
}
