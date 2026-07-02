import SwiftUI
import ConfluenceKit

struct BlueskyLoginView: View {
    @Environment(BlueskyAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var handle = ""
    @State private var appPassword = ""
    @State private var errorMessage: String?
    @State private var isLoggingIn = false

    private var canSubmit: Bool {
        !handle.trimmingCharacters(in: .whitespaces).isEmpty && !appPassword.isEmpty && !isLoggingIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to Bluesky")
                .font(.title2).bold()
            Text("Use an app password — not your main account password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Link("Create an app password", destination: URL(string: "https://bsky.app/settings/app-passwords")!)
                .font(.subheadline)

            Form {
                TextField("Handle", text: $handle, prompt: Text("alice.bsky.social"))
                    .textContentType(.username)
                    .accessibilityLabel("Bluesky handle")
                SecureField("App password", text: $appPassword, prompt: Text("xxxx-xxxx-xxxx-xxxx"))
                    .accessibilityLabel("Bluesky app password")
            }
            .formStyle(.columns)
            .disabled(isLoggingIn)
            .onSubmit { if canSubmit { Task { await logIn() } } }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isLoggingIn { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") { Task { await logIn() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func logIn() async {
        isLoggingIn = true
        errorMessage = nil
        do {
            try await account.logIn(identifier: handle, appPassword: appPassword)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sign in failed. Please try again."
        }
        isLoggingIn = false
    }
}
