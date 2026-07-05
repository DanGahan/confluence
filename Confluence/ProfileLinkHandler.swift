import SwiftUI
import AppKit
import ConfluenceKit

private struct ProfileTarget: Identifiable {
    let network: Network
    let accountID: String
    let handle: String
    var id: String { "\(network.rawValue):\(accountID)" }
}

/// Routes tapped links: an in-app profile link (@-mention) opens ProfileView; any other
/// URL (web link) opens in the default browser.
private struct ProfileLinkHandler: ViewModifier {
    @State private var target: ProfileTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let profile = ProfileLink.parse(url) {
                    target = ProfileTarget(network: profile.network, accountID: profile.id, handle: profile.handle)
                    return .handled
                }
                if let handle = ProfileLink.blueskyWebProfileHandle(url) {
                    target = ProfileTarget(network: .bluesky, accountID: handle, handle: handle)
                    return .handled
                }
                // Open web links ourselves: `.systemAction` returned from a programmatically
                // invoked OpenURLAction (our NSTextView delegate calls this) doesn't reliably
                // open, which left every post link dead.
                NSWorkspace.shared.open(url)
                return .handled
            })
            .sheet(item: $target) { t in
                ProfileView(network: t.network, authorID: t.accountID, handle: t.handle)
            }
    }
}

extension View {
    /// Makes @-mention links open ProfileView and web links open in the browser.
    func handleProfileLinks() -> some View { modifier(ProfileLinkHandler()) }
}
