import SwiftUI

// Bridge menu-bar commands (Scene-level) to the focused feed window's actions.
extension FocusedValues {
    @Entry var refreshFeed: (() -> Void)?
    @Entry var scrollFeedToTop: (() -> Void)?
    @Entry var newPost: (() -> Void)?
}

/// Standard menu-bar commands. Edit/Window/Help come from SwiftUI automatically.
struct AppCommands: Commands {
    @FocusedValue(\.refreshFeed) private var refreshFeed
    @FocusedValue(\.scrollFeedToTop) private var scrollFeedToTop
    @FocusedValue(\.newPost) private var newPost

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Post") { newPost?() }
                .keyboardShortcut("n")
                .disabled(newPost == nil)
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
