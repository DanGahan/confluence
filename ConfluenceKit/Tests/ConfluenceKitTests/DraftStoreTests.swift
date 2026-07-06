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

        let d = Draft(text: "hello", attachments: [Data([1, 2])], postToBluesky: true, postToMastodon: false)
        store.save(d)
        #expect(store.drafts.map(\.id) == [d.id])

        // Update by id (same id replaces, doesn't duplicate).
        var edited = d; edited.text = "hello world"; edited.savedAt = Date()
        store.save(edited)
        #expect(store.drafts.count == 1)
        #expect(store.drafts[0].text == "hello world")

        // Persists to disk and reloads.
        let reopened = DraftStore(directory: dir)
        #expect(reopened.drafts.map(\.text) == ["hello world"])
        #expect(reopened.drafts[0].attachments == [Data([1, 2])])

        store.delete(d.id)
        #expect(store.drafts.isEmpty)
        #expect(DraftStore(directory: dir).drafts.isEmpty)
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
        let empty = Draft(text: "  ", attachments: [Data([1]), Data([2])], postToBluesky: true, postToMastodon: false)
        #expect(empty.preview == "2 images")
        let text = Draft(text: "first line\nsecond", attachments: [], postToBluesky: true, postToMastodon: false)
        #expect(text.preview == "first line")
    }
}
