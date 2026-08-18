import Testing
import Foundation
@testable import ConfluenceKit

/// Sendable wrapper for the URL→response map so the MockURLProtocol handler
/// (which is @Sendable) can read it directly without any actor hop.
private final class Script: @unchecked Sendable {
    let responses: [String: (Int, Data)]
    init(_ responses: [String: (Int, Data)]) { self.responses = responses }
}

private func discovery(_ scripted: [String: (Int, Data)]) -> ATProtoDiscovery {
    let script = Script(scripted)
    let session = MockURLProtocol.session { request in
        let key = request.url?.absoluteString ?? ""
        guard let (status, body) = script.responses[key] else {
            throw URLError(.badURL) // → ATProtoDiscoveryError.network at the caller
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (http, body)
    }
    return ATProtoDiscovery(session: session, plcDirectory: URL(string: "https://plc.directory")!)
}

struct ATProtoDiscoveryTests {

    // MARK: fixtures

    private static let plcDIDDoc = Data("""
    {
      "service": [
        {"id": "#atproto_pds", "type": "AtprotoPersonalDataServer",
         "serviceEndpoint": "https://pds.alice.example"}
      ]
    }
    """.utf8)

    private static let protectedResource = Data("""
    {"authorization_servers": ["https://bsky.social"]}
    """.utf8)

    private static let asMetadata = Data("""
    {
      "authorization_endpoint": "https://bsky.social/oauth/authorize",
      "token_endpoint": "https://bsky.social/oauth/token",
      "pushed_authorization_request_endpoint": "https://bsky.social/oauth/par",
      "revocation_endpoint": "https://bsky.social/oauth/revoke"
    }
    """.utf8)

    // MARK: happy path

    @Test func plcDIDResolvesThroughFullPipeline() async throws {
        let sut = discovery([
            "https://plc.directory/did:plc:alice": (200, Self.plcDIDDoc),
            "https://pds.alice.example/.well-known/oauth-protected-resource": (200, Self.protectedResource),
            "https://bsky.social/.well-known/oauth-authorization-server": (200, Self.asMetadata),
        ])
        let endpoints = try await sut.endpoints(for: "did:plc:alice")
        #expect(endpoints.pdsURL.absoluteString == "https://pds.alice.example")
        #expect(endpoints.authorizationServer.absoluteString == "https://bsky.social")
        #expect(endpoints.pushedAuthorizationRequestEndpoint.absoluteString == "https://bsky.social/oauth/par")
        #expect(endpoints.authorizationEndpoint.absoluteString == "https://bsky.social/oauth/authorize")
        #expect(endpoints.tokenEndpoint.absoluteString == "https://bsky.social/oauth/token")
        #expect(endpoints.revocationEndpoint?.absoluteString == "https://bsky.social/oauth/revoke")
    }

    @Test func webDIDResolvesFromWellKnownOnItsDomain() async throws {
        let sut = discovery([
            "https://alice.example/.well-known/did.json": (200, Self.plcDIDDoc),
            "https://pds.alice.example/.well-known/oauth-protected-resource": (200, Self.protectedResource),
            "https://bsky.social/.well-known/oauth-authorization-server": (200, Self.asMetadata),
        ])
        let endpoints = try await sut.endpoints(for: "did:web:alice.example")
        #expect(endpoints.pdsURL.absoluteString == "https://pds.alice.example")
    }

    @Test func webDIDWithPathResolvesFromPathScopedURL() async throws {
        let sut = discovery([
            "https://example.com/users/alice/did.json": (200, Self.plcDIDDoc),
            "https://pds.alice.example/.well-known/oauth-protected-resource": (200, Self.protectedResource),
            "https://bsky.social/.well-known/oauth-authorization-server": (200, Self.asMetadata),
        ])
        let endpoints = try await sut.endpoints(for: "did:web:example.com:users:alice")
        #expect(endpoints.pdsURL.absoluteString == "https://pds.alice.example")
    }

    // MARK: parses DID document correctly

    @Test func didDocumentWithoutAtprotoPDSSurfacesAsError() async {
        let didDocNoPDS = Data(#"""
        {"service": [{"id": "#other", "type": "SomethingElse", "serviceEndpoint": "https://x"}]}
        """#.utf8)
        let sut = discovery(["https://plc.directory/did:plc:alice": (200, didDocNoPDS)])
        await #expect(throws: ATProtoDiscoveryError.noPDSInDIDDocument) {
            _ = try await sut.endpoints(for: "did:plc:alice")
        }
    }

    @Test func didDocumentAcceptsFullyQualifiedServiceID() async throws {
        // Some DID generators emit `did:plc:xxx#atproto_pds` rather than just `#atproto_pds`.
        let didDoc = Data(#"""
        {"service": [{"id": "did:plc:alice#atproto_pds", "type": "AtprotoPersonalDataServer",
                      "serviceEndpoint": "https://pds.alice.example"}]}
        """#.utf8)
        let sut = discovery([
            "https://plc.directory/did:plc:alice": (200, didDoc),
            "https://pds.alice.example/.well-known/oauth-protected-resource": (200, Self.protectedResource),
            "https://bsky.social/.well-known/oauth-authorization-server": (200, Self.asMetadata),
        ])
        let endpoints = try await sut.endpoints(for: "did:plc:alice")
        #expect(endpoints.pdsURL.absoluteString == "https://pds.alice.example")
    }

    // MARK: error cases

    @Test func unsupportedDIDMethodThrows() async {
        let sut = discovery([:])
        await #expect(throws: ATProtoDiscoveryError.unsupportedDIDMethod("did:key:foo")) {
            _ = try await sut.endpoints(for: "did:key:foo")
        }
    }

    @Test func networkFailureBubblesUp() async {
        let sut = discovery([:]) // any URL returns .badURL → mapped to .network
        await #expect(throws: ATProtoDiscoveryError.network) {
            _ = try await sut.endpoints(for: "did:plc:alice")
        }
    }

    @Test func malformedAuthorizationServerMetadataSurfaces() async {
        let sut = discovery([
            "https://plc.directory/did:plc:alice": (200, Self.plcDIDDoc),
            "https://pds.alice.example/.well-known/oauth-protected-resource": (200, Self.protectedResource),
            // Missing endpoints entirely → decode succeeds, but nil endpoints → surfaces.
            "https://bsky.social/.well-known/oauth-authorization-server": (200, Data("{}".utf8)),
        ])
        await #expect(throws: ATProtoDiscoveryError.malformedAuthorizationServerMetadata) {
            _ = try await sut.endpoints(for: "did:plc:alice")
        }
    }

    @Test func emptyAuthorizationServersListSurfaces() async {
        let sut = discovery([
            "https://plc.directory/did:plc:alice": (200, Self.plcDIDDoc),
            "https://pds.alice.example/.well-known/oauth-protected-resource":
                (200, Data(#"{"authorization_servers": []}"#.utf8)),
        ])
        await #expect(throws: ATProtoDiscoveryError.malformedProtectedResource) {
            _ = try await sut.endpoints(for: "did:plc:alice")
        }
    }
}
