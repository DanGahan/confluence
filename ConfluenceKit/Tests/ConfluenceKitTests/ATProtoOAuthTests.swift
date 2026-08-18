import Testing
import Foundation
import CryptoKit
@testable import ConfluenceKit

struct ATProtoOAuthTests {
    @Test func pkceChallengeIsS256OfVerifier() {
        // RFC 7636 Appendix B test vector.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceGeneratesUniqueVerifiersOfValidLength() {
        let a = PKCE(), b = PKCE()
        #expect(a.verifier != b.verifier)
        #expect((43...128).contains(a.verifier.count))
        // Challenge is the base64url SHA-256 of the verifier.
        #expect(a.challenge == Base64URL.encode(Data(SHA256.hash(data: Data(a.verifier.utf8)))))
    }

    @Test func callbackSchemeIsDerivedFromRedirect() {
        #expect(ATProtoOAuthClient.confluence.callbackScheme == "io.github.dangahan.confluence")
    }

    @Test func parParametersCarryPKCEAndState() {
        let client = ATProtoOAuthClient(clientID: "https://c/meta.json", redirectURI: "app://cb", scope: "atproto")
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let p = parParameters(client: client, pkce: pkce, state: "xyz", loginHint: "alice.bsky.social")
        #expect(p["client_id"] == "https://c/meta.json")
        #expect(p["redirect_uri"] == "app://cb")
        #expect(p["response_type"] == "code")
        #expect(p["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(p["code_challenge_method"] == "S256")
        #expect(p["state"] == "xyz")
        #expect(p["login_hint"] == "alice.bsky.social")
    }

    @Test func parParametersOmitEmptyLoginHint() {
        let p = parParameters(client: .confluence, pkce: PKCE(), state: "s", loginHint: nil)
        #expect(p["login_hint"] == nil)
    }

    @Test func authorizationURLReferencesRequestURIOnly() {
        let url = authorizationURL(authorizationEndpoint: URL(string: "https://as.example/authorize")!,
                                   clientID: "https://c/meta.json", requestURI: "urn:ietf:params:oauth:request_uri:abc")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(url.path == "/authorize")
        #expect(items.first { $0.name == "client_id" }?.value == "https://c/meta.json")
        #expect(items.first { $0.name == "request_uri" }?.value == "urn:ietf:params:oauth:request_uri:abc")
        #expect(items.count == 2) // PAR: nothing else goes on the browser URL
    }
}
