import Foundation
import Observation

/// Runs a search against one network. Returns results (with a failed flag), never throws.
public typealias SearchFetcher = @Sendable (_ query: String) async -> SearchResults

/// Owns search state: debounced query, parallel per-network fetch, merged results.
/// No search history is stored.
@MainActor
@Observable
public final class SearchStore {
    public private(set) var people: [SearchActor] = []
    public private(set) var posts: [FeedItem] = []
    public private(set) var failedNetworks: Set<Network> = []
    public private(set) var isSearching = false

    private var fetchers: [Network: SearchFetcher] = [:]
    private var debounceTask: Task<Void, Never>?

    public init() {}

    public func setFetchers(_ fetchers: [Network: SearchFetcher]) {
        self.fetchers = fetchers
    }

    /// Debounced entry point (300ms). Empty query clears results.
    public func search(_ query: String) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    public func clear() {
        debounceTask?.cancel()
        people = []; posts = []; failedNetworks = []; isSearching = false
    }

    /// Undebounced search — runs all networks in parallel and merges. Exposed for tests.
    public func runSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }

        let active = Array(fetchers)
        let results = await withTaskGroup(of: (Network, SearchResults).self) { group in
            for (network, fetcher) in active {
                group.addTask { (network, await fetcher(query)) }
            }
            var acc: [(Network, SearchResults)] = []
            for await result in group { acc.append(result) }
            return acc
        }
        guard !Task.isCancelled else { return }

        var allPeople: [SearchActor] = []
        var postGroups: [[FeedItem]] = []
        var failures: Set<Network> = []
        for (network, result) in results.sorted(by: { $0.0.rawValue < $1.0.rawValue }) {
            if result.failed { failures.insert(network) }
            allPeople.append(contentsOf: result.people)
            postGroups.append(result.posts)
        }
        people = allPeople
        posts = mergeFeeds(postGroups)
        failedNetworks = failures
    }
}
