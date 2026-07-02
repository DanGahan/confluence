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
            if response.statusCode == 401 { throw BlueskyError.invalidCredentials }
            throw BlueskyError.server("Bluesky timeline returned status \(response.statusCode).")
        }
        let decoded: Timeline
        do { decoded = try JSONDecoder().decode(Timeline.self, from: data) }
        catch { throw BlueskyError.malformedResponse }
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

    private struct Timeline: Decodable {
        let cursor: String?
        let feed: [FeedEntry]
    }

    private struct FeedEntry: Decodable {
        let post: Post
        let reason: Reason?

        var feedItem: FeedItem? {
            guard let createdAt = ISO8601.date(from: post.record.createdAt) else { return nil }
            return FeedItem(
                network: .bluesky,
                rawId: post.uri,
                authorName: post.author.displayName ?? post.author.handle,
                authorHandle: post.author.handle,
                avatarURL: post.author.avatar.flatMap(URL.init(string:)),
                createdAt: createdAt,
                text: post.record.text,
                imageURLs: post.embed?.images?.compactMap { URL(string: $0.fullsize) } ?? [],
                repostedBy: reason?.by?.displayName
            )
        }
    }

    private struct Post: Decodable {
        let uri: String
        let author: Author
        let record: Record
        let embed: Embed?
    }
    private struct Author: Decodable {
        let handle: String
        let displayName: String?
        let avatar: String?
    }
    private struct Record: Decodable {
        let text: String
        let createdAt: String
    }
    private struct Embed: Decodable {
        let images: [EmbedImage]?
    }
    private struct EmbedImage: Decodable {
        let fullsize: String
    }
    private struct Reason: Decodable {
        let by: ReasonActor?
    }
    private struct ReasonActor: Decodable {
        let displayName: String?
    }
}
