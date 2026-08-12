import Foundation

/// Custom URL for an in-app profile link (a tapped @-mention). Distinguished from web
/// links by scheme so the UI can route it to ProfileView instead of the browser.
public enum ProfileLink {
    public static let scheme = "confluence-profile"

    public static func url(network: Network, id: String, handle: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "profile"
        components.queryItems = [
            URLQueryItem(name: "net", value: network.rawValue),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "handle", value: handle),
        ]
        return components.url
    }

    public static func parse(_ url: URL) -> (network: Network, id: String, handle: String)? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let net = items.first(where: { $0.name == "net" })?.value, let network = Network(rawValue: net),
              let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return (network, id, items.first(where: { $0.name == "handle" })?.value ?? "")
    }

    /// A `https://bsky.app/profile/{handle}` web URL → the handle, so it can open in ProfileView
    /// instead of the Bluesky app. Post/feed/list sub-paths return nil (they open normally).
    public static func blueskyWebProfileHandle(_ url: URL) -> String? {
        guard let host = url.host, host == "bsky.app" || host == "www.bsky.app" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "profile", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// A `https://bsky.app/profile/{handle}/post/{rkey}` web URL → (handle, rkey), so the post
    /// can open as an in-app thread instead of the Bluesky app. The handle still needs resolving
    /// to a DID before building the `at://` URI `getPostThread` wants.
    public static func blueskyWebPostRef(_ url: URL) -> (handle: String, rkey: String)? {
        guard let host = url.host, host == "bsky.app" || host == "www.bsky.app" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[0] == "profile", parts[2] == "post",
              !parts[1].isEmpty, !parts[3].isEmpty else { return nil }
        return (parts[1], parts[3])
    }

    /// True if `url` looks like a Mastodon status permalink (`…/@user/{id}` or
    /// `…/statuses/{id}`, id all-digits), so it can be resolved onto the user's instance and
    /// opened as an in-app thread instead of the browser. Matches on path shape only — the
    /// resolve step (a search) confirms the status actually exists, so a false positive here
    /// just costs one lookup that falls back to opening the link normally.
    public static func looksLikeMastodonStatus(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) else { return false }
        let prev = parts[parts.count - 2]
        return prev.hasPrefix("@") || prev == "statuses"
    }
}

/// A run of text with an optional link. Assembled into an AttributedString whose `.link`
/// runs SwiftUI renders as tappable, tinted links.
struct LinkRun {
    var text: String
    var url: URL?
}

func attributedString(from runs: [LinkRun]) -> AttributedString {
    var result = AttributedString()
    for run in runs {
        var piece = AttributedString(run.text)
        if let url = run.url { piece.link = url }
        result.append(piece)
    }
    return result
}

/// Maps a UTF-8 byte range (Bluesky facet indices are UTF-8 offsets) to a String range.
func stringRange(in text: String, utf8Start: Int, utf8End: Int) -> Range<String.Index>? {
    let utf8 = text.utf8
    guard utf8Start >= 0, utf8Start <= utf8End, utf8End <= utf8.count,
          let s = utf8.index(utf8.startIndex, offsetBy: utf8Start, limitedBy: utf8.endIndex),
          let e = utf8.index(utf8.startIndex, offsetBy: utf8End, limitedBy: utf8.endIndex),
          let sStr = s.samePosition(in: text), let eStr = e.samePosition(in: text) else { return nil }
    return sStr..<eStr
}

// MARK: - Auto-linking bare URLs

private let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Adds `.link` attributes to bare URLs not already inside a link/mention run. Mirrors the
/// official clients, which linkify URLs even when a post carries no facets (common for bots
/// and bridged posts). Never overwrites an existing link (facet links, @-mentions win).
func autolinked(_ attributed: AttributedString) -> AttributedString {
    let text = String(attributed.characters)
    guard let detector = urlDetector, !text.isEmpty else { return attributed }
    var result = attributed
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in detector.matches(in: text, range: full) {
        guard let url = match.url, let r = Range(match.range, in: text) else { continue }
        let lower = text.distance(from: text.startIndex, to: r.lowerBound)
        let upper = text.distance(from: text.startIndex, to: r.upperBound)
        guard let start = result.index(result.startIndex, offsetByCharacters: lower, limitedBy: result.endIndex),
              let end = result.index(result.startIndex, offsetByCharacters: upper, limitedBy: result.endIndex) else { continue }
        if result[start..<end].runs.allSatisfy({ $0.link == nil }) {
            result[start..<end].link = url
        }
    }
    return result
}

