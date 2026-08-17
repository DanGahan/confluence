import Foundation

extension BlueskyClient {
    /// The Bluesky chat service is a separate appview, reached by proxying XRPC calls to the PDS
    /// with this header. Requires an app password with DM access (see SPEC F15 / Accounts).
    private static let chatProxy = "did:web:api.bsky.chat#bsky_chat"

    /// `chat.bsky.convo.listConvos`.
    public func listConvos(accessToken: String, selfDID: String, limit: Int = 50) async throws -> [Conversation] {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/chat.bsky.convo.listConvos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let data = try await chatGET(components.url!, accessToken: accessToken)
        guard let decoded = try? JSONDecoder().decode(ConvoList.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.convos.compactMap { $0.conversation(selfDID: selfDID) }
    }

    /// `chat.bsky.convo.getMessages` — returned oldest-first for display.
    public func messages(convoId: String, accessToken: String, selfDID: String, limit: Int = 50) async throws -> [DirectMessage] {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/chat.bsky.convo.getMessages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "convoId", value: convoId), URLQueryItem(name: "limit", value: String(limit))]
        let data = try await chatGET(components.url!, accessToken: accessToken)
        guard let decoded = try? JSONDecoder().decode(MessageList.self, from: data) else { throw BlueskyError.malformedResponse }
        return decoded.messages.compactMap { $0.message(selfDID: selfDID) }.sorted { $0.sentAt < $1.sentAt }
    }

    /// `chat.bsky.convo.sendMessage` — returns the created message.
    public func sendMessage(convoId: String, text: String, accessToken: String, selfDID: String) async throws -> DirectMessage {
        let url = pdsURL.appending(path: "xrpc/chat.bsky.convo.sendMessage")
        let body = try JSONSerialization.data(withJSONObject: ["convoId": convoId, "message": ["text": text]])
        let data = try await chatPOST(url, body: body, accessToken: accessToken)
        guard let msg = try? JSONDecoder().decode(Message.self, from: data), let dm = msg.message(selfDID: selfDID) else {
            throw BlueskyError.malformedResponse
        }
        return dm
    }

    /// `chat.bsky.convo.updateRead`.
    public func markConvoRead(convoId: String, accessToken: String) async throws {
        let url = pdsURL.appending(path: "xrpc/chat.bsky.convo.updateRead")
        let body = try JSONSerialization.data(withJSONObject: ["convoId": convoId])
        _ = try await chatPOST(url, body: body, accessToken: accessToken)
    }

    // MARK: - Chat transport (adds the atproto-proxy header + shared error handling)

    private func chatGET(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.chatProxy, forHTTPHeaderField: "atproto-proxy")
        return try await chatSend(request)
    }

    private func chatPOST(_ url: URL, body: Data, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.chatProxy, forHTTPHeaderField: "atproto-proxy")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await chatSend(request)
    }

    private func chatSend(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.dataWithRateLimit(for: request) }
        catch { throw BlueskyError.network }
        guard let http = response as? HTTPURLResponse else { throw BlueskyError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let err = (try? JSONDecoder().decode(ChatErr.self, from: data))?.error
            // A normal app password can't reach chat (403). Surface as invalidCredentials so the
            // UI can prompt for a DM-scoped app password rather than showing a raw error.
            if http.statusCode == 401 || http.statusCode == 403 || err == "ExpiredToken" || err == "InvalidToken" {
                throw BlueskyError.invalidCredentials
            }
            if http.statusCode == 429 { throw BlueskyError.rateLimited }
            throw BlueskyError.server("Bluesky chat returned status \(http.statusCode).")
        }
        return data
    }

    private struct ChatErr: Decodable { let error: String? }
    private struct ConvoList: Decodable { let convos: [Convo] }
    private struct Convo: Decodable {
        let id: String
        let members: [Member]
        let lastMessage: LastMessage?
        let unreadCount: Int?
        func conversation(selfDID: String) -> Conversation? {
            let others = members.filter { $0.did != selfDID }
            let date = lastMessage?.sentAt.flatMap(ISO8601.date(from:)) ?? Date(timeIntervalSince1970: 0)
            return Conversation(
                network: .bluesky, rawId: id,
                participants: others.map {
                    DMParticipant(id: $0.did, name: $0.displayName ?? $0.handle, handle: $0.handle,
                                  avatarURL: $0.avatar.flatMap(URL.init(string:)))
                },
                lastSnippet: lastMessage?.text ?? "",
                lastActivity: date,
                unread: (unreadCount ?? 0) > 0
            )
        }
    }
    private struct Member: Decodable { let did: String; let handle: String; let displayName: String?; let avatar: String? }
    private struct LastMessage: Decodable { let text: String?; let sentAt: String? }
    private struct MessageList: Decodable { let messages: [Message] }
    // Deleted messages arrive without text (a union type) and are dropped by the optional decode.
    private struct Message: Decodable {
        let id: String?; let text: String?; let sentAt: String?; let sender: Sender?
        func message(selfDID: String) -> DirectMessage? {
            guard let id, let text, let sentAt, let date = ISO8601.date(from: sentAt), let sender else { return nil }
            return DirectMessage(network: .bluesky, rawId: id, senderID: sender.did,
                                 isFromMe: sender.did == selfDID, text: text, sentAt: date)
        }
    }
    private struct Sender: Decodable { let did: String }
}
