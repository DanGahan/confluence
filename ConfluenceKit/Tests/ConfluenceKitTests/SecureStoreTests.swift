import Testing
import Foundation
@testable import ConfluenceKit

// The real Keychain can't be tested headlessly (needs an entitled, signed process and
// otherwise prompts). This covers the SecureStore contract via the in-memory store; the
// account-store tests exercise the same contract for the login/logout flows.
struct SecureStoreTests {
    @Test func roundTripsAndOverwrites() throws {
        let store = EphemeralSecureStore()
        try store.set(Data("first".utf8), for: "k")
        try store.set(Data("second".utf8), for: "k")
        #expect(try store.get("k") == Data("second".utf8))
    }

    @Test func codableConvenience() throws {
        let store = EphemeralSecureStore()
        let session = BlueskySession(did: "d", handle: "h", accessJwt: "a", refreshJwt: "r")
        try store.set(session, for: "s")
        #expect(try store.value(BlueskySession.self, for: "s") == session)
    }

    @Test func deleteAndDeleteAll() throws {
        let store = EphemeralSecureStore()
        try store.set(Data("a".utf8), for: "one")
        try store.set(Data("b".utf8), for: "two")

        try store.delete("one")
        #expect(try store.get("one") == nil)
        #expect(try store.get("two") != nil)

        try store.deleteAll()
        #expect(try store.get("two") == nil)
    }

    @Test func missingReturnsNil() throws {
        #expect(try EphemeralSecureStore().get("absent") == nil)
    }
}
