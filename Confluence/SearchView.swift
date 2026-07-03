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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Bluesky and Mastodon", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onChange(of: query) { _, new in search.search(new) }
                    .onSubmit { search.search(query) }
                if !query.isEmpty {
                    Button { query = ""; search.clear() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])
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
        .onDisappear { search.clear() } // no search history stored
    }

    @ViewBuilder private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                   description: Text("Find people and posts across both networks."))
                .frame(maxHeight: .infinity)
        } else if search.people.isEmpty && search.posts.isEmpty && !search.isSearching {
            ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
        } else {
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
                        ForEach(search.posts) { post in SearchPostRow(post: post) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct PersonRow: View {
    @Environment(FollowStore.self) private var follows
    let person: SearchActor

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(person.avatarURL) { Color.secondary.opacity(0.2) }
                .frame(width: 40, height: 40).clipShape(Circle())
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

private struct SearchPostRow: View {
    let post: FeedItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(post.avatarURL) { Color.secondary.opacity(0.2) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(post.authorName).fontWeight(.semibold).lineLimit(1)
                    Text("@\(post.authorHandle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    networkBadge(post.network)
                }
                if !post.text.isEmpty { Text(post.attributedText).font(.callout).lineLimit(4) }
            }
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
