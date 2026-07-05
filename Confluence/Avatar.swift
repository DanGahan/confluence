import SwiftUI

/// A circular avatar with a person-glyph fallback for missing/failed images — e.g. bridged
/// accounts whose avatar 404s at the CDN — so it never shows as a blank grey disc.
struct Avatar: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        RemoteImage(url) {
            ZStack {
                Circle().fill(.quaternary)
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
