import Foundation

extension MastodonClient {
    /// `GET /api/v2/search`. `cursor` (a numeric offset) nil = first page (accounts + statuses);
    /// non-nil = the next page of statuses only. `failed` set on any error.
    public func search(host: String, accessToken: String, query: String, cursor: String? = nil, limit: Int = 25) async -> SearchResults {
        let offset = Int(cursor ?? "0") ?? 0
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v2/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if cursor == nil {
            components.queryItems?.append(URLQueryItem(name: "resolve", value: "true"))
        } else {
            // Paging: only need more statuses.
            components.queryItems?.append(URLQueryItem(name: "type", value: "statuses"))
            components.queryItems?.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        guard let url = components.url else { return SearchResults(failed: true) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.dataWithRateLimit(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return SearchResults(failed: true)
        }
        let posts = searchStatusItems(from: data, host: host) // rich decoding (links, images)
        // A full page implies more may exist; a short page is the end.
        let next = posts.count >= limit ? String(offset + posts.count) : nil

        if cursor != nil { return SearchResults(posts: posts, postsCursor: next) }

        let people = (try? JSONDecoder().decode(Response.self, from: data))?.accounts.map {
            SearchActor(network: .mastodon, authorID: $0.id, name: $0.displayName.isEmpty ? $0.acct : $0.displayName,
                        handle: $0.acct.contains("@") ? $0.acct : "\($0.acct)@\(host)",
                        avatarURL: URL(string: $0.avatar), bio: htmlToPlainText($0.note))
        } ?? []
        return SearchResults(people: people, posts: posts, postsCursor: next)
    }

    private struct Response: Decodable {
        let accounts: [Account]
    }
    private struct Account: Decodable {
        let id: String; let displayName: String; let acct: String; let avatar: String; let note: String
        enum CodingKeys: String, CodingKey { case id, acct, avatar, note; case displayName = "display_name" }
    }
}
