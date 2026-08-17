import SwiftUI
import ConfluenceKit

private struct ProfileTarget: Identifiable {
    let network: Network
    let accountID: String
    let handle: String
    var id: String { "\(network.rawValue):\(accountID)" }
}

/// What a tapped link opened, as a single sheet source (SwiftUI dislikes stacking multiple
/// `.sheet(item:)` on one view).
private enum LinkSheet: Identifiable {
    case profile(ProfileTarget)
    case thread(FeedItem)
    #if os(iOS)
    case web(URL)
    #endif
    var id: String {
        switch self {
        case .profile(let t): return "profile:\(t.id)"
        case .thread(let item): return "thread:\(item.id)"
        #if os(iOS)
        case .web(let url): return "web:\(url.absoluteString)"
        #endif
        }
    }
}

/// Routes tapped links: an in-app profile link (@-mention) opens ProfileView; a Mastodon
/// status permalink resolves onto the user's instance and opens its thread; any other URL
/// opens in the default browser.
private struct ProfileLinkHandler: ViewModifier {
    @Environment(MastodonAccountStore.self) private var mastodon
    #if os(iOS)
    @AppStorage(BrowsingPreference.openLinksInAppKey) private var openLinksInApp = BrowsingPreference.openLinksInAppDefault
    #endif
    @State private var sheet: LinkSheet?
    @State private var resolvingStatus: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let profile = ProfileLink.parse(url) {
                    sheet = .profile(ProfileTarget(network: profile.network, accountID: profile.id, handle: profile.handle))
                    return .handled
                }
                if let handle = ProfileLink.blueskyWebProfileHandle(url) {
                    sheet = .profile(ProfileTarget(network: .bluesky, accountID: handle, handle: handle))
                    return .handled
                }
                // A Mastodon status permalink → open its thread in-app. Needs a Mastodon
                // session to resolve the (usually remote) status onto the user's instance;
                // without one, fall through to the browser.
                if mastodon.session != nil, ProfileLink.looksLikeMastodonStatus(url) {
                    resolvingStatus = url
                    return .handled
                }
                #if os(iOS)
                // iOS: open external web links in the in-app browser (default), as a sheet like
                // the thread/profile screens. Off → system browser.
                if openLinksInApp, url.scheme == "http" || url.scheme == "https" {
                    sheet = .web(url)
                    return .handled
                }
                #endif
                // Open web links ourselves: `.systemAction` returned from a programmatically
                // invoked OpenURLAction (our NSTextView delegate calls this) doesn't reliably
                // open, which left every post link dead.
                openExternally(url)
                return .handled
            })
            .task(id: resolvingStatus) { await resolveStatus() }
            .sheet(item: $sheet) { s in
                switch s {
                case .profile(let t): ProfileView(network: t.network, authorID: t.accountID, handle: t.handle)
                case .thread(let item): ThreadView(item: item)
                #if os(iOS)
                case .web(let url): SafariView(url: url).ignoresSafeArea()
                #endif
                }
            }
    }

    /// Resolves a tapped Mastodon status URL to a local status (via search on the user's
    /// instance) and opens its thread. Falls back to the browser if it can't be resolved.
    private func resolveStatus() async {
        guard let url = resolvingStatus, let session = mastodon.session else { return }
        let results = await MastodonClient().search(host: session.host, accessToken: session.accessToken, query: url.absoluteString)
        if let post = results.posts.first {
            sheet = .thread(post)
        } else {
            openExternally(url) // couldn't resolve it — open normally
        }
        resolvingStatus = nil
    }
}

extension View {
    /// Makes @-mention links open ProfileView, Mastodon status links open their thread in-app,
    /// and other web links open in the browser.
    func handleProfileLinks() -> some View { modifier(ProfileLinkHandler()) }
}
