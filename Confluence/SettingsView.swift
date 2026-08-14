import SwiftUI
import ConfluenceKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        // macOS Settings window: tabbed panes at a fixed size.
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            AppearanceSettings()
                .tabItem { Label("Fonts & Colors", systemImage: "textformat") }
            MediaSettings()
                .tabItem { Label("Media Preview", systemImage: "photo") }
        }
        .frame(width: 480, height: 380)
        #else
        // iOS has no Settings scene, so this is presented as a sheet from the feed toolbar:
        // a navigation list into the same panes, plus About (which is a menu window on macOS).
        NavigationStack {
            List {
                NavigationLink { AccountsSettings().navigationTitle("Accounts") } label: {
                    Label("Accounts", systemImage: "person.2")
                }
                NavigationLink { AppearanceSettings().navigationTitle("Fonts & Colors") } label: {
                    Label("Fonts & Colors", systemImage: "textformat")
                }
                NavigationLink { MediaSettings().navigationTitle("Media Preview") } label: {
                    Label("Media Preview", systemImage: "photo")
                }
                NavigationLink { AboutView().navigationTitle("About") } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #endif
    }
}

// MARK: - Accounts

private struct AccountsSettings: View {
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @State private var blueskyProfile: Profile?
    @State private var mastodonProfile: Profile?
    @State private var showingBlueskyLogin = false
    @State private var showingMastodonLogin = false

    private var accountsKey: String { "\(bluesky.session?.did ?? "-")|\(mastodon.session?.host ?? "-")" }

    var body: some View {
        Form {
            Section("Bluesky") {
                if let session = bluesky.session {
                    accountRow(profile: blueskyProfile, name: session.handle, handle: "@\(session.handle)")
                    Button("Sign Out", role: .destructive) { try? bluesky.logOut(); blueskyProfile = nil }
                } else {
                    Button("Sign In to Bluesky…") { showingBlueskyLogin = true }
                }
            }
            Section("Mastodon") {
                if let session = mastodon.session {
                    accountRow(profile: mastodonProfile,
                               name: mastodonProfile?.name ?? session.host,
                               handle: mastodonProfile.map { "@\($0.handle)" } ?? session.host)
                    LabeledContent("Server", value: session.host)
                    Button("Sign Out", role: .destructive) { Task { try? await mastodon.logOut(); mastodonProfile = nil } }
                } else {
                    Button("Sign In to Mastodon…") { showingMastodonLogin = true }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: accountsKey) { await load() }
        .sheet(isPresented: $showingBlueskyLogin) { BlueskyLoginView() }
        .sheet(isPresented: $showingMastodonLogin) { MastodonLoginView() }
    }

    private func accountRow(profile: Profile?, name: String, handle: String) -> some View {
        HStack(spacing: 10) {
            Avatar(url: profile?.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.name ?? name).fontWeight(.semibold)
                Text(handle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func load() async {
        if let session = bluesky.session {
            blueskyProfile = try? await BlueskyClient().profile(accessToken: session.accessJwt, actor: session.did)
        }
        if let session = mastodon.session {
            mastodonProfile = try? await MastodonClient().currentAccount(host: session.host, accessToken: session.accessToken)
        }
    }
}

// MARK: - Media Preview

private struct MediaSettings: View {
    @AppStorage(MediaPreference.fullSizeKey) private var fullSizeMedia = MediaPreference.fullSizeDefault

    var body: some View {
        Form {
            Section("Images") {
                Toggle("Display Full Size media", isOn: $fullSizeMedia)
                Text(fullSizeMedia
                     ? "Images show in full at their natural shape (portrait, landscape, or square), scaled to the window."
                     : "Images show in a fixed letterbox. Turn on to see the whole image regardless of orientation.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Fonts & Colors

private struct AppearanceSettings: View {
    @AppStorage(PostAppearance.fontNameKey) private var fontName = PostAppearance.defaultName
    @AppStorage(PostAppearance.fontSizeKey) private var fontSize = PostAppearance.defaultSize
    @AppStorage(PostAppearance.linkColorKey) private var linkColorHex = PostAppearance.defaultLinkColorHex

    private var linkColor: Binding<Color> {
        Binding(get: { PostAppearance.linkColor(hex: linkColorHex) },
                set: { linkColorHex = PostAppearance.hex($0) })
    }

    var body: some View {
        Form {
            Section("Post Text") {
                Picker("Font", selection: $fontName) {
                    ForEach(PostAppearance.choices, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: PostAppearance.minSize...PostAppearance.maxSize, step: 1)
                            .frame(width: 180)
                        Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ColorPicker("Link Colour", selection: linkColor, supportsOpacity: false)
                Button("Reset to Default") {
                    fontName = PostAppearance.defaultName
                    fontSize = PostAppearance.defaultSize
                    linkColorHex = PostAppearance.defaultLinkColorHex
                }
            }
            Section("Preview") {
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(PostAppearance.font(name: fontName, size: fontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                Text(previewLink)
                    .font(PostAppearance.font(name: fontName, size: fontSize))
                    .tint(PostAppearance.linkColor(hex: linkColorHex))
            }
        }
        .formStyle(.grouped)
    }

    private var previewLink: AttributedString {
        var s = AttributedString("Tap this link to see the colour.")
        if let range = s.range(of: "this link") { s[range].link = URL(string: "https://example.com") }
        return s
    }
}
