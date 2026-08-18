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
            Text("Sign in to Bluesky").font(.title2).bold()

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

            if useAppPassword {
                // Fallback: app password (bypasses 2FA — OAuth is preferred).
                Link("Create an app password", destination: URL(string: "https://bsky.app/settings/app-passwords")!)
                    .font(.caption)
                HStack {
                    if isLoggingIn { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sign In") { Task { await logIn() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(!canAppPasswordSubmit)
                }
            } else {
                // Primary: OAuth via the browser.
                Text("Signs in through your browser — no app password, and keeps 2FA.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if isOAuthing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sign in with OAuth") { Task { await logInOAuth() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(handleEmpty || isOAuthing)
                }
            }

            HStack {
                Button(useAppPassword ? "Use OAuth instead" : "Use an app password instead") {
                    withAnimation { useAppPassword.toggle(); errorMessage = nil }
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
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
