import Testing
import Foundation
@testable import ConfluenceKit

@MainActor
struct DraftStoreTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return dir
    }

    @Test func savesUpdatesDeletesAndPersists() {
        let dir = tempDir()
        let store = DraftStore(directory: dir)
        #expect(store.drafts.isEmpty)

        let attachment = Attachment(data: Data([1, 2]), alt: "a description")
        let d = Draft(text: "hello", attachments: [attachment], postToBluesky: true, postToMastodon: false)
        store.save(d)
        #expect(store.drafts.map(\.id) == [d.id])

        // Update by id (same id replaces, doesn't duplicate).
        var edited = d; edited.text = "hello world"; edited.savedAt = Date()
        store.save(edited)
        #expect(store.drafts.count == 1)
        #expect(store.drafts[0].text == "hello world")

        // Persists to disk and reloads — alt-text survives the round trip.
        let reopened = DraftStore(directory: dir)
        #expect(reopened.drafts.map(\.text) == ["hello world"])
        #expect(reopened.drafts[0].attachments.map(\.data) == [Data([1, 2])])
        #expect(reopened.drafts[0].attachments.map(\.alt) == ["a description"])

        store.delete(d.id)
        #expect(store.drafts.isEmpty)
        #expect(DraftStore(directory: dir).drafts.isEmpty)
    }

    @Test func legacyDraftsWithRawDataAttachmentsUpgradeCleanly() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("drafts.json")
        // Old shape: attachments encoded as [Data] rather than [Attachment].
        let legacy = #"""
        [{"id":"11111111-1111-1111-1111-111111111111","text":"legacy","attachments":["AQI="],"postToBluesky":true,"postToMastodon":false,"savedAt":123}]
        """#
        try legacy.data(using: .utf8)!.write(to: file)

        let store = DraftStore(directory: dir)
        #expect(store.drafts.count == 1)
        #expect(store.drafts[0].text == "legacy")
        #expect(store.drafts[0].attachments.map(\.data) == [Data([1, 2])])
        #expect(store.drafts[0].attachments.map(\.alt) == [""]) // no alt was stored
    }

    @Test func mostRecentFirst() {
        let store = DraftStore(directory: tempDir())
        let old = Draft(text: "old", attachments: [], postToBluesky: true, postToMastodon: true,
                        savedAt: Date(timeIntervalSince1970: 100))
        let new = Draft(text: "new", attachments: [], postToBluesky: true, postToMastodon: true,
                        savedAt: Date(timeIntervalSince1970: 200))
        store.save(old); store.save(new)
        #expect(store.drafts.map(\.text) == ["new", "old"])
    }

    @Test func previewFallsBackToImageCount() {
        let empty = Draft(text: "  ", attachments: [Attachment(data: Data([1])), Attachment(data: Data([2]))],
                          postToBluesky: true, postToMastodon: false)
        #expect(empty.preview == "2 images")
        let text = Draft(text: "first line\nsecond", attachments: [], postToBluesky: true, postToMastodon: false)
        #expect(text.preview == "first line")
    }
}
