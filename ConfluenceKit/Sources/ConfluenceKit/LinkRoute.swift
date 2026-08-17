import Foundation

/// Where a tapped link should go. Pure classification, split out from the SwiftUI handler so it
/// is unit-testable — a bsky post link opening in-app instead of the Bluesky app regressed once
/// (#154 → #207) precisely because this decision lived, untested, inside a view closure.
public enum LinkRoute: Equatable, Sendable {
    /// An in-app `confluence://` profile link (from an @-mention facet).
    case appProfile(network: Network, id: String, handle: String)
    /// A `bsky.app/profile/{handle}` web link → open the profile in-app.
    case blueskyProfile(handle: String)
    /// A `bsky.app/profile/{handle}/post/{rkey}` web link → open the thread in-app.
    case blueskyThread(handle: String, rkey: String)
    /// A Mastodon status permalink → resolve onto the user's instance and open the thread.
    case mastodonThread
    /// Anything else — a normal web link (browser, or the iOS in-app browser).
    case web
}

/// Builds the `at://` URI for a bsky.app post link. The profile segment may be a **handle**
/// (`alice.bsky.social`, needs resolving to a DID) or **already a DID** (`did:plc:…`, used
/// directly) — bsky.app emits both, and passing a DID to `resolveHandle` fails (#207). The
/// resolver is injected so this is unit-tested without a network call.
public func blueskyPostATURI(profileID: String, rkey: String,
                             resolveHandle: (String) async throws -> String) async rethrows -> String {
    let did = profileID.hasPrefix("did:") ? profileID : try await resolveHandle(profileID)
    return "at://\(did)/app.bsky.feed.post/\(rkey)"
}

/// Classifies a tapped URL. `hasBluesky`/`hasMastodon` gate the routes that need a session to
/// resolve (handle→DID, remote status→local id); without one, those fall through to `.web`.
public func classifyLink(_ url: URL, hasBluesky: Bool, hasMastodon: Bool) -> LinkRoute {
    if let p = ProfileLink.parse(url) {
        return .appProfile(network: p.network, id: p.id, handle: p.handle)
    }
    if let handle = ProfileLink.blueskyWebProfileHandle(url) {
        return .blueskyProfile(handle: handle)
    }
    if hasBluesky, let ref = ProfileLink.blueskyWebPostRef(url) {
        return .blueskyThread(handle: ref.handle, rkey: ref.rkey)
    }
    if hasMastodon, ProfileLink.looksLikeMastodonStatus(url) {
        return .mastodonThread
    }
    return .web
}
