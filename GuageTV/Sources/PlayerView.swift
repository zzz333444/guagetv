import AVFoundation
import AVKit
import SwiftUI

/// Playback page — dual engine:
///  - AVPlayer (native): HLS/MP4/MOV — hardware decode, best battery.
///  - mpv (FFmpegKit's libmpv): everything else — MKV/FLV/AVI/TS/WebM,
///    ASS subtitles, AV1 — the formats AVPlayer refuses.
/// Engine is picked by file extension; spider headers go to both.
struct PlayerView: View {
    let urlString: String
    var header: [String: String] = [:]
    var title: String = ""

    private static let mpvExtensions: Set<String> = [
        "mkv", "flv", "avi", "wmv", "rmvb", "ts", "mpg", "mpeg",
        "m2ts", "webm", "3gp", "asf", "vob", "f4v",
    ]

    var body: some View {
        if let url = URL(string: urlString) {
            if Self.mpvExtensions.contains(url.pathExtension.lowercased()) {
                MPVPlayerView(url: url, header: header)
            } else {
                NativePlayerView(url: url, header: header)
            }
        } else {
            ZStack {
                Theme.bg.ignoresSafeArea()
                Text("播放地址无效").foregroundStyle(.secondary)
            }
        }
    }
}

/// AVPlayer engine page.
struct NativePlayerView: View {
    let url: URL
    var header: [String: String] = [:]

    var body: some View {
        VideoPlayer(player: makePlayer())
            .ignoresSafeArea()
    }

    private func makePlayer() -> AVPlayer {
        // NOTE: the AVURLAssetHTTPHeaderFieldsKey constant is not exposed in
        // the iOS 26 SDK's Swift interface; its literal string value is the
        // documented key and works on every version.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": header
        ])
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}
