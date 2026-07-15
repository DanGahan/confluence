import Testing
import Foundation
@testable import ConfluenceKit

/// In-memory SecureStore standing in for the Keychain (which needs an entitled process).
final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func set(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    func get(_ account: String) throws -> Data? { lock.withLock { items[account] } }
    func delete(_ account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
    func deleteAll() throws { lock.withLock { items.removeAll() } }
    var isEmpty: Bool { lock.withLock { items.isEmpty } }
}

@MainActor
struct BlueskyAccountStoreTests {
    nonisolated func okSessionJSON(_ handle: String = "alice.bsky.social", access: String = "access", refresh: String = "refresh") -> Data {
        """
        {"did":"did:plc:abc","handle":"\(handle)","accessJwt":"\(access)","refreshJwt":"\(refresh)"}
        """.data(using: .utf8)!
    }

    func store(_ keychain: SecureStore, handler: @escaping MockURLProtocol.Handler) -> BlueskyAccountStore {
        BlueskyAccountStore(client: BlueskyClient(session: MockURLProtocol.session(handler: handler)), keychain: keychain)
    }

    @Test func loginPersistsSessionAndFlipsState() async throws {
        let keychain = InMemorySecureStore()
        let sut = store(keychain) { ($0.ok(), self.okSessionJSON()) }

        #expect(sut.isLoggedIn == false)
        try await sut.logIn(identifier: "alice.bsky.social", appPassword: "pw")

        #expect(sut.isLoggedIn)
        #expect(sut.session?.handle == "alice.bsky.social")
        #expect(keychain.isEmpty == false)
    }

    @Test func loginStripsLeadingAtFromHandle() async throws {
        let sut = store(InMemorySecureStore()) { request in
            let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: String]
            #expect(body?["identifier"] == "alice.bsky.social")
            return (request.ok(), self.okSessionJSON())
        }
        try await sut.logIn(identifier: "  @alice.bsky.social ", appPassword: "pw")
        #expect(sut.isLoggedIn)
    }

    @Test func failedLoginPersistsNothing() async {
        let keychain = InMemorySecureStore()
        let sut = store(keychain) { request in
            (request.status(401), #"{"error":"AuthenticationRequired"}"#.data(using: .utf8)!)
        }
        await #expect(throws: BlueskyError.invalidCredentials) {
            try await sut.logIn(identifier: "alice.bsky.social", appPassword: "wrong")
        }
        #expect(sut.isLoggedIn == false)
        #expect(keychain.isEmpty)
    }

    @Test func logoutClearsStoredCredentials() async throws {
        let keychain = InMemorySecureStore()
        let sut = store(keychain) { ($0.ok(), self.okSessionJSON()) }
        try await sut.logIn(identifier: "alice.bsky.social", appPassword: "pw")

        try sut.logOut()
        #expect(sut.isLoggedIn == false)
        #expect(keychain.isEmpty)
    }

    @Test func restoresPersistedSessionOnRestore() async throws {
        let keychain = InMemorySecureStore()
        try keychain.set(okSessionJSON("bob.bsky.social"), for: "session")

        let sut = store(keychain) { ($0.ok(), Data()) }
        #expect(sut.session == nil)  // not read in init (#126) — restore() reads it after launch
        await sut.restore()
        #expect(sut.session?.handle == "bob.bsky.social")
    }

    @Test func refreshUpdatesTokens() async throws {
        let keychain = InMemorySecureStore()
        try keychain.set(okSessionJSON(), for: "session")
        let sut = store(keychain) { ($0.ok(), self.okSessionJSON(access: "new", refresh: "new-ref")) }
        await sut.restore()

        try await sut.refresh()
        #expect(sut.session?.accessJwt == "new")
        let persisted = try keychain.value(BlueskySession.self, for: "session")
        #expect(persisted?.refreshJwt == "new-ref")
    }

    /// G4: on an expired token, withFreshSession refreshes once and retries body with the new
    /// token; the happy path runs body once with no refresh.
    @Test func withFreshSessionRefreshesOnceAndRetries() async throws {
        let keychain = InMemorySecureStore()
        try keychain.set(okSessionJSON(access: "old"), for: "session")
        let sut = store(keychain) { ($0.ok(), self.okSessionJSON(access: "new", refresh: "new-ref")) }
        await sut.restore()

        final class Box: @unchecked Sendable { var calls = 0; var seen: [String] = [] }
        let box = Box()
        let result: String = try await sut.withFreshSession { session in
            box.calls += 1
            box.seen.append(session.accessJwt)
            if box.calls == 1 { throw BlueskyError.invalidCredentials } // simulate expiry
            return "ok:\(session.accessJwt)"
        }
        #expect(result == "ok:new")
        #expect(box.seen == ["old", "new"]) // retried with the refreshed token
        #expect(sut.session?.accessJwt == "new")
    }

    @Test func withFreshSessionRunsBodyOnceOnSuccess() async throws {
        let keychain = InMemorySecureStore()
        try keychain.set(okSessionJSON(access: "tok"), for: "session")
        let sut = store(keychain) { ($0.ok(), self.okSessionJSON()) }
        await sut.restore()

        final class Box: @unchecked Sendable { var calls = 0 }
        let box = Box()
        let out: Int = try await sut.withFreshSession { _ in box.calls += 1; return 7 }
        #expect(out == 7)
        #expect(box.calls == 1) // no refresh, no retry
    }

    @Test func withFreshSessionThrowsWhenLoggedOut() async {
        let sut = store(InMemorySecureStore()) { ($0.ok(), Data()) }
        await #expect(throws: BlueskyError.invalidCredentials) {
            try await sut.withFreshSession { _ in 1 }
        }
    }
}

