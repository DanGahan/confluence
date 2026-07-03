import SwiftUI

/// AsyncImage wrapper using the phase-based initializer. The `content:placeholder:`
/// initializer can get stuck on its placeholder inside a LazyVStack on macOS (see #28);
/// the phase-based form renders reliably.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    private let placeholder: Placeholder

    init(_ url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                placeholder
            }
        }
    }
}
