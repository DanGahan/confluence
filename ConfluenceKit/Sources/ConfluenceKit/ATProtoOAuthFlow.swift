import Foundation

/// A persisted OAuth session for a Bluesky account. All token/key fields are sensitive — Keychain
/// only, never logged. Distinct from the app-password `BlueskySession` (which has accessJwt/
/// refreshJwt); the presence of one vs the other is how the app knows which auth path to use.
public struct ATProtoOAuthSession: Codable, Sendable, Equatable {
    public let did: String
    public let handle: String
    public var accessToken: String
    public var refreshToken: String
    public let dpopPrivateKey: Data      // 32-byte P-256 scalar, from DPoPKey.exportPrivateKey()
    public let pdsURL: URL
    public let authorizationServer: URL
    public let tokenEndpoint: URL

    public init(did: String, handle: String, accessToken: String, refreshToken: String,
                dpopPrivateKey: Data, pdsURL: URL, authorizationServer: URL, tokenEndpoint: URL) {
        self.did = did; self.handle = handle
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.dpopPrivateKey = dpopPrivateKey
        self.pdsURL = pdsURL; self.authorizationServer = authorizationServer; self.tokenEndpoint = tokenEndpoint
    }

    public func dpopKey() throws -> DPoPKey { try DPoPKey.imported(from: dpopPrivateKey) }
}

/// Carries the state from `begin` (before the browser) to `complete` (after it): the URL to open,
/// plus the PKCE verifier, DPoP key, discovered endpoints, and `state` needed to finish.
public struct ATProtoAuthorizationRequest: Sendable {
    public let authorizationURL: URL
    public let callbackScheme: String
    let did: String
    let endpoints: ATProtoOAuthEndpoints
    let pkce: PKCE
    let dpopKey: DPoPKey
    let state: String
}

/// Orchestrates the ATProto OAuth flow around the browser step: `begin` resolves the handle,
/// discovers endpoints, and pushes the authorization request (PAR) to get the URL to open;
/// the app hands that to ASWebAuthenticationSession; `complete` verifies `state`, exchanges the
/// code, and returns a persisted session. See docs/ATPROTO_OAUTH.md.
public struct ATProtoOAuthFlow: Sendable {
    let client: ATProtoOAuthClient
    let service: ATProtoOAuthService
    let discovery: ATProtoDiscovery

    public init(session: URLSession = .shared, client: ATProtoOAuthClient = .confluence) {
        self.client = client
        self.service = ATProtoOAuthService(session: session, client: client)
        self.discovery = ATProtoDiscovery(session: session)
    }

    /// Phase 1: handle → DID → endpoints → PAR → browser authorization URL.
    public func begin(handle: String) async throws -> ATProtoAuthorizationRequest {
        let cleanHandle = handle.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let did = try await service.resolveHandle(cleanHandle)
        let endpoints = try await discovery.endpoints(for: did)
        let pkce = PKCE()
        let dpopKey = DPoPKey()
        let state = UUID().uuidString
        let params = parParameters(client: client, pkce: pkce, state: state, loginHint: cleanHandle)
        let requestURI = try await service.pushAuthorizationRequest(
            endpoint: endpoints.pushedAuthorizationRequestEndpoint, params: params, dpop: DPoPProofBuilder(key: dpopKey))
        guard let url = authorizationURL(authorizationEndpoint: endpoints.authorizationEndpoint,
                                         clientID: client.clientID, requestURI: requestURI) else {
            throw ATProtoOAuthError.malformedResponse
        }
        return ATProtoAuthorizationRequest(authorizationURL: url, callbackScheme: client.callbackScheme,
                                           did: did, endpoints: endpoints, pkce: pkce, dpopKey: dpopKey, state: state)
    }

    /// Phase 2: verify the returned `state`, exchange the `code` for tokens, build the session.
    public func complete(_ request: ATProtoAuthorizationRequest, callbackURL: URL, handle: String) async throws -> ATProtoOAuthSession {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == request.state else {
            throw ATProtoOAuthError.malformedResponse // state mismatch → possible CSRF, abort
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw ATProtoOAuthError.malformedResponse
        }
        let tokens = try await service.exchangeCode(tokenEndpoint: request.endpoints.tokenEndpoint,
                                                    code: code, verifier: request.pkce.verifier,
                                                    dpop: DPoPProofBuilder(key: request.dpopKey))
        return ATProtoOAuthSession(
            did: tokens.sub ?? request.did,
            handle: handle.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")),
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            dpopPrivateKey: request.dpopKey.exportPrivateKey(),
            pdsURL: request.endpoints.pdsURL,
            authorizationServer: request.endpoints.authorizationServer,
            tokenEndpoint: request.endpoints.tokenEndpoint)
    }
}
