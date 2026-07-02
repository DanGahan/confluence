import SwiftUI
import ConfluenceKit

struct ContentView: View {
    var body: some View {
        // Placeholder shell. F3 replaces this with the combined feed.
        ContentUnavailableView(
            "No Accounts",
            systemImage: "person.crop.circle.badge.plus",
            description: Text("Add a Bluesky or Mastodon account in Settings to see your feed.")
        )
        .frame(minWidth: 480, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
