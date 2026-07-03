import SwiftUI
import ConfluenceKit

struct ComposerView: View {
    @Environment(ComposerStore.self) private var composerStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    var body: some View {
        @Bindable var composer = composerStore
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New Post").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            TextEditor(text: $composer.text)
                .font(.body)
                .frame(minHeight: 120)
                .focused($editorFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 16) {
                if composer.isConnected(.bluesky) {
                    Toggle("Post to Bluesky", isOn: $composer.postToBluesky)
                }
                if composer.isConnected(.mastodon) {
                    Toggle("Post to Mastodon", isOn: $composer.postToMastodon)
                }
                Spacer()
                Text("\(composer.characterCount)/\(composer.characterLimit)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(composer.isOverLimit ? .red : .secondary)
                    .accessibilityLabel("\(composer.characterCount) of \(composer.characterLimit) characters")
            }

            if !composer.failed.isEmpty {
                let names = composer.failed.keys.map { $0 == .bluesky ? "Bluesky" : "Mastodon" }.sorted().joined(separator: " and ")
                Label("Couldn't post to \(names). Bluesky/Mastodon that already posted won't be posted again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if composer.isPosting { ProgressView().controlSize(.small) }
                Spacer()
                Button(composer.failed.isEmpty ? "Post" : "Retry") {
                    Task {
                        await composerStore.post()
                        if composerStore.didPostAll { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!composer.canPost)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { editorFocused = true }
    }
}
