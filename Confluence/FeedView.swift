import SwiftUI
import ConfluenceKit

struct FeedView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @State private var feed = FeedStore()
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false
    @State private var lastPagedTailID: String?

    private var accountsKey: String {
        "\(bluesky.session?.did ?? "-")|\(mastodon.session?.host ?? "-")"
    }

    var body: some View {
        List {
            if !feed.failedNetworks.isEmpty {
                failureBanner
            }
            ForEach(feed.items) { item in
                FeedRow(item: item)
                    .onAppear {
                        // Page each tail at most once, else onAppear chain-loads the whole timeline.
                        guard item.id == feed.items.last?.id, item.id != lastPagedTailID else { return }
                        lastPagedTailID = item.id
                        Task { await feed.loadMore() }
                    }
            }
            if feed.hasMore && !feed.items.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            }
        }
        .listStyle(.inset)
        .refreshable { await feed.refresh() }
        .overlay {
            if feed.items.isEmpty {
                if feed.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Posts Yet", systemImage: "tray", description: Text("Pull down to refresh."))
                }
            }
        }
        .task(id: accountsKey) {
            feed.setFetchers(makeFetchers())
            await feed.refresh()
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    if !bluesky.isLoggedIn { Button("Add Bluesky Account") { showingBlueskyLogin = true } }
                    if !mastodon.isLoggedIn { Button("Add Mastodon Account") { showingMastodonLogin = true } }
                    if bluesky.isLoggedIn && mastodon.isLoggedIn {
                        Text("Both accounts connected")
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .help("Accounts")
            }
            ToolbarItem {
                Button { Task { await feed.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh")
            }
        }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
    }

    private var failureBanner: some View {
        let names = feed.failedNetworks.map { $0 == .bluesky ? "Bluesky" : "Mastodon" }.sorted().joined(separator: " and ")
        return Label("Couldn't refresh \(names). Showing what loaded.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    private func makeFetchers() -> [Network: PageFetcher] {
        var fetchers: [Network: PageFetcher] = [:]
        if bluesky.isLoggedIn {
            let store = bluesky
            let client = BlueskyClient()
            fetchers[.bluesky] = { cursor in
                guard let token = await store.session?.accessJwt else { throw BlueskyError.invalidCredentials }
                do {
                    return try await client.timeline(accessToken: token, cursor: cursor)
                } catch BlueskyError.invalidCredentials {
                    // Access token expired — refresh once and retry.
                    try await store.refresh()
                    guard let fresh = await store.session?.accessJwt else { throw BlueskyError.invalidCredentials }
                    return try await client.timeline(accessToken: fresh, cursor: cursor)
                }
            }
        }
        if let session = mastodon.session {
            let client = MastodonClient()
            fetchers[.mastodon] = { cursor in
                try await client.homeTimeline(host: session.host, accessToken: session.accessToken, maxId: cursor)
            }
        }
        return fetchers
    }
}

private struct FeedRow: View {
    let item: FeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: item.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                if let repostedBy = item.repostedBy {
                    Label("Reposted by \(repostedBy)", systemImage: "arrow.2.squarepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(item.authorName).fontWeight(.semibold).lineLimit(1)
                    Text("@\(item.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    networkBadge
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }
                if !item.text.isEmpty {
                    Text(item.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !item.imageURLs.isEmpty {
                    // Non-scrolling row — a nested horizontal ScrollView steals the List's
                    // vertical scroll gesture on macOS. Both networks cap posts at 4 images.
                    HStack(spacing: 6) {
                        ForEach(item.imageURLs.prefix(4), id: \.self) { url in
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.15)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var networkBadge: some View {
        let isBluesky = item.network == .bluesky
        return Text(isBluesky ? "Bluesky" : "Mastodon")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((isBluesky ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
            .foregroundStyle(isBluesky ? Color.blue : Color.purple)
    }

    private var accessibilitySummary: String {
        let network = item.network == .bluesky ? "Bluesky" : "Mastodon"
        let repost = item.repostedBy.map { "Reposted by \($0). " } ?? ""
        return "\(repost)\(item.authorName) on \(network): \(item.text)"
    }
}
