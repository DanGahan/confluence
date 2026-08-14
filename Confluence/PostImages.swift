import SwiftUI

/// A post's images. Default: a fixed-height letterbox row (up to 4). With "Display Full Size
/// media" on (#99): each image at its natural aspect ratio, stacked vertically, scaled to the
/// column and capped in height so the whole image is visible without dominating.
struct PostImages: View {
    let urls: [URL]
    /// Letterbox height when full-size is off (feed 140, thread/profile 120).
    var letterboxHeight: CGFloat = 140
    /// Tapping an image opens the lightbox; nil = not tappable (e.g. thread view).
    var onTap: ((_ start: Int, _ images: [URL]) -> Void)? = nil

    @AppStorage(MediaPreference.fullSizeKey) private var fullSize = MediaPreference.fullSizeDefault

    var body: some View {
        let images = Array(urls.prefix(4))
        if fullSize {
            VStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.element) { i, url in
                    tappable(i, images) {
                        RemoteImage(url, contentMode: .fit) { Color.secondary.opacity(0.15) }
                            .frame(maxWidth: .infinity, maxHeight: MediaPreference.fullSizeMaxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        } else {
            // Non-scrolling row — a nested horizontal ScrollView steals the List's vertical
            // scroll gesture on macOS. Both networks cap posts at 4 images.
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.element) { i, url in
                    tappable(i, images) {
                        RemoteImage(url) { Color.secondary.opacity(0.15) }
                            .frame(maxWidth: .infinity).frame(height: letterboxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    @ViewBuilder private func tappable(_ i: Int, _ images: [URL], @ViewBuilder _ content: () -> some View) -> some View {
        if let onTap {
            Button { onTap(i, images) } label: { content() }
                .buttonStyle(.plain)
                // Was unlabelled — VoiceOver read nothing. Label it and note it opens the lightbox.
                .accessibilityLabel(images.count > 1 ? "Image \(i + 1) of \(images.count)" : "Image")
                .accessibilityHint("Opens full screen")
        } else {
            content()
        }
    }
}
