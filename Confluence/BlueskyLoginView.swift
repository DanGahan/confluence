import SwiftUI
import ConfluenceKit

struct BlueskyLoginView: View {
    @Environment(BlueskyAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var handle = ""
    @State private var appPassword = ""
    @State private var errorMessage: String?
    @State private var isLoggingIn = false
    @State private var isOAuthing = false
    @State private var useAppPassword = false     // fallback path, hidden by default

    private var handleEmpty: Bool { handle.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canAppPasswordSubmit: Bool { !handleEmpty && !appPassword.isEmpty && !isLoggingIn }
    private var busy: Bool { isLoggingIn || isOAuthing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to Bluesky").font(.title2).bold()
                Text("The secure way — sign in through your browser. Your password never touches the app and two-factor authentication keeps working.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Handle", text: $handle, prompt: Text("alice.bsky.social"))
                    .textContentType(.username)
                    .accessibilityLabel("Bluesky handle")
                if useAppPassword {
                    SecureField("App password", text: $appPassword, prompt: Text("xxxx-xxxx-xxxx-xxxx"))
                        .accessibilityLabel("Bluesky app password")
                }
            }
            .formStyle(.columns)
            .disabled(busy)
            .onSubmit { if useAppPassword { if canAppPasswordSubmit { Task { await logIn() } } }
                        else if !handleEmpty { Task { await logInOAuth() } } }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            // Primary action: OAuth, full-width and prominent.
            Button {
                Task { await logInOAuth() }
            } label: {
                HStack {
                    if isOAuthing { ProgressView().controlSize(.small).tint(.white) }
                    Text("Sign in with Bluesky").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(handleEmpty || busy)

            if useAppPassword {
                // De-emphasised fallback, with the honest caveat.
                Divider()
                Text("App passwords bypass two-factor authentication. Only use this if OAuth doesn’t work for your account.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Create an app password", destination: URL(string: "https://bsky.app/settings/app-passwords")!)
                    .font(.caption)
                HStack {
                    if isLoggingIn { ProgressView().controlSize(.small) }
                    Button("Hide") { withAnimation { useAppPassword = false; errorMessage = nil } }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign in with app password") { Task { await logIn() } }
                        .disabled(!canAppPasswordSubmit)
                }
            }

            HStack {
                if !useAppPassword {
                    Button("Trouble signing in? Use an app password") {
                        withAnimation { useAppPassword = true; errorMessage = nil }
                    }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
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

    private func logInOAuth() async {
        isOAuthing = true
        errorMessage = nil
        do {
            try await account.logInWithOAuth(handle: handle)
            dismiss() // signed in — the feed loads over DPoP
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "OAuth sign-in failed. Please try again."
        }
        isOAuthing = false
    }
}
