import SwiftUI
import ConfluenceKit

@main
struct ConfluenceApp: App {
    @State private var bluesky = BlueskyAccountStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluesky)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(bluesky)
        }
    }
}
