import CoreGraphics
import Foundation
import libmpv
import QuartzCore
import SwiftUI
import UIKit

/// Second playback engine: libmpv from FFmpegKit (FFmpeg demux/decode,
/// libass ASS subtitles, dav1d AV1, libdovi metadata) — the same stack
/// Rex's license page lists. KSPlayer's own binary turned out to ship no
/// iOS-device slice in its free build, so the mpv core is used directly.
///
/// Two render paths (设置 → 播放 → mpv 渲染）:
/// - Metal (default): `wid` straight onto a CAMetalLayer with
///   vo=gpu-next via libplacebo/MoltenVK — zero-copy GPU output,
///   hardware tone mapping. The bundled FFmpegKit binary was
///   verified to already contain the whole gpu-next stack; only
///   the app-side wiring was missing.
/// - Software (fallback): mpv's render API into a CPU buffer
///   blitted to a CALayer. Used when the setting forces it, or
///   automatically when the Metal context fails to initialise.
/// One selectable audio/subtitle track, shared by both engines'
/// controllers and the player's track picker.
struct PlayerTrack: Identifiable, Equatable {
    let id: Int
    let label: String
    var selected: Bool
}

final class MPVController: ObservableObject {
    /// Which surface the view layer should show. Starts at the
    /// user's preference; flips to false if Metal init fails so
    /// the software surface swaps in.
    @Published var metalActive: Bool

    /// The CAMetalLayer handed over by the metal surface view
    /// (created by the representable before start() runs).
    private weak var metalLayer: MPVMetalLayer?

    init() {
        metalActive = UserDefaults.standard.string(forKey: "mpvRenderer") != "sw"
    }

    func attachMetalLayer(_ layer: MPVMetalLayer) { metalLayer = layer }
    func detachMetalLayer() { metalLayer = nil }
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var speed: Double = 1.0
    @Published var isBuffering = false
    /// Demuxer cache download rate, bytes/sec (mpv's cache-speed).
    @Published var netSpeedBytes: Double = 0
    /// "1920×1080 · hevc" once mpv reports the video size.
    @Published var specText: String = ""

    /// Playback failure / natural end, wired by PlayerView (which
    /// owns recovery: retry, then engine switch, then surface).
    var onFailure: ((String) -> Void)?
    var onEnded: (() -> Void)?
    private var lastFileError = ""
    private var wasEOF = false

    func setSpeed(_ value: Double) {
        speed = value
        setProperty("speed", String(value))
    }

    /// Current frame as an image (for the screenshot button). The
    /// software path renders a frame directly; the Metal path asks
    /// mpv to write one out (the GPU owns the pixels there).
    func snapshot() -> CGImage? {
        if metalActive {
            let path = NSTemporaryDirectory() + "guage-snapshot.jpg"
            try? FileManager.default.removeItem(atPath: path)
            command(["screenshot-to-file", path, "video"])
            for _ in 0..<6 {
                if let img = UIImage(contentsOfFile: path), let cg = img.cgImage {
                    return cg
                }
                Thread.sleep(forTimeInterval: 0.08)
            }
            return nil
        }
        return renderFrame(maxSize: CGSize(width: 1280, height: 720), scale: 1)
    }

    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var buffer: UnsafeMutableRawPointer?
    private var bufferBytes: Int = 0
    private var pollTimer: Timer?

    // MARK: lifecycle

