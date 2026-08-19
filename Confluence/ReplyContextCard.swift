import SwiftUI
import ConfluenceKit

/// A card below a reply previewing the post it's responding to (#212). Styled like `LinkCardView`;
/// tapping opens that post's thread. On Bluesky the parent's text is shown; on Mastodon the home
/// timeline gives only the parent's author, so it reads "Replying to @handle" and still opens the
/// thread (parent body would need a lazy fetch — a follow-up).
struct ReplyContextCard: View {
    let reply: ReplyRef
    var onOpen: () -> Void

    private var who: String {
        if !reply.authorName.isEmpty { return reply.authorName }
        if !reply.authorHandle.isEmpty { return "@\(reply.authorHandle)" }
        return "a post"
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Replying to \(who)", systemImage: "arrowshape.turn.up.left")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).lineLimit(1)
                if !reply.snippet.isEmpty {
                    Text(reply.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
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
    }
}
