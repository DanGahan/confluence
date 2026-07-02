import Testing
import Foundation
@testable import ConfluenceKit

struct MastodonClientTests {
    func client(handler: @escaping MockURLProtocol.Handler) -> MastodonClient {
        MastodonClient(session: MockURLProtocol.session(handler: handler))
    }

    // MARK: normalizeHost

    @Test(arguments: [
        ("mastodon.social", "mastodon.social"),
        ("https://mastodon.social/", "mastodon.social"),
        ("  HTTPS://Mastodon.Social/@alice ", "mastodon.social"),
        ("@fosstodon.org", "fosstodon.org"),
    ])
    func normalizesHost(_ input: String, _ expected: String) throws {
        #expect(try MastodonClient.normalizeHost(input) == expected)
    }

    @Test(arguments: ["", "not a host", "localhost", "  "])
    func rejectsInvalidHost(_ input: String) {
        #expect(throws: MastodonError.invalidInstance) { try MastodonClient.normalizeHost(input) }
    }

    // MARK: registerApp

    @Test func registerAppPostsFormAndDecodes() async throws {
        let sut = client { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://mastodon.social/api/v1/apps")
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("client_name=Confluence"))
            #expect(body.contains("scopes=read%20write%20follow"))
            let json = #"{"client_id":"cid","client_secret":"secret"}"#.data(using: .utf8)!
            return (request.status(200), json)
        }
        let app = try await sut.registerApp(host: "mastodon.social")
        #expect(app.clientId == "cid")
        #expect(app.clientSecret == "secret")
    }

    // MARK: validateInstance

    @Test func validateInstanceThrowsOnNon200() async {
        let sut = client { ($0.status(404), Data()) }
        await #expect(throws: MastodonError.invalidInstance) {
            try await sut.validateInstance(host: "not-mastodon.example")
        }
    }

    // MARK: authorizationURL

    @Test func authorizationURLHasRequiredQueryItems() throws {
        let url = try MastodonClient().authorizationURL(host: "mastodon.social", clientId: "cid", state: "xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.host == "mastodon.social")
        #expect(url.path == "/oauth/authorize")
        #expect(value("client_id") == "cid")
        #expect(value("response_type") == "code")
        #expect(value("state") == "xyz")
        #expect(value("redirect_uri") == MastodonClient.redirectURI)
        #expect(value("scope") == "read write follow")
    }

    // MARK: exchangeCode

    @Test func exchangeCodePostsFormAndReturnsToken() async throws {
        let app = MastodonApp(clientId: "cid", clientSecret: "secret")
        let sut = client { request in
            #expect(request.url?.absoluteString == "https://mastodon.social/oauth/token")
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(body.contains("grant_type=authorization_code"))
            #expect(body.contains("code=abc123"))
            #expect(body.contains("client_secret=secret"))
            return (request.status(200), #"{"access_token":"tok","token_type":"Bearer"}"#.data(using: .utf8)!)
        }
        let token = try await sut.exchangeCode("abc123", host: "mastodon.social", app: app)
        #expect(token == "tok")
    }

    @Test func exchangeCodeThrowsOnRejection() async {
        let app = MastodonApp(clientId: "cid", clientSecret: "secret")
        let sut = client { ($0.status(401), Data()) }
        await #expect(throws: MastodonError.tokenExchangeFailed) {
            try await sut.exchangeCode("bad", host: "mastodon.social", app: app)
        }
    }
}
