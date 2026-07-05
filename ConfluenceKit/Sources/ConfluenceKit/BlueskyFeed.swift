import Foundation

extension BlueskyClient {
    /// `app.bsky.feed.getTimeline` — the home timeline as normalized feed items.
    public func timeline(accessToken: String, cursor: String?, limit: Int = 50) async throws -> FeedPage {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/app.bsky.feed.getTimeline"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await timelineData(for: request)
        guard (200..<300).contains(response.statusCode) else {
            // AT Proto signals an expired/invalid access token with 400 ExpiredToken (not 401).
            // Map those to .invalidCredentials so the caller refreshes and retries.
            let xrpcError = (try? JSONDecoder().decode(XRPCErrorBody.self, from: data))?.error
            if response.statusCode == 401 || xrpcError == "ExpiredToken" || xrpcError == "InvalidToken" || xrpcError == "AuthenticationRequired" {
                throw BlueskyError.invalidCredentials
            }
            throw BlueskyError.server("Bluesky timeline returned status \(response.statusCode).")
        }
        let decoded: Timeline
        do { decoded = try JSONDecoder().decode(Timeline.self, from: data) }
        catch { throw BlueskyError.malformedResponse }
        return FeedPage(items: decoded.feed.compactMap(\.feedItem), nextCursor: decoded.cursor)
    }

