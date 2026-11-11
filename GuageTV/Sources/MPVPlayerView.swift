import CoreGraphics
import Foundation
import libmpv
import SwiftUI
import UIKit

/// Second playback engine: libmpv from FFmpegKit (FFmpeg demux/decode,
/// libass ASS subtitles, dav1d AV1, libdovi metadata) — the same stack
/// Rex's license page lists. KSPlayer's own binary turned out to ship no
/// iOS-device slice in its free build, so the mpv core is used directly.
///
/// Rendering uses mpv's software render API into a CPU buffer blitted to
/// a CALayer — simplest correct integration; VideoToolbox hardware
/// decoding still applies via hwdec=auto-safe.
final class MPVController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var speed: Double = 1.0

    func setSpeed(_ value: Double) {
        speed = value
        setProperty("speed", String(value))
    }

    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var buffer: UnsafeMutableRawPointer?
    private var bufferBytes: Int = 0
    private var pollTimer: Timer?

    // MARK: lifecycle

    func start(url: URL, header: [String: String]) {
        guard handle == nil, let h = mpv_create() else { return }
        handle = h
        setOption("vo", "libmpv")
        setOption("hwdec", "auto-safe")
        setOption("terminal", "no")
        setOption("msg-level", "all=warn")
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "64MiB")
        if !header.isEmpty {
            let fields = header.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            mpv_set_property_string(h, "http-header-fields", fields)
        }
        guard mpv_initialize(h) >= 0 else { return }
        createRenderContext()
        let scale = UserDefaults.standard.object(forKey: "subtitleScale") as? Double ?? 1.0
        setProperty("sub-scale", String(scale))
        command(["loadfile", url.absoluteString])
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
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

    private func poll() {
        duration = stringProperty("duration").flatMap(Double.init) ?? 0
        currentTime = stringProperty("time-pos").flatMap(Double.init) ?? 0
        isPlaying = stringProperty("pause") == "no" && stringProperty("eof-reached") != "yes"
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

/// Render surface for the mpv engine. All chrome (close bar, transport
/// controls) lives in PlayerView, which owns the controller.
struct MPVPlayerView: View {
    let url: URL
    var header: [String: String] = [:]
    let controller: MPVController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVRenderRepresentable(controller: controller)
                .ignoresSafeArea()
        }
        .onAppear { controller.start(url: url, header: header) }
        .onDisappear { controller.stop() }
    }
}
