import SwiftUI

/// In-memory image cache so a scrolled-off image resolves instantly when it returns.
/// NSCache is thread-safe, so this is shared between the loader actor and the views.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Downloads owned by the app, not by any view. A view awaiting a load can be cancelled when
/// its row scrolls off (SwiftUI cancels `.task`), but the download here keeps running and fills
/// the cache — so the image is ready the moment the row returns, instead of restarting and
/// getting cancelled again ("loads eventually", #42). Concurrent requests for the same URL
/// share one download.
actor ImageLoader {
    static let shared = ImageLoader()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = ImageCache.shared.image(for: url) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        // Unstructured Task: not a child of the caller, so caller cancellation (scroll-off)
        // doesn't cancel the download.
        let task = Task<NSImage?, Never> { await Self.download(url) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { ImageCache.shared.insert(image, for: url) }
        return image
    }

    private static func download(_ url: URL) async -> NSImage? {
        for attempt in 0..<3 {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return NSImage(data: data)
            } catch {
                // ponytail: fixed 3 tries w/ linear backoff; add jitter/cap if it ever matters.
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }
            }
        }
        return nil
    }
}

/// Cached async image. Replaces AsyncImage, which on macOS cancels in-flight loads when a row
/// scrolls off and doesn't reliably retry. Cache hits render with no placeholder flash.
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
        guard let url else { image = nil; return }
        if let cached = ImageCache.shared.image(for: url) { image = cached; return }
        image = nil // placeholder while the first load runs
        let loaded = await ImageLoader.shared.image(for: url)
        if !Task.isCancelled { image = loaded }
    }
}
