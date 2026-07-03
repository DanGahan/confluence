import Foundation

extension MastodonClient {
    /// `GET /api/v2/search` — accounts + statuses in one call. `failed` set on any error.
    public func search(host: String, accessToken: String, query: String, limit: Int = 25) async -> SearchResults {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v2/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "resolve", value: "true"),
        ]
        guard let url = components.url else { return SearchResults(failed: true) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return SearchResults(failed: true)
        }
        let people = decoded.accounts.map {
            SearchActor(network: .mastodon, authorID: $0.id, name: $0.displayName.isEmpty ? $0.acct : $0.displayName,
                        handle: $0.acct.contains("@") ? $0.acct : "\($0.acct)@\(host)",
                        avatarURL: URL(string: $0.avatar), bio: htmlToPlainText($0.note))
        }
        let posts = decoded.statuses.compactMap { $0.feedItem(host: host) }
        return SearchResults(people: people, posts: posts)
    }

    private struct Response: Decodable {
        let accounts: [Account]
        let statuses: [Status]
    }
    private struct Account: Decodable {
        let id: String; let displayName: String; let acct: String; let avatar: String; let note: String
        enum CodingKeys: String, CodingKey { case id, acct, avatar, note; case displayName = "display_name" }
    }
    private struct Status: Decodable {
        let id: String; let createdAt: String; let content: String; let account: Account
        enum CodingKeys: String, CodingKey { case id, content, account; case createdAt = "created_at" }
        func feedItem(host: String) -> FeedItem? {
            guard let date = ISO8601.date(from: createdAt) else { return nil }
            return FeedItem(network: .mastodon, rawId: id, authorID: account.id,
                            authorName: account.displayName.isEmpty ? account.acct : account.displayName,
                            authorHandle: account.acct.contains("@") ? account.acct : "\(account.acct)@\(host)",
                            avatarURL: URL(string: account.avatar), createdAt: date, text: htmlToPlainText(content))
        }
    }
}
