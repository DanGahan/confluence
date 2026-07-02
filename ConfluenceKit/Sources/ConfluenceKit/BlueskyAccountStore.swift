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
}
