import SwiftUI
import ConfluenceKit

@main
struct ConfluenceApp: App {
    @State private var bluesky: BlueskyAccountStore
    @State private var mastodon: MastodonAccountStore
    @State private var follows = FollowStore()
    @State private var notifications = NotificationStore()

    init() {
        // UI tests use in-memory storage: a clean logged-out state, and no Keychain access
        // (which would pop a system prompt on every launch for unsigned/ad-hoc builds).
        let uiTest = ProcessInfo.processInfo.arguments.contains("-uiTestLoggedOut")
        let blueskyStore: any SecureStore = uiTest ? EphemeralSecureStore() : Keychain(service: "com.dangahan.confluence.bluesky")
        let mastodonStore: any SecureStore = uiTest ? EphemeralSecureStore() : Keychain(service: "com.dangahan.confluence.mastodon")
        _bluesky = State(initialValue: BlueskyAccountStore(keychain: blueskyStore))
        _mastodon = State(initialValue: MastodonAccountStore(authenticator: WebAuthSession(), keychain: mastodonStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluesky)
                .environment(mastodon)
                .environment(follows)
                .environment(notifications)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(bluesky)
                .environment(mastodon)
        }
    }
}
