import Foundation

extension MastodonClient {
    /// `GET /api/v1/conversations` — Mastodon "DMs" are `direct`-visibility statuses, not a
    /// private inbox (see SPEC F15).
    public func conversations(host: String, accessToken: String, limit: Int = 40) async throws -> [Conversation] {
        let url = try convoURL(host: host, path: "/api/v1/conversations",
                               query: [URLQueryItem(name: "limit", value: String(limit))])
        let data = try await convoGET(url, accessToken: accessToken)
        guard let convos = try? JSONDecoder().decode([Convo].self, from: data) else { throw MastodonError.malformedResponse }
        return convos.compactMap { $0.conversation(host: host) }
    }

    /// A conversation's thread = the last status plus its ancestors (earlier messages).
    public func directThread(conversation: Conversation, host: String, accessToken: String, selfAccountID: String) async throws -> [DirectMessage] {
        guard let statusID = conversation.mastodonReplyToID else { return [] }
        let statusData = try await convoGET(try convoURL(host: host, path: "/api/v1/statuses/\(statusID)"), accessToken: accessToken)
        let contextData = try await convoGET(try convoURL(host: host, path: "/api/v1/statuses/\(statusID)/context"), accessToken: accessToken)
        guard let last = try? JSONDecoder().decode(DMStatus.self, from: statusData),
              let context = try? JSONDecoder().decode(Context.self, from: contextData) else {
            throw MastodonError.malformedResponse
        }
        return (context.ancestors + [last]).map { $0.message(selfAccountID: selfAccountID) }
    }

    /// Send = post a `direct`-visibility status mentioning the other participants, threaded onto
    /// the conversation's last status. Returns the created message.
    public func sendDirect(conversation: Conversation, text: String, host: String, accessToken: String, selfAccountID: String) async throws -> DirectMessage {
        let mentions = conversation.participants.map { "@\($0.handle)" }.joined(separator: " ")
        let status = mentions.isEmpty ? text : "\(mentions) \(text)"
        var request = URLRequest(url: try convoURL(host: host, path: "/api/v1/statuses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "visibility", value: "direct"),
        ] + (conversation.mastodonReplyToID.map { [URLQueryItem(name: "in_reply_to_id", value: $0)] } ?? [])
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let data = try await convoSend(request)
        guard let created = try? JSONDecoder().decode(DMStatus.self, from: data) else { throw MastodonError.malformedResponse }
        return created.message(selfAccountID: selfAccountID)
    }

    /// `POST /api/v1/conversations/:id/read`.
    public func markConversationRead(id: String, host: String, accessToken: String) async throws {
        var request = URLRequest(url: try convoURL(host: host, path: "/api/v1/conversations/\(id)/read"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await convoSend(request)
    }

    // MARK: - helpers

    private func convoURL(host: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = path
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw MastodonError.malformedResponse }
        return url
    }

    private func convoGET(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await convoSend(request)
    }

    private func convoSend(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.dataWithRateLimit(for: request) }
        catch { throw MastodonError.network }
        guard let http = response as? HTTPURLResponse else { throw MastodonError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MastodonError.tokenExchangeFailed }
            if http.statusCode == 429 { throw MastodonError.rateLimited }
            throw MastodonError.server("Mastodon conversations returned status \(http.statusCode).")
        }
        return data
    }

    private struct Convo: Decodable {
        let id: String
        let unread: Bool
        let accounts: [Account]
        let lastStatus: DMStatus?
        enum CodingKeys: String, CodingKey { case id, unread, accounts; case lastStatus = "last_status" }
        func conversation(host: String) -> Conversation? {
            Conversation(
                network: .mastodon, rawId: id,
                participants: accounts.map { $0.participant(host: host) },
                lastSnippet: lastStatus.map { htmlToPlainText($0.content) } ?? "",
                lastActivity: lastStatus.flatMap { ISO8601.date(from: $0.createdAt) } ?? Date(timeIntervalSince1970: 0),
                unread: unread,
                mastodonReplyToID: lastStatus?.id
            )
        }
    }
    private struct Context: Decodable { let ancestors: [DMStatus] }
    private struct Account: Decodable {
        let id: String; let acct: String; let displayName: String; let avatar: String
        enum CodingKeys: String, CodingKey { case id, acct, avatar; case displayName = "display_name" }
        func participant(host: String) -> DMParticipant {
            DMParticipant(id: id, name: displayName.isEmpty ? acct : displayName,
                          handle: acct.contains("@") ? acct : "\(acct)@\(host)",
                          avatarURL: URL(string: avatar))
        }
    }
    private struct DMStatus: Decodable {
        let id: String; let content: String; let createdAt: String; let account: Account
        enum CodingKeys: String, CodingKey { case id, content, account; case createdAt = "created_at" }
        func message(selfAccountID: String) -> DirectMessage {
            DirectMessage(network: .mastodon, rawId: id, senderID: account.id,
                          isFromMe: account.id == selfAccountID,
                          text: htmlToPlainText(content),
                          sentAt: ISO8601.date(from: createdAt) ?? Date(timeIntervalSince1970: 0))
        }
    }
}
