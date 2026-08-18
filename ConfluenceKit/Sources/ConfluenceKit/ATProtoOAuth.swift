import Foundation
import CryptoKit

/// PKCE (RFC 7636) verifier + S256 challenge for the authorization request. The verifier is kept
/// client-side and sent only at code exchange; the challenge travels in the (PAR) auth request.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Fresh verifier from 32 CSPRNG bytes → 43-char base64url (within RFC 7636's 43–128 range).
    public init() {
        var rng = SystemRandomNumberGenerator() // cryptographically secure on Apple platforms
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        self.init(verifier: Base64URL.encode(Data(bytes)))
    }
}

/// Static configuration for our ATProto OAuth client. `clientID` is the public metadata URL that
/// Bluesky's authorization server fetches; `redirectURI` must be one listed in that metadata.
public struct ATProtoOAuthClient: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: String
    public let scope: String

    public init(clientID: String, redirectURI: String, scope: String = "atproto transition:generic") {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
    }

    /// ponytail: client_id + redirect_uri must match the hosted client-metadata.json on the
    /// gh-pages branch. Finalise the redirect scheme against Bluesky's live rules in this slice.
    public static let confluence = ATProtoOAuthClient(
        clientID: "https://dangahan.github.io/confluence/oauth/client-metadata.json",
        redirectURI: "io.github.dangahan.confluence://oauth-callback"
    )

    /// The URL scheme the app must register (Info.plist) and hand to ASWebAuthenticationSession.
    public var callbackScheme: String {
        String(redirectURI.prefix(while: { $0 != ":" }))
    }
}

/// The form parameters pushed to the PAR endpoint (RFC 9126). The server returns a `request_uri`
/// that the browser authorization request then references, so these params never hit the browser.
public func parParameters(client: ATProtoOAuthClient, pkce: PKCE, state: String,
                          loginHint: String? = nil) -> [String: String] {
    var params = [
        "client_id": client.clientID,
        "redirect_uri": client.redirectURI,
        "response_type": "code",
        "scope": client.scope,
        "state": state,
        "code_challenge": pkce.challenge,
        "code_challenge_method": "S256",
    ]
    if let loginHint, !loginHint.isEmpty { params["login_hint"] = loginHint }
    return params
}

/// The browser authorization URL built from the PAR `request_uri` (the only two params allowed
/// at the authorization endpoint once PAR is used).
public func authorizationURL(authorizationEndpoint: URL, clientID: String, requestURI: String) -> URL? {
    var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "request_uri", value: requestURI),
    ]
    return components?.url
}
