import Foundation

/// Remembers where the user was in the feed so a relaunch can return there.
/// Stores only a post id + timestamp in UserDefaults (no post content).
public struct FeedPositionStore: @unchecked Sendable { // UserDefaults is thread-safe
    private let defaults: UserDefaults
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One saved position per scope (e.g. the current feed filter), so each tab/view restores
    /// independently.
    private func key(_ scope: String) -> String { "feedPosition.\(scope)" }

    private struct Stored: Codable { let itemID: String; let savedAt: Date }

    public func save(itemID: String, for scope: String, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Stored(itemID: itemID, savedAt: now)) else { return }
        defaults.set(data, forKey: key(scope))
    }

    /// The saved item id for `scope`, or nil if none or older than 7 days (which also clears it).
    public func savedItemID(for scope: String, now: Date = Date()) -> String? {
        guard let data = defaults.data(forKey: key(scope)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        guard now.timeIntervalSince(stored.savedAt) <= maxAge else {
            clear(for: scope)
            return nil
        }
        return stored.itemID
    }

    public func clear(for scope: String) {
        defaults.removeObject(forKey: key(scope))
    }
}
