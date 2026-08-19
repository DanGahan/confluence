import Testing
import Foundation
@testable import ConfluenceKit

/// Thread-safe helpers for stateful MockURLProtocol handlers (@Sendable).
private final class Seq: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

/// Reads the `nonce` claim out of a request's DPoP proof header (base64url JWT payload).
private func dpopNonce(_ request: URLRequest) -> String? {
    guard let header = request.value(forHTTPHeaderField: "DPoP") else { return nil }
    let parts = header.split(separator: ".")
    guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
          let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    return json["nonce"] as? String
}

struct ATProtoOAuthServiceTests {
    private func dpop() -> DPoPProofBuilder { DPoPProofBuilder(key: DPoPKey()) }

    @Test func resolveHandleReturnsDID() async throws {
        let svc = ATProtoOAuthService(session: MockURLProtocol.session { request in
            #expect(request.url?.path == "/xrpc/com.atproto.identity.resolveHandle")
            #expect(request.url?.query?.contains("handle=alice.bsky.social") == true)
            return (request.status(200), #"{"did":"did:plc:alice"}"#.data(using: .utf8)!)
        })
        #expect(try await svc.resolveHandle("alice.bsky.social") == "did:plc:alice")
    }

    @Test func parReturnsRequestURI() async throws {
        let svc = ATProtoOAuthService(session: MockURLProtocol.session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "DPoP") != nil) // proof attached
            return (request.status(201), #"{"request_uri":"urn:ietf:params:oauth:request_uri:abc","expires_in":60}"#.data(using: .utf8)!)
        })
        let uri = try await svc.pushAuthorizationRequest(endpoint: URL(string: "https://as.example/par")!,
                                                         params: ["client_id": "x"], dpop: dpop())
        #expect(uri == "urn:ietf:params:oauth:request_uri:abc")
    }

    @Test func retriesOnceWithServerDPoPNonce() async throws {
        let seq = Seq()
        let retryNonce = Box<String?>(nil)
        let svc = ATProtoOAuthService(session: MockURLProtocol.session { request in
            if seq.next() == 0 {
                // AS demands a nonce: 400 + DPoP-Nonce, error use_dpop_nonce.
                let resp = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                                           headerFields: ["DPoP-Nonce": "srv-nonce-1"])!
                return (resp, #"{"error":"use_dpop_nonce"}"#.data(using: .utf8)!)
            }
            retryNonce.value = dpopNonce(request) // capture the retry's proof nonce
            return (request.status(200), #"{"request_uri":"urn:ok"}"#.data(using: .utf8)!)
        }, nonceStore: DPoPNonceStore()) // fresh cache so the first attempt starts nonce-less
        let uri = try await svc.pushAuthorizationRequest(endpoint: URL(string: "https://as.example/par")!,
                                                         params: ["client_id": "x"], dpop: dpop())
        #expect(uri == "urn:ok")
        #expect(retryNonce.value == "srv-nonce-1") // the retry carried the server nonce
    }

    @Test func exchangeCodeReturnsTokens() async throws {
        let svc = ATProtoOAuthService(session: MockURLProtocol.session { request in
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("grant_type=authorization_code"))
            #expect(body.contains("code_verifier=ver"))
            let json = #"{"access_token":"at","refresh_token":"rt","token_type":"DPoP","sub":"did:plc:me","scope":"atproto"}"#
            return (request.status(200), json.data(using: .utf8)!)
        })
        let tokens = try await svc.exchangeCode(tokenEndpoint: URL(string: "https://as.example/token")!,
                                                code: "authcode", verifier: "ver", dpop: dpop())
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.tokenType == "DPoP")
        #expect(tokens.sub == "did:plc:me")
    }
}
