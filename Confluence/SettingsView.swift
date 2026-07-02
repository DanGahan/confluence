import SwiftUI
import ConfluenceKit

struct SettingsView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false

    var body: some View {
        Form {
            Section("Bluesky") {
                if let session = bluesky.session {
                    LabeledContent("Account", value: "@\(session.handle)")
                    Button("Sign Out", role: .destructive) {
                        try? bluesky.logOut()
                    }
                } else {
                    Button("Sign In to Bluesky…") { showingBlueskyLogin = true }
                }
            }
            Section("Mastodon") {
                if let session = mastodon.session {
                    LabeledContent("Server", value: session.host)
                    Button("Sign Out", role: .destructive) {
                        Task { try? await mastodon.logOut() }
                    }
                } else {
                    Button("Sign In to Mastodon…") { showingMastodonLogin = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 300)
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
    }
}
