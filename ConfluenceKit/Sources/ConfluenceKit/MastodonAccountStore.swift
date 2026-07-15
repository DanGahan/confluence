import Foundation
import Observation

/// Performs the browser-based OAuth consent step and returns the callback URL.
/// The app implements this with ASWebAuthenticationSession; tests use a stub.
public protocol WebAuthenticator: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Owns Mastodon auth state: instance entry → registration → OAuth → token, plus logout.
/// The session (including the client secret and token) is persisted in the Keychain only.
@MainActor
@Observable
public final class MastodonAccountStore {
    public private(set) var session: MastodonSession?

    private let client: MastodonClient
    private let authenticator: any WebAuthenticator
    private let keychain: any SecureStore
    private static let account = "session"

    public var isLoggedIn: Bool { session != nil }

    public init(
        client: MastodonClient = MastodonClient(),
        authenticator: any WebAuthenticator,
        keychain: any SecureStore = Keychain(service: "com.dangahan.confluence.mastodon")
    ) {
        self.client = client
        self.authenticator = authenticator
        self.keychain = keychain
    }

    /// Restores a persisted session (if any) from the Keychain.
    ///
    /// The Keychain read happens on a detached task, off the main actor, so the app remains
    /// interactive while it runs — including if the OS shows an access prompt (#131). Call
    /// after the UI is up, not from `init` (#126). Corrupt/absent item = logged-out.
    public func restore() async {
        let store = keychain
        let account = Self.account
        let restored: MastodonSession? = await Task.detached {
            try? store.value(MastodonSession.self, for: account)
        }.value
        session = restored
    }

    public func logIn(instance: String) async throws {
        let host = try MastodonClient.normalizeHost(instance)
        try await client.validateInstance(host: host)

        let app = try await client.registerApp(host: host)
        let state = Self.randomState()
        let authURL = try client.authorizationURL(host: host, clientId: app.clientId, state: state)

        let callback = try await authenticator.authenticate(url: authURL, callbackScheme: MastodonClient.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw MastodonError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MastodonError.authorizationDenied
        }

        let token = try await client.exchangeCode(code, host: host, app: app)
        let newSession = MastodonSession(host: host, app: app, accessToken: token)
        try keychain.set(newSession, for: Self.account)
        session = newSession
    }

    public func logOut() async throws {
        if let session { await client.revoke(session: session) }
        try keychain.deleteAll()
        session = nil
    }

    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
