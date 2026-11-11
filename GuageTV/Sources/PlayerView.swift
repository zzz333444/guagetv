import AVFoundation
import AVKit
import SwiftUI
#if canImport(KSPlayerUI)
import KSPlayer
import KSPlayerUI
import MPVPlayer
#endif

/// Playback page — dual engine, mirroring how Rex is built:
///  - Engine 1: AVPlayer (native, hardware decode, best battery/HLS)
///  - Engine 2: mpv via KSPlayer's MPVPlayer module (FFmpeg + libass +
///    dav1d: MKV/FLV/ASS subtitles/AV1 and everything AVPlayer rejects)
/// KSPlayer's layer tries the first engine and falls back to the second
/// automatically; the user can also force an engine from DetailView later.
/// Spider-supplied headers are forwarded to whichever engine plays.
struct PlayerView: View {
    let urlString: String
    var header: [String: String] = [:]
    var title: String = ""

    var body: some View {
        if let url = URL(string: urlString) {
            #if canImport(KSPlayerUI)
            KSPlayerContainer(url: url, header: header, title: title)
                .ignoresSafeArea()
            #else
            NativePlayerView(url: url, header: header)
            #endif
        } else {
            ZStack {
                Theme.bg.ignoresSafeArea()
                Text("播放地址无效").foregroundStyle(.secondary)
            }
        }
    }
}

/// AVPlayer fallback (also the sole engine if the KSPlayer package is
/// ever removed).
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

#if canImport(KSPlayerUI)
/// UIKit bridge for KSPlayer's IOSVideoPlayerView.
struct KSPlayerContainer: UIViewRepresentable {
    let url: URL
    var header: [String: String] = [:]
    var title: String = ""

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        // mpv (FFmpeg) as the fallback engine behind AVPlayer.
        KSOptions.secondPlayerType = KSMPVPlayer.self
        let view = IOSVideoPlayerView()
        let options = KSOptions()
        if !header.isEmpty { options.appendHeader(header) }
        let definition = KSPlayerResourceDefinition(url: url, definition: "默认", options: options)
        let resource = KSPlayerResource(name: title, definitions: [definition])
        view.set(resource: resource)
        return view
    }

    func updateUIView(_ uiView: IOSVideoPlayerView, context: Context) {}
}
#endif
