import AVFoundation
import AVKit
import SwiftUI

/// Playback page. AVPlayer handles HLS (.m3u8) and mp4 natively.
/// `header` comes from the spider's playerContent result; AVURLAsset applies
/// it via AVURLAssetHTTPHeaderFieldsKey.
struct PlayerView: View {
    let urlString: String
    var header: [String: String] = [:]

    var body: some View {
        if let url = URL(string: urlString) {
            VideoPlayer(player: makePlayer(url: url))
                .ignoresSafeArea()
        } else {
            Text("播放地址无效").foregroundStyle(.secondary)
        }
    }

    private func makePlayer(url: URL) -> AVPlayer {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetHTTPHeaderFieldsKey: header
        ])
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}