private extension AttributedString {
    func index(_ i: Index, offsetByCharacters distance: Int, limitedBy limit: Index) -> Index? {
        characters.index(i, offsetBy: distance, limitedBy: limit)
    }
}

// MARK: - Bluesky (facets)

/// A resolved facet: a UTF-8 byte range and the URL it links to (web link or profile link).
struct FacetSpan { let start: Int; let end: Int; let url: URL? }

/// Builds an AttributedString from text and byte-ranged facet spans.
func blueskyRichText(text: String, spans: [FacetSpan]) -> AttributedString {
    var runs: [LinkRun] = []
    var cursor = 0
    for span in spans.sorted(by: { $0.start < $1.start }) {
        guard span.start >= cursor, let linked = stringRange(in: text, utf8Start: span.start, utf8End: span.end) else { continue }
        if let pre = stringRange(in: text, utf8Start: cursor, utf8End: span.start) {
            runs.append(LinkRun(text: String(text[pre])))
        }
        runs.append(LinkRun(text: String(text[linked]), url: span.url))
        cursor = span.end
    }
    if let tail = stringRange(in: text, utf8Start: cursor, utf8End: text.utf8.count) {
        runs.append(LinkRun(text: String(text[tail])))
    }
    return attributedString(from: runs)
}

// MARK: - Mastodon (HTML)

/// Builds an AttributedString from Mastodon status HTML. `mentions` maps an <a> href to the
/// in-app profile URL so @-mentions route to ProfileView; other <a>s become web links.
func mastodonRichText(html: String, mentions: [String: URL]) -> AttributedString {
    var runs: [LinkRun] = []
    var text = ""
    func flush() {
        if !text.isEmpty { runs.append(LinkRun(text: decodeHTMLEntities(text))); text = "" }
    }

    var i = html.startIndex
    while i < html.endIndex {
        guard html[i] == "<", let close = html[i...].firstIndex(of: ">") else {
            text.append(html[i]); i = html.index(after: i); continue
        }
        let tag = html[html.index(after: i)..<close].trimmingCharacters(in: .whitespaces)
        let lower = tag.lowercased()
        if lower == "br" || lower == "br/" || lower == "br /" {
            text += "\n"
            i = html.index(after: close)
        } else if lower == "/p" {
            text += "\n\n"
            i = html.index(after: close)
        } else if lower == "a" || lower.hasPrefix("a ") {
            flush()
            let href = htmlAttribute("href", in: tag)
            if let aClose = html.range(of: "</a>", options: .caseInsensitive, range: html.index(after: close)..<html.endIndex) {
                let inner = decodeHTMLEntities(stripTags(String(html[html.index(after: close)..<aClose.lowerBound])))
                // href entities (e.g. &amp; in query strings) must be decoded before URL().
                let url = href.flatMap { mentions[$0] } ?? href.flatMap { URL(string: decodeHTMLEntities($0)) }
                runs.append(LinkRun(text: inner, url: url))
                i = aClose.upperBound
            } else {
                i = html.index(after: close)
            }
        } else {
            i = html.index(after: close) // skip other tags
        }
    }
    flush()

    // Trim leading/trailing whitespace runs.
    while let first = runs.first, first.url == nil, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runs.removeFirst() }
    while let last = runs.last, last.url == nil, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runs.removeLast() }
    if runs.indices.contains(runs.count - 1), runs[runs.count - 1].url == nil {
        runs[runs.count - 1].text = String(runs[runs.count - 1].text.reversed().drop(while: { $0 == "\n" || $0 == " " }).reversed())
    }
    return attributedString(from: runs)
}

func decodeHTMLEntities(_ s: String) -> String {
    var text = s
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
    for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
    return text
}

func stripTags(_ s: String) -> String {
    s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
}

/// Extracts an attribute value from a tag body like `href="..." class="..."`.
func htmlAttribute(_ name: String, in tag: String) -> String? {
    guard let range = tag.range(of: "\(name)=\"", options: .caseInsensitive) else { return nil }
    let rest = tag[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}
