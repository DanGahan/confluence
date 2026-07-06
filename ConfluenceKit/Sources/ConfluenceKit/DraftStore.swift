import Foundation
import Observation

/// A saved composer draft: text, image attachments, and the chosen networks. No credentials.
public struct Draft: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var attachments: [Data]
    public var postToBluesky: Bool
    public var postToMastodon: Bool
    public var savedAt: Date

    public init(id: UUID = UUID(), text: String, attachments: [Data],
                postToBluesky: Bool, postToMastodon: Bool, savedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.postToBluesky = postToBluesky
        self.postToMastodon = postToMastodon
        self.savedAt = savedAt
    }

    /// One-line preview for the drafts list.
    public var preview: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return attachments.isEmpty ? "Empty draft" : "\(attachments.count) image\(attachments.count == 1 ? "" : "s")"
    }
}

/// Persists composer drafts to a JSON file on disk (Application Support). No secrets stored.
@MainActor
@Observable
public final class DraftStore {
    public private(set) var drafts: [Draft] = []

    private let fileURL: URL

    /// `directory` defaults to Application Support/Confluence; tests pass a temp directory.
    public init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("drafts.json")
        load()
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Confluence", isDirectory: true)
    }

    /// Insert or update a draft (matched by id), keeping the list most-recent first.
    public func save(_ draft: Draft) {
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        drafts.sort { $0.savedAt > $1.savedAt }
        persist()
    }

    public func delete(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Draft].self, from: data) else { return }
        drafts = decoded.sorted { $0.savedAt > $1.savedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
