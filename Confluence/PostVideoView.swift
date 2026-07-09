import SwiftUI
import AVKit
import ConfluenceKit

/// A post video: poster thumbnail with a play affordance; tap plays inline with AVKit.
/// Handles Bluesky HLS playlists and Mastodon mp4/gifv — AVPlayer plays both natively.
struct PostVideoView: View {
    let video: PostVideo
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
            } else {
                Button { start() } label: {
                    RemoteImage(video.thumbnailURL) { Color.secondary.opacity(0.15) }
                        .overlay(
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement()
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays inline")
    }

    private func start() { player = AVPlayer(url: video.url) }
}
