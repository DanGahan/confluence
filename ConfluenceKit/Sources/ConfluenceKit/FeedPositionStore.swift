import Foundation

/// Remembers where the user was in the feed so a relaunch can return there.
/// Stores only a post id + timestamp in UserDefaults (no post content).
public struct FeedPositionStore: @unchecked Sendable { // UserDefaults is thread-safe
    private let defaults: UserDefaults
    private let key = "feedPosition"
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct Stored: Codable { let itemID: String; let savedAt: Date }

    public func save(itemID: String, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Stored(itemID: itemID, savedAt: now)) else { return }
        defaults.set(data, forKey: key)
    }

    /// The saved item id, or nil if there's none or it's older than 7 days (which also clears it).
    public func savedItemID(now: Date = Date()) -> String? {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        guard now.timeIntervalSince(stored.savedAt) <= maxAge else {
            clear()
            return nil
        }
        return stored.itemID
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
