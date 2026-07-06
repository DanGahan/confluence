import Foundation
import Observation

/// Runs a search against one network. `cursor` nil = first page. Never throws.
public typealias SearchFetcher = @Sendable (_ query: String, _ cursor: String?) async -> SearchResults

/// Owns search state: debounced query, parallel per-network fetch, merged results.
/// No search history is stored.
@MainActor
@Observable
public final class SearchStore {
    public private(set) var people: [SearchActor] = []
    public private(set) var posts: [FeedItem] = []
    public private(set) var failedNetworks: Set<Network> = []
    public private(set) var isSearching = false
    /// The last few distinct searches, most-recent first (max 5). Persisted locally.
    public private(set) var recentSearches: [String] = []

    private var fetchers: [Network: SearchFetcher] = [:]
    private var debounceTask: Task<Void, Never>?
    private var currentQuery = ""
    private var postGroups: [Network: [FeedItem]] = [:]
    private var postCursors: [Network: String] = [:] // next-page cursor per network; absent = end
    private let defaults: UserDefaults
    private static let recentsKey = "recentSearches"
    private static let maxRecents = 5

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Records a deliberate search (Enter or a tapped recent) into the recents list.
    public func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentSearches = Array(list.prefix(Self.maxRecents))
        defaults.set(recentSearches, forKey: Self.recentsKey)
    }

    public func clearRecents() {
        recentSearches = []
        defaults.removeObject(forKey: Self.recentsKey)
    }

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
        postGroups = [:]; postCursors = [:]; currentQuery = ""
    }

    /// Whether any network has a further page of post results.
    public var hasMore: Bool { !postCursors.isEmpty }

    /// Undebounced first-page search — runs all networks in parallel and merges. Exposed for tests.
    public func runSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        currentQuery = query
        postGroups = [:]; postCursors = [:]

        let active = Array(fetchers)
        let results = await withTaskGroup(of: (Network, SearchResults).self) { group in
            for (network, fetcher) in active {
                group.addTask { (network, await fetcher(query, nil)) }
            }
            var acc: [(Network, SearchResults)] = []
            for await result in group { acc.append(result) }
            return acc
        }
        guard !Task.isCancelled else { return }

        var allPeople: [SearchActor] = []
        var failures: Set<Network> = []
        for (network, result) in results.sorted(by: { $0.0.rawValue < $1.0.rawValue }) {
            if result.failed { failures.insert(network) }
            allPeople.append(contentsOf: result.people)
            postGroups[network] = result.posts
            if let cursor = result.postsCursor, !result.posts.isEmpty { postCursors[network] = cursor }
        }
        people = allPeople
        posts = mergeFeeds(Array(postGroups.values))
        failedNetworks = failures
    }

    /// Loads the next page of posts for every network that still has one, and appends them.
    public func loadMore() async {
        guard !isSearching, hasMore else { return }
        let query = currentQuery
        let pages = Array(postCursors) // (network, cursor)
        isSearching = true
        defer { isSearching = false }

        let results = await withTaskGroup(of: (Network, SearchResults?).self) { group in
            for (network, cursor) in pages {
                guard let fetcher = fetchers[network] else { continue }
                group.addTask { (network, await fetcher(query, cursor)) }
            }
            var acc: [(Network, SearchResults?)] = []
            for await result in group { acc.append(result) }
            return acc
        }
        guard !Task.isCancelled, currentQuery == query else { return } // query changed mid-load

        for (network, result) in results {
            guard let result, !result.failed else { continue }
            postGroups[network, default: []].append(contentsOf: result.posts)
            if let cursor = result.postsCursor, !result.posts.isEmpty { postCursors[network] = cursor }
            else { postCursors[network] = nil }
        }
        posts = mergeFeeds(Array(postGroups.values))
    }
}
