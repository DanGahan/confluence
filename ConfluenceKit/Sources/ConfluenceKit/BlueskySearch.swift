import Foundation

extension BlueskyClient {
    /// Searches people (`app.bsky.actor.searchActors`) and posts (`app.bsky.feed.searchPosts`)
    /// in parallel. `failed` is set only if the network is entirely unreachable.
    /// `cursor` nil = first page (people + posts); non-nil = the next page of posts only.
    public func search(accessToken: String, query: String, cursor: String? = nil, limit: Int = 25) async -> SearchResults {
        if let cursor {
            guard let data = try? await get(accessToken: accessToken, method: "app.bsky.feed.searchPosts",
                                            query: query, limit: limit, cursor: cursor) else {
                return SearchResults(failed: true)
            }
            let (items, next) = searchPostItems(from: data)
            return SearchResults(posts: items, postsCursor: next)
        }
        async let actors = try? searchActors(accessToken: accessToken, query: query, limit: limit)
        async let postsData = try? get(accessToken: accessToken, method: "app.bsky.feed.searchPosts",
                                       query: query, limit: limit, cursor: nil)
        let (people, pd) = await (actors, postsData)
        let (items, next) = pd.map { searchPostItems(from: $0) } ?? ([], nil) // rich decoding (links, images, cards)
        return SearchResults(people: people ?? [], posts: items, failed: people == nil && pd == nil, postsCursor: next)
    }

    private func searchActors(accessToken: String, query: String, limit: Int) async throws -> [SearchActor] {
        let data = try await get(accessToken: accessToken, method: "app.bsky.actor.searchActors", query: query, limit: limit, cursor: nil)
        guard let decoded = try? JSONDecoder().decode(Actors.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.actors.map {
            SearchActor(network: .bluesky, authorID: $0.did, name: $0.displayName ?? $0.handle, handle: $0.handle,
                        avatarURL: $0.avatar.flatMap(URL.init(string:)), isFollowing: $0.viewer?.following != nil,
                        followURI: $0.viewer?.following, bio: $0.description ?? "")
        }
    }

    private func get(accessToken: String, method: String, query: String, limit: Int, cursor: String?) async throws -> Data {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/\(method)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
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

}
