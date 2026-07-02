import Testing
import Foundation
@testable import ConfluenceKit

// Exercises the real Keychain. Under `swift test` (unsigned) this runs against the
// legacy-keychain fallback; a signed app uses the data-protection keychain.
@Suite(.serialized)
struct KeychainTests {
    func makeKeychain() -> Keychain { Keychain(service: "com.dangahan.confluence.tests.\(UUID().uuidString)") }

    @Test func roundTripsCodableValue() throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteAll() }

        let session = BlueskySession(did: "did:plc:x", handle: "a.bsky.social", accessJwt: "acc", refreshJwt: "ref")
        try keychain.set(session, for: "session")
        #expect(try keychain.value(BlueskySession.self, for: "session") == session)
    }

    @Test func overwritesExistingItem() throws {
        let keychain = makeKeychain()
        defer { try? keychain.deleteAll() }

        try keychain.set(Data("first".utf8), for: "k")
        try keychain.set(Data("second".utf8), for: "k")
        #expect(try keychain.get("k") == Data("second".utf8))
    }

    @Test func deleteAllClearsEverything() throws {
        let keychain = makeKeychain()
        try keychain.set(Data("a".utf8), for: "one")
        try keychain.set(Data("b".utf8), for: "two")

        try keychain.deleteAll()
        #expect(try keychain.get("one") == nil)
        #expect(try keychain.get("two") == nil)
    }

    @Test func missingItemReturnsNil() throws {
        #expect(try makeKeychain().get("absent") == nil)
    }
}
