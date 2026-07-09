import SwiftUI
import ConfluenceKit

struct ContentView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false

    private var anyLoggedIn: Bool { bluesky.isLoggedIn || mastodon.isLoggedIn }

    var body: some View {
        Group {
            if anyLoggedIn {
                FeedView()
            } else {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add a Bluesky or Mastodon account to see your feed.")
                } actions: {
                    Button("Add Bluesky Account") { showingBlueskyLogin = true }
                    Button("Add Mastodon Account") { showingMastodonLogin = true }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 600)
        // Restore persisted sessions here, once the window is on screen — not in the stores'
        // init, where the synchronous Keychain read blocked launch and left the app window-less
        // until a Dock click (#126). The prompt (if any) now appears over a visible window.
        .task { bluesky.restore(); mastodon.restore() }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
    }
}
