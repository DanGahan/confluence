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
                // ponytail: placeholder until F3 replaces this with the combined feed.
                ContentUnavailableView {
                    Label("Signed In", systemImage: "checkmark.circle")
                } description: {
                    VStack(spacing: 4) {
                        if let s = bluesky.session { Text("Bluesky: @\(s.handle)") }
                        if let s = mastodon.session { Text("Mastodon: \(s.host)") }
                        Text("Your combined feed arrives in a later update.")
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    if !bluesky.isLoggedIn {
                        Button("Add Bluesky Account") { showingBlueskyLogin = true }
                    }
                    if !mastodon.isLoggedIn {
                        Button("Add Mastodon Account") { showingMastodonLogin = true }
                    }
                }
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
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
    }
}
