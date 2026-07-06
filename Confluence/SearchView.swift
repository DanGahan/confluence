import SwiftUI
import ConfluenceKit

struct SearchView: View {
    @Environment(SearchStore.self) private var search
    @Environment(FollowStore.self) private var follows
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showPeople = true
    @State private var showPosts = true
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SheetCloseButton { dismiss() }
                Spacer()
            }
            .padding([.horizontal, .top])
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Bluesky and Mastodon", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onChange(of: query) { _, new in search.search(new) }
                    .onSubmit { search.recordSearch(query); search.search(query) }
                if !query.isEmpty {
                    Button { query = ""; search.clear() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal).padding(.top, 10)
            HStack(spacing: 8) {
                Toggle("People", isOn: $showPeople).toggleStyle(.button)
                Toggle("Posts", isOn: $showPosts).toggleStyle(.button)
                Spacer()
            }
            .controlSize(.small)
            .padding([.horizontal, .top], 8)
            .padding(.bottom, 8)
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 520)
        .handleProfileLinks()
        .onAppear { fieldFocused = true }
        .onDisappear { search.clear() } // results aren't kept; recents are (persisted separately)
    }

    @ViewBuilder private var content: some View {
        if trimmedQuery.isEmpty {
            if search.recentSearches.isEmpty {
                ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                       description: Text("Find people and posts across both networks."))
                    .frame(maxHeight: .infinity)
            } else {
                recentSearches
            }
        } else if search.people.isEmpty && search.posts.isEmpty && !search.isSearching {
            ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
        } else {
            results
        }
    }

    private var recentSearches: some View {
        List {
            Section {
                ForEach(search.recentSearches, id: \.self) { q in
                    Button {
                        query = q                 // onChange runs the search
                        search.recordSearch(q)    // bump it to the top
                    } label: {
                        Label(q, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear") { search.clearRecents() }.font(.caption)
                }
            }
        }
        .listStyle(.inset)
    }

    private var results: some View {
        List {
            if !search.failedNetworks.isEmpty {
                let names = search.failedNetworks.map { $0 == .bluesky ? "Bluesky" : "Mastodon" }.sorted().joined(separator: " and ")
                Label("\(names) search failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showPeople && !search.people.isEmpty {
                Section("People") {
                    // Cap people only when posts are also shown, so posts stay reachable.
                    ForEach(showPosts ? Array(search.people.prefix(8)) : search.people) { person in
                        PersonRow(person: person)
                    }
                }
            }
            if showPosts && !search.posts.isEmpty {
                Section("Posts") {
                    // Reuse the feed row so search behaves exactly like the feed (right-click
                    // actions, hover links, images/lightbox, cards).
                    ForEach(search.posts) { post in FeedRow(item: post) }
                    if search.hasMore {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            .onAppear { Task { await search.loadMore() } }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct PersonRow: View {
    @Environment(FollowStore.self) private var follows
    let person: SearchActor

    var body: some View {
        HStack(spacing: 10) {
            Avatar(url: person.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name).fontWeight(.semibold).lineLimit(1)
                    networkBadge(person.network)
                }
                Text("@\(person.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !person.bio.isEmpty {
                    Text(person.bio).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button(follows.isFollowing(person) ? "Following" : "Follow") {
                Task { await follows.toggle(person) }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(follows.isFollowing(person) ? "Unfollow" : "Follow") \(person.handle)")
        }
        .padding(.vertical, 4)
    }
}

private func networkBadge(_ network: Network) -> some View {
    let isBluesky = network == .bluesky
    return Text(isBluesky ? "Bluesky" : "Mastodon")
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background((isBluesky ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
        .foregroundStyle(isBluesky ? Color.blue : Color.purple)
}