    func start(url: URL, header: [String: String], startAt: Double = 0) {
        guard handle == nil, let first = mpv_create() else { return }
        lastFileError = ""
        wasEOF = false

        // One configure pass per attempt: Metal first (when the
        // preference and a surface allow), software as the fallback.
        func configure(_ h: OpaquePointer, metal: Bool) {
            if metal, let layer = metalLayer {
                var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
                _ = mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)
                setOptionOn(h, "vo", "gpu-next")
                setOptionOn(h, "gpu-api", "vulkan")
                setOptionOn(h, "gpu-context", "moltenvk")
                setOptionOn(h, "hwdec", "videotoolbox")
                // Direct rendering: decoder output goes straight
                // to the VO without a CPU-side copy (mpv falls
                // back internally when a codec can't do it).
                setOptionOn(h, "vd-lavc-dr", "yes")
                // GPU picture quality maxed (v1.35): EWA Lanczos
                // up/down scaling with sigmoid upscaling and
                // debanding — libplacebo's best built-in filters.
                setOptionOn(h, "scale", "ewa_lanczos")
                setOptionOn(h, "cscale", "ewa_lanczos")
                setOptionOn(h, "dscale", "mitchell")
                setOptionOn(h, "sigmoid-upscaling", "yes")
                setOptionOn(h, "deband", "yes")
                if UserDefaults.standard.string(forKey: "videoGravity") == "fill" {
                    setOptionOn(h, "panscan", "1.0")
                }
            } else {
                setOptionOn(h, "vo", "libmpv")
                setOptionOn(h, "hwdec", "auto-safe")
            }
            setOptionOn(h, "terminal", "no")
            setOptionOn(h, "msg-level", "all=warn")
            setOptionOn(h, "cache", "yes")
            // Buffers maxed (v1.35, at the user's explicit ask —
            // the earlier "60s is enough" call is superseded):
            // two minutes of cache, a 256MiB forward cap, and a
            // 60s readahead target. Costs memory on long streams;
            // buys real stall resistance on weak networks.
            setOptionOn(h, "cache-secs", "120")
            setOptionOn(h, "demuxer-max-bytes", "256MiB")
            setOptionOn(h, "demuxer-max-back-bytes", "64MiB")
            // Read further ahead so brief network dips don't reach
            // the screen; hold playback while the cache refills
            // after an underrun instead of stutter-playing.
            setOptionOn(h, "demuxer-readahead-secs", "60")
            setOptionOn(h, "cache-pause", "yes")
            setOptionOn(h, "cache-pause-wait", "1")
            // Network resilience: fail a stalled connection in
            // 15s instead of hanging, and let libavformat's HTTP
            // layer reconnect (streamed content included) with a
            // capped 5s backoff.
            setOptionOn(h, "network-timeout", "15")
            setOptionOn(h, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
            // Sync: audio is the master clock; on a weak link the
            // VO drops late frames rather than letting A/V drift.
            setOptionOn(h, "video-sync", "audio")
            setOptionOn(h, "framedrop", "vo")
            // HDR handling from 设置 → 音画 (auto = leave mpv's
            // defaults untouched): 动态映射 drives peak detection
            // + the tone-mapping curve; 增强层 sets libplacebo's
            // contrast recovery. Both only bite on the GPU path.
            switch UserDefaults.standard.string(forKey: "player.hdrMapping") ?? "auto" {
            case "on":
                setOptionOn(h, "hdr-compute-peak", "yes")
                setOptionOn(h, "tone-mapping", "mobius")
            case "off":
                setOptionOn(h, "hdr-compute-peak", "no")
            default:
                break
            }
            switch UserDefaults.standard.string(forKey: "player.hdrLayer") ?? "auto" {
            case "on":
                setOptionOn(h, "hdr-contrast-recovery", "0.6")
            case "off":
                setOptionOn(h, "hdr-contrast-recovery", "0")
            default:
                break
            }
            if startAt > 1 { setOptionOn(h, "start", String(startAt)) }
            if !header.isEmpty {
                let fields = header.map { "\($0.key): \($0.value)" }.joined(separator: ",")
                _ = mpv_set_property_string(h, "http-header-fields", fields)
            }
        }

        let wantMetal = metalActive && metalLayer != nil
        var h = first
        var usingMetal = wantMetal
        configure(h, metal: wantMetal)
        handle = h
        if mpv_initialize(h) < 0 {
            guard usingMetal, let second = mpv_create() else {
                mpv_terminate_destroy(h)
                handle = nil
                return
            }
            // Metal context refused to come up — rebuild on the
            // software path and tell the view layer to swap
            // surfaces.
            mpv_terminate_destroy(h)
            h = second
            handle = h
            usingMetal = false
            configure(h, metal: false)
            guard mpv_initialize(h) >= 0 else {
                mpv_terminate_destroy(h)
                handle = nil
                return
            }
        }
        if usingMetal {
            registerBackgroundObservers()
        } else {
            if metalActive { metalActive = false }
            createRenderContext()
        }
        let scale = UserDefaults.standard.object(forKey: "subtitleScale") as? Double ?? 1.0
        setProperty("sub-scale", String(scale))
        specText = ""
        command(["loadfile", url.absoluteString])
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// MoltenVK drawables do not survive backgrounding — park the
    /// video track while the app is away so the return trip is not
    /// a black screen (the MPVKit demo does the same).
    private var backgroundObservers: [NSObjectProtocol] = []

    private func registerBackgroundObservers() {
        guard backgroundObservers.isEmpty else { return }
        let center = NotificationCenter.default
        backgroundObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Background audio (v1.42): park the video, keep the
            // sound running (the app declares the audio background
            // mode, so iOS lets the process live). With the setting
            // off, pause outright like a plain video app.
            let keepAudio = UserDefaults.standard.object(forKey: "player.backgroundAudio") as? Bool ?? true
            if keepAudio {
                self?.setProperty("vid", "no")
            } else {
                self?.setProperty("pause", "yes")
            }
        })
        backgroundObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setProperty("vid", "auto") })
    }

    private func unregisterBackgroundObservers() {
        backgroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        backgroundObservers = []
    }

    /// Resident-handle load (v1.38): episode and line switches
    /// reuse the live mpv handle — only the file changes, no
    /// mpv_create / render-context rebuild, so switching is as
    /// fast as the network allows. Falls back to a full start
    /// when no handle is up yet; the heavy rebuild stays reload().
    func load(url: URL, header: [String: String], startAt: Double = 0) {
        guard let h = handle else {
            start(url: url, header: header, startAt: startAt)
            return
        }
        let fields = header.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        _ = mpv_set_property_string(h, "http-header-fields", fields)
        _ = mpv_set_property_string(h, "start", startAt > 1 ? String(startAt) : "none")
        specText = ""
        command(["loadfile", url.absoluteString])
    }

    /// Rebuild from scratch (failure recovery): the view layer
    /// stays put, only the mpv handle is recycled.
    func reload(url: URL, header: [String: String], startAt: Double = 0) {
        stop()
        start(url: url, header: header, startAt: startAt)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        unregisterBackgroundObservers()
        if let ctx = renderContext {
            mpv_render_context_free(ctx)
            renderContext = nil
        }
        if let h = handle {
            mpv_terminate_destroy(h)
            handle = nil
        }
        if let b = buffer {
            free(b)
            buffer = nil
            bufferBytes = 0
        }
    }

    // MARK: tracks （音轨 / 字幕）

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subTracks: [PlayerTrack] = []
    @Published var currentAudioID = -1
    @Published var currentSubID = -1
    /// Dual subtitles (v1.42): mpv's secondary-sid renders a
    /// second subtitle track above the primary one.
    @Published var currentSecondarySubID = -1
    private var pollCount = 0

    /// track-list via per-index string properties (mpv exposes
    /// them read-only); refreshed on a 1s cadence from poll().
    private func refreshTracks() {
        guard let count = stringProperty("track-list/count").flatMap(Int.init) else { return }
        var audios: [PlayerTrack] = []
        var subs: [PlayerTrack] = []
        var curA = -1
        var curS = -1
        for i in 0..<count {
            let base = "track-list/\(i)"
            guard let type = stringProperty("\(base)/type"),
                  type == "audio" || type == "sub",
                  let tid = stringProperty("\(base)/id").flatMap(Int.init) else { continue }
            let title = stringProperty("\(base)/title") ?? ""
            let lang = stringProperty("\(base)/lang") ?? ""
            let label = !title.isEmpty ? title
                : (!lang.isEmpty ? lang : (type == "audio" ? "音轨 \(tid)" : "字幕 \(tid)"))
            let selected = stringProperty("\(base)/selected") == "yes"
            let track = PlayerTrack(id: tid, label: label, selected: selected)
            if type == "audio" {
                audios.append(track)
                if selected { curA = tid }
            } else {
                subs.append(track)
                if selected { curS = tid }
            }
        }
        if audios != audioTracks { audioTracks = audios }
        if subs != subTracks { subTracks = subs }
        currentAudioID = curA
        currentSubID = curS
        let secondary = stringProperty("secondary-sid").flatMap(Int.init) ?? -1
        if secondary != currentSecondarySubID { currentSecondarySubID = secondary }
    }

    func selectAudio(_ id: Int) {
        setProperty("aid", id < 0 ? "no" : "\(id)")
        currentAudioID = id
    }

    func selectSub(_ id: Int) {
        setProperty("sid", id < 0 ? "no" : "\(id)")
        currentSubID = id
    }

    func selectSecondarySub(_ id: Int) {
        setProperty("secondary-sid", id < 0 ? "no" : "\(id)")
        currentSecondarySubID = id
    }

    // MARK: controls

    func togglePlay() {
        setProperty("pause", isPlaying ? "yes" : "no")
    }

    func seek(to seconds: Double) {
        command(["seek", String(seconds), "absolute"])
    }

    func seekRelative(_ delta: Double) {
        command(["seek", String(delta), "relative"])
    }

    /// Live 画面适配 switch from the player's top bar: panscan is
    /// a plain runtime property, no reload needed.
    func setFill(_ fill: Bool) {
        setProperty("panscan", fill ? "1.0" : "0.0")
    }

    // MARK: rendering (called from the view's display link, main thread)

    func renderFrame(maxSize: CGSize, scale: CGFloat) -> CGImage? {
        guard let ctx = renderContext else { return nil }
        let flags = mpv_render_context_update(ctx)
        guard flags & 1 != 0 else { return nil }   // MPV_RENDER_UPDATE_FRAME
        let w = Int32(min(maxSize.width * scale, 1920))
        let hgt = Int32(maxSize.height * scale)
        guard w > 0, hgt > 0 else { return nil }
        let needed = Int(w) * Int(hgt) * 4
        if buffer == nil || bufferBytes < needed {
            if let b = buffer { free(b) }
            buffer = malloc(needed)
            bufferBytes = needed
        }
        guard let buf = buffer else { return nil }
        var size: [Int32] = [w, hgt]
        var stride = Int(w) * 4
        var result: Int32 = -1
        "bgra".withCString { fmt in
            withUnsafeMutablePointer(to: &size) { sizePtr in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    var params: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: fmt)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buf),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    result = mpv_render_context_render(ctx, &params)
                }
            }
        }
        guard result >= 0 else { return nil }
        let data = Data(bytes: buf, count: needed)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: Int(w), height: Int(hgt),
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: mpv plumbing

    private func createRenderContext() {
        guard let h = handle else { return }
        "sw".withCString { apiType in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            mpv_render_context_create(&renderContext, h, &params)
        }
    }

    private func setOption(_ name: String, _ value: String) {
        guard let h = handle else { return }
        setOptionOn(h, name, value)
    }

    private func setOptionOn(_ h: OpaquePointer, _ name: String, _ value: String) {
        _ = mpv_set_option_string(h, name, value)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let h = handle else { return }
        _ = mpv_set_property_string(h, name, value)
    }

    private func command(_ args: [String]) {
        guard let h = handle else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { str in
            str.withCString { strdup($0) }.map { UnsafePointer($0) }
        }
        cArgs.append(nil)
        defer { cArgs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        _ = mpv_command(h, &cArgs)
    }

    private func stringProperty(_ name: String) -> String? {
        guard let h = handle, let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(UnsafeMutableRawPointer(c)) }
        return String(cString: c)
    }

    /// Stats-overlay fields (v1.40), refreshed with the track poll.
    @Published var fpsText = ""
    @Published var dropText = ""
    @Published var cacheText = ""

    private func refreshStats() {
        if let fps = stringProperty("estimated-vf-fps").flatMap(Double.init), fps > 0 {
            fpsText = String(format: "%.0f fps", fps)
        }
        if let drops = stringProperty("frame-drop-count").flatMap(Int.init) {
            dropText = "丢帧 \(drops)"
        }
        if let cache = stringProperty("demuxer-cache-duration").flatMap(Double.init), cache > 0 {
            cacheText = String(format: "缓存 %.0fs", cache)
        }
    }

    /// Cap HLS variant bitrate (player.hlsQuality): mpv's
    /// hls-bitrate option takes max=<bytes/s>.
    func applyHLSBitrate(_ mode: String) {
        let value: String
        switch mode {
        case "1080": value = "max=8000000"
        case "720": value = "max=4500000"
        case "480": value = "max=1800000"
        default: value = "no"
        }
        setProperty("hls-bitrate", value)
    }

    private func poll() {
        pollCount += 1
        if pollCount % 4 == 0 { refreshTracks(); refreshStats() }
        duration = stringProperty("duration").flatMap(Double.init) ?? 0
        currentTime = stringProperty("time-pos").flatMap(Double.init) ?? 0
        let userPaused = stringProperty("pause") == "yes"
        let eof = stringProperty("eof-reached") == "yes"
        isPlaying = !userPaused && !eof
        // Buffering = waiting on the network, not waiting on the user:
        // paused-for-cache / seeking / core idle all count, a deliberate
        // pause and end-of-file never show the spinner.
        isBuffering = !userPaused && !eof
            && (stringProperty("paused-for-cache") == "yes"
                || stringProperty("seeking") == "yes"
                || stringProperty("core-idle") == "yes")
        netSpeedBytes = stringProperty("cache-speed").flatMap(Double.init) ?? 0
        // Failure + end surfacing for PlayerView's recovery flow.
        let fileError = stringProperty("file-error") ?? ""
        if !fileError.isEmpty, fileError != lastFileError {
            lastFileError = fileError
            onFailure?(fileError)
        }
        if eof, !wasEOF, duration > 0 { onEnded?() }
        wasEOF = eof
        if specText.isEmpty,
           let w = stringProperty("width"), let h = stringProperty("height"),
           w != "0", h != "0" {
            let codec = stringProperty("video-codec") ?? ""
            specText = codec.isEmpty ? "\(w)×\(h)" : "\(w)×\(h) · \(codec)"
        }
    }
}

