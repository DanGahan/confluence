import Foundation

extension MastodonClient {
    /// `GET /api/v1/timelines/home` — the home timeline as normalized feed items.
    /// Pagination uses `max_id` = the id of the last (oldest) status returned.
    public func homeTimeline(host: String, accessToken: String, maxId: String?, limit: Int = 40) async throws -> FeedPage {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/timelines/home"
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            + (maxId.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            throw MastodonError.server("Mastodon timeline returned status \(http.statusCode).")
        }

        let statuses: [Status]
        do { statuses = try JSONDecoder().decode([Status].self, from: data) }
        catch { throw MastodonError.malformedResponse }

        let items = statuses.compactMap { $0.feedItem(host: host) }
        // Next page starts below the oldest status we received.
        return FeedPage(items: items, nextCursor: statuses.isEmpty ? nil : statuses.last?.id)
    }

    // MARK: - Wire format (only the fields we render)

    private struct Status: Decodable {
        let id: String
        let createdAt: String
        let content: String
        let account: Account
        let mediaAttachments: [Media]
        let reblog: Box?

        enum CodingKeys: String, CodingKey {
            case id, content, account, reblog
            case createdAt = "created_at"
            case mediaAttachments = "media_attachments"
        }

        /// A boost carries the original post in `reblog`; show that, attributed to the booster.
        func feedItem(host: String) -> FeedItem? {
            if let reblog = reblog?.value {
                // Order by the boost time (this status), not the original's authored time.
                return reblog.feedItem(host: host, boostedBy: account.displayName.isEmpty ? account.acct : account.displayName,
                                       boostId: id, orderCreatedAt: createdAt)
            }
            return feedItem(host: host, boostedBy: nil, boostId: nil, orderCreatedAt: createdAt)
        }

        private func feedItem(host: String, boostedBy: String?, boostId: String?, orderCreatedAt: String) -> FeedItem? {
            guard let date = ISO8601.date(from: orderCreatedAt) else { return nil }
            return FeedItem(
                network: .mastodon,
                rawId: boostId ?? id,
                authorID: account.id,
                authorName: account.displayName.isEmpty ? account.acct : account.displayName,
                authorHandle: account.acct.contains("@") ? account.acct : "\(account.acct)@\(host)",
                avatarURL: URL(string: account.avatar),
                createdAt: date,
                text: htmlToPlainText(content),
                imageURLs: mediaAttachments.filter { $0.type == "image" }.compactMap { URL(string: $0.url) },
                repostedBy: boostedBy
            )
        }

        // Indirection so Status can contain a Status (reblog).
        final class Box: Decodable { let value: Status; init(from decoder: Decoder) throws { value = try Status(from: decoder) } }
    }

    private struct Account: Decodable {
        let id: String
        let displayName: String
        let acct: String
        let avatar: String
        enum CodingKeys: String, CodingKey { case id, acct, avatar; case displayName = "display_name" }
    }
    private struct Media: Decodable {
        let type: String
        let url: String
    }
}

/// Minimal HTML → text for Mastodon post bodies. Full rendering (links, mentions) is F11.
// ponytail: regex strip + common entities; swap for AttributedString(html:) if rich text is needed.
func htmlToPlainText(_ html: String) -> String {
    var text = html
    text = text.replacingOccurrences(of: "</p>", with: "\n\n")
    text = text.replacingOccurrences(of: "<br>", with: "\n")
    text = text.replacingOccurrences(of: "<br/>", with: "\n")
    text = text.replacingOccurrences(of: "<br />", with: "\n")
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
    for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
