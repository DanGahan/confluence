import Foundation

/// A composer image attachment: the JPEG bytes to upload and an optional alt-text
/// description (image description sent to both Bluesky's `alt` and Mastodon's
/// `description`). Empty alt is preserved — it still posts, it just carries no
/// description.
public struct Attachment: Codable, Sendable, Equatable, Identifiable {
    /// Stable id so SwiftUI ForEach doesn't confuse attachments when alt-text changes.
    public let id: UUID
    public let data: Data
    public var alt: String

    public init(id: UUID = UUID(), data: Data, alt: String = "") {
        self.id = id
        self.data = data
        self.alt = alt
    }

    // Legacy drafts persisted images as raw `Data` inside `[Data]`; new drafts use
    // `[Attachment]`. Tolerate both shapes on decode so an upgrade doesn't lose drafts.
    // The legacy path emits an empty alt (no description was ever entered) and a fresh id.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(Data.self) {
            self.id = UUID()
            self.data = single
            self.alt = ""
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.data = try c.decode(Data.self, forKey: .data)
        self.alt = (try? c.decode(String.self, forKey: .alt)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, data, alt }
}