/// CALayer surface driven by a display link. Gestures: single tap toggles
/// play/pause; double tap on the left/right half seeks by the 操控 step.
final class MPVRenderUIView: UIView {
    weak var controller: MPVController?
    private var link: CADisplayLink?
    private var gesturesInstalled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
            installGestures()
        } else if window == nil {
            link?.invalidate()
            link = nil
        }
    }

    private func installGestures() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
        isUserInteractionEnabled = true
    }

    @objc private func handleSingleTap() {
        controller?.togglePlay()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard bounds.width > 0 else { return }
        let step = UserDefaults.standard.object(forKey: "seekStep") as? Double ?? 15.0
        let x = gesture.location(in: self).x
        controller?.seekRelative(x < bounds.width / 2 ? -step : step)
    }

    @objc private func tick() {
        guard let c = controller, bounds.width > 0, bounds.height > 0 else { return }
        layer.contentsGravity = UserDefaults.standard.string(forKey: "videoGravity") == "fill"
            ? .resizeAspectFill : .resizeAspect
        if let img = c.renderFrame(maxSize: bounds.size, scale: window?.screen.scale ?? 2) {
            layer.contents = img
        }
    }
}

private struct MPVRenderRepresentable: UIViewRepresentable {
    let controller: MPVController

    func makeUIView(context: Context) -> MPVRenderUIView {
        let v = MPVRenderUIView()
        v.backgroundColor = .black
        v.controller = controller
        return v
    }

