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
            return FeedItem(
                network: .bluesky,
                rawId: post.uri,
                authorID: post.author.did,
                authorName: post.author.displayName ?? post.author.handle,
                authorHandle: post.author.handle,
                avatarURL: post.author.avatar.flatMap(URL.init(string:)),
                createdAt: createdAt,
                text: post.record.text,
                attributedText: Self.attributed(from: post.record),
                imageURLs: post.embed?.images?.compactMap { URL(string: $0.fullsize) } ?? [],
                repostedBy: reason?.by?.displayName,
                isFollowing: post.author.viewer?.following != nil,
                followURI: post.author.viewer?.following
            )
        }

        static func attributed(from record: Record) -> AttributedString? {
            guard let facets = record.facets, !facets.isEmpty else { return nil }
            let spans: [FacetSpan] = facets.compactMap { facet in
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
            return spans.isEmpty ? nil : blueskyRichText(text: record.text, spans: spans)
        }
    }

    private struct Post: Decodable {
        let uri: String
        let author: Author
        let record: Record
        let embed: Embed?
        let indexedAt: String?
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
    }
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
    }
    private struct EmbedImage: Decodable {
        let fullsize: String
    }
    private struct Reason: Decodable {
        let by: ReasonActor?
        let indexedAt: String?
    }
    private struct ReasonActor: Decodable {
        let displayName: String?
    }
}
