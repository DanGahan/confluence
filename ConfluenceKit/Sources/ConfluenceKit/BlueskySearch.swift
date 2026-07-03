import Foundation

extension BlueskyClient {
    /// Searches people (`app.bsky.actor.searchActors`) and posts (`app.bsky.feed.searchPosts`)
    /// in parallel. `failed` is set only if the network is entirely unreachable.
    public func search(accessToken: String, query: String, limit: Int = 25) async -> SearchResults {
        async let actors = try? searchActors(accessToken: accessToken, query: query, limit: limit)
        async let posts = try? searchPosts(accessToken: accessToken, query: query, limit: limit)
        let (people, foundPosts) = await (actors, posts)
        return SearchResults(people: people ?? [], posts: foundPosts ?? [], failed: people == nil && foundPosts == nil)
    }

    private func searchActors(accessToken: String, query: String, limit: Int) async throws -> [SearchActor] {
        let data = try await get(accessToken: accessToken, method: "app.bsky.actor.searchActors", query: query, limit: limit)
        guard let decoded = try? JSONDecoder().decode(Actors.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.actors.map {
            SearchActor(network: .bluesky, authorID: $0.did, name: $0.displayName ?? $0.handle, handle: $0.handle,
                        avatarURL: $0.avatar.flatMap(URL.init(string:)), isFollowing: $0.viewer?.following != nil,
                        followURI: $0.viewer?.following, bio: $0.description ?? "")
        }
    }

    private func searchPosts(accessToken: String, query: String, limit: Int) async throws -> [FeedItem] {
        let data = try await get(accessToken: accessToken, method: "app.bsky.feed.searchPosts", query: query, limit: limit)
        guard let decoded = try? JSONDecoder().decode(Posts.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.posts.compactMap(\.feedItem)
    }

    private func get(accessToken: String, method: String, query: String, limit: Int) async throws -> Data {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/\(method)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BlueskyError.server("Bluesky search failed.")
        }
        return data
    }

    // MARK: wire format

    private struct Actors: Decodable { let actors: [Actor] }
    private struct Actor: Decodable {
        let did: String; let handle: String; let displayName: String?; let avatar: String?
        let description: String?; let viewer: ActorViewer?
    }
    private struct ActorViewer: Decodable { let following: String? }

    private struct Posts: Decodable { let posts: [SearchPost] }
    private struct SearchPost: Decodable {
        let uri: String; let author: PostAuthor; let record: PostRecord
        var feedItem: FeedItem? {
            guard let date = ISO8601.date(from: record.createdAt) else { return nil }
            return FeedItem(network: .bluesky, rawId: uri, authorID: author.did,
                            authorName: author.displayName ?? author.handle, authorHandle: author.handle,
                            avatarURL: author.avatar.flatMap(URL.init(string:)), createdAt: date, text: record.text,
                            isFollowing: author.viewer?.following != nil, followURI: author.viewer?.following)
        }
    }
    private struct PostAuthor: Decodable {
        let did: String; let handle: String; let displayName: String?; let avatar: String?; let viewer: ActorViewer?
    }
    private struct PostRecord: Decodable { let text: String; let createdAt: String }
}
