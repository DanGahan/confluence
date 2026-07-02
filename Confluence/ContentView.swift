import SwiftUI
import ConfluenceKit

struct ContentView: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @State private var showingLogin = false

    var body: some View {
        Group {
            if let session = bluesky.session {
                // ponytail: placeholder until F3 replaces this with the combined feed.
                ContentUnavailableView {
                    Label("Signed In", systemImage: "checkmark.circle")
                } description: {
                    Text("Signed in to Bluesky as @\(session.handle). Your combined feed arrives in a later update.")
                }
            } else {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add a Bluesky account to see your feed.")
                } actions: {
                    Button("Add Bluesky Account") { showingLogin = true }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 600)
        .sheet(isPresented: $showingLogin) {
            BlueskyLoginView()
        }
    }
}
