import Foundation

extension BlueskyClient {
    /// Creates an `app.bsky.feed.post` record. Returns the new post's URI.
    public func post(accessToken: String, repoDID: String, text: String) async throws -> String {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.createRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": repoDID,
            "collection": "app.bsky.feed.post",
            "record": [
                "$type": "app.bsky.feed.post",
                "text": text,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ],
        ])

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BlueskyError.network }
        guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw BlueskyError.invalidCredentials }
            throw BlueskyError.server("Bluesky returned status \(http.statusCode).")
        }
        struct Created: Decodable { let uri: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw BlueskyError.malformedResponse }
        return created.uri
    }
}
