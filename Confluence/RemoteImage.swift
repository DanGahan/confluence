import SwiftUI
import OSLog

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
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // A non-2xx (e.g. 429 rate-limit during a scroll burst) returns an error-page
                // body, not an image — must retry, not decode it to nil and give up.
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                if let image = NSImage(data: data) { return image }
                throw URLError(.cannotDecodeContentData)
            } catch {
                // Exponential backoff with jitter, capped — so a scroll burst that 429s many
                // images at once doesn't retry them all in lockstep (thundering herd).
                if attempt < 2 {
                    let base = min(300 << attempt, 2000)          // 300, 600, … capped at 2000ms
                    let backoff = base + Int.random(in: 0...base / 2)
                    try? await Task.sleep(for: .milliseconds(backoff))
                }
            }
        }
        imageLog.error("image load failed after retries: \(url.host ?? "?", privacy: .public)")
        return nil
    }
}

private let imageLog = Logger(subsystem: "com.dangahan.confluence", category: "images")

/// Cached async image. Replaces AsyncImage, which on macOS cancels in-flight loads when a row
/// scrolls off and doesn't reliably retry. Cache hits render with no placeholder flash.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    private let contentMode: ContentMode
    private let placeholder: Placeholder
    @State private var image: NSImage?

    /// `.fill` (default) crops to the caller's frame; `.fit` shows the whole image at its
    /// natural aspect ratio (used by full-size media, #99).
    init(_ url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    var body: some View {
        content
            .contentShape(Rectangle()) // hit area = exactly this view's frame
            .task(id: url) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let image {
            if contentMode == .fit {
                // Whole image, natural aspect ratio; caller caps the height. scaledToFit never
                // overflows its frame, so the #69 hit-test spill doesn't apply here.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                // Contain the scaledToFill overflow: a bare Image renders (and hit-tests!)
                // beyond its frame — .clipShape hides the spill visually but the invisible
                // overflow still swallows clicks on whatever sits above/below (e.g. a link
                // on the last text line right above a post image, #69).
                Color.clear
                    .overlay(Image(nsImage: image).resizable().scaledToFill())
                    .clipped()
            }
        } else if contentMode == .fit {
            placeholder.aspectRatio(3.0 / 2.0, contentMode: .fit) // reserve rough space pre-load
        } else {
            placeholder
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let cached = ImageCache.shared.image(for: url) { image = cached; return }
        image = nil // placeholder while the first load runs
        let loaded = await ImageLoader.shared.image(for: url)
        if !Task.isCancelled { image = loaded }
    }
}
