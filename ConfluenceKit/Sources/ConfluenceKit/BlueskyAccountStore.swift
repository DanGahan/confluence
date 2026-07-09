import Foundation
import Observation

/// Owns Bluesky auth state for the UI: log in, restore on launch, refresh, log out.
/// The session is persisted in the Keychain and nowhere else.
@MainActor
@Observable
public final class BlueskyAccountStore {
    public private(set) var session: BlueskySession?

    private let client: BlueskyClient
    private let keychain: any SecureStore
    private static let account = "session"

    public var isLoggedIn: Bool { session != nil }

    public init(
        client: BlueskyClient = BlueskyClient(),
        keychain: any SecureStore = Keychain(service: "com.dangahan.confluence.bluesky")
    ) {
        self.client = client
        self.keychain = keychain
        // Restore a persisted session, if any. A corrupt item is treated as logged-out.
        session = try? keychain.value(BlueskySession.self, for: Self.account)
    }

    public func logIn(identifier: String, appPassword: String) async throws {
        let handle = identifier.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let newSession = try await client.createSession(identifier: handle, appPassword: appPassword)
        try keychain.set(newSession, for: Self.account)
        session = newSession
    }

    /// Exchanges the stored refresh token for fresh tokens.
    public func refresh() async throws {
        guard let current = session else { return }
        let refreshed = try await client.refreshSession(refreshJwt: current.refreshJwt)
        try keychain.set(refreshed, for: Self.account)
        session = refreshed
    }

    public func logOut() throws {
        try keychain.deleteAll()
        session = nil
    }

    /// Runs `body` with the current session; if the access token has expired
    /// (`BlueskyError.invalidCredentials`), refreshes once and retries. Centralises the
    /// refresh-retry that every authenticated Bluesky call in the app otherwise repeats.
    /// `nonisolated` so `body` (the network call) runs off the main actor as before; only the
    /// session read and refresh hop to the main actor.
    public nonisolated func withFreshSession<T: Sendable>(
        _ body: @Sendable (BlueskySession) async throws -> T
    ) async throws -> T {
        guard let session = await session else { throw BlueskyError.invalidCredentials }
        do {
            return try await body(session)
        } catch BlueskyError.invalidCredentials {
            try await refresh()
            guard let fresh = await self.session else { throw BlueskyError.invalidCredentials }
            return try await body(fresh)
        }
    }
}
