import Foundation

extension MastodonClient {
    /// `GET /api/v1/notifications` — filtered to follow/mention/reblog.
    public func notifications(host: String, accessToken: String, limit: Int = 40) async throws -> [NotificationItem] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/notifications"
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "types[]", value: "follow"),
            URLQueryItem(name: "types[]", value: "mention"),
            URLQueryItem(name: "types[]", value: "reblog"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            throw MastodonError.server("Mastodon notifications returned status \(http.statusCode).")
        }
        guard let notes = try? JSONDecoder().decode([Note].self, from: data) else { throw MastodonError.malformedResponse }
        return notes.compactMap { $0.item(host: host) }
    }

    private struct Note: Decodable {
        let id: String
        let type: String          // follow, mention, reblog, favourite, ...
        let createdAt: String
        let account: Account
        let status: Status?

        enum CodingKeys: String, CodingKey { case id, type, account, status; case createdAt = "created_at" }

        func item(host: String) -> NotificationItem? {
            let kind: NotificationItem.Kind
            switch type {
            case "follow": kind = .follow
            case "mention": kind = .mention
            case "reblog": kind = .repost
            default: return nil
            }
            guard let date = ISO8601.date(from: createdAt) else { return nil }
            return NotificationItem(
                network: .mastodon,
                rawId: id,
                kind: kind,
                actorName: account.displayName.isEmpty ? account.acct : account.displayName,
                actorHandle: account.acct.contains("@") ? account.acct : "\(account.acct)@\(host)",
                avatarURL: URL(string: account.avatar),
                createdAt: date,
                snippet: status.map { htmlToPlainText($0.content) } ?? ""
            )
        }
    }
    private struct Account: Decodable {
        let displayName: String; let acct: String; let avatar: String
        enum CodingKeys: String, CodingKey { case acct, avatar; case displayName = "display_name" }
    }
    private struct Status: Decodable { let content: String }
}
