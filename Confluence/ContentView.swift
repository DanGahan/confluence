import SwiftUI
import ConfluenceKit

struct ContentView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false
    /// True until the launch-time Keychain restore finishes, so we show a loading indicator
    /// instead of briefly flashing the "No Accounts" onboarding when a session actually
    /// exists (#131). The stores' `restore()` runs the Keychain read off the main actor.
    @State private var restoring = true

    private var anyLoggedIn: Bool { bluesky.isLoggedIn || mastodon.isLoggedIn }

    var body: some View {
        Group {
            if restoring {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Restoring accounts")
            } else if anyLoggedIn || UITestLaunch.mockFeed {
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
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600) // macOS window min size; on iPhone this would overflow
        #endif
        // Restore persisted sessions here, once the window is on screen — not in the stores'
        // init, where the synchronous Keychain read blocked launch and left the app window-less
        // until a Dock click (#126). Each store reads the Keychain off the main actor and both
        // are awaited in parallel so the loading state clears the moment both have resolved.
        .task {
            async let b: Void = bluesky.restore()
            async let m: Void = mastodon.restore()
            _ = await (b, m)
            restoring = false
        }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
    }
}
