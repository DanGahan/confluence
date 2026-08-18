import Foundation

extension BlueskyClient {
    /// Creates an `app.bsky.graph.follow` record. Returns the new record's URI (needed to unfollow).
    public func follow(auth: BlueskyAuth, repoDID: String, subjectDID: String) async throws -> String {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.createRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": repoDID,
            "collection": "app.bsky.graph.follow",
            "record": [
                "$type": "app.bsky.graph.follow",
                "subject": subjectDID,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ],
        ])
        let (data, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else { throw mapError(http.statusCode) }
        struct Created: Decodable { let uri: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw BlueskyError.malformedResponse }
        return created.uri
    }

    /// Deletes a follow record by its `at://repo/collection/rkey` URI.
    public func unfollow(auth: BlueskyAuth, followURI: String) async throws {
        let parts = followURI.replacingOccurrences(of: "at://", with: "").split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw BlueskyError.malformedResponse }
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.deleteRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": parts[0], "collection": parts[1], "rkey": parts[2],
        ])
        let (_, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else { throw mapError(http.statusCode) }
    }

    private func mapError(_ status: Int) -> BlueskyError {
        switch status {
        case 401: return .invalidCredentials
        case 429: return .rateLimited
        default: return .server("Bluesky returned status \(status).")
        }
    }
}
