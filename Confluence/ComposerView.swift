import SwiftUI
#if os(macOS)
import AppKit
#endif
import PhotosUI
import ConfluenceKit

struct ComposerView: View {
    @Environment(ComposerStore.self) private var composerStore
    @Environment(BlueskyAccountStore.self) private var bluesky
    @Environment(MastodonAccountStore.self) private var mastodon
    @Environment(DraftStore.self) private var draftStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    @State private var accounts: [Network: Profile] = [:]
    @State private var following: [SearchActor] = []
    @State private var addingLink = false
    @State private var linkText = ""
    @State private var showingLibrary = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var editingDraftID: UUID?
    @State private var showingDrafts = false

    private var hasContent: Bool {
        !composerStore.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerStore.attachments.isEmpty
    }

    var body: some View {
        @Bindable var composer = composerStore
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SheetCloseButton { dismiss() }
                Text(editingDraftID == nil ? "New Post" : "Draft").font(.headline)
                Spacer()
                Button { showingDrafts = true } label: {
                    Label("Drafts", systemImage: "tray.full")
                }
                .disabled(draftStore.drafts.isEmpty)
                .popover(isPresented: $showingDrafts, arrowEdge: .top) { draftsPopover }
            }

            TextEditor(text: $composer.text)
                .font(.body)
                .frame(minHeight: 110)
                .focused($editorFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if !mentionSuggestions.isEmpty {
                mentionList
            }

            if !composer.attachments.isEmpty {
                attachmentChips(composer)
            }

            attachmentBar(composer)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if composer.isConnected(.bluesky) {
                        Toggle(isOn: $composer.postToBluesky) { accountRow(.bluesky, fallback: bluesky.session?.handle) }
                    }
                    if composer.isConnected(.mastodon) {
                        Toggle(isOn: $composer.postToMastodon) { accountRow(.mastodon, fallback: mastodon.session?.host) }
                    }
                }
                Spacer()
                Text("\(composer.characterCount)/\(composer.characterLimit)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(composer.isOverLimit ? .red : .secondary)
                    .accessibilityLabel("\(composer.characterCount) of \(composer.characterLimit) characters")
            }

