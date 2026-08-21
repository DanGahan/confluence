import Foundation
import os

// Chat failures log the HTTP status/error code or the DecodingError's *key path* only — never
// field values — so no message content is logged (SPEC F15). The convo/message decode paths are
// still unexercised against real data (needs an account with DMs), so these stay useful.
private let chatLog = Logger(subsystem: "com.dangahan.confluence", category: "bluesky.chat")

extension BlueskyClient {
    /// The Bluesky chat service is a separate appview, reached by proxying XRPC calls to the PDS
    /// with this header. Requires an app password with DM access (see SPEC F15 / Accounts).
    private static let chatProxy = "did:web:api.bsky.chat#bsky_chat"

    /// Chat must be called on the account's own PDS, not the `bsky.social` entryway: the entryway
    /// forwards authed requests to the PDS but drops the chat-proxy directive on that hop, so chat
    /// methods come back 501 (#202). Resolve the PDS service endpoint from the DID document —
    /// `did:plc` via plc.directory, `did:web` via its well-known doc.
    public func resolvePdsEndpoint(did: String) async throws -> URL {
        let docURL: URL
        if did.hasPrefix("did:plc:") {
            guard let u = URL(string: "https://plc.directory/\(did)") else { throw BlueskyError.malformedResponse }
            docURL = u
        } else if did.hasPrefix("did:web:") {
            let host = String(did.dropFirst("did:web:".count))
            guard let h = host.removingPercentEncoding, let u = URL(string: "https://\(h)/.well-known/did.json") else {
                throw BlueskyError.malformedResponse
            }
            docURL = u
        } else {
            throw BlueskyError.malformedResponse
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.dataWithRateLimit(for: URLRequest(url: docURL)) }
        catch { throw BlueskyError.network }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let doc = try? JSONDecoder().decode(DIDDoc.self, from: data),
              let endpoint = doc.service?.first(where: { $0.id.hasSuffix("atproto_pds") })?.serviceEndpoint,
              let url = URL(string: endpoint), url.scheme == "https" else {  // HTTPS only, no ATS exceptions
            throw BlueskyError.malformedResponse
        }
        return url
    }

    private struct DIDDoc: Decodable {
        let service: [Service]?
        struct Service: Decodable { let id: String; let serviceEndpoint: String }
    }

    /// `chat.bsky.convo.listConvos`.
    public func listConvos(auth: BlueskyAuth, selfDID: String, limit: Int = 50) async throws -> [Conversation] {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/chat.bsky.convo.listConvos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let data = try await chatGET(components.url!, auth: auth)
        do {
            return try JSONDecoder().decode(ConvoList.self, from: data).convos.compactMap { $0.conversation(selfDID: selfDID) }
        } catch {
            chatLog.error("listConvos: 2xx but decode failed — \(String(describing: error), privacy: .public)")
            throw BlueskyError.malformedResponse
        }
    }

    /// `chat.bsky.convo.getMessages` — returned oldest-first for display.
    public func messages(convoId: String, auth: BlueskyAuth, selfDID: String, limit: Int = 50) async throws -> [DirectMessage] {
        var components = URLComponents(url: pdsURL.appending(path: "xrpc/chat.bsky.convo.getMessages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "convoId", value: convoId), URLQueryItem(name: "limit", value: String(limit))]
        let data = try await chatGET(components.url!, auth: auth)
        do {
            return try JSONDecoder().decode(MessageList.self, from: data).messages.compactMap { $0.message(selfDID: selfDID) }.sorted { $0.sentAt < $1.sentAt }
        } catch {
            chatLog.error("getMessages: 2xx but decode failed — \(String(describing: error), privacy: .public)")
            throw BlueskyError.malformedResponse
        }
    }

    /// `chat.bsky.convo.sendMessage` — returns the created message.
    public func sendMessage(convoId: String, text: String, auth: BlueskyAuth, selfDID: String) async throws -> DirectMessage {
        let url = pdsURL.appending(path: "xrpc/chat.bsky.convo.sendMessage")
        let body = try JSONSerialization.data(withJSONObject: ["convoId": convoId, "message": ["text": text]])
        let data = try await chatPOST(url, body: body, auth: auth)
        guard let msg = try? JSONDecoder().decode(Message.self, from: data), let dm = msg.message(selfDID: selfDID) else {
            throw BlueskyError.malformedResponse
        }
        return dm
    }

    /// `chat.bsky.convo.updateRead`.
    public func markConvoRead(convoId: String, auth: BlueskyAuth) async throws {
        let url = pdsURL.appending(path: "xrpc/chat.bsky.convo.updateRead")
        let body = try JSONSerialization.data(withJSONObject: ["convoId": convoId])
        _ = try await chatPOST(url, body: body, auth: auth)
    }

    // MARK: - Chat transport (adds the atproto-proxy header + shared error handling)

    private func chatGET(_ url: URL, auth: BlueskyAuth) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.chatProxy, forHTTPHeaderField: "atproto-proxy")
        return try await chatPerform(request, auth: auth)
    }

    private func chatPOST(_ url: URL, body: Data, auth: BlueskyAuth) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.chatProxy, forHTTPHeaderField: "atproto-proxy")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await chatPerform(request, auth: auth)
    }

    private func chatPerform(_ request: URLRequest, auth: BlueskyAuth) async throws -> Data {
        let (data, http) = try await performAuthed(request, auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            let err = (try? JSONDecoder().decode(ChatErr.self, from: data))?.error
            // Error codes are public (no secrets/content) — logs which failure this is.
            chatLog.error("chat \(request.url?.lastPathComponent ?? "?", privacy: .public) failed: status \(http.statusCode, privacy: .public) error \(err ?? "nil", privacy: .public)")
            // A 403 (ScopeMissingError) is a permission problem, not an expired token: an OAuth
            // token without the chat scope, or an app password without DM access. Refreshing won't
            // fix it — and mapping it to invalidCredentials makes withAuth refresh + retry on every
            // DM poll, churning the single-use OAuth refresh token (and, before coalescing, racing
            // it to death). Surface it distinctly so the UI prompts re-auth without a refresh (#217).
            if http.statusCode == 403 || err == "ScopeMissingError" {
                throw BlueskyError.chatUnavailable
            }
            // A genuine expired/invalid access token — let withAuth refresh once and retry.
            if http.statusCode == 401 || err == "ExpiredToken" || err == "InvalidToken" {
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
