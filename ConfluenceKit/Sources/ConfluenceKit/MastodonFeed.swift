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

    /// `GET /api/v1/accounts/:id/statuses` — a single account's posts.
    public func accountStatuses(host: String, accessToken: String, accountID: String, maxId: String?, limit: Int = 40) async throws -> FeedPage {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/accounts/\(accountID)/statuses"
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            + (maxId.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MastodonError.server("Mastodon account statuses failed.")
        }
        guard let statuses = try? JSONDecoder().decode([Status].self, from: data) else { throw MastodonError.malformedResponse }
        let items = statuses.compactMap { $0.feedItem(host: host) }
        return FeedPage(items: items, nextCursor: statuses.isEmpty ? nil : statuses.last?.id)
    }

    /// `GET /api/v1/statuses/:id` + `/context` — the full conversation, chronological.
    public func statusContext(host: String, accessToken: String, statusID: String) async throws -> PostThread {
        async let focus = fetchStatus(host: host, accessToken: accessToken, statusID: statusID)
        async let context = fetchContext(host: host, accessToken: accessToken, statusID: statusID)
        let (focusStatus, ctx) = try await (focus, context)

        let all = (ctx.ancestors + [focusStatus] + ctx.descendants).compactMap { $0.feedItem(host: host) }
        let focusID = focusStatus.feedItem(host: host)?.id ?? all.first?.id ?? ""
        return PostThread(items: chronological(all), focusID: focusID)
    }

    private func fetchStatus(host: String, accessToken: String, statusID: String) async throws -> Status {
        let data = try await getJSON(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)")
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { throw MastodonError.malformedResponse }
        return status
    }

    private func fetchContext(host: String, accessToken: String, statusID: String) async throws -> Context {
        let data = try await getJSON(host: host, accessToken: accessToken, path: "/api/v1/statuses/\(statusID)/context")
        guard let ctx = try? JSONDecoder().decode(Context.self, from: data) else { throw MastodonError.malformedResponse }
        return ctx
    }

    private func getJSON(host: String, accessToken: String, path: String) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MastodonError.server("Mastodon request to \(path) failed.")
        }
        return data
    }

    private struct Context: Decodable {
        let ancestors: [Status]
        let descendants: [Status]
    }

    /// Decodes the `statuses` array of a `/api/v2/search` response into rich feed items
    /// (links, images) using the same status decoding as the timeline. Internal so
    /// MastodonSearch can reuse the private status model.
    func searchStatusItems(from data: Data, host: String) -> [FeedItem] {
        struct Response: Decodable { let statuses: [Status] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.statuses.compactMap { $0.feedItem(host: host) }
    }

    // MARK: - Wire format (only the fields we render)

    private struct Status: Decodable {
        let id: String
        let createdAt: String
        let content: String
        let account: Account
        let mediaAttachments: [Media]
        let mentions: [Mention]?
        let reblog: Box?
        let repliesCount: Int?
        let inReplyToId: String?
        let url: String?
        let card: Card?

        enum CodingKeys: String, CodingKey {
            case id, content, account, mentions, reblog, url, card
            case createdAt = "created_at"
            case mediaAttachments = "media_attachments"
            case repliesCount = "replies_count"
            case inReplyToId = "in_reply_to_id"
        }

        /// Maps an <a> href (a mention's account URL) to its in-app profile link.
        var mentionLinks: [String: URL] {
            var map: [String: URL] = [:]
            for mention in mentions ?? [] {
                if let url = ProfileLink.url(network: .mastodon, id: mention.id, handle: mention.acct) {
                    map[mention.url] = url
                }
            }
            return map
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
                attributedText: autolinked(mastodonRichText(html: content, mentions: mentionLinks)),
                imageURLs: mediaAttachments.filter { $0.type == "image" }.compactMap { URL(string: $0.url) },
                videos: mediaAttachments.compactMap(\.postVideo),
                // Show the link-preview card only when the post has no media of its own
                // (mirrors the Bluesky rule that images/video win over a card).
                linkCard: mediaAttachments.isEmpty ? card?.linkCard : nil,
                repostedBy: boostedBy,
                threadID: id, // the original status id (for a boost this is the reblog's id)
                replyCount: repliesCount ?? 0,
                isReply: inReplyToId != nil,
                postURL: url.flatMap { URL(string: $0) }
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
        let previewUrl: String?
        enum CodingKeys: String, CodingKey { case type, url; case previewUrl = "preview_url" }

        /// A playable video/gifv attachment, if this is one and the URL parses.
        var postVideo: PostVideo? {
            guard type == "video" || type == "gifv", let playURL = URL(string: url) else { return nil }
            return PostVideo(url: playURL, thumbnailURL: previewUrl.flatMap { URL(string: $0) })
        }
    }
    private struct Mention: Decodable {
        let id: String
        let url: String   // the account's profile URL, matches the <a href> in content
        let acct: String
    }
    /// A status's link-preview card (`/api/v1/statuses` `card`, Open Graph-derived).
    private struct Card: Decodable {
        let url: String
        let title: String
        let description: String
        let image: String?

        var linkCard: LinkCard? {
            guard let link = URL(string: url) else { return nil }
            return LinkCard(url: link, title: title.isEmpty ? url : title, description: description,
                            thumbURL: image.flatMap { URL(string: $0) })
        }
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
    return decodeHTMLEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
}
