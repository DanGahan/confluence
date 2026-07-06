import Foundation
import Observation

/// Publishes text (and any attached image data) to one network. Throws on failure.
public typealias Poster = @Sendable (_ text: String, _ images: [Data]) async throws -> Void

/// Owns the cross-post composer: text, per-network targets (persisted), character limits,
/// and independent posting. Posting skips networks that already succeeded, so retrying a
/// partial failure never double-posts.
@MainActor
@Observable
public final class ComposerStore {
    public var text = ""
    /// Attached image data (JPEG), uploaded per network on post. Capped at 4 (both networks' max).
    public var attachments: [Data] = []
    public var postToBluesky: Bool { didSet { defaults.set(postToBluesky, forKey: "postToBluesky") } }
    public var postToMastodon: Bool { didSet { defaults.set(postToMastodon, forKey: "postToMastodon") } }

    public static let maxAttachments = 4

    public private(set) var succeeded: Set<Network> = []
    public private(set) var failed: [Network: String] = [:]
    public private(set) var isPosting = false

    private var posters: [Network: Poster] = [:]
    private var limits: [Network: Int] = [.bluesky: 300, .mastodon: 500]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.postToBluesky = defaults.object(forKey: "postToBluesky") as? Bool ?? true
        self.postToMastodon = defaults.object(forKey: "postToMastodon") as? Bool ?? true
    }

    /// Configure the connected networks (their posters) and known limits.
    public func configure(posters: [Network: Poster], limits: [Network: Int]) {
        self.posters = posters
        for (network, limit) in limits { self.limits[network] = limit }
    }

    public func isConnected(_ network: Network) -> Bool { posters[network] != nil }

    /// Networks that are both toggled on and connected.
    public var selectedNetworks: Set<Network> {
        var set: Set<Network> = []
        if postToBluesky, isConnected(.bluesky) { set.insert(.bluesky) }
        if postToMastodon, isConnected(.mastodon) { set.insert(.mastodon) }
        return set
    }

    /// Grapheme count (Bluesky counts graphemes; good enough for Mastodon too).
    public var characterCount: Int { text.count }

    /// Tightest limit among the selected networks (or the smallest known if none selected).
    public var characterLimit: Int {
        let selected = selectedNetworks.compactMap { limits[$0] }
        return selected.min() ?? limits.values.min() ?? 300
    }

    public var isOverLimit: Bool { characterCount > characterLimit }

    public var canPost: Bool {
        !isPosting && !selectedNetworks.isEmpty && !isOverLimit
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// Posts to each selected network independently. Networks already in `succeeded` are
    /// skipped, so calling again after a partial failure is a safe retry (no double-post).
    public func post() async {
        guard !isPosting else { return }
        isPosting = true
        defer { isPosting = false }
        failed = [:]
        for network in selectedNetworks where !succeeded.contains(network) {
            guard let poster = posters[network] else { continue }
            do {
                try await poster(text, attachments)
                succeeded.insert(network)
            } catch {
                failed[network] = (error as? LocalizedError)?.errorDescription ?? "Post failed."
            }
        }
    }

    public var didPostAll: Bool { failed.isEmpty && !succeeded.isEmpty }

    public func reset() {
        text = ""
        attachments = []
        succeeded = []
        failed = [:]
    }
}
