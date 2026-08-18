import SwiftUI
import ConfluenceKit

/// A profile's following or followers list, with inline follow buttons.
struct FollowListView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    let network: Network
    let authorID: String
    let kind: FollowListKind

    @State private var actors: [SearchActor] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if actors.isEmpty {
                ContentUnavailableView("Nobody here yet", systemImage: "person.2")
            } else {
                ForEach(actors) { ActorRow(actor: $0) }
            }
        }
        .listStyle(.inset)
        .navigationTitle(kind == .following ? "Following" : "Followers")
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch network {
        case .bluesky:
            guard bluesky.isLoggedIn else { return }
            actors = (try? await bluesky.withAuth { auth, _ in try await BlueskyClient().followList(auth: auth, actor: authorID, kind: kind) }) ?? []
        case .mastodon:
            guard let session = mastodon.session else { return }
            actors = (try? await MastodonClient().followList(host: session.host, accessToken: session.accessToken, accountID: authorID, kind: kind)) ?? []
        }
    }
}
