import SwiftUI
import ConfluenceKit

struct MastodonLoginView: View {
    @Environment(MastodonAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var instance = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var canSubmit: Bool {
        !instance.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to Mastodon")
                .font(.title2).bold()
            Text("Enter your server's domain. You'll approve access in your browser.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                TextField("Server", text: $instance, prompt: Text("mastodon.social"))
                    .textContentType(.URL)
                    .accessibilityLabel("Mastodon server domain")
            }
            .formStyle(.columns)
            .disabled(isWorking)
            .onSubmit { if canSubmit { Task { await logIn() } } }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { Task { await logIn() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func logIn() async {
        isWorking = true
        errorMessage = nil
        do {
            try await account.logIn(instance: instance)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sign in failed. Please try again."
        }
        isWorking = false
    }
}
