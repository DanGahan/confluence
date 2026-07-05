import Testing
import Foundation
@testable import ConfluenceKit

struct RichTextTests {
    // MARK: ProfileLink

    @Test func profileLinkRoundTrips() throws {
        let url = try #require(ProfileLink.url(network: .bluesky, id: "did:plc:x", handle: "a.bsky.social"))
        let parsed = try #require(ProfileLink.parse(url))
        #expect(parsed.network == .bluesky)
        #expect(parsed.id == "did:plc:x")
        #expect(parsed.handle == "a.bsky.social")
    }

    @Test func profileLinkRejectsOtherURLs() {
        #expect(ProfileLink.parse(URL(string: "https://example.com")!) == nil)
    }

    @Test func blueskyWebProfileHandleParsing() {
        #expect(ProfileLink.blueskyWebProfileHandle(URL(string: "https://bsky.app/profile/alice.bsky.social")!) == "alice.bsky.social")
        #expect(ProfileLink.blueskyWebProfileHandle(URL(string: "https://www.bsky.app/profile/bob.test")!) == "bob.test")
        // Post / feed sub-paths and non-bsky hosts are not profile links.
        #expect(ProfileLink.blueskyWebProfileHandle(URL(string: "https://bsky.app/profile/alice/post/abc")!) == nil)
        #expect(ProfileLink.blueskyWebProfileHandle(URL(string: "https://example.com/profile/x")!) == nil)
    }

    // MARK: Bluesky facets (UTF-8 byte ranges)

    @Test func blueskyLinkAndMentionFacets() {
        let text = "hi @alice and see https://ex.com"
        // "@alice" bytes 3..9, url bytes 18..32
        let spans = [
            FacetSpan(start: 3, end: 9, url: ProfileLink.url(network: .bluesky, id: "did:1", handle: "")),
            FacetSpan(start: 18, end: 32, url: URL(string: "https://ex.com")),
        ]
        let attr = blueskyRichText(text: text, spans: spans)
        #expect(String(attr.characters) == text) // text preserved
        // The mention run links to a profile URL, the link run to the web URL.
        let links = attr.runs.compactMap { $0.link }
        #expect(links.contains { $0.scheme == ProfileLink.scheme })
        #expect(links.contains { $0.absoluteString == "https://ex.com" })
    }

    @Test func blueskyFacetsHandleEmojiByteOffsets() {
        let text = "👍 @bob"   // 👍 is 4 UTF-8 bytes + space = 5; "@bob" at bytes 5..9
        let spans = [FacetSpan(start: 5, end: 9, url: URL(string: "https://x"))]
        let attr = blueskyRichText(text: text, spans: spans)
        let linkedRun = attr.runs.first { $0.link != nil }
        #expect(linkedRun.map { String(attr[$0.range].characters) } == "@bob")
    }

    // MARK: Mastodon HTML

    @Test func mastodonLinkAndMention() {
        let html = "<p>hey <a href=\"https://m.social/@bob\" class=\"u-url mention\">@<span>bob</span></a> check <a href=\"https://ex.com\">this</a></p>"
        let mentions = ["https://m.social/@bob": ProfileLink.url(network: .mastodon, id: "42", handle: "bob")!]
        let attr = mastodonRichText(html: html, mentions: mentions)
        let text = String(attr.characters)
        #expect(text.contains("hey @bob check this"))
        let links = attr.runs.compactMap { $0.link }
        #expect(links.contains { $0.scheme == ProfileLink.scheme })       // mention -> profile
        #expect(links.contains { $0.absoluteString == "https://ex.com" }) // link -> web
    }

    // MARK: Auto-linking bare URLs

    @Test func autolinkAddsLinkToBareURL() {
        let attr = autolinked(AttributedString("see https://example.com/story now"))
        let linked = attr.runs.first { $0.link != nil }
        #expect(linked.map { String(attr[$0.range].characters) } == "https://example.com/story")
        #expect(linked?.link?.absoluteString == "https://example.com/story")
    }

    @Test func autolinkDoesNotOverwriteExistingLink() {
        // A facet already linked the truncated display text to the full URL; autolink must
        // not clobber it with the visible (partial) URL.
        let spans = [FacetSpan(start: 0, end: 20, url: URL(string: "https://example.com/full-story"))]
        let attr = autolinked(blueskyRichText(text: "https://example.co/x", spans: spans))
        let links = attr.runs.compactMap { $0.link?.absoluteString }
        #expect(links == ["https://example.com/full-story"])
    }

    @Test func mastodonStripsTagsAndDecodesEntities() {
        let attr = mastodonRichText(html: "<p>a &amp; b</p><p>line2</p>", mentions: [:])
        #expect(String(attr.characters) == "a & b\n\nline2")
    }
}
