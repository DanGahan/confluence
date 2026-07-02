import Testing
import Foundation
@testable import ConfluenceKit

struct BlueskyClientTests {
    func client(handler: @escaping MockURLProtocol.Handler) -> BlueskyClient {
        BlueskyClient(pdsURL: URL(string: "https://bsky.social")!, session: MockURLProtocol.session(handler: handler))
    }

    @Test func createSessionBuildsCorrectRequestAndDecodes() async throws {
        let sut = client { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/xrpc/com.atproto.server.createSession")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: String]
            #expect(body?["identifier"] == "alice.bsky.social")
            #expect(body?["password"] == "app-pw-1234")

            let json = """
            {"did":"did:plc:abc","handle":"alice.bsky.social","accessJwt":"access","refreshJwt":"refresh"}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let session = try await sut.createSession(identifier: "alice.bsky.social", appPassword: "app-pw-1234")
        #expect(session.did == "did:plc:abc")
        #expect(session.handle == "alice.bsky.social")
        #expect(session.accessJwt == "access")
        #expect(session.refreshJwt == "refresh")
    }

    @Test func badPasswordMapsToInvalidCredentials() async {
        let sut = client { request in
            let json = #"{"error":"AuthenticationRequired","message":"Invalid identifier or password"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, json)
        }
        await #expect(throws: BlueskyError.invalidCredentials) {
            try await sut.createSession(identifier: "alice.bsky.social", appPassword: "wrong")
        }
    }

    @Test func malformedSuccessBodyThrowsMalformed() async {
        let sut = client { request in
            ( HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
              Data("not json".utf8) )
        }
        await #expect(throws: BlueskyError.malformedResponse) {
            try await sut.createSession(identifier: "alice.bsky.social", appPassword: "x")
        }
    }

    @Test func refreshSendsBearerRefreshToken() async throws {
        let sut = client { request in
            #expect(request.url?.path == "/xrpc/com.atproto.server.refreshSession")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refresh-tok")
            let json = """
            {"did":"did:plc:abc","handle":"alice.bsky.social","accessJwt":"new-access","refreshJwt":"new-refresh"}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let session = try await sut.refreshSession(refreshJwt: "refresh-tok")
        #expect(session.accessJwt == "new-access")
    }
}
