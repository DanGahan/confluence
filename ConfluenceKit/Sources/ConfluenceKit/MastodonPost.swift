import Foundation

extension MastodonClient {
    /// `POST /api/v1/statuses` — publishes a status.
    public func post(host: String, accessToken: String, text: String) async throws {
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
