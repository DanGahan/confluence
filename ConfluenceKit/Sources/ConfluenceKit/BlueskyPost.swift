import Foundation

extension BlueskyClient {
    /// Uploads image bytes via `com.atproto.repo.uploadBlob`. Returns the `blob` object as JSON
    /// data, ready to embed in a post's `app.bsky.embed.images`.
    public func uploadImage(auth: BlueskyAuth, data: Data, mimeType: String) async throws -> Data {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.uploadBlob"))
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (respData, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw BlueskyError.invalidCredentials }
            if http.statusCode == 429 { throw BlueskyError.rateLimited }
            throw BlueskyError.server("Bluesky upload returned status \(http.statusCode).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let blob = obj["blob"] else { throw BlueskyError.malformedResponse }
        return try JSONSerialization.data(withJSONObject: blob)
    }

    /// Creates an `app.bsky.feed.post` record, optionally with image blobs and per-image alt-text.
    /// `images` pairs each uploaded blob (returned by `uploadImage`) with its alt description
    /// (empty string is allowed and posts as no description).
    public func post(auth: BlueskyAuth, repoDID: String, text: String,
                     images: [(blob: Data, alt: String)] = [],
                     reply: (parent: PostRef, root: PostRef)? = nil) async throws -> String {
        var record: [String: Any] = [
            "$type": "app.bsky.feed.post",
            "text": text,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let reply {
            record["reply"] = [
                "parent": ["uri": reply.parent.uri, "cid": reply.parent.cid],
                "root": ["uri": reply.root.uri, "cid": reply.root.cid],
            ]
        }
        if !images.isEmpty {
            let embeds = try images.map { image in
                ["alt": image.alt, "image": try JSONSerialization.jsonObject(with: image.blob)]
            }
            record["embed"] = ["$type": "app.bsky.embed.images", "images": embeds]
        }

        var request = URLRequest(url: pdsURL.appending(path: "xrpc/com.atproto.repo.createRecord"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "repo": repoDID, "collection": "app.bsky.feed.post", "record": record,
        ])

        let (data, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw BlueskyError.invalidCredentials }
            if http.statusCode == 429 { throw BlueskyError.rateLimited }
            throw BlueskyError.server("Bluesky returned status \(http.statusCode).")
        }
        struct Created: Decodable { let uri: String }
        guard let created = try? JSONDecoder().decode(Created.self, from: data) else { throw BlueskyError.malformedResponse }
        return created.uri
    }
}
