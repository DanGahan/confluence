import SwiftUI

// Bridge menu-bar commands (Scene-level) to the focused feed window's actions.
extension FocusedValues {
    @Entry var refreshFeed: (() -> Void)?
    @Entry var scrollFeedToTop: (() -> Void)?
}

/// Standard menu-bar commands. Edit/Window/Help come from SwiftUI automatically.
struct AppCommands: Commands {
    @FocusedValue(\.refreshFeed) private var refreshFeed
    @FocusedValue(\.scrollFeedToTop) private var scrollFeedToTop

    var body: some Commands {
        // File → New Post (⌘N). The composer is F8 (deferred), so it's present but disabled.
        CommandGroup(replacing: .newItem) {
            Button("New Post") {}
                .keyboardShortcut("n")
                .disabled(true)
        }
        CommandMenu("View") {
            Button("Refresh") { refreshFeed?() }
                .keyboardShortcut("r")
                .disabled(refreshFeed == nil)
            Button("Scroll to Top") { scrollFeedToTop?() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(scrollFeedToTop == nil)
        }
    }
}
