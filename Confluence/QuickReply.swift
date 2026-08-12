import SwiftUI
import ConfluenceKit

/// Author name + handle as a tap target that opens the profile. Used in every post row so the
/// username behaves like the avatar (opens profile) and is excluded from the reply-expand tap.
struct AuthorLabel: View {
    let item: FeedItem
    @State private var showingProfile = false

    var body: some View {
        Button { showingProfile = true } label: {
            HStack(spacing: 6) {
                Text(item.authorName).fontWeight(.semibold).lineLimit(1)
                Text("@\(item.authorHandle)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.authorName), @\(item.authorHandle). Opens profile.")
        .sheet(isPresented: $showingProfile) {
            ProfileView(network: item.network, authorID: item.authorID, handle: item.authorHandle)
        }
    }
}

/// Click a post's body → the row grows to reveal an inline reply field + Reply button. Attached
/// to every post row (feed, thread, profile, search) via `.quickReply(item)`. Avatar, username,
/// media, links and the "N replies" button all consume their own clicks, so only the post's
/// chrome/text toggles the box.
private struct QuickReply: ViewModifier {
    let item: FeedItem
    @Environment(PostActionStore.self) private var postActions
    /// Owned by the host row so its context menu can open the box too, not just the body tap.
    @Binding var expanded: Bool
    @State private var text = ""
    @State private var posting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var networkName: String { item.network == .bluesky ? "Bluesky" : "Mastodon" }
    private var limit: Int { item.network.defaultCharacterLimit }
    private var overLimit: Bool { text.count > limit }
    /// Only Bluesky's cap is firm enough to block on; Mastodon over-limit is a soft warning
    /// (instances vary — the server rejects if it's genuinely too long).
    private var overHardLimit: Bool { item.network.isHardCharacterLimit && overLimit }
    private var canPost: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !posting && !overHardLimit
    }

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                // Invisible-but-hittable backing (not .contentShape) so links keep their
                // pointing-hand hover — same trick as elsewhere in the feed.
                .background(Color.black.opacity(0.001))
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
            if expanded { replyField }
        }
        // Focus on open, clear on close — covers both the body tap and the context-menu item.
        .onChange(of: expanded) { _, isOpen in
            if isOpen { fieldFocused = true }
            else { text = ""; errorMessage = nil; posting = false }
        }
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Single-line, fixed-height field. A vertical-growth TextField (axis: .vertical)
            // renegotiates its intrinsic height against the enclosing LazyVStack every layout
            // pass, which blows sizeThatFits up exponentially and beachballs the feed — so we
            // keep the field's height fixed. ponytail: multiline growth would need a
            // fixed-frame TextEditor, not axis: .vertical, inside the lazy row.
            TextField("Reply on \(networkName)…", text: $text)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($fieldFocused)
                .disabled(posting)
                .onSubmit { if canPost { send() } }
                .accessibilityLabel("Reply text")
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("\(text.count)/\(limit)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(overLimit ? .red : .secondary)
                    .accessibilityLabel("\(text.count) of \(limit) characters")
                Spacer()
                Button("Cancel") { collapse() }.disabled(posting)
                Button("Reply") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canPost)
            }
        }
        .padding(.leading, 54) // line up under the post text, past the 44pt avatar + spacing
        .transition(.opacity) // opacity only; a .move transition thrashes layout in a LazyVStack
    }

    private func collapse() {
        withAnimation(.snappy(duration: 0.2)) { expanded = false } // onChange clears the fields
    }

    private func send() {
        posting = true
        errorMessage = nil
        Task {
            do {
                try await postActions.reply(item, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                // ponytail: no optimistic insert — collapse and let the next refresh show the
                // reply. Adding one means splicing the new post into the live feed/thread state.
                collapse()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't post reply. Please try again."
                posting = false
            }
        }
    }
}

extension View {
    /// Make a post row expand an inline reply box. `expanded` is owned by the row so its
    /// context menu can also open the box (via a "Reply" item), not just a body tap.
    func quickReply(_ item: FeedItem, expanded: Binding<Bool>) -> some View {
        modifier(QuickReply(item: item, expanded: expanded))
    }
}
