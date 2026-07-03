import Foundation

extension BlueskyClient {
    /// Creates an `app.bsky.graph.follow` record. Returns the new record's URI (needed to unfollow).
    public func follow(accessToken: String, repoDID: String, subjectDID: String) async throws -> String {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.createRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": repoDID,
            "collection": "app.bsky.graph.follow",
            "record": [
                "$type": "app.bsky.graph.follow",
                "subject": subjectDID,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ],
        ])
        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else { throw mapError(http.statusCode) }
        struct Created: Decodable { let uri: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw BlueskyError.malformedResponse }
        return created.uri
    }

    /// Deletes a follow record by its `at://repo/collection/rkey` URI.
    public func unfollow(accessToken: String, followURI: String) async throws {
        let parts = followURI.replacingOccurrences(of: "at://", with: "").split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw BlueskyError.malformedResponse }
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.deleteRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": parts[0], "collection": parts[1], "rkey": parts[2],
        ])
        let (_, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else { throw mapError(http.statusCode) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
            return (data, http)
        } catch let error as BlueskyError { throw error }
        catch { throw BlueskyError.network }
    }

    private func mapError(_ status: Int) -> BlueskyError {
        status == 401 ? .invalidCredentials : .server("Bluesky returned status \(status).")
    }
}
