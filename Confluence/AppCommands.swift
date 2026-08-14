import SwiftUI

// Bridge menu-bar commands (Scene-level) to the focused feed window's actions.
extension FocusedValues {
    @Entry var refreshFeed: (() -> Void)?
    @Entry var scrollFeedToTop: (() -> Void)?
    @Entry var newPost: (() -> Void)?
    @Entry var openSearch: (() -> Void)?
    @Entry var openOwnFeed: ((OwnFeedScope) -> Void)?
    @Entry var availableOwnScopes: Set<OwnFeedScope>?
}

#if os(macOS)
import AppKit

/// Standard menu-bar commands. Edit/Window/Help come from SwiftUI automatically. macOS-only —
/// iOS has no menu bar (iPad hardware-keyboard shortcuts are a later nice-to-have).
struct AppCommands: Commands {
    @FocusedValue(\.refreshFeed) private var refreshFeed
    @FocusedValue(\.scrollFeedToTop) private var scrollFeedToTop
    @FocusedValue(\.newPost) private var newPost
    @FocusedValue(\.openSearch) private var openSearch
    @FocusedValue(\.openOwnFeed) private var openOwnFeed
    @FocusedValue(\.availableOwnScopes) private var availableOwnScopes

    var body: some Commands {
        // Replace the default "About Confluence" menu item so it opens our custom About
        // window (which surfaces the release version and the git commit the artefact was
        // built from — see BuildInfo).
        CommandGroup(replacing: .appInfo) {
            Button("About Confluence") { AboutWindow.show() }
        }
        CommandMenu("My Posts") {
            ForEach(OwnFeedScope.allCases) { scope in
                Button(scope.title) { openOwnFeed?(scope) }
                    .disabled(openOwnFeed == nil || !(availableOwnScopes?.contains(scope) ?? false))
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Post") { newPost?() }
                .keyboardShortcut("n")
                .disabled(newPost == nil)
            // Replicates the tab bar's "+": force the key window to prefer tabs, then route
            // newWindowForTab: through the responder chain so the new window joins as a tab.
            Button("New Tab") {
                NSApp.keyWindow?.tabbingMode = .preferred
                NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("t")
        }
        // Add to the system-provided View menu (Show Tab Bar, Enter Full Screen) rather than
        // declaring a second "View" menu with CommandMenu.
        CommandGroup(after: .sidebar) {
            Button("Search") { openSearch?() }
                .keyboardShortcut("s")
                .disabled(openSearch == nil)
            Button("Refresh") { refreshFeed?() }
                .keyboardShortcut("r")
                .disabled(refreshFeed == nil)
            Button("Scroll to Top") { scrollFeedToTop?() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(scrollFeedToTop == nil)
            Divider()
        }
    }
}

#endif
