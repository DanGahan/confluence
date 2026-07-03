import SwiftUI
import ConfluenceKit

/// Small network label used across feed, search, notifications, and profiles.
struct NetworkBadge: View {
    let network: Network
    var body: some View {
        let isBluesky = network == .bluesky
        Text(isBluesky ? "Bluesky" : "Mastodon")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((isBluesky ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
            .foregroundStyle(isBluesky ? Color.blue : Color.purple)
    }
}

/// A person row with a Follow/Following button. Used in search and follow lists.
struct ActorRow: View {
    @Environment(FollowStore.self) private var follows
    let actor: SearchActor
    var onSelect: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(actor.avatarURL) { Color.secondary.opacity(0.2) }
                .frame(width: 40, height: 40).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(actor.name).fontWeight(.semibold).lineLimit(1)
                    NetworkBadge(network: actor.network)
                }
                Text("@\(actor.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !actor.bio.isEmpty {
                    Text(actor.bio).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button(follows.isFollowing(actor) ? "Following" : "Follow") {
                Task { await follows.toggle(actor) }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(follows.isFollowing(actor) ? "Unfollow" : "Follow") \(actor.handle)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
    }
}
