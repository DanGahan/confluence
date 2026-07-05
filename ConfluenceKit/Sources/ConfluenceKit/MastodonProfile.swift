import Foundation

extension MastodonClient {
    /// `GET /api/v1/accounts/:id` plus a relationship lookup for follow state.
    public func profile(host: String, accessToken: String, accountID: String) async throws -> Profile {
        let data = try await get(host: host, accessToken: accessToken, path: "/api/v1/accounts/\(accountID)", items: [])
        guard let a = try? JSONDecoder().decode(Account.self, from: data) else { throw MastodonError.malformedResponse }
        let following = await isFollowing(host: host, accessToken: accessToken, accountID: accountID)
        return Profile(
            network: .mastodon, authorID: a.id, name: a.displayName.isEmpty ? a.acct : a.displayName,
            handle: a.acct.contains("@") ? a.acct : "\(a.acct)@\(host)", avatarURL: URL(string: a.avatar),
            bio: htmlToPlainText(a.note), followersCount: a.followersCount ?? 0, followingCount: a.followingCount ?? 0,
            postsCount: a.statusesCount ?? 0, isFollowing: following, followURI: nil
        )
    }

    /// `GET /api/v1/accounts/verify_credentials` — the signed-in user's own account.
    public func currentAccount(host: String, accessToken: String) async throws -> Profile {
        let data = try await get(host: host, accessToken: accessToken, path: "/api/v1/accounts/verify_credentials", items: [])
        guard let a = try? JSONDecoder().decode(Account.self, from: data) else { throw MastodonError.malformedResponse }
        return Profile(
            network: .mastodon, authorID: a.id, name: a.displayName.isEmpty ? a.acct : a.displayName,
            handle: a.acct.contains("@") ? a.acct : "\(a.acct)@\(host)", avatarURL: URL(string: a.avatar),
            bio: htmlToPlainText(a.note), followersCount: a.followersCount ?? 0, followingCount: a.followingCount ?? 0,
            postsCount: a.statusesCount ?? 0, isFollowing: false, followURI: nil
        )
    }

    /// `GET /api/v1/accounts/:id/following` or `/followers`.
    public func followList(host: String, accessToken: String, accountID: String, kind: FollowListKind, limit: Int = 50) async throws -> [SearchActor] {
        let path = "/api/v1/accounts/\(accountID)/\(kind == .following ? "following" : "followers")"
        let data = try await get(host: host, accessToken: accessToken, path: path, items: [URLQueryItem(name: "limit", value: String(limit))])
        guard let accounts = try? JSONDecoder().decode([Account].self, from: data) else { throw MastodonError.malformedResponse }
        return accounts.map {
            SearchActor(network: .mastodon, authorID: $0.id, name: $0.displayName.isEmpty ? $0.acct : $0.displayName,
                        handle: $0.acct.contains("@") ? $0.acct : "\($0.acct)@\(host)", avatarURL: URL(string: $0.avatar),
                        bio: htmlToPlainText($0.note))
        }
    }

    private func isFollowing(host: String, accessToken: String, accountID: String) async -> Bool {
        guard let data = try? await get(host: host, accessToken: accessToken,
                                        path: "/api/v1/accounts/relationships", items: [URLQueryItem(name: "id[]", value: accountID)]),
              let rels = try? JSONDecoder().decode([Relationship].self, from: data) else { return false }
        return rels.first?.following ?? false
    }
    private struct Relationship: Decodable { let following: Bool }

    private func get(host: String, accessToken: String, path: String, items: [URLQueryItem]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw MastodonError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MastodonError.server("Mastodon request failed.")
        }
        return data
    }

    private struct Account: Decodable {
        let id: String; let displayName: String; let acct: String; let avatar: String; let note: String
        let followersCount: Int?; let followingCount: Int?; let statusesCount: Int?
        enum CodingKeys: String, CodingKey {
            case id, acct, avatar, note
            case displayName = "display_name"
            case followersCount = "followers_count"
            case followingCount = "following_count"
            case statusesCount = "statuses_count"
        }
    }
}
