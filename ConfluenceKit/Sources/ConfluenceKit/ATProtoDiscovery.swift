import Foundation

/// The endpoints the ATProto OAuth flow needs, once discovery has run to
/// completion for a given user's DID. See `docs/ATPROTO_OAUTH.md`.
public struct ATProtoOAuthEndpoints: Sendable, Equatable {
    public let pdsURL: URL
    public let authorizationServer: URL
    public let pushedAuthorizationRequestEndpoint: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL?
}

public enum ATProtoDiscoveryError: Error, Equatable {
    case unsupportedDIDMethod(String)
    case malformedDIDDocument
    case noPDSInDIDDocument
    case malformedProtectedResource
    case malformedAuthorizationServerMetadata
    case network
}

/// Walks the ATProto discovery chain:
///
/// ```
/// DID → DID document → PDS URL
///                    → /.well-known/oauth-protected-resource → AS URL
///                    → /.well-known/oauth-authorization-server → endpoints
/// ```
///
/// `did:plc:*` DIDs resolve via `plc.directory`; `did:web:host` resolve via
/// `https://host/.well-known/did.json`. Handle resolution (handle → DID) lives
/// in slice 2 alongside the OAuth flow itself.
public struct ATProtoDiscovery: Sendable {
    let session: URLSession
    let plcDirectory: URL

    public init(session: URLSession = .shared,
                plcDirectory: URL = URL(string: "https://plc.directory")!) {
        self.session = session
        self.plcDirectory = plcDirectory
    }

    /// Runs the full pipeline for a DID and returns the OAuth endpoints for its PDS.
    public func endpoints(for did: String) async throws -> ATProtoOAuthEndpoints {
        let didDoc = try await didDocument(for: did)
        guard let pds = didDoc.pdsURL else { throw ATProtoDiscoveryError.noPDSInDIDDocument }
        let protectedResource = try await protectedResource(pds: pds)
        // `authorization_servers` is an ordered array; take the first advertised.
        guard let asURL = protectedResource.authorization_servers.first,
              let authServer = URL(string: asURL) else {
            throw ATProtoDiscoveryError.malformedProtectedResource
        }
        let metadata = try await authorizationServerMetadata(for: authServer)
        guard let auth = metadata.authorization_endpoint.flatMap(URL.init(string:)),
              let token = metadata.token_endpoint.flatMap(URL.init(string:)),
              let par = metadata.pushed_authorization_request_endpoint.flatMap(URL.init(string:)) else {
            throw ATProtoDiscoveryError.malformedAuthorizationServerMetadata
        }
        return ATProtoOAuthEndpoints(
            pdsURL: pds,
            authorizationServer: authServer,
            pushedAuthorizationRequestEndpoint: par,
            authorizationEndpoint: auth,
            tokenEndpoint: token,
            revocationEndpoint: metadata.revocation_endpoint.flatMap(URL.init(string:))
        )
    }

    // MARK: DID → DID document

    /// Fetches the DID document. `did:plc:*` from the PLC directory; `did:web:*`
    /// from `https://<host>/.well-known/did.json` (with support for path-scoped
    /// DIDs, e.g. `did:web:example.com:user:alice` → `https://example.com/user/alice/did.json`).
    func didDocument(for did: String) async throws -> DIDDocument {
        let url: URL
        if did.hasPrefix("did:plc:") {
            url = plcDirectory.appending(path: did)
        } else if did.hasPrefix("did:web:") {
            let rest = String(did.dropFirst("did:web:".count))
            let parts = rest.split(separator: ":").map { $0.removingPercentEncoding ?? String($0) }
            guard let host = parts.first else { throw ATProtoDiscoveryError.unsupportedDIDMethod(did) }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = parts.count == 1
                ? "/.well-known/did.json"
                : "/" + parts.dropFirst().joined(separator: "/") + "/did.json"
            guard let built = components.url else { throw ATProtoDiscoveryError.unsupportedDIDMethod(did) }
            url = built
        } else {
            throw ATProtoDiscoveryError.unsupportedDIDMethod(did)
        }
        let data = try await getJSON(url)
        do { return try JSONDecoder().decode(DIDDocument.self, from: data) }
        catch { throw ATProtoDiscoveryError.malformedDIDDocument }
    }

    // MARK: PDS → protected-resource metadata

    func protectedResource(pds: URL) async throws -> ProtectedResourceMetadata {
        let url = pds.appending(path: ".well-known/oauth-protected-resource")
        let data = try await getJSON(url)
        do { return try JSONDecoder().decode(ProtectedResourceMetadata.self, from: data) }
        catch { throw ATProtoDiscoveryError.malformedProtectedResource }
    }

    // MARK: AS → authorization-server metadata

    func authorizationServerMetadata(for authServer: URL) async throws -> AuthorizationServerMetadata {
        let url = authServer.appending(path: ".well-known/oauth-authorization-server")
        let data = try await getJSON(url)
        do { return try JSONDecoder().decode(AuthorizationServerMetadata.self, from: data) }
        catch { throw ATProtoDiscoveryError.malformedAuthorizationServerMetadata }
    }

    // MARK: Helpers

    private func getJSON(_ url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { throw ATProtoDiscoveryError.network }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ATProtoDiscoveryError.network
        }
        return data
    }

    // MARK: Wire types (only the fields we use)

    struct DIDDocument: Decodable {
        let service: [Service]?

        struct Service: Decodable {
            let id: String
            let type: String
            let serviceEndpoint: String
        }

        /// The PDS lives in the service entry with id `#atproto_pds`. Different DID
        /// generators emit the id as either `#atproto_pds` or the fully-qualified
        /// form `did:...:...#atproto_pds`; match on the fragment.
        var pdsURL: URL? {
            let service = (service ?? []).first { entry in
                entry.type == "AtprotoPersonalDataServer" || entry.id.hasSuffix("#atproto_pds")
            }
            return service.flatMap { URL(string: $0.serviceEndpoint) }
        }
    }

    struct ProtectedResourceMetadata: Decodable {
        let authorization_servers: [String]
    }

    struct AuthorizationServerMetadata: Decodable {
        let authorization_endpoint: String?
        let token_endpoint: String?
        let pushed_authorization_request_endpoint: String?
        let revocation_endpoint: String?
    }
}
