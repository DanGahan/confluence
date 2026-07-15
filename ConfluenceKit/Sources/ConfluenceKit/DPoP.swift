import Foundation
import CryptoKit

/// A P-256 signing key used to prove possession of the OAuth access token on every
/// ATProto request (DPoP, RFC 9449). Persisted via `SecureStore` — one key per
/// account. See `docs/ATPROTO_OAUTH.md`.
public struct DPoPKey: Sendable {
    let privateKey: P256.Signing.PrivateKey

    public init() {
        self.privateKey = P256.Signing.PrivateKey()
    }

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// The JWK representation of the public half — used both in the DPoP JWT header
    /// (`jwk` field) and as the identifier the server binds the token to.
    public var publicJWK: [String: String] {
        // `rawRepresentation` on the public key is the uncompressed X||Y form: 64 bytes.
        let raw = privateKey.publicKey.rawRepresentation
        let x = raw.prefix(32)
        let y = raw.suffix(32)
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": Base64URL.encode(x),
            "y": Base64URL.encode(y),
        ]
    }

    /// Compact serialization for Keychain storage. The public half is derivable, so
    /// only the 32-byte private scalar is stored.
    public func exportPrivateKey() -> Data {
        privateKey.rawRepresentation
    }

    /// Restore a previously exported key. Corrupt input throws so callers can force
    /// a fresh key generation (which forces re-auth — an acceptable failure mode).
    public static func imported(from data: Data) throws -> DPoPKey {
        let key = try P256.Signing.PrivateKey(rawRepresentation: data)
        return DPoPKey(privateKey: key)
    }
}

/// Builds a DPoP proof JWT (RFC 9449 §4). Compact JWS with ES256, header includes
/// the public JWK; payload names the HTTP method + URL of the request the proof
/// covers, plus a fresh `jti` for replay resistance.
///
/// `nonce` is included when the server has sent a `DPoP-Nonce` header (the client
/// must retry the request with the echoed nonce). `accessToken` is included on
/// requests that carry one, via the `ath` claim = base64url(sha256(access_token)) —
/// so a stolen DPoP JWT can't be paired with a different token.
public struct DPoPProofBuilder: Sendable {
    let key: DPoPKey
    let clock: @Sendable () -> Date
    let jti: @Sendable () -> String

    /// Default clock and jti sources. Tests inject deterministic values.
    public init(
        key: DPoPKey,
        clock: @escaping @Sendable () -> Date = { Date() },
        jti: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.key = key
        self.clock = clock
        self.jti = jti
    }

    /// Produces the compact-serialized JWT ready for the `DPoP:` header value.
    public func proof(
        htm: String,
        htu: URL,
        nonce: String? = nil,
        accessToken: String? = nil
    ) throws -> String {
        let header: [String: Any] = [
            "typ": "dpop+jwt",
            "alg": "ES256",
            "jwk": key.publicJWK,
        ]

        // `htu` is the target URL without query or fragment (RFC 9449 §4.2).
        var components = URLComponents(url: htu, resolvingAgainstBaseURL: false)!
        components.query = nil
        components.fragment = nil
        let cleanURL = components.url?.absoluteString ?? htu.absoluteString

        var payload: [String: Any] = [
            "htm": htm.uppercased(),
            "htu": cleanURL,
            "iat": Int(clock().timeIntervalSince1970),
            "jti": jti(),
        ]
        if let nonce { payload["nonce"] = nonce }
        if let accessToken {
            let hash = SHA256.hash(data: Data(accessToken.utf8))
            payload["ath"] = Base64URL.encode(Data(hash))
        }

        let headerBytes = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadBytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = "\(Base64URL.encode(headerBytes)).\(Base64URL.encode(payloadBytes))"

        // JWS ES256 signature is the raw R||S concatenation (64 bytes for P-256),
        // NOT the DER encoding that ECDSA usually produces. `rawRepresentation` on
        // the CryptoKit signature gives us the right form.
        let signature = try key.privateKey.signature(for: Data(signingInput.utf8))
        let signatureB64 = Base64URL.encode(signature.rawRepresentation)

        return "\(signingInput).\(signatureB64)"
    }
}

/// Base64URL without padding (RFC 4648 §5). JWS/JWT wire format everywhere.
enum Base64URL {
    static func encode<T: DataProtocol>(_ bytes: T) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }
}
