import AVFoundation
import AVKit
import SwiftUI

/// Playback page — dual engine:
///  - AVPlayer (native): HLS/MP4/MOV — hardware decode, best battery.
///  - mpv (FFmpegKit's libmpv): everything else — MKV/FLV/AVI/TS/WebM,
///    ASS subtitles, AV1 — the formats AVPlayer refuses.
/// Engine is picked by file extension; the 播放设置 preference can force
/// one ("auto" / "native" / "mpv").
///
/// Chrome (v7): this page owns ALL controls — a top bar with close,
/// title and prev/next-episode, and (mpv) a full transport bar with
/// seek slider, ±step, and speed. The native engine keeps the system
/// transport UI and gets the same top bar.
struct PlayerView: View {
    struct EpisodeRef: Identifiable {
        let name: String
        let url: String
        var id: String { name + "|" + url }
    }

    let episodes: [EpisodeRef]
    var header: [String: String] = [:]
    var title: String = ""

    @State private var index: Int
    @StateObject private var mpv = MPVController()
    @State private var showChrome = true
    @State private var chromeGeneration = 0
    @Environment(\.dismiss) private var dismiss

    init(urlString: String, header: [String: String] = [:], title: String = "") {
        self.episodes = [EpisodeRef(name: "", url: urlString)]
        self.header = header
        self.title = title
        _index = State(initialValue: 0)
    }

    init(episodes: [EpisodeRef], startIndex: Int, header: [String: String] = [:], title: String = "") {
        self.episodes = episodes
        self.header = header
        self.title = title
        _index = State(initialValue: min(max(startIndex, 0), max(episodes.count - 1, 0)))
    }

    private static let mpvExtensions: Set<String> = [
        "mkv", "flv", "avi", "wmv", "rmvb", "ts", "mpg", "mpeg",
        "m2ts", "webm", "3gp", "asf", "vob", "f4v",
    ]

    private var current: EpisodeRef { episodes[min(index, episodes.count - 1)] }

    private var isMPV: Bool {
        switch UserDefaults.standard.string(forKey: "enginePreference") ?? "auto" {
        case "mpv": return true
        case "native": return false
        default:
            guard let url = URL(string: current.url) else { return false }
            return Self.mpvExtensions.contains(url.pathExtension.lowercased())
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            engineView
                .id(current.url)
            chromeTapStrip
            if showChrome { chrome }
        }
        .preferredColorScheme(.dark)
        .onAppear { scheduleChromeHide() }
        .onChange(of: index) { _ in
            showChrome = true
            scheduleChromeHide()
        }
    }

    @ViewBuilder
    private var engineView: some View {
        if let url = URL(string: current.url) {
            if isMPV {
                MPVPlayerView(url: url, header: header, controller: mpv)
            } else {
                NativePlayerView(url: url, header: header)
            }
        } else {
            Text("播放地址无效").foregroundStyle(.secondary)
        }
    }

    /// Invisible strip at the very top: tapping it brings the chrome back
    /// after it auto-hides, without stealing the engines' own gestures.
    private var chromeTapStrip: some View {
        VStack {
            Color.white.opacity(0.001)
                .frame(height: 46)
                .contentShape(Rectangle())
                .onTapGesture {
                    showChrome.toggle()
                    if showChrome { scheduleChromeHide() }
                }
            Spacer()
        }
    }

    private var chrome: some View {
        VStack {
            topBar
            Spacer()
            if isMPV { mpvTransport }
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.5), in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
                if !current.name.isEmpty {
                    Text(current.name).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer()
            if episodes.count > 1 {
                Button { index -= 1 } label: {
                    Image(systemName: "backward.end.fill")
                        .foregroundStyle(index > 0 ? .white : .white.opacity(0.3))
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(index <= 0)
                Button { index += 1 } label: {
                    Image(systemName: "forward.end.fill")
                        .foregroundStyle(index < episodes.count - 1 ? .white : .white.opacity(0.3))
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(index >= episodes.count - 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var mpvTransport: some View {
        let step = Double(UserDefaults.standard.object(forKey: "seekStep") as? Int ?? 15)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(timeLabel(mpv.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                Slider(
                    value: Binding(
                        get: { mpv.currentTime },
                        set: { mpv.currentTime = $0 }
                    ),
                    in: 0...max(mpv.duration, 1),
                    onEditingChanged: { editing in
                        if !editing { mpv.seek(to: mpv.currentTime) }
                        pokeChrome()
                    }
                )
                .tint(.white)
                Text(timeLabel(mpv.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            HStack(spacing: 22) {
                Button { mpv.seekRelative(-step); pokeChrome() } label: {
                    Image(systemName: "gobackward.\(Int(step))")
                        .font(.title3).foregroundStyle(.white)
                }
                Button { mpv.togglePlay(); pokeChrome() } label: {
                    Image(systemName: mpv.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle).foregroundStyle(.white)
                }
                Button { mpv.seekRelative(step); pokeChrome() } label: {
                    Image(systemName: "goforward.\(Int(step))")
                        .font(.title3).foregroundStyle(.white)
                }
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate, specifier: "%.2g")x") { mpv.setSpeed(rate); pokeChrome() }
                    }
                } label: {
                    Text("\(mpv.speed, specifier: "%.2g")x")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.45))
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func scheduleChromeHide() {
        chromeGeneration += 1
        let gen = chromeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if gen == chromeGeneration { withAnimation { showChrome = false } }
        }
    }

    private func pokeChrome() {
        showChrome = true
        scheduleChromeHide()
    }
}

/// AVPlayer engine page. The player is created once per URL (stored in
/// @State) — recreating it in body would restart playback on every
/// state change.
struct NativePlayerView: View {
    let url: URL
    var header: [String: String] = [:]
    @State private var player: AVPlayer

    init(url: URL, header: [String: String] = [:]) {
        self.url = url
        self.header = header
        // NOTE: the AVURLAssetHTTPHeaderFieldsKey constant is not exposed in
        // the iOS 26 SDK's Swift interface; its literal string value is the
        // documented key and works on every version.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": header
        ])
        _player = State(initialValue: AVPlayer(playerItem: AVPlayerItem(asset: asset)))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }
}
