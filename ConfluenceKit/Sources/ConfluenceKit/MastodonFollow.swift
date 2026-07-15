import Foundation

extension MastodonClient {
    /// `POST /api/v1/accounts/:id/follow`
    public func follow(host: String, accessToken: String, accountID: String) async throws {
        try await relationshipAction(host: host, accessToken: accessToken, accountID: accountID, verb: "follow")
    }

    /// `POST /api/v1/accounts/:id/unfollow`
    public func unfollow(host: String, accessToken: String, accountID: String) async throws {
        try await relationshipAction(host: host, accessToken: accessToken, accountID: accountID, verb: "unfollow")
    }

    private func relationshipAction(host: String, accessToken: String, accountID: String, verb: String) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // accountID comes from the API (numeric-ish); still, encode it into the path safely.
        components.path = "/api/v1/accounts/\(accountID)/\(verb)"
        guard let url = components.url else { throw MastodonError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response: URLResponse
        do { (_, response) = try await session.dataWithRateLimit(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            if http.statusCode == 429 { throw MastodonError.rateLimited }
            throw MastodonError.server("Mastodon returned status \(http.statusCode).")
        }
    }
}
