import Foundation

extension MastodonClient {
    /// `POST /api/v1/statuses/:id/reblog`
    public func reblog(host: String, accessToken: String, statusID: String) async throws {
        try await action(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)/reblog")
    }

    /// `POST /api/v1/statuses/:id/unreblog`
    public func unreblog(host: String, accessToken: String, statusID: String) async throws {
        try await action(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)/unreblog")
    }

    /// `POST /api/v1/statuses/:id/favourite`
    public func favourite(host: String, accessToken: String, statusID: String) async throws {
        try await action(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)/favourite")
    }

    /// `POST /api/v1/statuses/:id/unfavourite`
    public func unfavourite(host: String, accessToken: String, statusID: String) async throws {
        try await action(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)/unfavourite")
    }

    /// `POST /api/v1/accounts/:id/block`
    public func block(host: String, accessToken: String, accountID: String) async throws {
        try await action(host: host, accessToken: accessToken, path: "/api/v1/accounts/\(accountID)/block")
    }

    /// `DELETE /api/v1/statuses/:id` — deletes one of the signed-in user's own posts.
    public func deletePost(host: String, accessToken: String, statusID: String) async throws {
        try await action(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)", method: "DELETE")
    }

    private func action(host: String, accessToken: String, path: String, method: String = "POST") async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path // ids come from the API; URLComponents percent-encodes the path
        guard let url = components.url else { throw MastodonError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            throw MastodonError.server("Mastodon returned status \(http.statusCode).")
        }
    }
}
