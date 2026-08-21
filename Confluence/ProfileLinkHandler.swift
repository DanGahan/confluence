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
    @Environment(BlueskyAccountStore.self) private var bluesky
    #if os(iOS)
    @AppStorage(BrowsingPreference.openLinksInAppKey) private var openLinksInApp = BrowsingPreference.openLinksInAppDefault
    #endif
    @State private var sheet: LinkSheet?
    @State private var resolvingStatus: URL?
    @State private var resolvingBlueskyPost: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                // Routing decision lives in the unit-tested classifyLink (ConfluenceKit) so a
                // rewrite can't silently drop a case again (#154 → #207).
                switch classifyLink(url, hasBluesky: bluesky.isLoggedIn, hasMastodon: mastodon.session != nil) {
                case .appProfile(let network, let id, let handle):
                    sheet = .profile(ProfileTarget(network: network, accountID: id, handle: handle))
                case .blueskyProfile(let handle):
                    sheet = .profile(ProfileTarget(network: .bluesky, accountID: handle, handle: handle))
                case .blueskyThread:
                    resolvingBlueskyPost = url // resolved async (handle→DID) then opened
                case .mastodonThread:
                    resolvingStatus = url      // resolved async onto the user's instance
                case .web:
                    #if os(iOS)
                    // iOS: external web links open in the in-app browser by default; off → system.
                    if openLinksInApp, url.scheme == "http" || url.scheme == "https" {
                        sheet = .web(url)
                        return .handled
                    }
                    #endif
                    // Open web links ourselves: `.systemAction` from a programmatically invoked
                    // OpenURLAction (our NSTextView delegate calls this) doesn't reliably open.
                    openExternally(url)
                }
                return .handled
            })
            .task(id: resolvingStatus) { await resolveStatus() }
            .task(id: resolvingBlueskyPost) { await resolveBlueskyPost() }
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

    /// Resolves a tapped bsky.app post URL to an `at://` URI and opens its thread. The profile
    /// segment may be a handle (resolve → DID) or already a DID (used as-is); see blueskyPostATURI.
    /// Falls back to the browser if a handle can't be resolved.
    private func resolveBlueskyPost() async {
        guard let url = resolvingBlueskyPost, let ref = ProfileLink.blueskyWebPostRef(url) else { return }
        defer { resolvingBlueskyPost = nil }
        do {
            let client = bluesky.blueskyClient()
            let uri = try await bluesky.withAuth { auth, _ in
                try await blueskyPostATURI(profileID: ref.handle, rkey: ref.rkey) {
                    try await client.resolveHandle(auth: auth, handle: $0)
                }
            }
            // ThreadView loads the conversation from threadID; the rest is placeholder.
            sheet = .thread(FeedItem(network: .bluesky, rawId: uri, authorName: ref.handle,
                                     authorHandle: ref.handle, avatarURL: nil, createdAt: Date(),
                                     text: "", threadID: uri))
        } catch {
            openExternally(url) // couldn't resolve the handle — open normally
        }
    }
}

extension View {
    /// Makes @-mention links open ProfileView, Mastodon status links open their thread in-app,
    /// and other web links open in the browser.
    func handleProfileLinks() -> some View { modifier(ProfileLinkHandler()) }
}
