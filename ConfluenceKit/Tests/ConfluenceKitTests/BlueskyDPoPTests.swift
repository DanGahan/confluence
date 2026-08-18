import Testing
import Foundation
@testable import ConfluenceKit

private final class Seq: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

/// Guards slice-3 (#105): an OAuth (DPoP) auth signs authed Bluesky calls with the DPoP scheme +
/// a per-request proof, and retries once on a DPoP-Nonce challenge — while app-password stays Bearer.
struct BlueskyDPoPTests {
    @Test func bearerAuthUsesBearerSchemeNoProof() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            #expect(req.value(forHTTPHeaderField: "DPoP") == nil)
            return (req.status(200), #"{"feed":[]}"#.data(using: .utf8)!)
        })
        _ = try await client.timeline(auth: .bearer("tok"), cursor: nil)
    }

    @Test func dpopAuthSignsWithProofAndDPoPScheme() async throws {
        let client = BlueskyClient(session: MockURLProtocol.session { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "DPoP tok")
            #expect(req.value(forHTTPHeaderField: "DPoP") != nil) // per-request proof attached
            return (req.status(200), #"{"feed":[]}"#.data(using: .utf8)!)
        })
        _ = try await client.timeline(auth: .dpop(accessToken: "tok", key: DPoPKey()), cursor: nil)
    }

    @Test func dpopRetriesOnceWithServerNonce() async throws {
        let seq = Seq()
        let secondCarriedNonce = Box(false)
        let client = BlueskyClient(session: MockURLProtocol.session { req in
            if seq.next() == 0 {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil,
                                           headerFields: ["DPoP-Nonce": "srv-1"])!
                return (resp, Data())
            }
            // retry: pull the nonce claim from the fresh DPoP proof
            if let header = req.value(forHTTPHeaderField: "DPoP") {
                let parts = header.split(separator: ".")
                if parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
                   let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    secondCarriedNonce.value = (json["nonce"] as? String) == "srv-1"
                }
            }
            return (req.status(200), #"{"feed":[]}"#.data(using: .utf8)!)
        })
        _ = try await client.timeline(auth: .dpop(accessToken: "tok", key: DPoPKey()), cursor: nil)
        #expect(secondCarriedNonce.value)
    }
}
