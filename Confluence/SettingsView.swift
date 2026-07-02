import SwiftUI
import ConfluenceKit

struct SettingsView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @State private var showingLogin = false

    var body: some View {
        Form {
            Section("Bluesky") {
                if let session = bluesky.session {
                    LabeledContent("Account", value: "@\(session.handle)")
                    Button("Sign Out", role: .destructive) {
                        try? bluesky.logOut()
                    }
                } else {
                    Button("Sign In to Bluesky…") { showingLogin = true }
                }
            }
            // F2 adds a Mastodon section here.
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 220)
        .sheet(isPresented: $showingLogin) {
            BlueskyLoginView()
        }
    }
}
