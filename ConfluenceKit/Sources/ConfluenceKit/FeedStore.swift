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
    /// Networks whose last fetch returned 429 after the client's retry budget. Distinct
    /// from `failedNetworks` so the UI can surface a rate-limit banner ("try again in a
    /// moment") rather than a generic failure.
    public private(set) var rateLimitedNetworks: Set<Network> = []
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

    /// Whether more can load. With a `filter` (the currently-shown network), reflects only that
    /// network — so a filtered view stops spinning once *it* is exhausted, even if the hidden
    /// network still has pages (#214).
    public func hasMore(for filter: Network? = nil) -> Bool {
        if let filter { return fetchers.keys.contains(filter) && !reachedEnd.contains(filter) }
        return fetchers.keys.contains { !reachedEnd.contains($0) }
    }

    /// Oldest (earliest) loaded post for a network, or nil if none loaded.
    private func oldestLoaded(_ network: Network) -> Date? {
        perNetwork[network]?.map(\.createdAt).min()
    }

    /// The timestamp above which the combined feed is provably complete: the *newest* of the
    /// oldest-loaded posts across networks that still have pages (and haven't failed). Below it,
    /// the shallowest stream hasn't been fetched yet, so a later page could interleave posts —
    /// hence `combinedVisible` hides that region and `loadMore` pages that stream to catch up.
    /// nil when nothing constrains completeness (all networks ended) → show everything.
    private var completenessWatermark: Date? {
        fetchers.keys
            .filter { !reachedEnd.contains($0) && !failedNetworks.contains($0) }
            .compactMap { oldestLoaded($0) }
            .max()
    }

    /// The combined feed trimmed to the complete region (see `completenessWatermark`), so posts
    /// from both networks always appear in true post order with nothing missing that an un-fetched
    /// page would slot into the middle. Single-network (filtered) views use `items` directly.
    public var combinedVisible: [FeedItem] {
        guard let watermark = completenessWatermark else { return items }
        return items.filter { $0.createdAt >= watermark }
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

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
        for (network, result) in results {
            switch result {
            case .success(let page):
                // Fresh top-of-feed for this network: replace its items and reset its pagination.
                perNetwork[network] = page.items
                reachedEnd.remove(network); failedNetworks.remove(network); rateLimitedNetworks.remove(network)
                if let cursor = page.nextCursor, !page.items.isEmpty { cursors[network] = cursor }
                else { cursors[network] = nil; reachedEnd.insert(network) }
            case .failure(let error):
                // Don't blank a feed that was showing fine: keep this network's existing items and
                // pagination on a failed refresh (e.g. a 429 from deep scrolling). Just flag it so
                // the UI can surface the failure and the user can retry — no forced app restart.
                if isRateLimitError(error) { rateLimitedNetworks.insert(network) }
                else { failedNetworks.insert(network) }
            }
        }
        // Forget any network that's no longer active (account removed) so it doesn't linger.
        let activeKeys = Set(fetchers.keys)
        perNetwork = perNetwork.filter { activeKeys.contains($0.key) }
        cursors = cursors.filter { activeKeys.contains($0.key) }
        reachedEnd.formIntersection(activeKeys)
        failedNetworks.formIntersection(activeKeys)
        rateLimitedNetworks.formIntersection(activeKeys)
        rebuild()
    }

    /// `filter` = the network currently shown (nil = combined). Filtered: paginate just that
    /// network (#214). Combined: page the network(s) holding up the completeness watermark — the
    /// shallowest still-loading stream — so older posts from BOTH networks descend into the visible
    /// feed in true post order. Paging the already-deeper stream would just pile up hidden posts;
    /// catching up the shallow one (extra calls to whichever is behind) is what fixes the "past a
    /// point it's all one network" bug. Failed streams are retried (a timeout must not freeze it).
    public func loadMore(preferring filter: Network? = nil) async {
        guard !isLoading, hasMore(for: filter) else { return }
        let targets: [Network]
        if let filter {
            targets = (fetchers.keys.contains(filter) && !reachedEnd.contains(filter)) ? [filter] : []
        } else {
            let active = fetchers.keys.filter { !reachedEnd.contains($0) }
            let watermark = completenessWatermark
            targets = active.filter { network in
                if failedNetworks.contains(network) { return true }          // retry a failed stream
                guard let oldest = oldestLoaded(network), let watermark else { return true } // (re)load empty
                return oldest >= watermark                                   // shallowest → holds the watermark
            }
        }
        guard !targets.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }
        let results = await withTaskGroup(of: (Network, Result<FeedPage, Error>).self) { group in
            for network in targets {
                let fetcher = fetchers[network]!, cursor = cursors[network]
                group.addTask {
                    do { return (network, .success(try await fetcher(cursor))) }
                    catch { return (network, .failure(error)) }
                }
            }
            var acc: [(Network, Result<FeedPage, Error>)] = []
            for await result in group { acc.append(result) }
            return acc
        }
        for (network, result) in results {
            switch result {
            case .success(let page):
                perNetwork[network, default: []].append(contentsOf: page.items)
                failedNetworks.remove(network); rateLimitedNetworks.remove(network)
                if let cursor = page.nextCursor, !page.items.isEmpty { cursors[network] = cursor }
                else { reachedEnd.insert(network) }
            case .failure(let error):
                // Transient (a timeout or blip): flag for the UI but keep the network eligible so
                // the next scroll retries it. A one-off failure must not permanently freeze
                // pagination — that's what left Bluesky silently stuck with no retry.
                if isRateLimitError(error) { rateLimitedNetworks.insert(network) }
                else { failedNetworks.insert(network) }
            }
        }
        rebuild()
    }

    private func rebuild() {
        items = mergeFeeds(Array(perNetwork.values))
    }
}
