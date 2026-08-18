import Foundation

public enum ATProtoOAuthError: Error, Equatable {
    case handleResolution
    case malformedResponse
    case server(Int)
}

/// Tokens from the ATProto token endpoint. All fields sensitive — Keychain only, never logged.
public struct ATProtoTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String   // "DPoP"
    public let sub: String?        // the account DID, when the server returns it
    public let scope: String?
}

/// Network side of the ATProto OAuth flow: handle resolution, PAR, and token exchange/refresh.
/// Every request to the authorization server carries a DPoP proof and retries once, transparently,
/// on a `DPoP-Nonce` challenge (the AS forcing a server-chosen nonce). See docs/ATPROTO_OAUTH.md.
public struct ATProtoOAuthService: Sendable {
    let session: URLSession
    let client: ATProtoOAuthClient
    let appview: URL

    public init(session: URLSession = .shared, client: ATProtoOAuthClient = .confluence,
                appview: URL = URL(string: "https://public.api.bsky.app")!) {
        self.session = session
        self.client = client
        self.appview = appview
    }

    /// Unauthenticated handle → DID via the public appview (the server resolves DNS/well-known).
    public func resolveHandle(_ handle: String) async throws -> String {
        var components = URLComponents(url: appview.appending(path: "xrpc/com.atproto.identity.resolveHandle"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: components.url!) }
        catch { throw ATProtoOAuthError.handleResolution }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ATProtoOAuthError.handleResolution
        }
        struct Resolved: Decodable { let did: String }
        guard let r = try? JSONDecoder().decode(Resolved.self, from: data) else { throw ATProtoOAuthError.malformedResponse }
        return r.did
    }

    /// PAR (RFC 9126): push the authorization params, receive an opaque `request_uri` for the
    /// browser authorization request.
    public func pushAuthorizationRequest(endpoint: URL, params: [String: String], dpop: DPoPProofBuilder) async throws -> String {
        let (data, http) = try await dpopForm(url: endpoint, form: params, dpop: dpop)
        guard (200..<300).contains(http.statusCode) else { throw ATProtoOAuthError.server(http.statusCode) }
        struct PAR: Decodable { let request_uri: String }
        guard let par = try? JSONDecoder().decode(PAR.self, from: data) else { throw ATProtoOAuthError.malformedResponse }
        return par.request_uri
    }

    /// Exchange the authorization code (+ PKCE verifier) for DPoP-bound tokens.
    public func exchangeCode(tokenEndpoint: URL, code: String, verifier: String, dpop: DPoPProofBuilder) async throws -> ATProtoTokens {
        try await token(tokenEndpoint: tokenEndpoint, dpop: dpop, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": client.redirectURI,
            "client_id": client.clientID,
            "code_verifier": verifier,
        ])
    }

    /// Refresh an expired access token (also DPoP-bound + nonce-aware).
    public func refresh(tokenEndpoint: URL, refreshToken: String, dpop: DPoPProofBuilder) async throws -> ATProtoTokens {
        try await token(tokenEndpoint: tokenEndpoint, dpop: dpop, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientID,
        ])
    }

    private func token(tokenEndpoint: URL, dpop: DPoPProofBuilder, form: [String: String]) async throws -> ATProtoTokens {
        let (data, http) = try await dpopForm(url: tokenEndpoint, form: form, dpop: dpop)
        guard (200..<300).contains(http.statusCode) else { throw ATProtoOAuthError.server(http.statusCode) }
        struct Response: Decodable {
            let access_token: String; let refresh_token: String; let token_type: String
            let sub: String?; let scope: String?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw ATProtoOAuthError.malformedResponse }
        return ATProtoTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                             tokenType: r.token_type, sub: r.sub, scope: r.scope)
    }

    /// POSTs a form with a DPoP proof; on a `DPoP-Nonce` challenge (400/401 + the header), retries
    /// exactly once with the echoed nonce baked into a fresh proof.
    private func dpopForm(url: URL, form: [String: String], dpop: DPoPProofBuilder) async throws -> (Data, HTTPURLResponse) {
        func send(nonce: String?) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(try dpop.proof(htm: "POST", htu: url, nonce: nonce), forHTTPHeaderField: "DPoP")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ATProtoOAuthError.malformedResponse }
            return (data, http)
        }
        let (data, http) = try await send(nonce: nil)
        if (http.statusCode == 400 || http.statusCode == 401),
           let nonce = http.value(forHTTPHeaderField: "DPoP-Nonce") {
            return try await send(nonce: nonce)
        }
        return (data, http)
    }
}