    func updateUIView(_ uiView: MPVRenderUIView, context: Context) {
        uiView.controller = controller
    }
}

/// CAMetalLayer with the MPVKit demo's two survival hacks:
/// MoltenVK occasionally tries to shrink the drawable to 1×1
/// (visible flicker) — refuse degenerate sizes; EDR activation
/// stays on the main thread (all layer mutation here is).
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// GPU surface for the Metal path: mpv draws into this view's
/// CAMetalLayer itself (wid mode), no display link, no CPU copies.
/// The view only keeps the drawable sized to its bounds.
final class MPVMetalUIView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.wantsExtendedDynamicRangeContent = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
    }
}

private struct MPVMetalRepresentable: UIViewRepresentable {
    let controller: MPVController

    func makeUIView(context: Context) -> MPVMetalUIView {
        let v = MPVMetalUIView()
        controller.attachMetalLayer(v.metalLayer)
        return v
    }

    func updateUIView(_ uiView: MPVMetalUIView, context: Context) {}

    static func dismantleUIView(_ uiView: MPVMetalUIView, coordinator: ()) {
        // The controller's weak layer pointer dies with the view;
        // nothing to detach explicitly.
    }
}

/// Render surface for the mpv engine. All chrome (close bar, transport
/// controls) lives in PlayerView, which owns the controller.
struct MPVPlayerView: View {
    let url: URL
    var header: [String: String] = [:]
    var startAt: Double = 0
    @ObservedObject var controller: MPVController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if controller.metalActive {
                MPVMetalRepresentable(controller: controller)
                    .ignoresSafeArea()
            } else {
                MPVRenderRepresentable(controller: controller)
                    .ignoresSafeArea()
            }
        }
        .onAppear { controller.load(url: url, header: header, startAt: startAt) }
        .onChange(of: url) { next in
            controller.load(url: next, header: header, startAt: startAt)
        }
        .onDisappear { controller.stop() }
    }
}
