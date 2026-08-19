import SwiftUI
import ConfluenceKit

/// A card below a reply previewing the post it's responding to (#212). Styled like `LinkCardView`;
/// tapping opens that post's thread. Bluesky carries the parent inline; Mastodon's home timeline
/// omits the parent body, so the card lazily fetches it (`statusPreview`), cached per id.
struct ReplyContextCard: View {
    let reply: ReplyRef
    let network: Network
    var onOpen: () -> Void

    @Environment(MastodonAccountStore.self) private var mastodon
    @State private var fetched: ReplyRef?

    private var shown: ReplyRef { fetched ?? reply }
    private var who: String {
        if !shown.authorName.isEmpty { return shown.authorName }
        if !shown.authorHandle.isEmpty { return "@\(shown.authorHandle)" }
        return "a post"
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Replying to \(who)", systemImage: "arrowshape.turn.up.left")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).lineLimit(1)
                if !shown.snippet.isEmpty {
                    Text(shown.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(.link) // behaves like a link — pointing hand on hover
        #endif
        .accessibilityLabel("Replying to \(who). Opens the thread.")
        .task(id: reply.threadID) { await fillMastodonBody() }
    }

    /// Mastodon-only: the parent body isn't in the home timeline, so fetch it once (cached).
    private func fillMastodonBody() async {
        guard network == .mastodon, reply.snippet.isEmpty, fetched == nil,
              let session = mastodon.session else { return }
        if let cached = ReplyPreviewCache.shared.get(reply.threadID) { fetched = cached; return }
        guard let ref = try? await MastodonClient().statusPreview(
            host: session.host, accessToken: session.accessToken, id: reply.threadID) else { return }
        ReplyPreviewCache.shared.set(reply.threadID, ref)
        fetched = ref
    }
}

/// Dedupes parent-status lookups across feed rows and scrolls (per app session).
@MainActor final class ReplyPreviewCache {
    static let shared = ReplyPreviewCache()
    private var cache: [String: ReplyRef] = [:]
    func get(_ id: String) -> ReplyRef? { cache[id] }
    func set(_ id: String, _ ref: ReplyRef) { cache[id] = ref }
}
