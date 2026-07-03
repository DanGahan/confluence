import Foundation

extension BlueskyClient {
    /// `app.bsky.actor.getProfile`
    public func profile(accessToken: String, actor: String) async throws -> Profile {
        let data = try await xrpcGet(accessToken: accessToken, method: "app.bsky.actor.getProfile",
                                     items: [URLQueryItem(name: "actor", value: actor)])
        guard let p = try? JSONDecoder().decode(ProfileView.self, from: data) else { throw BlueskyError.malformedResponse }
        return Profile(
            network: .bluesky, authorID: p.did, name: p.displayName ?? p.handle, handle: p.handle,
            avatarURL: p.avatar.flatMap(URL.init(string:)), bio: p.description ?? "",
            followersCount: p.followersCount ?? 0, followingCount: p.followsCount ?? 0, postsCount: p.postsCount ?? 0,
            isFollowing: p.viewer?.following != nil, followURI: p.viewer?.following
        )
    }

    /// `app.bsky.graph.getFollows` / `getFollowers` — returns follow-able actors.
    public func followList(accessToken: String, actor: String, kind: FollowListKind, limit: Int = 50) async throws -> [SearchActor] {
        let method = kind == .following ? "app.bsky.graph.getFollows" : "app.bsky.graph.getFollowers"
        let data = try await xrpcGet(accessToken: accessToken, method: method,
                                     items: [URLQueryItem(name: "actor", value: actor), URLQueryItem(name: "limit", value: String(limit))])
        guard let decoded = try? JSONDecoder().decode(FollowList.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.actors.map {
            SearchActor(network: .bluesky, authorID: $0.did, name: $0.displayName ?? $0.handle, handle: $0.handle,
                        avatarURL: $0.avatar.flatMap(URL.init(string:)), isFollowing: $0.viewer?.following != nil,
                        followURI: $0.viewer?.following, bio: $0.description ?? "")
        }
    }

    private func xrpcGet(accessToken: String, method: String, items: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/\(method)"), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { throw BlueskyError.invalidCredentials }
                throw BlueskyError.server("Bluesky returned status \(http.statusCode).")
            }
            return data
        } catch let error as BlueskyError { throw error }
        catch { throw BlueskyError.network }
    }

    private struct ProfileView: Decodable {
        let did: String; let handle: String; let displayName: String?; let description: String?; let avatar: String?
        let followersCount: Int?; let followsCount: Int?; let postsCount: Int?; let viewer: ProfileViewer?
    }
    private struct ProfileViewer: Decodable { let following: String? }
    private struct FollowList: Decodable {
        let actors: [ListActor]
        // getFollows uses "follows", getFollowers uses "followers"; normalize both to `actors`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            actors = (try? c.decode([ListActor].self, forKey: .follows))
                ?? (try? c.decode([ListActor].self, forKey: .followers)) ?? []
        }
        enum Key: String, CodingKey { case follows, followers }
    }
    private struct ListActor: Decodable {
        let did: String; let handle: String; let displayName: String?; let avatar: String?
        let description: String?; let viewer: ProfileViewer?
    }
}
