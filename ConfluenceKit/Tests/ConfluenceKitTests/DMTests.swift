import Testing
import Foundation
@testable import ConfluenceKit

struct DMModelTests {
    func convo(_ n: Network, _ id: String, activity: TimeInterval, unread: Bool = false) -> Conversation {
        Conversation(network: n, rawId: id, participants: [DMParticipant(id: "p", name: "P", handle: "p", avatarURL: nil)],
                     lastSnippet: "hi", lastActivity: Date(timeIntervalSince1970: activity), unread: unread)
    }

    @Test func mergeConversationsSortsNewestFirstAndDedupes() {
        let merged = mergeConversations([
            [convo(.bluesky, "a", activity: 100), convo(.bluesky, "b", activity: 300)],
            [convo(.mastodon, "c", activity: 200), convo(.bluesky, "b", activity: 300)], // dup b
        ])
        #expect(merged.map(\.id) == ["bluesky:b", "mastodon:c", "bluesky:a"])
    }

    @Test func mastodonConversationsAreNotPrivate() {
        #expect(convo(.mastodon, "x", activity: 1).isPrivate == false)
        #expect(convo(.bluesky, "y", activity: 1).isPrivate == true)
    }
}

struct BlueskyChatTests {
    @Test func listConvosFiltersSelfAndFlagsUnread() async throws {
        let json = """
        {"convos":[
          {"id":"c1","unreadCount":2,"members":[
             {"did":"did:me","handle":"me.bsky.social"},
             {"did":"did:ada","handle":"ada.bsky.social","displayName":"Ada","avatar":"https://a"}],
           "lastMessage":{"text":"hey there","sentAt":"2026-07-01T10:00:00.000Z"}}
        ]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/chat.bsky.convo.listConvos")
            #expect(request.value(forHTTPHeaderField: "atproto-proxy") == "did:web:api.bsky.chat#bsky_chat")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (request.status(200), json)
        })
        let convos = try await client.listConvos(auth: .bearer("tok"), selfDID: "did:me")
        #expect(convos.count == 1)
        #expect(convos[0].participants.map(\.id) == ["did:ada"]) // self dropped
        #expect(convos[0].title == "Ada")
        #expect(convos[0].unread == true)
        #expect(convos[0].lastSnippet == "hey there")
    }

    @Test func getMessagesMarksFromMeAndSortsOldestFirst() async throws {
        let json = """
        {"messages":[
          {"id":"m2","text":"second","sentAt":"2026-07-01T10:05:00.000Z","sender":{"did":"did:ada"}},
          {"id":"m1","text":"first","sentAt":"2026-07-01T10:00:00.000Z","sender":{"did":"did:me"}},
          {"id":"gone","sender":{"did":"did:ada"}}
        ]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/chat.bsky.convo.getMessages")
            return (request.status(200), json)
        })
        let msgs = try await client.messages(convoId: "c1", auth: .bearer("tok"), selfDID: "did:me")
        #expect(msgs.map(\.rawId) == ["m1", "m2"])       // oldest first, deleted dropped
        #expect(msgs[0].isFromMe == true)
        #expect(msgs[1].isFromMe == false)
    }

    @Test func sendMessagePostsBodyAndReturnsMessage() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/xrpc/chat.bsky.convo.sendMessage")
            let body = try! JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect(body["convoId"] as? String == "c1")
            #expect((body["message"] as? [String: Any])?["text"] as? String == "yo")
            let resp = #"{"id":"m9","text":"yo","sentAt":"2026-07-01T11:00:00.000Z","sender":{"did":"did:me"}}"#
            return (request.status(200), resp.data(using: .utf8)!)
        })
        let dm = try await client.sendMessage(convoId: "c1", text: "yo", auth: .bearer("tok"), selfDID: "did:me")
        #expect(dm.rawId == "m9")
        #expect(dm.isFromMe == true)
    }

    @Test func resolvePdsEndpointReadsDidDocServiceEndpoint() async throws {
        let didDoc = """
        {"id":"did:plc:abc","service":[
          {"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://puffball.us-east.host.bsky.network"}
        ]}
        """.data(using: .utf8)!
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            #expect(request.url?.absoluteString == "https://plc.directory/did:plc:abc")
            return (request.status(200), didDoc)
        })
        let url = try await client.resolvePdsEndpoint(did: "did:plc:abc")
        #expect(url.absoluteString == "https://puffball.us-east.host.bsky.network")
    }

    @Test func chat403SurfacesAsInvalidCredentials() async {
        let client = BlueskyClient(session: MockURLProtocol.session { request in
            (request.status(403), #"{"error":"AccessDenied"}"#.data(using: .utf8)!)
        })
        await #expect(throws: BlueskyError.invalidCredentials) {
            _ = try await client.listConvos(auth: .bearer("tok"), selfDID: "did:me")
        }
    }
}

