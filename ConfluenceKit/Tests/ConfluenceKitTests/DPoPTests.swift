import Testing
import Foundation
import CryptoKit
@testable import ConfluenceKit

struct DPoPTests {

    // MARK: Base64URL

    @Test func base64URLRoundTrips() {
        for input: [UInt8] in [[], [0], [255], [0, 1, 2, 3, 4, 5, 6, 7]] {
            let encoded = Base64URL.encode(Data(input))
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(!encoded.contains("="))
            #expect(Base64URL.decode(encoded) == Data(input))
        }
    }

    // MARK: Key persistence

    @Test func exportedKeyRoundTrips() throws {
        let original = DPoPKey()
        let restored = try DPoPKey.imported(from: original.exportPrivateKey())
        // Public JWK is derivable from the private scalar, so restored must match.
        #expect(restored.publicJWK == original.publicJWK)
    }

    @Test func importCorruptDataThrows() {
        #expect(throws: Error.self) {
            _ = try DPoPKey.imported(from: Data([0, 1, 2, 3])) // too short for P-256 scalar
        }
    }

    @Test func publicJWKShape() {
        let jwk = DPoPKey().publicJWK
        #expect(jwk["kty"] == "EC")
        #expect(jwk["crv"] == "P-256")
        // x/y are 32-byte coordinates → 43 base64url chars (no padding).
        #expect(jwk["x"]?.count == 43)
        #expect(jwk["y"]?.count == 43)
    }

    // MARK: Proof shape

    private func decodePart(_ jwt: String, index: Int) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", maxSplits: 2).map(String.init)
        let data = try #require(Base64URL.decode(parts[index]))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func proofHeaderCarriesTypAlgAndJWK() throws {
        let key = DPoPKey()
        let builder = DPoPProofBuilder(key: key,
                                       clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                                       jti: { "fixed-jti" })
        let jwt = try builder.proof(htm: "POST", htu: URL(string: "https://pds.example/token")!)
        let header = try decodePart(jwt, index: 0)
        #expect(header["typ"] as? String == "dpop+jwt")
        #expect(header["alg"] as? String == "ES256")
        let jwk = try #require(header["jwk"] as? [String: String])
        #expect(jwk == key.publicJWK)
    }

    @Test func proofPayloadCarriesRequiredClaims() throws {
        let builder = DPoPProofBuilder(key: DPoPKey(),
                                       clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                                       jti: { "fixed-jti" })
        let jwt = try builder.proof(htm: "post", htu: URL(string: "https://pds.example/token?foo=bar#x")!)
        let payload = try decodePart(jwt, index: 1)
        #expect(payload["htm"] as? String == "POST")                       // upper-cased
        #expect(payload["htu"] as? String == "https://pds.example/token") // query + fragment stripped
        #expect(payload["iat"] as? Int == 1_700_000_000)
        #expect(payload["jti"] as? String == "fixed-jti")
        #expect(payload["nonce"] == nil)
        #expect(payload["ath"] == nil)
    }

    @Test func proofIncludesNonceAndAccessTokenHashWhenGiven() throws {
        let builder = DPoPProofBuilder(key: DPoPKey())
        let token = "an-access-token"
        let jwt = try builder.proof(
            htm: "GET",
            htu: URL(string: "https://pds.example/xrpc/app.bsky.actor.getProfile")!,
            nonce: "server-nonce",
            accessToken: token
        )
        let payload = try decodePart(jwt, index: 1)
        #expect(payload["nonce"] as? String == "server-nonce")
        // ath = base64url(sha256(access_token))
        let expected = Base64URL.encode(Data(SHA256.hash(data: Data(token.utf8))))
        #expect(payload["ath"] as? String == expected)
    }

    @Test func eachProofGetsAFreshJTI() throws {
        let builder = DPoPProofBuilder(key: DPoPKey())
        let jwt1 = try builder.proof(htm: "GET", htu: URL(string: "https://pds.example/x")!)
        let jwt2 = try builder.proof(htm: "GET", htu: URL(string: "https://pds.example/x")!)
        let payload1 = try decodePart(jwt1, index: 1)
        let payload2 = try decodePart(jwt2, index: 1)
        #expect((payload1["jti"] as? String) != (payload2["jti"] as? String))
    }

    // MARK: Signature verification

    @Test func signatureVerifiesWithTheSamePublicKey() throws {
        let key = DPoPKey()
        let builder = DPoPProofBuilder(key: key)
        let jwt = try builder.proof(htm: "POST", htu: URL(string: "https://pds.example/token")!)

        let parts = jwt.split(separator: ".", maxSplits: 2).map(String.init)
        let signingInput = "\(parts[0]).\(parts[1])"
        let signatureBytes = try #require(Base64URL.decode(parts[2]))
        // ES256 signature is R||S (64 bytes for P-256), imported via `rawRepresentation`.
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        #expect(key.privateKey.publicKey.isValidSignature(signature, for: Data(signingInput.utf8)))
    }

    @Test func signatureFailsForATamperedPayload() throws {
        let key = DPoPKey()
        let builder = DPoPProofBuilder(key: key)
        let jwt = try builder.proof(htm: "POST", htu: URL(string: "https://pds.example/token")!)
        var parts = jwt.split(separator: ".", maxSplits: 2).map(String.init)
        // Tamper: swap the payload for an entirely different one.
        parts[1] = Base64URL.encode(Data(#"{"htm":"DELETE","htu":"https://evil/","iat":0,"jti":"x"}"#.utf8))
        let tamperedInput = "\(parts[0]).\(parts[1])"
        let signatureBytes = try #require(Base64URL.decode(parts[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        #expect(!key.privateKey.publicKey.isValidSignature(signature, for: Data(tamperedInput.utf8)))
    }
}
