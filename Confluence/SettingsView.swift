import SwiftUI

struct SettingsView: View {
    var body: some View {
        // Placeholder. F1/F2 add the Accounts pane (Bluesky + Mastodon login) here.
        Form {
            Text("Accounts settings will appear here.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 250)
    }
}

#Preview {
    SettingsView()
}
