import Foundation
import Observation

public typealias NotificationFetcher = @Sendable () async throws -> [NotificationItem]

/// Owns notification state: fetch, merge, and unread counts. Unread is tracked locally
/// (a per-network "last seen" timestamp in UserDefaults) so it works uniformly across
/// both networks. Networks are supplied as fetchers so this is testable.
@MainActor
@Observable
public final class NotificationStore {
    public private(set) var items: [NotificationItem] = []
    public private(set) var unreadCount = 0
    public private(set) var perNetworkUnread: [Network: Int] = [:]
    public private(set) var failedNetworks: Set<Network> = []

    private var fetchers: [Network: NotificationFetcher] = [:]
    private let defaults: UserDefaults
    private let seenPrefix = "notifLastSeen."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func setFetchers(_ fetchers: [Network: NotificationFetcher]) {
        self.fetchers = fetchers
    }

    public func refresh() async {
        let active = Array(fetchers)
        let results = await withTaskGroup(of: (Network, Result<[NotificationItem], Error>).self) { group in
            for (network, fetcher) in active {
                group.addTask {
                    do { return (network, .success(try await fetcher())) }
                    catch { return (network, .failure(error)) }
                }
            }
            var acc: [(Network, Result<[NotificationItem], Error>)] = []
            for await result in group { acc.append(result) }
            return acc
        }

        var perNetwork: [Network: [NotificationItem]] = [:]
        var failures: Set<Network> = []
        for (network, result) in results {
            switch result {
            case .success(let notes): perNetwork[network] = notes
            case .failure: failures.insert(network)
            }
        }
        failedNetworks = failures
        items = mergeNotifications(Array(perNetwork.values))
        recomputeUnread()
    }

    /// Mark everything seen (called when the notifications screen opens).
    public func markSeen() {
        for network in fetchers.keys {
            let newest = items.filter { $0.network == network }.map(\.createdAt).max() ?? Date()
            defaults.set(newest.timeIntervalSince1970, forKey: seenPrefix + network.rawValue)
        }
        perNetworkUnread = [:]
        unreadCount = 0
    }

    private func recomputeUnread() {
        var counts: [Network: Int] = [:]
        for network in fetchers.keys {
            let seen = Date(timeIntervalSince1970: defaults.double(forKey: seenPrefix + network.rawValue))
            counts[network] = items.filter { $0.network == network && $0.createdAt > seen }.count
        }
        perNetworkUnread = counts.filter { $0.value > 0 }
        unreadCount = counts.values.reduce(0, +)
    }
}
