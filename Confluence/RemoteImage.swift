import SwiftUI

/// In-memory image cache so a scrolled-off image resolves instantly when it returns.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Cached async image. Replaces AsyncImage, which on macOS cancels in-flight loads when a
/// row scrolls off and doesn't reliably retry — leaving sporadic blank images (#30).
/// This reloads on reappear via `.task(id:)`; the cache makes that instant after first load.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    private let placeholder: Placeholder
    @State private var image: NSImage?

    init(_ url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        // Two attempts: a scrolled-away load may be cancelled mid-flight; retry on return.
        for attempt in 0..<2 {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                if let loaded = NSImage(data: data) {
                    ImageCache.shared.insert(loaded, for: url)
                    image = loaded
                    return
                }
                return // decoded to nil — a real bad image, don't retry
            } catch {
                if Task.isCancelled { return }
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            }
        }
    }
}
