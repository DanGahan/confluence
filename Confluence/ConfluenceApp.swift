import SwiftUI
import ConfluenceKit

@main
struct ConfluenceApp: App {
    @State private var bluesky: BlueskyAccountStore
    @State private var mastodon: MastodonAccountStore
    @State private var follows = FollowStore()
    @State private var notifications = NotificationStore()
    @State private var search = SearchStore()
    @State private var composer = ComposerStore()
    @State private var postActions = PostActionStore()
    @State private var drafts = DraftStore()

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
                .environment(search)
                .environment(composer)
                .environment(postActions)
                .environment(drafts)
                .background(FeedWindowConfigurator()) // prefer tabs so ⌘T adds a tab, not a window
        }
        .windowResizability(.contentMinSize)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(bluesky)
                .environment(mastodon)
        }
    }
}

/// When a new feed window appears, folds it into an existing feed window's tab group so New Tab
/// (⌘T) adds a *tab* to the current window rather than opening a separate window — regardless of
/// the system "prefer tabs when opening documents" setting. Retries until the window attaches.
private struct FeedWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        func apply() {
            guard let window = view.window else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { apply() }
                return
            }
            window.tabbingIdentifier = "feed"
            let others = NSApp.windows.filter { $0 !== window && $0.tabbingIdentifier == "feed" && $0.isVisible }
            // Prefer an existing multi-tab group; otherwise start a group with any feed window.
            if let host = others.first(where: { ($0.tabGroup?.windows.count ?? 0) > 1 }) ?? others.first,
               window.tabGroup !== host.tabGroup {
                host.addTabbedWindow(window, ordered: .above)
            }
            // Bring the new window forward and activate the app. On a fresh launch SwiftUI
            // doesn't reliably make us frontmost (#94); a user-opened tab/window is meant to
            // come forward too.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { apply() }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
