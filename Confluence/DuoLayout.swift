import SwiftUI
import ConfluenceKit

// ponytail: inline search and per-network filtered feeds are placeholders — each needs a
// dedicated inline view before it can be enabled. See docs/GAPS.md G18.

/// Which view fills the left (secondary) column when the Duo is unfolded in landscape.
enum DuoSecondaryPanel: String, CaseIterable {
    case dms = "dms"
    case search = "search"
    case blueskyFeed = "bluesky"
    case mastodonFeed = "mastodon"

    var label: String {
        switch self {
        case .dms: "Messages"
        case .search: "Search"
        case .blueskyFeed: "Bluesky Feed"
        case .mastodonFeed: "Mastodon Feed"
        }
    }

    var systemImage: String {
        switch self {
        case .dms: "envelope"
        case .search: "magnifyingglass"
        case .blueskyFeed: "bubble.left"
        case .mastodonFeed: "tusk"
        }
    }
}

/// Adaptive root for iOS: on an iPhone with a regular horizontal size class (Duo unfolded in
/// landscape, or Plus/Max in landscape) this renders a split view with the primary feed on the
/// right and a configurable secondary panel on the left. All other configurations — portrait,
/// folded front screen, iPad — fall through to the standard single-column FeedView.
struct DuoLayout: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @AppStorage("duo.secondaryPanel") private var panel: DuoSecondaryPanel = .dms

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone, horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                DuoSecondaryPanelView(panel: panel)
                    .frame(maxWidth: .infinity)
                Divider()
                FeedView()
                    .frame(maxWidth: .infinity)
            }
        } else {
            FeedView()
        }
        #else
        FeedView()
        #endif
    }
}

/// The left-column secondary panel rendered inline (no modal chrome).
private struct DuoSecondaryPanelView: View {
    let panel: DuoSecondaryPanel

    var body: some View {
        switch panel {
        case .dms:
            NavigationStack {
                DirectMessagesView(isInline: true)
            }
        case .search, .blueskyFeed, .mastodonFeed:
            ContentUnavailableView(
                panel.label,
                systemImage: panel.systemImage,
                description: Text("This panel is coming soon.")
            )
        }
    }
}
