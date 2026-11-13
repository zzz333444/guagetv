import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Playback page — dual engine under ONE custom chrome (v8, modelled on
/// the reference layout the user picked):
///  - top-left: close + [rotate, lock] pill; top-right: [aspect,
///    screenshot, PiP/AirPlay] pill
///  - bottom: title/episode block, thin seek bar with a round knob,
///    [play/pause + time pill] … [episode list, rate, more] pill
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
    var pic: String = ""
    var header: [String: String] = [:]
    var title: String = ""
    /// When set, playback reports its position to HistoryStore and
    /// resumes at resumeAt once the duration is known.
    var historyID: String?
    var resumeAt: Double = 0

    @State private var index: Int
    @StateObject private var mpv = MPVController()
    @StateObject private var native = NativeController()
    @State private var engineOverride: Bool?
    @State private var showChrome = true
    @State private var chromeGeneration = 0
    @State private var showEpisodes = false
    @State private var showPlayerSettings = false
    /// Screen brightness captured when the player's own
    /// brightness setting （设置 → 音画 → 单独调整播放亮度） takes
    /// over, restored verbatim when the player closes.
    @State private var brightnessBeforePlay: CGFloat?
    @State private var rotationLocked = false
    /// Device battery for the status strip (Rex shows it next to
    /// the net speed). -1 = unknown. Refreshed on appear and by
    /// the 5-second progress loop.
    @State private var batteryLevel: Float = -1
    @State private var toast: String?
    @State private var dragMode: DragMode?
    @State private var dragStartTime: Double = 0
    @State private var dragStartLevel: Double = 0
    @State private var dragLevel: Double = 0
    @State private var scrubTarget: Double = 0
    @State private var hudVisible = false
    @State private var previewImage: UIImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var lastPreviewTarget: Double = -10
    @State private var showRemaining = false
    @State private var didResume = false
    @State private var hudGeneration = 0
    /// Where a freshly (re)built engine should land: set on engine
    /// switches and failure recovery so playback continues at the
    /// same position instead of restarting from zero.
    @State private var pendingStart: Double?
    /// Failure recovery ladder: 0 = rebuild same engine, 1 = switch
    /// engine, 2 = surface the error. Reset by progress / episode
    /// change / manual engine switch.
    @State private var recoveryStep = 0
    @State private var lastFailureAt: Date?
    @State private var boostActive = false
    @State private var rateBeforeBoost: Double = 1
    @State private var toastGeneration = 0
    /// Stall watchdog state (see watchdogTick).
    @State private var stallTicks = 0
    @State private var lastWatchTime: Double = -1

    private enum DragMode { case scrub, brightness, volume }
    @Environment(\.dismiss) private var dismiss

    init(urlString: String, header: [String: String] = [:], title: String = "") {
        self.episodes = [EpisodeRef(name: "", url: urlString)]
        self.header = header
        self.title = title
        _index = State(initialValue: 0)
    }

    init(episodes: [EpisodeRef], startIndex: Int, header: [String: String] = [:], title: String = "",
         historyID: String? = nil, resumeAt: Double = 0, pic: String = "") {
        self.episodes = episodes
        self.header = header
        self.title = title
        self.historyID = historyID
        self.resumeAt = resumeAt
        self.pic = pic
        _index = State(initialValue: min(max(startIndex, 0), max(episodes.count - 1, 0)))
    }

    /// Engine heuristic (auto mode): the HLS/MP4 family stays on
    /// the native engine (Dolby Vision / HDR + battery), every
    /// other container goes to mpv, and extension-less URLs (proxy
    /// play links) default native — the recovery ladder switches
    /// engines if the first pick can't play.
    private static let nativeExtensions: Set<String> = ["m3u8", "mp4", "mov", "m4v"]

    private static let mpvExtensions: Set<String> = [
        "mkv", "flv", "avi", "wmv", "rmvb", "rm", "ts", "mpg", "mpeg",
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
            let ext = url.pathExtension.lowercased()
            if Self.nativeExtensions.contains(ext) { return false }
            return Self.mpvExtensions.contains(ext)
        }
    }

    private var isPlaying: Bool { isMPV ? mpv.isPlaying : native.isPlaying }
    private var isBuffering: Bool { isMPV ? mpv.isBuffering : native.isBuffering }
    private var netSpeedBytes: Double { isMPV ? mpv.netSpeedBytes : native.netSpeedBytes }
    private var specText: String { isMPV ? mpv.specText : native.specText }
    @AppStorage("skipIntroSeconds") private var skipIntroSeconds = 0
    @AppStorage("skipOutroSeconds") private var skipOutroSeconds = 0
    /// Player feature switches (设置 → 播放 writes these; default on).
    @AppStorage("player.showSpeed") private var showSpeedPill = true
    @AppStorage("player.showResolution") private var showResolutionPill = true
    @AppStorage("player.showPiPButton") private var showPiPButton = true
    @AppStorage("player.showAirPlayButton") private var showAirPlayButton = true
    @AppStorage("player.showEpisodeButton") private var showEpisodeButton = true
    @AppStorage("player.longPressBoost") private var longPressBoostEnabled = true
    @AppStorage("player.autoNext") private var autoNextEnabled = true
    /// Second wave of button switches (v1.35): every small chrome
    /// button gets its own toggle in 设置 → 播放.
    @AppStorage("player.showClock") private var showClock = true
    @AppStorage("player.showScreenshot") private var showScreenshotButton = true
    @AppStorage("player.showGravity") private var showGravityButton = true
    @AppStorage("player.showRate") private var showRateButton = true
    @AppStorage("player.showEpisodeSwitch") private var showEpisodeSwitch = true
    /// Same key 设置 → 音画 writes; the in-player settings sheet
    /// offers it too (mpv applies it on the next load).
    @AppStorage("videoGravity") private var videoGravity = "aspect"
    @State private var didSkipIntro = false
    private var currentTime: Double { isMPV ? mpv.currentTime : native.currentTime }
    private var duration: Double { isMPV ? mpv.duration : native.duration }
    private var seekStep: Double { Double(UserDefaults.standard.object(forKey: "seekStep") as? Int ?? 15) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                engineLayer
                    .id(current.url + (isMPV ? "#mpv" : "#av"))
                gestureLayer(size: geo.size)
                VolumeHost()
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                if hudVisible, dragMode == .scrub {
                    VStack { scrubPill; Spacer() }
                } else if hudVisible {
                    hud
                }
                if isBuffering {
                    bufferingDots
                } else if !isPlaying && duration > 0 {
                    // Paused: one big plain play glyph in the centre
                    // (reference-player style — no glass, no card).
                    Button { togglePlay() } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 54, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 10)
                            .frame(width: 96, height: 96)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if showChrome {
                    chrome(isLandscape: geo.size.width > geo.size.height)
                }
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.black.opacity(0.7), in: Capsule())
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if UserDefaults.standard.bool(forKey: "player.keepBrightness") {
                brightnessBeforePlay = UIScreen.main.brightness
                let saved = UserDefaults.standard.object(forKey: "player.brightness") as? Double
                UIScreen.main.brightness = CGFloat(saved ?? Double(UIScreen.main.brightness))
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            mpv.onFailure = { handlePlaybackFailure($0) }
            mpv.onEnded = { advanceToNext() }
            native.onFailure = { handlePlaybackFailure($0) }
            native.onEnded = { advanceToNext() }
            scheduleChromeHide()
        }
        .onChange(of: duration) { _ in
            applyPendingStartIfNeeded()
            applyResumeIfNeeded()
            applyIntroSkipIfNeeded()
        }
        .onChange(of: currentTime) { _ in
            if currentTime > 3, recoveryStep != 0 { recoveryStep = 0 }
            checkOutroSkip()
        }
        .task { await saveProgressLoop() }
        .onDisappear {
            saveProgress(accumulate: false)
            if let brightnessBeforePlay {
                UIScreen.main.brightness = brightnessBeforePlay
            }
            brightnessBeforePlay = nil
        }
        .onChange(of: index) { _ in
            didSkipIntro = false
            pendingStart = nil
            recoveryStep = 0
            stallTicks = 0
            pokeChrome()
        }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showPlayerSettings) { playerSettingsSheet }
    }

    // MARK: engine layers

    @ViewBuilder
    private var engineLayer: some View {
        if let url = URL(string: current.url) {
            if isMPV {
                MPVPlayerView(url: url, header: header,
                              startAt: pendingStart ?? resumeAt, controller: mpv)
            } else {
                AVPlayerLayerView(player: native.player,
                                  onLayer: { native.setupPiP(layer: $0) })
                    .ignoresSafeArea()
                    .onAppear { native.load(url: url, header: header) }
                    .onDisappear { native.pause() }
            }
        } else {
            Text("播放地址无效").foregroundStyle(.secondary)
        }
    }

    // MARK: gestures

    private func gestureLayer(size: CGSize) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { seekBy(-seekStep); showSeekToast(delta: -seekStep) }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { seekBy(seekStep); showSeekToast(delta: seekStep) }
        }
        .onTapGesture {
            withAnimation { showChrome.toggle() }
            if showChrome { scheduleChromeHide() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in handleDrag(value, size: size) }
                .onEnded { _ in endDrag() }
        )
        // Hold to fast-forward (mainstream player behaviour): a
        // deliberate 2-second hold anywhere boosts to 2x until
        // release. The threshold is long on purpose — the drag
        // gesture needs real movement, a hold stays put — so a
        // scrub never trips the boost by accident; handleDrag also
        // stands down while boosting. Engagement happens in
        // `perform` (fires only once the full 2 s has elapsed);
        // `pressing` only watches for the release edge.
        .onLongPressGesture(minimumDuration: 2.0, maximumDistance: 12, pressing: { isPressing in
            if !isPressing { releaseBoost() }
        }) {
            engageBoost()
        }
    }

    private func engageBoost() {
        guard longPressBoostEnabled, !boostActive, isPlaying else { return }
        boostActive = true
        rateBeforeBoost = currentRate
        setRate(2.0)
        showToast("2 倍速播放中，松开恢复")
    }

    private func releaseBoost() {
        guard boostActive else { return }
        boostActive = false
        setRate(rateBeforeBoost)
    }

    /// One drag, three jobs (mainstream player behaviour): horizontal
    /// scrubs, vertical on the left half is brightness, on the right
    /// half volume. Direction locks on first clear movement; a HUD
    /// shows the value only while adjusting — nothing stays on screen.
    private func handleDrag(_ value: DragGesture.Value, size: CGSize) {
        if boostActive { return }
        let dx = value.translation.width
        let dy = value.translation.height
        if dragMode == nil {
            guard abs(dx) > 10 || abs(dy) > 10 else { return }
            if abs(dx) > abs(dy) {
                dragMode = .scrub
                dragStartTime = currentTime
                scrubTarget = currentTime
            } else if value.startLocation.x < size.width / 2 {
                dragMode = .brightness
                dragStartLevel = Double(UIScreen.main.brightness)
                dragLevel = dragStartLevel
            } else {
                dragMode = .volume
                dragStartLevel = VolumeControl.current()
                dragLevel = dragStartLevel
            }
            hudGeneration += 1
            withAnimation { hudVisible = true }
        }
        switch dragMode {
        case .scrub:
            guard duration > 0 else { return }
            let delta = Double(dx) / Double(size.width) * duration
            scrubTarget = min(max(dragStartTime + delta, 0), duration)
            requestPreview(at: scrubTarget)
        case .brightness:
            let level = min(max(dragStartLevel - Double(dy) / 220, 0.05), 1)
            dragLevel = level
            UIScreen.main.brightness = CGFloat(level)
        case .volume:
            let level = min(max(dragStartLevel - Double(dy) / 220, 0), 1)
            dragLevel = level
            VolumeControl.set(level)
        case .none:
            break
        }
    }

    private func endDrag() {
        if dragMode == .scrub, duration > 0 { seek(to: scrubTarget) }
        clearPreview()
        dragMode = nil
        hudGeneration += 1
        let gen = hudGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if gen == hudGeneration { withAnimation { hudVisible = false } }
        }
    }

    /// Scrub feedback, modelled on the reference the user sent:
    /// a floating pill at the top centre — target / total on the
    /// first line, the signed offset from where the drag started
    /// on the second. No thumbnail, no icon.
    private var scrubPill: some View {
        VStack(spacing: 2) {
            Text("\(timeLabel(scrubTarget)) / \(timeLabel(duration))")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(deltaLabel)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.text.opacity(0.75))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color(white: 0.16).opacity(0.88), in: Capsule())
        .padding(.top, 12)
    }

    private var deltaLabel: String {
        let delta = Int(scrubTarget - dragStartTime)
        return (delta >= 0 ? "+" : "-") + timeLabel(Double(abs(delta)))
    }

    @ViewBuilder
    private var hud: some View {
        VStack(spacing: 8) {
            switch dragMode {
            case .scrub:
                EmptyView()
            case .brightness:
                hudBar(icon: "sun.max.fill", level: dragLevel)
            case .volume:
                hudBar(icon: dragLevel == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", level: dragLevel)
            case .none:
                EmptyView()
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    private func hudBar(icon: String, level: Double) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title3)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 110, height: 4)
                Capsule().fill(Color.white).frame(width: 110 * level, height: 4)
            }
            Text("\(Int(level * 100))%")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
    }

    // MARK: chrome

    private func chrome(isLandscape: Bool) -> some View {
        VStack(spacing: 2) {
            statusStrip
            topBar(isLandscape: isLandscape)
            Spacer()
            bottomBar
        }
        .transition(.opacity)
    }

    /// Reference-player (Rex) status strip: plain white text and
    /// glyphs straight on the picture — clock at the far left,
    /// resolution / net speed / battery at the far right. No glass.
    private var statusStrip: some View {
        HStack(spacing: 10) {
            if showClock { clockText }
            Spacer()
            if showResolutionPill, !specText.isEmpty {
                Text(specText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if showSpeedPill {
                Text(Self.formatSpeed(netSpeedBytes))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Image(systemName: batterySymbol)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private var batterySymbol: String {
        guard batteryLevel >= 0 else { return "battery.100" }
        switch batteryLevel {
        case 0.875...: return "battery.100"
        case 0.625...: return "battery.75"
        case 0.375...: return "battery.50"
        case 0.125...: return "battery.25"
        default: return "battery.0"
        }
    }

    /// Title row in the reference layout: plain ✕ + "剧名 第N集" on
    /// the left, a row of plain white function icons on the right
    /// （画面适配 / 截图 / 选集 / 画中画 / 投屏 / 播放设置）. Rotation
    /// and its lock moved into the settings sheet — the reference
    /// chrome carries neither.
    private func topBar(isLandscape: Bool) -> some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            Text(titleLine)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 20) {
                if showGravityButton {
                    Button { toggleGravity(); pokeChrome() } label: {
                        topIcon("aspectratio")
                    }
                    .buttonStyle(.plain)
                }
                if showScreenshotButton {
                    Button { saveSnapshot() } label: {
                        topIcon("camera")
                    }
                    .buttonStyle(.plain)
                }
                if showEpisodeButton, episodes.count > 1 {
                    Button { showEpisodes = true; pokeChrome() } label: {
                        topIcon("clapperboard")
                    }
                    .buttonStyle(.plain)
                }
                if !isMPV {
                    if showPiPButton, AVPictureInPictureController.isPictureInPictureSupported() {
                        Button { native.togglePiP() } label: {
                            topIcon(native.isPiPActive ? "pip.exit" : "pip.enter")
                        }
                        .buttonStyle(.plain)
                    }
                    if showAirPlayButton {
                        RoutePickerView()
                            .frame(width: 30, height: 30)
                    }
                }
                Button { showPlayerSettings = true; pokeChrome() } label: {
                    topIcon("ellipsis")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
    }

    private func topIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
    }

    private var titleLine: String {
        if title.isEmpty { return current.name }
        if current.name.isEmpty || current.name == title { return title }
        return "\(title) \(current.name)"
    }

    /// Bottom chrome in the reference layout: elapsed time at the
    /// far left of the seek row, total at the far right (tap it to
    /// flip to remaining), then a control row — transport icons
    /// bottom-left, plain-text buttons bottom-right （引擎 / 选集 /
    /// 倍速， where the reference shows 原画 / 选集 / 倍速）.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(timeLabel(currentTime))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                SeekBar(value: currentTime, duration: duration,
                        preview: previewImage,
                        onDrag: { requestPreview(at: $0) }) { seconds in
                    seek(to: seconds)
                    clearPreview()
                }
                Text(showRemaining
                     ? "-\(timeLabel(max(duration - currentTime, 0)))"
                     : timeLabel(duration))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .onTapGesture { showRemaining.toggle(); pokeChrome() }
            }
            HStack(spacing: 24) {
                Button { togglePlay(); pokeChrome() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                // Episode stepping sits bottom-left in the
                // reference layout. Shown whenever the title has
                // episodes at all (v1.36 behaviour kept); the
                // arrows dim at the bounds.
                if showEpisodeSwitch, !episodes.isEmpty {
                    Button { prevEpisode(); pokeChrome() } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(index > 0 ? .white : .white.opacity(0.35))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    Button { nextEpisode(); pokeChrome() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(index < episodes.count - 1 ? .white : .white.opacity(0.35))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { switchEngine(manual: true); pokeChrome() } label: {
                    Text(isMPV ? "MPV" : "原生")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if showEpisodeButton, episodes.count > 1 {
                    Button { showEpisodes = true; pokeChrome() } label: {
                        Text("选集")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                if showRateButton {
                    Button { cycleRate(); pokeChrome() } label: {
                        Text(currentRate == 1 ? "倍速" : "倍速 \(String(format: "%.2g", currentRate))")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Current wall-clock time — far left of the status strip in
    /// the reference layout, plain text, no capsule. TimelineView
    /// re-renders it on a slow tick.
    private var clockText: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            Text(Self.clockFormatter.string(from: context.date))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    /// Buffering indicator in the reference style: three white
    /// dots cycling in the centre of the picture — no card, no
    /// caption. The phase derives from the timeline clock so it
    /// animates without any state of its own.
    private var bufferingDots: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .opacity(i == phase ? 1 : 0.25)
                }
            }
        }
    }

    static func codecName(_ subType: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((subType >> 24) & 0xff), UInt8((subType >> 16) & 0xff),
                              UInt8((subType >> 8) & 0xff), UInt8(subType & 0xff)]
        let code = String(bytes: bytes, encoding: .ascii) ?? ""
        switch code {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "H.265"
        case "vp09": return "VP9"
        case "av01": return "AV1"
        case "mp4v": return "MPEG-4"
        default: return code
        }
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB/s" }
        return String(format: "%.1f MB/s", kb / 1024)
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
                                .foregroundStyle(Theme.text)
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

    /// In-player settings (the bottom-right gear): everything the
    /// old ellipsis menu held — rate, seek steps, engine switch —
    /// plus the live feature toggles and the fill mode, bound to
    /// the same AppStorage keys 设置 → 播放 / 音画 write.
    private var playerSettingsSheet: some View {
        NavigationStack {
            List {
                Section("倍速") {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            setRate(rate); pokeChrome()
                        } label: {
                            HStack {
                                Text("\(rate, specifier: "%.2g")x").foregroundStyle(Theme.text)
                                Spacer()
                                if rate == currentRate {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
                Section("画面方向") {
                    Button {
                        if !rotationLocked {
                            rotate(toLandscape: !UIDevice.current.orientation.isLandscape)
                        }
                        showPlayerSettings = false
                    } label: {
                        Label("切换横竖屏", systemImage: "rotate.right")
                            .foregroundStyle(Theme.text)
                    }
                    Button { rotationLocked.toggle() } label: {
                        HStack {
                            Label("旋转锁定", systemImage: rotationLocked ? "lock.fill" : "lock.open.fill")
                                .foregroundStyle(Theme.text)
                            Spacer()
                            if rotationLocked {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                Section("快进快退") {
                    Button { seekBy(-seekStep); pokeChrome() } label: {
                        Label("快退 \(Int(seekStep)) 秒", systemImage: "gobackward")
                            .foregroundStyle(Theme.text)
                    }
                    Button { seekBy(seekStep); pokeChrome() } label: {
                        Label("快进 \(Int(seekStep)) 秒", systemImage: "goforward")
                            .foregroundStyle(Theme.text)
                    }
                }
                Section("跳过片头片尾") {
                    Stepper(value: $skipIntroSeconds, in: 0...600, step: 5) {
                        Text("片头跳过 \(skipIntroSeconds) 秒").foregroundStyle(Theme.text)
                    }
                    Stepper(value: $skipOutroSeconds, in: 0...600, step: 5) {
                        Text("片尾跳过 \(skipOutroSeconds) 秒").foregroundStyle(Theme.text)
                    }
                }
                Section("引擎") {
                    Button {
                        switchEngine(manual: true)
                        showPlayerSettings = false
                    } label: {
                        Label(isMPV ? "当前 FFmpeg 引擎 · 切换到原生引擎"
                                    : "当前原生引擎 · 切换到 FFmpeg 引擎",
                              systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.text)
                    }
                    Picker("画面适配", selection: $videoGravity) {
                        Text("适应屏幕").tag("aspect")
                        Text("填充屏幕").tag("fill")
                    }
                    .foregroundStyle(Theme.text)
                }
                Section("按钮与功能") {
                    Toggle("网速显示", isOn: $showSpeedPill)
                    Toggle("分辨率显示", isOn: $showResolutionPill)
                    Toggle("画中画按钮", isOn: $showPiPButton)
                    Toggle("投屏按钮", isOn: $showAirPlayButton)
                    Toggle("选集按钮", isOn: $showEpisodeButton)
                    Toggle("长按倍速", isOn: $longPressBoostEnabled)
                    Toggle("自动播放下一集", isOn: $autoNextEnabled)
                    Toggle("当前时间显示", isOn: $showClock)
                    Toggle("截图按钮", isOn: $showScreenshotButton)
                    Toggle("画面适配按钮", isOn: $showGravityButton)
                    Toggle("倍速按钮", isOn: $showRateButton)
                    Toggle("切集按钮", isOn: $showEpisodeSwitch)
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showPlayerSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: transport plumbing

    private var currentRate: Double { isMPV ? mpv.speed : Double(native.rate) }

    private func togglePlay() { isMPV ? mpv.togglePlay() : native.toggle() }
    private func seek(to seconds: Double, tolerant: Bool = false) {
        if isMPV { mpv.seek(to: seconds) } else { native.seek(to: seconds, tolerant: tolerant) }
    }
    private func seekBy(_ delta: Double) { isMPV ? mpv.seekRelative(delta) : native.seekRelative(delta) }
    private func setRate(_ rate: Double) {
        if isMPV { mpv.setSpeed(rate) } else { native.setRate(Float(rate)) }
    }

    /// Bottom-right capsule's rate slot: cycle the standard
    /// ladder, toast the landing rate.
    private func cycleRate() {
        let order = [1.0, 1.25, 1.5, 2.0, 0.5]
        let idx = order.firstIndex { abs($0 - currentRate) < 0.01 } ?? 0
        let next = order[(idx + 1) % order.count]
        setRate(next)
        // NOTE: `\(x, specifier:)` only compiles inside a
        // Text/LocalizedStringKey literal — in a plain String it
        // fails with "incorrect argument label (have '_:specifier:',
        // expected '_:default:')" (broke CI #113/#114). Use
        // String(format:) here.
        showToast("倍速 \(String(format: "%.2g", next))x")
    }

    /// Top-right capsule's first slot: 画面适配 ↔ 画面填充，
    /// applied live on both engines (mpv panscan property,
    /// AVPlayerLayer videoGravity via updateUIView).
    private func toggleGravity() {
        let fill = videoGravity != "fill"
        videoGravity = fill ? "fill" : "aspect"
        if isMPV { mpv.setFill(fill) }
        showToast(fill ? "画面填充" : "画面适应")
    }

    /// Engine switch that keeps the playhead: the fresh engine
    /// layer lands on pendingStart (mpv via its start option, the
    /// native engine via applyPendingStartIfNeeded).
    private func switchEngine(manual: Bool) {
        let targetMPV = !isMPV
        pendingStart = currentTime
        didSkipIntro = true
        engineOverride = targetMPV
        if manual {
            recoveryStep = 0
            showToast(targetMPV ? "已切换到 FFmpeg 引擎" : "已切换到原生引擎")
        }
        pokeChrome()
    }

    /// Single choke point for auto-advance: both engines' onEnded
    /// callbacks and the outro skip land here, so the 播放设置
    /// auto-next switch gates all of them. Off = stay at the end.
    private func advanceToNext() {
        guard autoNextEnabled, index < episodes.count - 1 else { return }
        index += 1
    }

    /// Manual episode stepping from the quick-switch capsule —
    /// deliberately NOT gated by the autoNext setting (that one
    /// only governs hands-free advance when an episode ends).
    private func prevEpisode() {
        if index > 0 { index -= 1 } else { showToast("已经是第一集") }
    }

    private func nextEpisode() {
        if index < episodes.count - 1 { index += 1 } else { showToast("已经是最后一集") }
    }

    /// Failure ladder, driven by both engines' failure callbacks:
    /// rebuild the same engine once, then switch engines (keeping
    /// the playhead), then give up and surface the error. Progress
    /// past a few seconds resets the ladder (see the currentTime
    /// change handler), so a stream that dies an hour in gets the
    /// full treatment again.
    private func handlePlaybackFailure(_ message: String) {
        if let last = lastFailureAt, Date.now.timeIntervalSince(last) < 3 { return }
        lastFailureAt = .now
        switch recoveryStep {
        case 0:
            recoveryStep = 1
            showToast("播放出错，正在自动重试…")
            reloadCurrentEngine()
        case 1:
            recoveryStep = 2
            showToast("正在切换引擎重试…")
            switchEngine(manual: false)
        default:
            showToast("播放失败：" + message)
        }
    }

    private func reloadCurrentEngine() {
        guard let url = URL(string: current.url) else { return }
        if isMPV {
            mpv.reload(url: url, header: header, startAt: currentTime)
        } else {
            // The native engine has no start option; pendingStart
            // lands it back at the playhead once duration reports.
            pendingStart = currentTime
            native.reload(url: url, header: header)
        }
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

    /// Seek-preview frames come from the native engine's generator
    /// (m3u8/mp4 — the bulk of playback). mpv would need a second
    /// decoder instance to grab arbitrary frames, so its scrub HUD
    /// stays time-only.
    private func requestPreview(at seconds: Double) {
        guard !isMPV else { return }
        guard abs(seconds - lastPreviewTarget) > 0.8 else { return }
        lastPreviewTarget = seconds
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            let image = await native.previewImage(at: seconds)
            if !Task.isCancelled, let image { previewImage = image }
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewImage = nil
        lastPreviewTarget = -10
    }

    private func showSeekToast(delta: Double) {
        let target = min(max(currentTime + delta, 0),
                         duration > 0 ? duration : .greatestFiniteMagnitude)
        showToast((delta >= 0 ? "快进至 " : "快退至 ") + timeLabel(target))
    }

    // MARK: history / resume

    /// Engine switches and same-engine rebuilds land here: once
    /// the fresh item reports a duration, jump back to where the
    /// previous engine left off.
    private func applyPendingStartIfNeeded() {
        guard let target = pendingStart, duration > 0 else { return }
        pendingStart = nil
        if target > 5 {
            seek(to: target, tolerant: true)
            showToast("已从 " + timeLabel(target) + " 继续播放")
        }
    }

    private func applyResumeIfNeeded() {
        guard !didResume, resumeAt > 5, duration > 0 else { return }
        didResume = true
        seek(to: resumeAt, tolerant: true)
        showToast("已续播至 " + timeLabel(resumeAt))
    }

    /// 跳片头：每集一次，时长已知后执行；有续播位置时以续播为准。
    private func applyIntroSkipIfNeeded() {
        let intro = Double(skipIntroSeconds)
        guard intro > 0, !didSkipIntro, duration > intro + 30 else { return }
        didSkipIntro = true
        if resumeAt > 5 { return }
        seek(to: intro)
        showToast("已跳过片头 " + timeLabel(intro))
    }

    /// 跳片尾：剩余时长进入片尾窗口且有下一集时自动切集。
    private func checkOutroSkip() {
        let outro = Double(skipOutroSeconds)
        guard outro > 0, duration > 0, index < episodes.count - 1 else { return }
        let remaining = duration - currentTime
        if remaining > 0, remaining <= outro { advanceToNext() }
    }

    private func saveProgress(accumulate: Bool = true) {
        guard let historyID else { return }
        HistoryStore.shared.updatePosition(
            id: historyID, position: currentTime, duration: duration,
            playing: isPlaying, accumulate: accumulate)
    }

    private func saveProgressLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            saveProgress()
            watchdogTick()
            batteryLevel = UIDevice.current.batteryLevel
        }
    }

    /// Stall watchdog: some failures never raise an error — the
    /// engine just sits in "buffering" forever (AVPlayer does this
    /// with proxied range fetchers and encodes it cannot decode:
    /// no failure event, an eternal spinner). ~25 s of buffering
    /// with zero playhead progress is treated as a failure and
    /// enters the same recovery ladder (rebuild, then switch
    /// engine), which is what gets those titles playing.
    private func watchdogTick() {
        let nearEnd = duration > 0 && currentTime >= duration - 1
        if isBuffering, !nearEnd {
            if currentTime == lastWatchTime {
                stallTicks += 1
            } else {
                stallTicks = 0
            }
            if stallTicks >= 5 {
                stallTicks = 0
                handlePlaybackFailure("加载超时")
            }
        } else {
            stallTicks = 0
        }
        lastWatchTime = currentTime
    }

    private func showToast(_ text: String) {
        toastGeneration += 1
        let gen = toastGeneration
        withAnimation { toast = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if gen == toastGeneration { withAnimation { toast = nil } }
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

// MARK: - Glass chrome styling

/// One glass language for every player control: thin material, a
/// hairline white stroke and a soft shadow. Buttons keep 44pt tap
/// targets; the modifier only dresses the container.
private struct GlassCapsuleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

private struct GlassCircleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

private extension View {
    func playerGlassCapsule() -> some View { modifier(GlassCapsuleStyle()) }
    func playerGlassCircle() -> some View { modifier(GlassCircleStyle()) }
}

// MARK: - Native engine controller

final class NativeController: NSObject, ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0
    @Published var isBuffering = false
    /// Download rate from the item's access log, bytes/sec.
    @Published var netSpeedBytes: Double = 0
    /// "1920×1080 · H.265" once the current item reports its video
    /// size; empty until then (spec pill hides itself).
    @Published var specText: String = ""
    @Published var isPiPActive = false
    private var pipController: AVPictureInPictureController?

    /// Playback failure / natural end, wired by PlayerView (which
    /// owns recovery: retry, then engine switch, then surface).
    var onFailure: ((String) -> Void)?
    var onEnded: (() -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []

    private func detachItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers = []
    }

    private func attachItemObservers(_ item: AVPlayerItem) {
        detachItemObservers()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "原生引擎播放失败"
            DispatchQueue.main.async { self?.onFailure?(message) }
        }
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.onFailure?(error?.localizedDescription ?? "原生引擎播放失败")
        })
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.onEnded?()
        })
    }

    /// Wire PiP to the rendering layer. Called again with a fresh
    /// layer when the episode (and thus the view) changes.
    func setupPiP(layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if pipController?.playerLayer === layer { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        pipController = controller
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }
    private var timeObserver: Any?
    private var loadedURL: URL?
    private var lastBytes: Int64 = 0
    private var lastBytesAt: Date?

    /// Force a fresh item for the same URL (failure recovery) —
    /// load() alone would short-circuit and just replay the corpse.
    func reload(url: URL, header: [String: String]) {
        loadedURL = nil
        load(url: url, header: header)
    }

    func load(url: URL, header: [String: String]) {
        specText = ""
        if loadedURL == url, player.currentItem != nil {
            player.play()
            return
        }
        loadedURL = url
        currentTime = 0
        duration = 0
        // Literal key: the AVURLAssetHTTPHeaderFieldsKey constant is not
        // exposed in the iOS 26 SDK's Swift interface.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": header,
            // Skip the precise-duration/timing scan (same literal-
            // key style as above): streams start as soon as they
            // can and the exact duration firms up while playing.
            "AVURLAssetPreferPreciseDurationAndTimingKey": false,
        ])
        let item = AVPlayerItem(asset: asset)
        // Forward buffer maxed (v1.35): a full minute of runway
        // so brief network dips never reach the screen.
        item.preferredForwardBufferDuration = 60
        // Adaptive HLS opens on the lowest eligible variant and
        // ramps up, instead of probing bandwidth at full rate
        // before the first frame.
        item.startsOnFirstEligibleVariant = true
        attachItemObservers(item)
        player.replaceCurrentItem(with: item)
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                    if self.specText.isEmpty, let item = self.player.currentItem {
                        let size = item.presentationSize
                        if size.width > 0 {
                            var text = "\(Int(size.width))×\(Int(size.height))"
                            Task { @MainActor in
                                if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                                   let descs = try? await track.load(.formatDescriptions),
                                   let desc = descs.first {
                                    let codec = PlayerView.codecName(CMFormatDescriptionGetMediaSubType(desc))
                                    if !codec.isEmpty { self.specText = text + " · " + codec }
                                }
                            }
                            self.specText = text
                        }
                    }
                }
                self.isPlaying = self.player.timeControlStatus == .playing
                self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.sampleSpeed()
            }
        }
        player.play()
    }

    /// Download rate from cumulative access-log bytes, sampled on a
    /// ~1 s cadence and lightly smoothed so the readout doesn't jitter.
    private func sampleSpeed() {
        guard let events = player.currentItem?.accessLog()?.events, !events.isEmpty else { return }
        let total = events.reduce(Int64(0)) { $0 + max($1.numberOfBytesTransferred, 0) }
        let now = Date()
        if let lastAt = lastBytesAt {
            let dt = now.timeIntervalSince(lastAt)
            if dt >= 1.0 {
                let rate = Double(max(total - lastBytes, 0)) / dt
                netSpeedBytes = netSpeedBytes == 0 ? rate : netSpeedBytes * 0.5 + rate * 0.5
                lastBytes = total
                lastBytesAt = now
            }
        } else {
            lastBytes = total
            lastBytesAt = now
        }
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

    func seek(to seconds: Double, tolerant: Bool = false) {
        // Frame-exact seeks make HLS wait for keyframe alignment;
        // resume / engine-switch landings use a tolerance window
        // and arrive noticeably faster.
        let tolerance = tolerant
            ? CMTime(seconds: 5, preferredTimescale: 600) : .zero
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func seekRelative(_ delta: Double) {
        seek(to: max(0, currentTime + delta), tolerant: true)
    }

    func setRate(_ value: Float) {
        rate = value
        if player.timeControlStatus == .playing { player.rate = value }
    }

    /// Frame at an arbitrary position, for the seek-preview bubble.
    /// Async generator API with a tolerant window so HLS doesn't have
    /// to land the exact frame.
    func previewImage(at seconds: Double) async -> UIImage? {
        guard let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
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
    var onLayer: ((AVPlayerLayer) -> Void)?

    /// 画面适配 from the shared setting: fill crops to the
    /// screen, aspect letterboxes. Read at make AND update time
    /// so the player's top-bar toggle lands live.
    private static var gravity: AVLayerVideoGravity {
        UserDefaults.standard.string(forKey: "videoGravity") == "fill"
            ? .resizeAspectFill : .resizeAspect
    }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = Self.gravity
        onLayer?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = Self.gravity
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
    var preview: UIImage?
    var onDrag: ((Double) -> Void)?
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
                if dragFraction != nil {
                    bubble(width: geo.size.width)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = min(max(drag.location.x / geo.size.width, 0), 1)
                        dragFraction = f
                        if duration > 0 { onDrag?(f * duration) }
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

    /// Floating preview while scrubbing the bar: target frame (native
    /// engine) + the exact landing time, clamped inside the bar.
    private func bubble(width: CGFloat) -> some View {
        let bubbleWidth: CGFloat = 128
        let x = min(max(width * fraction - bubbleWidth / 2, 0), max(width - bubbleWidth, 0))
        return VStack(spacing: 5) {
            if let preview {
                Image(uiImage: preview)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: bubbleWidth, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(timeText(fraction * duration))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
        }
        .padding(6)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .offset(x: x, y: -96)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - System volume bridge

/// iOS has no public volume setter; the supported route is driving the
/// slider inside an MPVolumeView kept in the view hierarchy.
private enum VolumeControl {
    static var view: MPVolumeView?

    static func current() -> Double {
        Double(AVAudioSession.sharedInstance().outputVolume)
    }

    static func set(_ value: Double) {
        guard let slider = view?.subviews.compactMap({ $0 as? UISlider }).first
        else { return }
        slider.value = Float(value)
        slider.sendActions(for: .valueChanged)
    }
}

private struct VolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.clipsToBounds = true
        VolumeControl.view = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

extension NativeController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
    }
    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
    }
}

/// In-player skip settings: same AppStorage keys as 设置 → 播放，
/// so values stay in sync. 片尾 reads the value on every tick
/// (applies immediately); 片头 applies from the next episode (or
/// when the playhead is dragged back before the intro end).
private struct SkipSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("skipIntroSeconds") private var skipIntroSeconds = 0
    @AppStorage("skipOutroSeconds") private var skipOutroSeconds = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                SkipSecondsEditor(title: "片头跳过", seconds: $skipIntroSeconds)
                SkipSecondsEditor(title: "片尾跳过", seconds: $skipOutroSeconds)
                Text("滑杆精确到 1 秒。片尾设置即时生效；片头设置从下一集起生效。")
                    .font(.footnote).foregroundStyle(Theme.textDim)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AmbientBackground(imageURL: nil))
            .navigationTitle("跳过片头片尾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundStyle(Theme.text)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
