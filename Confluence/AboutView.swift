import SwiftUI

/// Custom About window replacing macOS's default (which only shows CFBundleName and
/// CFBundleShortVersionString). Shows the release version and links the commit hash
/// to the GitHub commit the artefact was built from — useful when triaging a report.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.tertiary)
            }
            Text("Confluence").font(.title).fontWeight(.semibold)
            Text("One timeline. Two networks.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Version \(BuildInfo.version)")
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
                commitRow
            }
            .padding(.top, 4)

            Text("Bluesky + Mastodon, natively.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(30)
        .frame(width: 340)
    }

    @ViewBuilder private var commitRow: some View {
        if let url = BuildInfo.commitURL {
            Button {
                openURL(url)
            } label: {
                Label("Commit \(BuildInfo.commitShort)", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.monospacedDigit())
            }
            .buttonStyle(.link)
            .accessibilityLabel("Open commit \(BuildInfo.commit) on GitHub")
        } else {
            Text("Commit local")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Opens the custom About window instead of the default one macOS synthesises.
enum AboutWindow {
    static func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: AboutView())
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