            if !composer.failed.isEmpty {
                let names = composer.failed.keys.map { $0 == .bluesky ? "Bluesky" : "Mastodon" }.sorted().joined(separator: " and ")
                Label("Couldn't post to \(names). Anything that already posted won't be posted again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if composer.isPosting { ProgressView().controlSize(.small) }
                Button("Save Draft") { saveDraft() }
                    .disabled(!hasContent || composer.isPosting)
                Spacer()
                Button(composer.failed.isEmpty ? "Post" : "Retry") {
                    Task {
                        await composerStore.post()
                        if composerStore.didPostAll {
                            if let id = editingDraftID { draftStore.delete(id) } // posted → drop the draft
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!composer.canPost)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 460) // macOS composer width; iOS fills the sheet
        #endif
        .onAppear { editorFocused = true }
        .task { await load() }
    }

    // MARK: Drafts

    private func saveDraft() {
        let draft = Draft(id: editingDraftID ?? UUID(), text: composerStore.text,
                          attachments: composerStore.attachments,
                          postToBluesky: composerStore.postToBluesky, postToMastodon: composerStore.postToMastodon)
        draftStore.save(draft)
        composerStore.reset()
        editingDraftID = nil
        dismiss()
    }

    private func loadDraft(_ draft: Draft) {
        composerStore.text = draft.text
        composerStore.attachments = draft.attachments
        composerStore.postToBluesky = draft.postToBluesky
        composerStore.postToMastodon = draft.postToMastodon
        editingDraftID = draft.id
        showingDrafts = false
    }

    private var draftsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drafts").font(.headline)
            if draftStore.drafts.isEmpty {
                Text("No saved drafts.").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(draftStore.drafts) { draft in
                        HStack {
                            Button { loadDraft(draft) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(draft.preview).lineLimit(1)
                                    Text(draft.savedAt, format: .relative(presentation: .named))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) { draftStore.delete(draft.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Delete draft")
                        }
                    }
                }
                .listStyle(.inset)
                .frame(width: 300, height: 220)
            }
        }
        .padding(12)
    }

    // MARK: Attachments

    @ViewBuilder private func attachmentBar(_ composer: ComposerStore) -> some View {
        let full = composer.attachments.count >= ComposerStore.maxAttachments
        HStack(spacing: 12) {
            Menu {
                #if os(macOS)
                // File picker is NSOpenPanel (macOS); iOS uses the Photos library only.
                Button("Choose File…", systemImage: "folder") { pickPhotosFromFiles(composer) }
                #endif
                Button("Photo Library…", systemImage: "photo.stack") { showingLibrary = true }
            } label: {
                Image(systemName: "photo.on.rectangle")
            }
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Attach Photo")
            .disabled(full)
            .photosPicker(isPresented: $showingLibrary, selection: $pickerItems,
                          maxSelectionCount: ComposerStore.maxAttachments - composer.attachments.count, matching: .images)
            .onChange(of: pickerItems) { _, items in Task { await addLibraryPhotos(items, to: composer) } }

            Button { addingLink = true } label: { Image(systemName: "link") }
                .help("Attach Link")
                .popover(isPresented: $addingLink) { linkPopover(composer) }
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    private func addLibraryPhotos(_ items: [PhotosPickerItem], to composer: ComposerStore) async {
        for item in items {
            let room = ComposerStore.maxAttachments - composer.attachments.count
            guard room > 0 else { break }
            if let raw = try? await item.loadTransferable(type: Data.self),
               let image = PlatformImage(data: raw), let data = jpegData(from: image) {
                composer.attachments.append(Attachment(data: data))
            }
        }
        pickerItems = []
    }

    private func attachmentChips(_ composer: ComposerStore) -> some View {
        @Bindable var composer = composer
        return HStack(spacing: 8) {
            ForEach(Array(composer.attachments.enumerated()), id: \.element.id) { i, attachment in
                if let image = PlatformImage(data: attachment.data) {
                    AttachmentChip(image: image,
                                   alt: $composer.attachments[i].alt,
                                   onRemove: { composer.attachments.remove(at: i) })
                }
            }
        }
    }

    private func linkPopover(_ composer: ComposerStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attach a link").font(.headline)
            TextField("https://example.com", text: $linkText)
                .textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Spacer()
                Button("Add") {
                    let url = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !url.isEmpty {
                        composer.text += (composer.text.isEmpty || composer.text.hasSuffix(" ") ? "" : " ") + url
                    }
                    linkText = ""; addingLink = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    #if os(macOS)
    private func pickPhotosFromFiles(_ composer: ComposerStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let room = ComposerStore.maxAttachments - composer.attachments.count
        for url in panel.urls.prefix(room) {
            if let image = NSImage(contentsOf: url), let data = jpegData(from: image) {
                composer.attachments.append(Attachment(data: data))
            }
        }
    }
    #endif

    // MARK: @-mention autocomplete

    /// The trailing `@token` being typed at the end of the text (range + query), or nil.
    private var mention: (range: Range<String.Index>, query: String)? {
        let text = composerStore.text
        guard let at = text.lastIndex(of: "@") else { return nil }
        let after = text[text.index(after: at)...]
        guard !after.contains(where: { $0.isWhitespace }) else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        return (at..<text.endIndex, String(after))
    }

    private var mentionSuggestions: [SearchActor] {
        guard editorFocused, let query = mention?.query else { return [] }
        let q = query.lowercased()
        return following
            .filter { q.isEmpty || $0.handle.lowercased().contains(q) || $0.name.lowercased().contains(q) }
            .prefix(6).map { $0 }
    }

    private var mentionList: some View {
        VStack(spacing: 0) {
            ForEach(mentionSuggestions) { actor in
                Button { insertMention(actor) } label: {
                    HStack(spacing: 8) {
                        Avatar(url: actor.avatarURL, size: 24)
                        Text(actor.name).lineLimit(1)
                        Text("@\(actor.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        NetworkBadge(network: actor.network)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4).padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    private func insertMention(_ actor: SearchActor) {
        guard let mention else { return }
        composerStore.text.replaceSubrange(mention.range, with: "@\(actor.handle) ")
    }

    // MARK: Rows + loading

    private func accountRow(_ network: Network, fallback: String?) -> some View {
        let profile = accounts[network]
        return HStack(spacing: 8) {
            Avatar(url: profile?.avatarURL, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile?.name ?? (network == .bluesky ? "Bluesky" : "Mastodon"))
                    .fontWeight(.medium).lineLimit(1)
                Text(profile.map { "@\($0.handle)" } ?? (fallback.map { network == .bluesky ? "@\($0)" : $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func load() async {
        if let session = bluesky.session, accounts[.bluesky] == nil {
            accounts[.bluesky] = try? await BlueskyClient().profile(accessToken: session.accessJwt, actor: session.did)
        }
        if let session = mastodon.session, accounts[.mastodon] == nil {
            accounts[.mastodon] = try? await MastodonClient().currentAccount(host: session.host, accessToken: session.accessToken)
        }
        await loadFollowing()
    }

    private func loadFollowing() async {
        guard following.isEmpty else { return }
        var all: [SearchActor] = []
        if let session = bluesky.session {
            all += (try? await BlueskyClient().followList(accessToken: session.accessJwt, actor: session.did, kind: .following, limit: 100)) ?? []
        }
        if let session = mastodon.session, let id = accounts[.mastodon]?.authorID {
            all += (try? await MastodonClient().followList(host: session.host, accessToken: session.accessToken, accountID: id, kind: .following, limit: 100)) ?? []
        }
        following = all
    }
}

/// Attachment thumbnail with a remove button, an "ALT" badge, and a popover to enter the
/// image description. The badge fills in when alt is provided so the state is visible at a glance.
private struct AttachmentChip: View {
    let image: PlatformImage
    @Binding var alt: String
    let onRemove: () -> Void

    @State private var editing = false
    @State private var draft = ""

    private var hasAlt: Bool { !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Image(platformImage: image).resizable().scaledToFill()
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button { onRemove() } label: {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(2)
                .accessibilityLabel("Remove attachment")
            }
            .overlay(alignment: .bottomLeading) {
                Button {
                    draft = alt
                    editing = true
                } label: {
                    Text("ALT")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(hasAlt ? Color.accentColor : Color.black.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).padding(2)
                .accessibilityLabel(hasAlt ? "Edit image description" : "Add image description")
                .accessibilityValue(alt)
                .help(hasAlt ? "Edit image description" : "Add image description")
                .popover(isPresented: $editing, arrowEdge: .bottom) { altPopover }
            }
    }

    private var altPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe this image").font(.headline)
            Text("Screen readers read this description. Skip if the image is decorative.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .frame(width: 320, height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Image description")
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                Button("Save") {
                    alt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    editing = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }
}

/// Downscales an image and returns JPEG data under the size both networks accept (Bluesky caps
/// blobs at ~1 MB). ponytail: fixed 1600px / 0.8 quality; HEIC support pending.
private func jpegData(from image: PlatformImage, maxDimension: CGFloat = 1600, maxBytes: Int = 900_000) -> Data? {
    let size = image.size
    let scale = min(1, maxDimension / max(size.width, size.height))
    let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    #if os(macOS)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep else { return nil }
    rep.size = target
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= maxBytes {
            return data
        }
    }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.3])
    #else
    let scaled = UIGraphicsImageRenderer(size: target).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
    }
    for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
        if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
    }
    return scaled.jpegData(compressionQuality: 0.3)
    #endif
}
