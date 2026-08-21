import Testing
import Foundation
@testable import ConfluenceKit

/// Guards the link-routing decision that regressed twice (#154 → #207): a bsky.app post link
/// must route to the in-app thread, not the Bluesky app. Every route is pinned so a future
/// rewrite can't silently drop one.
struct LinkRouteTests {
    func url(_ s: String) -> URL { URL(string: s)! }

    @Test func blueskyPostLinkRoutesToThread() {
        let route = classifyLink(url("https://bsky.app/profile/patricklovellpresentsthecleannewdeal.com/post/3msp5glfvjs2g"),
                                 hasBluesky: true, hasMastodon: true)
        #expect(route == .blueskyThread(handle: "patricklovellpresentsthecleannewdeal.com", rkey: "3msp5glfvjs2g"))
    }

    @Test func blueskyPostLinkFallsBackToWebWithoutSession() {
        // No Bluesky session → can't resolve the handle, so it opens as a normal web link.
        let route = classifyLink(url("https://bsky.app/profile/alice.bsky.social/post/abc"),
                                 hasBluesky: false, hasMastodon: true)
        #expect(route == .web)
    }

    @Test func blueskyProfileLinkRoutesToProfile() {
        #expect(classifyLink(url("https://bsky.app/profile/alice.bsky.social"), hasBluesky: true, hasMastodon: true)
                == .blueskyProfile(handle: "alice.bsky.social"))
    }

    @Test func mastodonStatusRoutesToThreadOnlyWithSession() {
        let u = url("https://mastodon.social/@alice/116872581526086363")
        #expect(classifyLink(u, hasBluesky: true, hasMastodon: true) == .mastodonThread)
        #expect(classifyLink(u, hasBluesky: true, hasMastodon: false) == .web) // no instance to resolve on
    }

    @Test func appProfileSchemeRoutesToProfile() {
        let u = ProfileLink.url(network: .bluesky, id: "did:plc:x", handle: "x.bsky.social")!
        #expect(classifyLink(u, hasBluesky: true, hasMastodon: true) == .appProfile(network: .bluesky, id: "did:plc:x", handle: "x.bsky.social"))
    }

    @Test func plainWebLinkRoutesToWeb() {
        #expect(classifyLink(url("https://example.com/article"), hasBluesky: true, hasMastodon: true) == .web)
        #expect(classifyLink(url("https://bsky.app/profile/a/feed/xyz"), hasBluesky: true, hasMastodon: true) == .web)
    }

    // #207: a bsky.app post URL whose profile segment is already a DID must NOT be sent to
    // resolveHandle (that fails, dropping the user into the Bluesky app).
    @Test func postURIUsesDIDDirectlyWithoutResolving() async throws {
        var resolverCalled = false
        let uri = try await blueskyPostATURI(profileID: "did:plc:rhkcyc46ubi523e47bhnkpbb", rkey: "3mtatqdc5sf2f") { _ in
            resolverCalled = true; return "did:plc:WRONG"
        }
        #expect(uri == "at://did:plc:rhkcyc46ubi523e47bhnkpbb/app.bsky.feed.post/3mtatqdc5sf2f")
        #expect(resolverCalled == false)
    }

    @Test func postURIResolvesAHandle() async throws {
        let uri = try await blueskyPostATURI(profileID: "pitytheviolins.bsky.social", rkey: "3msxpwms7sk2m") { handle in
            #expect(handle == "pitytheviolins.bsky.social")
            return "did:plc:pity"
        }
        #expect(uri == "at://did:plc:pity/app.bsky.feed.post/3msxpwms7sk2m")
    }
}
