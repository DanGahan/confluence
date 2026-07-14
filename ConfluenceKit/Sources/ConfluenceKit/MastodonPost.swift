import Foundation

extension MastodonClient {
    /// `POST /api/v1/statuses` — publishes a status, optionally attaching uploaded media.
    public func post(host: String, accessToken: String, text: String, mediaIDs: [String] = []) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/statuses"
        guard let url = components.url else { throw MastodonError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "status", value: text)]
            + mediaIDs.map { URLQueryItem(name: "media_ids[]", value: $0) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            throw MastodonError.server("Mastodon returned status \(http.statusCode).")
        }
    }

    /// `POST /api/v2/media` (multipart) — uploads an image with an optional alt-text
    /// description. Returns the media id for `media_ids`.
    public func uploadImage(host: String, accessToken: String, data: Data,
                            filename: String, mimeType: String, description: String = "") async throws -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v2/media"
        guard let url = components.url else { throw MastodonError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        // Empty description would still be sent as an empty field — send it only when set,
        // matching Mastodon's convention that omitting `description` leaves the media unlabelled.
        if !description.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"description\"\r\n\r\n".data(using: .utf8)!)
            body.append(description.data(using: .utf8) ?? Data())
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let respData: Data
        let response: URLResponse
        do { (respData, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        // 200 = ready, 202 = still processing (id is usable once processing finishes).
        guard http.statusCode == 200 || http.statusCode == 202 else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            throw MastodonError.server("Mastodon media upload returned status \(http.statusCode).")
        }
        struct Media: Decodable { let id: String }
        guard let media = try? JSONDecoder().decode(Media.self, from: respData) else { throw MastodonError.malformedResponse }
        return media.id
    }

    /// `GET /api/v2/instance` — the instance's max status length (default 500).
    public func characterLimit(host: String) async -> Int {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v2/instance"
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(InstanceInfo.self, from: data),
              let max = decoded.configuration?.statuses?.maxCharacters else {
            return 500
        }
        return max
    }

    private struct InstanceInfo: Decodable {
        let configuration: Configuration?
        struct Configuration: Decodable { let statuses: Statuses? }
        struct Statuses: Decodable {
            let maxCharacters: Int?
            enum CodingKeys: String, CodingKey { case maxCharacters = "max_characters" }
        }
    }
}
