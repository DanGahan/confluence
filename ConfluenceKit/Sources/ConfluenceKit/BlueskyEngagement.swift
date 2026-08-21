import Foundation

extension BlueskyClient {
    /// Creates an `app.bsky.feed.repost` record for the given post. Returns the record URI.
    public func repost(auth: BlueskyAuth, repoDID: String, uri: String, cid: String) async throws -> String {
        try await createRecord(auth: auth, repoDID: repoDID, collection: "app.bsky.feed.repost", record: [
            "$type": "app.bsky.feed.repost",
            "subject": ["uri": uri, "cid": cid],
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    /// Creates an `app.bsky.feed.like` record for the given post. Returns the record URI.
    public func like(auth: BlueskyAuth, repoDID: String, uri: String, cid: String) async throws -> String {
        try await createRecord(auth: auth, repoDID: repoDID, collection: "app.bsky.feed.like", record: [
            "$type": "app.bsky.feed.like",
            "subject": ["uri": uri, "cid": cid],
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    /// Creates an `app.bsky.graph.block` record blocking an account. Returns the record URI.
    public func block(auth: BlueskyAuth, repoDID: String, subjectDID: String) async throws -> String {
        try await createRecord(auth: auth, repoDID: repoDID, collection: "app.bsky.graph.block", record: [
            "$type": "app.bsky.graph.block",
            "subject": subjectDID,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ])
    }

    /// `com.atproto.repo.deleteRecord` — deletes any record the user owns by its AT URI:
    /// a post (delete), or a repost/like record (un-repost/un-like).
    public func deleteRecord(auth: BlueskyAuth, uri: String) async throws {
        let parts = uri.replacingOccurrences(of: "at://", with: "").split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw BlueskyError.malformedResponse }
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.deleteRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": parts[0], "collection": parts[1], "rkey": parts[2],
        ])
        let (_, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw BlueskyError.invalidCredentials
            case 429: throw BlueskyError.rateLimited
            default: throw BlueskyError.server("Bluesky returned status \(http.statusCode).")
            }
        }
    }

    /// Deletes the signed-in user's own post by its AT URI.
    public func deletePost(auth: BlueskyAuth, uri: String) async throws {
        try await deleteRecord(auth: auth, uri: uri)
    }

    private func createRecord(auth: BlueskyAuth, repoDID: String, collection: String, record: [String: Any]) async throws -> String {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.createRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": repoDID, "collection": collection, "record": record,
        ])
        let (data, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw BlueskyError.invalidCredentials
            case 429: throw BlueskyError.rateLimited
            default: throw BlueskyError.server("Bluesky returned status \(http.statusCode).")
            }
        }
        struct Created: Decodable { let uri: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw BlueskyError.malformedResponse }
        return created.uri
    }
}
