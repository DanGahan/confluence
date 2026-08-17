/// The two social networks Confluence federates. Foundational — used across feed,
/// auth, notifications, and search. Everything else lands in feature-specific files.
public enum Network: String, Sendable, CaseIterable, Codable {
    case bluesky
    case mastodon

    /// Default post length limit (graphemes). Bluesky's 300 is a fixed protocol cap; Mastodon's
    /// 500 is the common default but instances may raise it — treat it as a soft guide, not a
    /// hard gate (the server is the real arbiter). See `isHardCharacterLimit`.
    public var defaultCharacterLimit: Int { self == .bluesky ? 300 : 500 }

    /// Whether `defaultCharacterLimit` is a firm cap we can enforce client-side (Bluesky) or a
    /// soft hint that varies per instance (Mastodon).
    public var isHardCharacterLimit: Bool { self == .bluesky }
}
