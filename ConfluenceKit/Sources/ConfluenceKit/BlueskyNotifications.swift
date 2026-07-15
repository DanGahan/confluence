import Foundation

extension BlueskyClient {
    /// `app.bsky.notification.listNotifications` — filtered to follow/mention/repost.
    public func notifications(accessToken: String, limit: Int = 50) async throws -> [NotificationItem] {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/app.bsky.notification.listNotifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.dataWithRateLimit(for: request) }
        catch { throw BlueskyError.network }
        guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let err = (try? JSONDecoder().decode(ErrBody.self, from: data))?.error
            if http.statusCode == 401 || err == "ExpiredToken" || err == "InvalidToken" || err == "AuthenticationRequired" {
                throw BlueskyError.invalidCredentials
            }
            if http.statusCode == 429 { throw BlueskyError.rateLimited }
            throw BlueskyError.server("Bluesky notifications returned status \(http.statusCode).")
        }
        guard let decoded = try? JSONDecoder().decode(Notifications.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.notifications.compactMap(\.item)
    }

    private struct ErrBody: Decodable { let error: String? }
    private struct Notifications: Decodable { let notifications: [Note] }

    private struct Note: Decodable {
        let uri: String
        let reason: String        // like, repost, follow, mention, reply, quote
        let author: Author
        let record: Record?
        let indexedAt: String

        var item: NotificationItem? {
            let kind: NotificationItem.Kind
            switch reason {
            case "follow": kind = .follow
            case "mention", "reply": kind = .mention
            case "repost": kind = .repost
            default: return nil // likes/quotes out of scope
            }
            guard let date = ISO8601.date(from: indexedAt) else { return nil }
            return NotificationItem(
                network: .bluesky,
                rawId: uri,
                kind: kind,
                actorID: author.did,
                actorName: author.displayName ?? author.handle,
                actorHandle: author.handle,
                avatarURL: author.avatar.flatMap(URL.init(string:)),
                createdAt: date,
                snippet: record?.text ?? ""
            )
        }
    }
    private struct Author: Decodable { let did: String; let handle: String; let displayName: String?; let avatar: String? }
    private struct Record: Decodable { let text: String? }
}
