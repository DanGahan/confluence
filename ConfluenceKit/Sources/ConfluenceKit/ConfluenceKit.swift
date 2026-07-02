/// The two social networks Confluence federates. Foundational — used across feed,
/// auth, notifications, and search. Everything else lands in feature-specific files.
public enum Network: String, Sendable, CaseIterable, Codable {
    case bluesky
    case mastodon
}
