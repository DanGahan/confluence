import Testing
import Foundation
@testable import ConfluenceKit

struct ATProtoOAuthFlowTests {
    private func endpoints() -> ATProtoOAuthEndpoints {
        ATProtoOAuthEndpoints(
            pdsURL: URL(string: "https://pds.example")!,
            authorizationServer: URL(string: "https://as.example")!,
            pushedAuthorizationRequestEndpoint: URL(string: "https://as.example/par")!,
            authorizationEndpoint: URL(string: "https://as.example/authorize")!,
            tokenEndpoint: URL(string: "https://as.example/token")!,
            revocationEndpoint: nil)
    }
    private func request(state: String) -> ATProtoAuthorizationRequest {
        ATProtoAuthorizationRequest(
            authorizationURL: URL(string: "https://as.example/authorize")!, callbackScheme: "app",
            did: "did:plc:me", endpoints: endpoints(), pkce: PKCE(verifier: "ver"), dpopKey: DPoPKey(), state: state)
    }

    @Test func completeRejectsStateMismatch() async {
        let flow = ATProtoOAuthFlow(session: MockURLProtocol.session { _ in
            Issue.record("token endpoint must not be called on state mismatch")
            return (URLRequest(url: URL(string: "https://x")!).status(200), Data())
        })
        let cb = URL(string: "app://oauth-callback?code=abc&state=WRONG")!
        await #expect(throws: ATProtoOAuthError.malformedResponse) {
            _ = try await flow.complete(request(state: "RIGHT"), callbackURL: cb, handle: "alice.bsky.social")
        }
    }

    @Test func completeExchangesCodeAndBuildsSession() async throws {
        let flow = ATProtoOAuthFlow(session: MockURLProtocol.session { req in
            #expect(req.url?.path == "/token")
            let body = String(data: MockURLProtocol.body(of: req), encoding: .utf8) ?? ""
            #expect(body.contains("code=authcode"))
            #expect(body.contains("code_verifier=ver"))
            let json = #"{"access_token":"at","refresh_token":"rt","token_type":"DPoP","sub":"did:plc:me"}"#
            return (req.status(200), json.data(using: .utf8)!)
        })
        let cb = URL(string: "app://oauth-callback?code=authcode&state=RIGHT")!
        let s = try await flow.complete(request(state: "RIGHT"), callbackURL: cb, handle: "@alice.bsky.social")
        #expect(s.did == "did:plc:me")
        #expect(s.handle == "alice.bsky.social") // trimmed
        #expect(s.accessToken == "at")
        #expect(s.tokenEndpoint == URL(string: "https://as.example/token")!)
        #expect((try? s.dpopKey()) != nil) // DPoP key round-trips from persisted scalar
    }
}
