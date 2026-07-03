import SwiftUI

/// A post's images plus which one was tapped — drives the lightbox sheet.
struct LightboxItem: Identifiable {
    let urls: [URL]
    let start: Int
    var id: String { urls.map(\.absoluteString).joined() + "#\(start)" }
}

/// Full-image viewer shown in a sheet. Click the image or the close button, or press Escape,
/// to dismiss. Arrow keys / on-image chevrons page through a multi-image post.
struct ImageLightbox: View {
    let urls: [URL]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

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
            .padding(24)
            .id(index)

            if urls.count > 1 {
                HStack {
                    pager(systemName: "chevron.left", to: index - 1)
                    Spacer()
                    pager(systemName: "chevron.right", to: index + 1)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 680)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(12)
            .keyboardShortcut(.cancelAction)
        }
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
