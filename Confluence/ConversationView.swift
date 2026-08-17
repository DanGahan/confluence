import SwiftUI
import ConfluenceKit

/// A DM thread: messages oldest → newest with a send box at the foot. Sends only to the
/// conversation's own network — DMs are never cross-posted (F15).
struct ConversationView: View {
    @Environment(DMStore.self) private var dms
    let conversation: Conversation

    @State private var messages: [DirectMessage] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if !conversation.isPrivate { notPrivateBanner }
            messageList
            Divider()
            sendBar
        }
        .navigationTitle(conversation.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await dms.markRead(conversation)
            await load()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                    ForEach(messages) { MessageBubble(message: $0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var sendBar: some View {
        VStack(spacing: 2) {
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { Task { await send() } }
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityLabel("Send")
            }
        }
        .padding(8)
    }

    private var notPrivateBanner: some View {
        Label("Not private — Mastodon direct messages are visible to the server and everyone mentioned.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.12))
    }

    private func load() async {
        loading = true
        do { messages = try await dms.messages(for: conversation) }
        catch { errorText = "Couldn’t load messages." }
        loading = false
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true; errorText = nil
        do {
            let sent = try await dms.send(text, to: conversation)
            messages.append(sent)
            draft = ""
        } catch {
            errorText = "Couldn’t send — check your connection and try again."
        }
        sending = false
    }
}

private struct MessageBubble: View {
    let message: DirectMessage
    var body: some View {
        Text(message.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(message.isFromMe ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.isFromMe ? "You" : "Them"): \(message.text)")
    }
}
