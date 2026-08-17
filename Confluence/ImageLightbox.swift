import SwiftUI

/// A post's images plus which one was tapped — drives the lightbox sheet.
struct LightboxItem: Identifiable {
    let urls: [URL]
    let start: Int
    var id: String { urls.map(\.absoluteString).joined() + "#\(start)" }
}

/// Full-image viewer shown in a sheet. Click the background or the close button, or press
/// Escape, to dismiss; click the image (or the zoom controls) to zoom, then drag to pan.
/// Arrow keys / on-image chevrons page through a multi-image post.
struct ImageLightbox: View {
    let urls: [URL]
    @State private var index: Int
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1 // scale committed between pinch gestures
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    init(item: LightboxItem) {
        self.urls = item.urls
        _index = State(initialValue: item.start)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { dismiss() }

            AsyncImage(url: urls[index]) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().controlSize(.large)
            }
            .scaleEffect(scale)
            .offset(offset)
            .padding(24)
            .id(index)
            .onTapGesture { setScale(scale > minScale ? minScale : 2) }
            .gesture(dragOrSwipe)
            .simultaneousGesture(pinch)

            if urls.count > 1 {
                HStack {
                    pager(systemName: "chevron.left", to: index - 1)
                    Spacer()
                    pager(systemName: "chevron.right", to: index + 1)
                }
                .padding(.horizontal, 8)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 680)
        #endif
        .overlay(alignment: .topLeading) {
            SheetCloseButton { dismiss() }.padding(12)
        }
        .overlay(alignment: .bottom) { zoomControls }
        .onChange(of: index) { resetZoom() } // fresh image starts un-zoomed
    }

    private var zoomControls: some View {
        HStack(spacing: 18) {
            zoomButton("minus.magnifyingglass", label: "Zoom out") { setScale(scale / 1.5) }
                .disabled(scale <= minScale)
            zoomButton("plus.magnifyingglass", label: "Zoom in") { setScale(scale * 1.5) }
                .disabled(scale >= maxScale)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.black.opacity(0.4), in: Capsule())
        .padding(.bottom, 20)
    }

    private func zoomButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.title2).foregroundStyle(.white).padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Pinch to zoom (#195). `magnification` is relative to the gesture's start, so multiply the
    /// scale we had when it began.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = clampScale(steadyScale * v.magnification) }
            .onEnded { _ in
                steadyScale = scale
                if scale <= minScale { offset = .zero; lastOffset = .zero }
            }
    }

    /// Zoomed in → drag to pan. At 1× → a horizontal swipe pages between images (#194); a
    /// downward swipe isn't handled here so the sheet's own swipe-to-dismiss still works.
    private var dragOrSwipe: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > minScale else { return }
                offset = CGSize(width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height)
            }
            .onEnded { v in
                if scale > minScale { lastOffset = offset; return }
                guard urls.count > 1 else { return }
                let threshold: CGFloat = 50
                if v.translation.width <= -threshold { go(to: index + 1) }        // swipe left → next
                else if v.translation.width >= threshold { go(to: index - 1) }     // swipe right → prev
            }
    }

    private func go(to target: Int) {
        guard target >= 0, target < urls.count else { return }
        withAnimation { index = target }
    }

    private func clampScale(_ s: CGFloat) -> CGFloat { min(max(s, minScale), maxScale) }

    private func setScale(_ target: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = clampScale(target)
            steadyScale = scale
            if scale == minScale { offset = .zero; lastOffset = .zero } // recenter at 1×
        }
    }

    private func resetZoom() {
        scale = minScale; steadyScale = minScale; offset = .zero; lastOffset = .zero
    }

    @ViewBuilder private func pager(systemName: String, to target: Int) -> some View {
        Button { withAnimation { index = target } } label: {
            Image(systemName: systemName)
                .font(.title)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(target < 0 || target >= urls.count)
        .opacity(target < 0 || target >= urls.count ? 0.25 : 1)
        .keyboardShortcut(systemName == "chevron.left" ? .leftArrow : .rightArrow, modifiers: [])
    }
}