    /// `app.bsky.feed.getPostThread` — a post with its parent chain and nested replies.
    /// Flattened to every post in the conversation, chronological (oldest first).
    public func postThread(accessToken: String, uri: String, depth: Int = 30) async throws -> PostThread {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/app.bsky.feed.getPostThread"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "depth", value: String(depth)),
            URLQueryItem(name: "parentHeight", value: "40"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await timelineData(for: request)
        guard (200..<300).contains(response.statusCode) else { throw BlueskyError.server("Bluesky thread status \(response.statusCode).") }
        guard let decoded = try? JSONDecoder().decode(ThreadResponse.self, from: data) else { throw BlueskyError.malformedResponse }

        var posts: [Post] = []
        decoded.thread.collect(into: &posts)
        let items = posts.compactMap { $0.threadFeedItem() }
        let focusID = decoded.thread.post?.threadFeedItem()?.id ?? items.first?.id ?? ""
        return PostThread(items: chronological(items), focusID: focusID)
    }

    /// `app.bsky.feed.getAuthorFeed` — a single user's posts. Same wire shape as the timeline.
    public func authorFeed(accessToken: String, actor: String, cursor: String?, limit: Int = 40) async throws -> FeedPage {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/app.bsky.feed.getAuthorFeed"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "actor", value: actor), URLQueryItem(name: "limit", value: String(limit))]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await timelineData(for: request)
        guard (200..<300).contains(response.statusCode) else { throw BlueskyError.server("Bluesky author feed status \(response.statusCode).") }
        guard let decoded = try? JSONDecoder().decode(Timeline.self, from: data) else { throw BlueskyError.malformedResponse }
        return FeedPage(items: decoded.feed.compactMap(\.feedItem), nextCursor: decoded.cursor)
    }

    // Reuses the private URLSession via a tiny internal shim so decoding stays here.
    private func timelineData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
            return (data, http)
        } catch let error as BlueskyError {
            throw error
        } catch {
            throw BlueskyError.network
        }
    }

    // MARK: - Wire format (only the fields we render)

    private struct XRPCErrorBody: Decodable { let error: String? }

    private struct Timeline: Decodable {
        let cursor: String?
        let feed: [FeedEntry]
    }

    private struct FeedEntry: Decodable {
        let post: Post
        let reason: Reason?

        var feedItem: FeedItem? {
            // Order by timeline time: a repost's own time, else when the post was indexed —
            // NOT the original post's authored time (a repost of an old post must not sink).
            let orderString = reason?.indexedAt ?? post.indexedAt ?? post.record.createdAt
            guard let createdAt = ISO8601.date(from: orderString) else { return nil }
            return post.makeFeedItem(orderDate: createdAt, repostedBy: reason?.by?.displayName)
        }

        static func attributed(from record: Record) -> AttributedString {
            let spans: [FacetSpan] = (record.facets ?? []).compactMap { facet in
                guard let feature = facet.features.first else { return nil }
                let url: URL?
                switch feature.type {
                case "app.bsky.richtext.facet#link":
                    url = feature.uri.flatMap { URL(string: $0) }
                case "app.bsky.richtext.facet#mention":
                    url = feature.did.flatMap { ProfileLink.url(network: .bluesky, id: $0, handle: "") }
                default:
                    return nil // hashtags etc. stay plain
                }
                return FacetSpan(start: facet.index.byteStart, end: facet.index.byteEnd, url: url)
            }
            let base = spans.isEmpty ? AttributedString(record.text) : blueskyRichText(text: record.text, spans: spans)
            // Facets cover most links; autolink catches bare URLs in posts that carry none.
            return autolinked(base)
        }
    }

    private struct Post: Decodable {
        let uri: String
        let cid: String?
        let author: Author
        let record: Record
        let embed: Embed?
        let indexedAt: String?
        let replyCount: Int?

        /// `at://did/app.bsky.feed.post/{rkey}` → `https://bsky.app/profile/{handle}/post/{rkey}`.
        var webURL: URL? {
            guard let rkey = uri.split(separator: "/").last else { return nil }
            return URL(string: "https://bsky.app/profile/\(author.handle)/post/\(rkey)")
        }

        func makeFeedItem(orderDate: Date, repostedBy: String?) -> FeedItem {
            FeedItem(
                network: .bluesky,
                rawId: uri,
                authorID: author.did,
                authorName: author.displayName ?? author.handle,
                authorHandle: author.handle,
                avatarURL: author.avatar.flatMap(URL.init(string:)),
                createdAt: orderDate,
                text: record.text,
                attributedText: FeedEntry.attributed(from: record),
                imageURLs: embed?.allImages?.compactMap { URL(string: $0.fullsize) } ?? [],
                linkCard: (embed?.allImages?.isEmpty ?? true) ? embed?.anyExternal?.linkCard : nil,
                repostedBy: repostedBy,
                isFollowing: author.viewer?.following != nil,
                followURI: author.viewer?.following,
                threadID: uri,
                replyCount: replyCount ?? 0,
                isReply: record.reply != nil,
                cid: cid,
                postURL: webURL
            )
        }

        /// A thread post orders by its own authored time (no repost wrapping in a thread).
        func threadFeedItem() -> FeedItem? {
            guard let date = ISO8601.date(from: record.createdAt) else { return nil }
            return makeFeedItem(orderDate: date, repostedBy: nil)
        }
    }

    private struct ThreadResponse: Decodable { let thread: ThreadNode }

    /// getPostThread is recursive (parent chain + nested replies); a class allows the
    /// self-reference. `post` is nil for blocked/not-found nodes, which we skip.
    private final class ThreadNode: Decodable {
        let post: Post?
        let parent: ThreadNode?
        let replies: [ThreadNode]?

        func collect(into posts: inout [Post]) {
            parent?.collect(into: &posts)
            if let post { posts.append(post) }
            for reply in replies ?? [] { reply.collect(into: &posts) }
        }
    }
    private struct Author: Decodable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: String?
        let viewer: Viewer?
    }
    private struct Viewer: Decodable {
        let following: String?
    }
    private struct Record: Decodable {
        let text: String
        let createdAt: String
        let facets: [Facet]?
        let reply: Reply?
    }
    private struct Reply: Decodable {} // presence marks this post as a reply
    private struct Facet: Decodable {
        let index: FacetIndex
        let features: [FacetFeature]
    }
    private struct FacetIndex: Decodable { let byteStart: Int; let byteEnd: Int }
    private struct FacetFeature: Decodable {
        let type: String
        let uri: String?
        let did: String?
        enum CodingKeys: String, CodingKey { case type = "$type", uri, did }
    }
    private struct Embed: Decodable {
        let images: [EmbedImage]?
        let external: ExternalEmbed?
        let media: EmbedMedia?  // recordWithMedia#view nests images/external under `media`

        var allImages: [EmbedImage]? { images ?? media?.images }
        var anyExternal: ExternalEmbed? { external ?? media?.external }
    }
    private struct EmbedMedia: Decodable {
        let images: [EmbedImage]?
        let external: ExternalEmbed?
    }
    private struct EmbedImage: Decodable {
        let fullsize: String
    }
    private struct ExternalEmbed: Decodable {
        let uri: String
        let title: String?
        let description: String?
        let thumb: String?

        var linkCard: LinkCard? {
            guard let url = URL(string: uri) else { return nil }
            return LinkCard(url: url, title: title ?? uri, description: description ?? "",
                            thumbURL: thumb.flatMap { URL(string: $0) })
        }
    }
    private struct Reason: Decodable {
        let by: ReasonActor?
        let indexedAt: String?
    }
    private struct ReasonActor: Decodable {
        let displayName: String?
    }
}
