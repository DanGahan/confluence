import Foundation

extension MastodonClient {
    /// `GET /api/v1/accounts/relationships` — returns accountID → isFollowing for the given ids.
    /// The Mastodon home timeline doesn't include follow state, so we fetch it separately.
    public func relationships(host: String, accessToken: String, accountIDs: [String]) async -> [String: Bool] {
        guard !accountIDs.isEmpty else { return [:] }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/accounts/relationships"
        components.queryItems = accountIDs.map { URLQueryItem(name: "id[]", value: $0) }
        guard let url = components.url else { return [:] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.dataWithRateLimit(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode([Relationship].self, from: data) else {
            return [:]
        }
        return Dictionary(decoded.map { ($0.id, $0.following) }, uniquingKeysWith: { a, _ in a })
    }

    private struct Relationship: Decodable {
        let id: String
        let following: Bool
    }
}