struct MastodonConversationsTests {
    @Test func conversationsDecodeAndCarryReplyTarget() async throws {
        let json = """
        [
          {"id":"conv1","unread":true,"accounts":[
             {"id":"11","acct":"ada","display_name":"Ada","avatar":"https://a"}],
           "last_status":{"id":"s1","content":"<p>hi there</p>","created_at":"2026-07-01T10:00:00.000Z",
             "account":{"id":"11","acct":"ada","display_name":"Ada","avatar":"https://a"}}}
        ]
        """.data(using: .utf8)!
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/conversations")
            return (request.status(200), json)
        })
        let convos = try await client.conversations(host: "mastodon.social", accessToken: "mtok")
        #expect(convos.count == 1)
        #expect(convos[0].unread == true)
        #expect(convos[0].isPrivate == false)
        #expect(convos[0].lastSnippet == "hi there")
        #expect(convos[0].mastodonReplyToID == "s1")
        #expect(convos[0].participants[0].handle == "ada@mastodon.social")
    }

    @Test func sendDirectMentionsParticipantsWithDirectVisibility() async throws {
        let convo = Conversation(network: .mastodon, rawId: "conv1",
                                 participants: [DMParticipant(id: "11", name: "Ada", handle: "ada@mastodon.social", avatarURL: nil)],
                                 lastSnippet: "hi", lastActivity: Date(), unread: false, mastodonReplyToID: "s1")
        let client = MastodonClient(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/api/v1/statuses")
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("visibility=direct"))
            #expect(body.contains("in_reply_to_id=s1"))
            #expect(body.contains("status=@ada@mastodon.social")) // participants mentioned
            let resp = #"{"id":"s2","content":"<p>reply</p>","created_at":"2026-07-01T11:00:00.000Z","account":{"id":"me","acct":"me","display_name":"Me","avatar":"https://m"}}"#
            return (request.status(200), resp.data(using: .utf8)!)
        })
        let dm = try await client.sendDirect(conversation: convo, text: "reply", host: "mastodon.social", accessToken: "mtok", selfAccountID: "me")
        #expect(dm.rawId == "s2")
        #expect(dm.isFromMe == true)
        #expect(dm.text == "reply")
    }
}

@MainActor
struct DMStoreTests {
    func actions(_ convos: [Conversation], fail: Bool = false) -> DMActions {
        DMActions(
            listConversations: { if fail { throw DMError.notAvailable }; return convos },
            messages: { _ in [] },
            send: { _, _ in DirectMessage(network: .bluesky, rawId: "x", senderID: "me", isFromMe: true, text: "", sentAt: Date()) },
            markRead: { _ in }
        )
    }
    func convo(_ n: Network, _ id: String, unread: Bool) -> Conversation {
        Conversation(network: n, rawId: id, participants: [], lastSnippet: "", lastActivity: Date(timeIntervalSince1970: id.hashValue == 0 ? 1 : Double(id.count)), unread: unread)
    }

    @Test func refreshMergesAndCountsUnread() async {
        let store = DMStore()
        store.setActions([
            .bluesky: actions([convo(.bluesky, "b1", unread: true)]),
            .mastodon: actions([convo(.mastodon, "m1", unread: false)]),
        ])
        await store.refresh()
        #expect(store.conversations.count == 2)
        #expect(store.unreadCount == 1)
        #expect(store.failedNetworks.isEmpty)
    }

    @Test func oneNetworkFailingIsRecordedNotFatal() async {
        let store = DMStore()
        store.setActions([
            .bluesky: actions([convo(.bluesky, "b1", unread: true)]),
            .mastodon: actions([], fail: true),
        ])
        await store.refresh()
        #expect(store.conversations.count == 1)
        #expect(store.failedNetworks == [.mastodon])
    }

    @Test func markReadFlipsUnreadLocally() async {
        let store = DMStore()
        let c = convo(.bluesky, "b1", unread: true)
        store.setActions([.bluesky: actions([c])])
        await store.refresh()
        #expect(store.unreadCount == 1)
        await store.markRead(store.conversations[0])
        #expect(store.unreadCount == 0)
    }
}
