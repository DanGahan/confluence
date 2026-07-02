import Foundation
import Observation

/// Fetches one page for a network given its cursor (nil = first page).
public typealias PageFetcher = @Sendable (_ cursor: String?) async throws -> FeedPage

/// Owns the combined feed: refresh, infinite scroll, and per-network failure state.
/// Networks are supplied as fetchers so this is testable without real clients.
@MainActor
@Observable
public final class FeedStore {
    public private(set) var items: [FeedItem] = []
    public private(set) var failedNetworks: Set<Network> = []
    public private(set) var isLoading = false

    private var fetchers: [Network: PageFetcher] = [:]
    private var cursors: [Network: String] = [:]
    private var reachedEnd: Set<Network> = []
    private var perNetwork: [Network: [FeedItem]] = [:]

    public init() {}

    /// Active networks change when accounts are added/removed.
    public func setFetchers(_ fetchers: [Network: PageFetcher]) {
        self.fetchers = fetchers
    }

    public var hasMore: Bool { fetchers.keys.contains { !reachedEnd.contains($0) } }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        cursors = [:]; reachedEnd = []; perNetwork = [:]; failedNetworks = []

        let active = Array(fetchers)
        let results = await withTaskGroup(of: (Network, Result<FeedPage, Error>).self) { group in
            for (network, fetcher) in active {
                group.addTask {
                    do { return (network, .success(try await fetcher(nil))) }
                    catch { return (network, .failure(error)) }
                }
            }
            var acc: [(Network, Result<FeedPage, Error>)] = []
            for await result in group { acc.append(result) }
            return acc
        }
        for (network, result) in results { apply(result, for: network, append: false) }
        rebuild()
    }

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        let candidates = fetchers.keys.filter { !reachedEnd.contains($0) && !failedNetworks.contains($0) }
        // Extend whichever loaded stream currently ends newest — that's where the merge gap is.
        guard let network = candidates.max(by: {
            (perNetwork[$0]?.last?.createdAt ?? .distantPast) < (perNetwork[$1]?.last?.createdAt ?? .distantPast)
        }), let fetcher = fetchers[network] else { return }

        isLoading = true
        defer { isLoading = false }
        do { apply(.success(try await fetcher(cursors[network])), for: network, append: true) }
        catch { apply(.failure(error), for: network, append: true) }
        rebuild()
    }

    private func apply(_ result: Result<FeedPage, Error>, for network: Network, append: Bool) {
        switch result {
        case .success(let page):
            if append { perNetwork[network, default: []].append(contentsOf: page.items) }
            else { perNetwork[network] = page.items }
            if let cursor = page.nextCursor, !page.items.isEmpty { cursors[network] = cursor }
            else { reachedEnd.insert(network) }
            failedNetworks.remove(network)
        case .failure:
            failedNetworks.insert(network)
            reachedEnd.insert(network) // stop paginating a failed network until next refresh
        }
    }

    private func rebuild() {
        items = mergeFeeds(Array(perNetwork.values))
    }
}
