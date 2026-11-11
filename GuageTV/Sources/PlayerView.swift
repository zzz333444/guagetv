import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Playback page — dual engine under ONE custom chrome (v8, modelled on
/// the reference layout the user picked):
///  - top-left: close + [rotate, lock] pill; top-right: [screenshot,
///    AirPlay] pill; left edge: brightness slider
///  - bottom: title/episode block, thin seek bar with a round knob,
///    [play/pause + time pill] … [episode list, more] pill
///  - single tap toggles chrome, double tap left/right seeks ∓step
/// Engines: AVPlayer via AVPlayerLayer (HLS/MP4 — hardware decode) or
/// libmpv (MKV/FLV/TS/… — FFmpeg). Engine by extension, forceable in
/// 播放设置 or per-session from the ••• menu.
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
    @StateObject private var native = NativeController()
    @State private var engineOverride: Bool?
    @State private var showChrome = true
    @State private var chromeGeneration = 0
    @State private var showEpisodes = false
    @State private var rotationLocked = false
    @State private var toast: String?
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
        if let engineOverride { return engineOverride }
        switch UserDefaults.standard.string(forKey: "enginePreference") ?? "auto" {
        case "mpv": return true
        case "native": return false
        default:
            guard let url = URL(string: current.url) else { return false }
            return Self.mpvExtensions.contains(url.pathExtension.lowercased())
        }
    }

    private var isPlaying: Bool { isMPV ? mpv.isPlaying : native.isPlaying }
    private var currentTime: Double { isMPV ? mpv.currentTime : native.currentTime }
    private var duration: Double { isMPV ? mpv.duration : native.duration }
    private var seekStep: Double { Double(UserDefaults.standard.object(forKey: "seekStep") as? Int ?? 15) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                engineLayer
                    .id(current.url + (isMPV ? "#mpv" : "#av"))
                tapZones
                if showChrome {
                    chrome(isLandscape: geo.size.width > geo.size.height)
                }
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.black.opacity(0.7), in: Capsule())
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { scheduleChromeHide() }
        .onChange(of: index) { _ in pokeChrome() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
    }

    // MARK: engine layers

    @ViewBuilder
    private var engineLayer: some View {
        if let url = URL(string: current.url) {
            if isMPV {
                MPVPlayerView(url: url, header: header, controller: mpv)
            } else {
                AVPlayerLayerView(player: native.player)
                    .ignoresSafeArea()
                    .onAppear { native.load(url: url, header: header) }
                    .onDisappear { native.pause() }
            }
        } else {
            Text("播放地址无效").foregroundStyle(.secondary)
        }
    }

    // MARK: gestures

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { seekBy(-seekStep) }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { seekBy(seekStep) }
        }
        .onTapGesture {
            withAnimation { showChrome.toggle() }
            if showChrome { scheduleChromeHide() }
        }
    }

    // MARK: chrome

    private func chrome(isLandscape: Bool) -> some View {
        VStack {
            topBar(isLandscape: isLandscape)
            Spacer()
            bottomBar
        }
        .overlay(alignment: .leading) { BrightnessRail().padding(.leading, 10) }
        .transition(.opacity)
    }

    private func topBar(isLandscape: Bool) -> some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            HStack(spacing: 2) {
                Button { if !rotationLocked { rotate(toLandscape: !isLandscape) } } label: {
                    Image(systemName: "rotate.right")
                        .foregroundStyle(rotationLocked ? .white.opacity(0.35) : .white)
                        .frame(width: 40, height: 40)
                }
                Button { rotationLocked.toggle(); pokeChrome() } label: {
                    Image(systemName: rotationLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
            }
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            HStack(spacing: 2) {
                Button { saveSnapshot() } label: {
                    Image(systemName: "camera")
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                if !isMPV {
                    RoutePickerView()
                        .frame(width: 40, height: 40)
                }
            }
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty || !current.name.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    if !current.name.isEmpty {
                        Text(current.name).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
            }
            SeekBar(value: currentTime, duration: duration) { seconds in
                seek(to: seconds)
            }
            HStack(spacing: 12) {
                Button { togglePlay(); pokeChrome() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Text("\(timeLabel(currentTime)) / \(timeLabel(duration))")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                HStack(spacing: 2) {
                    if episodes.count > 1 {
                        Button { showEpisodes = true } label: {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                        }
                    }
                    Menu {
                        Section("倍速") {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                                Button {
                                    setRate(rate); pokeChrome()
                                } label: {
                                    if rate == currentRate { Label("\(rate, specifier: "%.2g")x", systemImage: "checkmark") }
                                    else { Text("\(rate, specifier: "%.2g")x") }
                                }
                            }
                        }
                        Section {
                            Button { seekBy(-seekStep) } label: { Label("快退 \(Int(seekStep)) 秒", systemImage: "gobackward") }
                            Button { seekBy(seekStep) } label: { Label("快进 \(Int(seekStep)) 秒", systemImage: "goforward") }
                            Button { engineOverride = !isMPV; pokeChrome() } label: {
                                Label(isMPV ? "切换到原生引擎" : "切换到 FFmpeg 引擎", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                    }
                }
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var episodeSheet: some View {
        NavigationStack {
            List {
                ForEach(episodes.indices, id: \.self) { i in
                    Button {
                        index = i
                        showEpisodes = false
                    } label: {
                        HStack {
                            Text(episodes[i].name.isEmpty ? "第\(i + 1)集" : episodes[i].name)
                                .foregroundStyle(.white)
                            Spacer()
                            if i == index { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showEpisodes = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: transport plumbing

    private var currentRate: Double { isMPV ? mpv.speed : Double(native.rate) }

    private func togglePlay() { isMPV ? mpv.togglePlay() : native.toggle() }
    private func seek(to seconds: Double) { isMPV ? mpv.seek(to: seconds) : native.seek(to: seconds) }
    private func seekBy(_ delta: Double) { isMPV ? mpv.seekRelative(delta) : native.seekRelative(delta) }
    private func setRate(_ rate: Double) {
        if isMPV { mpv.setSpeed(rate) } else { native.setRate(Float(rate)) }
    }

    private func rotate(toLandscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let prefs = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: toLandscape ? .landscapeRight : .portrait)
        scene.requestGeometryUpdate(prefs)
        UIViewController.attemptRotationToDeviceOrientation()
        pokeChrome()
    }

    private func saveSnapshot() {
        let image: UIImage?
        if isMPV {
            image = mpv.snapshot().map { UIImage(cgImage: $0) }
        } else {
            image = native.snapshot()
        }
        if let image {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            showToast("截图已存相册")
        } else {
            showToast("截图失败")
        }
        pokeChrome()
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { toast = nil }
        }
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

// MARK: - Native engine controller

final class NativeController: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0
    private var timeObserver: Any?
    private var loadedURL: URL?

    func load(url: URL, header: [String: String]) {
        if loadedURL == url, player.currentItem != nil {
            player.play()
            return
        }
        loadedURL = url
        // Literal key: the AVURLAssetHTTPHeaderFieldsKey constant is not
        // exposed in the iOS 26 SDK's Swift interface.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": header])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
        player.play()
    }

    func pause() { player.pause() }

    func toggle() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.rate = rate
        }
        isPlaying = player.timeControlStatus == .playing
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekRelative(_ delta: Double) {
        seek(to: max(0, currentTime + delta))
    }

    func setRate(_ value: Float) {
        rate = value
        if player.timeControlStatus == .playing { player.rate = value }
    }

    func snapshot() -> UIImage? {
        guard let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        guard let cg = try? generator.copyCGImage(at: player.currentTime(), actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - AVPlayerLayer host

private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Seek bar (thin track, big knob — reference layout)

private struct SeekBar: View {
    let value: Double
    let duration: Double
    var onCommit: (Double) -> Void
    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(max(value / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 3)
                Capsule().fill(Color.white).frame(width: geo.size.width * fraction, height: 3)
                Circle().fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * fraction - 7)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragFraction = min(max(drag.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { drag in
                        let f = min(max(drag.location.x / geo.size.width, 0), 1)
                        dragFraction = nil
                        if duration > 0 { onCommit(f * duration) }
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Brightness rail (left edge — reference layout)

private struct BrightnessRail: View {
    @State private var level: Double = Double(UIScreen.main.brightness)

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(height: max(8, 110 * level))
            }
            .frame(width: 5, height: 110)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let f = 1 - min(max(drag.location.y / 130, 0), 1)
                    level = 0.1 + 0.9 * f
                    UIScreen.main.brightness = CGFloat(level)
                }
        )
    }
}
