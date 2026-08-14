import SwiftUI
import ConfluenceKit

/// A tappable preview for a post's shared link (Bluesky external embed). Opens the link in the
/// browser via the openURL environment. Renders thumb + title + description + host.
struct LinkCardView: View {
    let card: LinkCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(card.url) } label: {
            HStack(spacing: 10) {
                if let thumb = card.thumbURL {
                    RemoteImage(thumb) { Color.secondary.opacity(0.15) }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.callout).fontWeight(.semibold).lineLimit(2)
                    if !card.description.isEmpty {
                        Text(card.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(card.url.host ?? card.url.absoluteString)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(.link) // pointing hand: the card behaves like a link (macOS pointer API)
        #endif
        .accessibilityLabel("Link: \(card.title), \(card.url.host ?? "")")
    }
}
