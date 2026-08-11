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
    @State private var expanded = false
    @State private var text = ""
    @State private var posting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var networkName: String { item.network == .bluesky ? "Bluesky" : "Mastodon" }
    private var canPost: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !posting }

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                // Invisible-but-hittable backing (not .contentShape) so links keep their
                // pointing-hand hover — same trick as elsewhere in the feed.
                .background(Color.black.opacity(0.001))
                .onTapGesture { toggle() }
            if expanded { replyField }
        }
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Reply on \(networkName)…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($fieldFocused)
                .disabled(posting)
                .accessibilityLabel("Reply text")
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { collapse() }.disabled(posting)
                Button("Reply") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canPost)
            }
        }
        .padding(.leading, 54) // line up under the post text, past the 44pt avatar + spacing
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        if expanded { fieldFocused = true } else { collapse() }
    }

    private func collapse() {
        withAnimation(.snappy(duration: 0.2)) { expanded = false }
        text = ""; errorMessage = nil; posting = false
    }

    private func send() {
        posting = true
        errorMessage = nil
        Task {
            do {
                try await postActions.reply(item, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                // ponytail: no optimistic insert — collapse and let the next refresh show the
                // reply. Also no live character counter; over-limit is caught by the API below.
                collapse()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't post reply. Please try again."
                posting = false
            }
        }
    }
}

extension View {
    /// Make a post row expand an inline reply box when its body is clicked.
    func quickReply(_ item: FeedItem) -> some View { modifier(QuickReply(item: item)) }
}
