import Testing
import Foundation
@testable import ConfluenceKit

/// Stub browser step: echoes back a callback URL built from the authorize request's state.
struct StubAuthenticator: WebAuthenticator {
    enum Behavior: Sendable { case code(String), noCode, wrongState, denied }
    let behavior: Behavior

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        switch behavior {
        case .code(let code):
            return URL(string: "confluence://oauth-callback?code=\(code)&state=\(state)")!
        case .noCode:
            return URL(string: "confluence://oauth-callback?state=\(state)")!
        case .wrongState:
            return URL(string: "confluence://oauth-callback?code=x&state=tampered")!
        case .denied:
            throw MastodonError.authorizationDenied
        }
    }
}

@MainActor
struct MastodonAccountStoreTests {
    /// Answers instance/register/token endpoints in one handler.
    nonisolated func serverHandler(tokenStatus: Int = 200) -> MockURLProtocol.Handler {
        { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/v1/instance":
                return (request.status(200), #"{"uri":"mastodon.social"}"#.data(using: .utf8)!)
            case "/api/v1/apps":
                return (request.status(200), #"{"client_id":"cid","client_secret":"secret"}"#.data(using: .utf8)!)
            case "/oauth/token":
                return (request.status(tokenStatus), #"{"access_token":"tok","token_type":"Bearer"}"#.data(using: .utf8)!)
            default:
                return (request.status(404), Data())
            }
        }
    }

    func store(_ auth: WebAuthenticator, keychain: SecureStore = InMemorySecureStore(), tokenStatus: Int = 200) -> MastodonAccountStore {
        MastodonAccountStore(
            client: MastodonClient(session: MockURLProtocol.session(handler: serverHandler(tokenStatus: tokenStatus))),
            authenticator: auth,
            keychain: keychain
        )
    }

    @Test func successfulLoginPersistsSession() async throws {
        let keychain = InMemorySecureStore()
        let sut = store(StubAuthenticator(behavior: .code("abc")), keychain: keychain)

        try await sut.logIn(instance: "https://mastodon.social/")
        #expect(sut.isLoggedIn)
        #expect(sut.session?.host == "mastodon.social")
        #expect(sut.session?.accessToken == "tok")
        #expect(keychain.isEmpty == false)
    }

    @Test func stateMismatchIsRejectedAndNothingPersisted() async {
        let keychain = InMemorySecureStore()
        let sut = store(StubAuthenticator(behavior: .wrongState), keychain: keychain)

        await #expect(throws: MastodonError.stateMismatch) {
            try await sut.logIn(instance: "mastodon.social")
        }
        #expect(sut.isLoggedIn == false)
        #expect(keychain.isEmpty)
    }

    @Test func missingCodeThrowsAuthorizationDenied() async {
        let sut = store(StubAuthenticator(behavior: .noCode))
        await #expect(throws: MastodonError.authorizationDenied) {
            try await sut.logIn(instance: "mastodon.social")
        }
    }

    @Test func cancelledBrowserPropagates() async {
        let sut = store(StubAuthenticator(behavior: .denied))
        await #expect(throws: MastodonError.authorizationDenied) {
            try await sut.logIn(instance: "mastodon.social")
        }
    }

    @Test func invalidInstanceStopsBeforeBrowser() async {
        let sut = store(StubAuthenticator(behavior: .code("abc")))
        await #expect(throws: MastodonError.invalidInstance) {
            try await sut.logIn(instance: "not a domain")
        }
    }

    @Test func logoutClearsCredentials() async throws {
        let keychain = InMemorySecureStore()
        let sut = store(StubAuthenticator(behavior: .code("abc")), keychain: keychain)
        try await sut.logIn(instance: "mastodon.social")

        try await sut.logOut()
        #expect(sut.isLoggedIn == false)
        #expect(keychain.isEmpty)
    }
}
