import SwiftUI

/// 设置 (Settings) — Rex-style grouped glass cards. The four quick tiles
/// open real setting pages （播放引擎 / 画面填充 / 操控步长 / 字幕大小）,
/// all persisted with AppStorage and honoured by the player.
struct SettingsView: View {
    @Binding var config: TVBoxConfig?
    @State private var configURL = ""
    @State private var status = "还没有导入配置"

    /// Bump on every shipped build so screenshots self-identify.
    static let buildLabel = "v1.02 · Python"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.largeTitle.bold()).foregroundStyle(.white)
                    .onAppear {
                        if configURL.isEmpty, let saved = ConfigStore.savedSourceURL() {
                            configURL = saved
                        }
                    }

                    HStack(spacing: 12) {
                        NavigationLink { PlaySettingsView() } label: {
                            quickTile(icon: "slider.horizontal.3", title: "播放")
                        }
                        NavigationLink { AVSettingsView() } label: {
                            quickTile(icon: "play.rectangle", title: "音画")
                        }
                        NavigationLink { ControlSettingsView() } label: {
                            quickTile(icon: "hand.tap", title: "操控")
                        }
                        NavigationLink { SubtitleSettingsView() } label: {
                            quickTile(icon: "captions.bubble", title: "字幕")
                        }
                    }
                    .buttonStyle(.plain)

                    group(title: "数据与资源") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("TVBox 配置地址 https://…", text: $configURL)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("导入配置") { Task { await load() } }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                            Text(status).font(.footnote).foregroundStyle(Theme.textDim)
                            if let config {
                                Text("已加载 \(config.sites.count) 个站点 · \(config.lives?.count ?? 0) 个直播源")
                                    .font(.footnote).foregroundStyle(Theme.textDim)
                            }
                        }
                    }

                    group(title: "使用偏好") {
                        row(icon: "paintbrush", title: "外观与交互", value: "")
                        row(icon: "square.grid.2x2", title: "模块", value: "")
                    }

                    group(title: "应用") {
                        row(icon: "info.circle", title: "关于呱壳", value: Self.buildLabel)
                        row(icon: "chevron.left.forwardslash.chevron.right", title: "Python 运行时", value: PythonRuntime.shared.statusText)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .background(AmbientBackground(imageURL: nil))
            .preferredColorScheme(.dark)
        }
    }

    private func quickTile(icon: String, title: String) -> some View {
        GlassCard(padding: 12) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(.white)
                Text(title).font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Theme.textDim)
            GlassCard { VStack(alignment: .leading, spacing: 12) { content() } }
        }
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.textDim).frame(width: 22)
            Text(title).foregroundStyle(.white)
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(Theme.textDim) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textDim)
        }
    }

    private func load() async {
        var text = configURL.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text) else {
            status = "地址格式不对"
            return
        }
        status = "加载中…（多通道轮试中，稍等）"
        let data: Data
        do {
            data = try await NetFetch.dataForConfig(from: url)
        } catch {
            status = "加载失败：网络取不到内容（已试 okhttp、浏览器、禁跳转、WebKit 四种通道）"
            return
        }
        do {
            if MaoYuanAdapter.looksLikeMaoYuan(data) {
                config = try MaoYuanAdapter.convert(from: data)
                ConfigStore.save(data: data, sourceURL: text)
                status = "已加载（猫源配置已自动转换）"
            } else {
                config = try ConfigLoader.load(from: data)
                ConfigStore.save(data: data, sourceURL: text)
                status = "已加载 TVBox 配置"
            }
        } catch {
            let head = String(decoding: data.prefix(60), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            status = "加载失败：内容无法识别（\(data.count) 字节，开头：\(head)）"
        }
    }
}

// MARK: - Setting pages (all functional, persisted via AppStorage)

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 40)
        }
        .background(AmbientBackground(imageURL: nil))
        .preferredColorScheme(.dark)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 播放： default player engine — "auto" picks by file extension.
struct PlaySettingsView: View {
    @AppStorage("enginePreference") private var engine = "auto"

    var body: some View {
        SettingsPage(title: "播放") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("默认播放引擎").font(.headline).foregroundStyle(.white)
                    Picker("引擎", selection: $engine) {
                        Text("自动").tag("auto")
                        Text("原生").tag("native")
                        Text("增强 mpv").tag("mpv")
                    }
                    .pickerStyle(.segmented)
                    Text("自动：m3u8/mp4 用原生引擎（省电硬解），mkv/flv 等用 mpv 增强引擎。原生播不了的片，改成「增强 mpv」强制走 mpv。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

/// 音画： video fill mode for the mpv surface.
struct AVSettingsView: View {
    @AppStorage("videoGravity") private var gravity = "aspect"

    var body: some View {
        SettingsPage(title: "音画") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("画面填充（mpv 引擎）").font(.headline).foregroundStyle(.white)
                    Picker("填充", selection: $gravity) {
                        Text("适应（留黑边）").tag("aspect")
                        Text("填充（裁剪）").tag("fill")
                    }
                    .pickerStyle(.segmented)
                    Text("原生引擎使用系统播放界面，填充模式由系统决定。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

/// 操控： double-tap seek step on the mpv surface; single tap toggles play.
struct ControlSettingsView: View {
    @AppStorage("seekStep") private var step = 15.0

    var body: some View {
        SettingsPage(title: "操控") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("双击快进/快退（mpv 引擎）").font(.headline).foregroundStyle(.white)
                    Picker("步长", selection: $step) {
                        Text("10 秒").tag(10.0)
                        Text("15 秒").tag(15.0)
                        Text("30 秒").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    Text("播放页单击画面 = 播放/暂停；双击左半屏快退、右半屏快进。原生引擎用系统手势。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

/// 字幕： subtitle scale applied by the mpv engine (libass rendering).
struct SubtitleSettingsView: View {
    @AppStorage("subtitleScale") private var scale = 1.0

    var body: some View {
        SettingsPage(title: "字幕") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("字幕大小（mpv 引擎）").font(.headline).foregroundStyle(.white)
                    Slider(value: $scale, in: 0.5...2.0, step: 0.1)
                        .tint(.white)
                    HStack {
                        Text("小").font(.caption).foregroundStyle(Theme.textDim)
                        Spacer()
                        Text(String(format: "%.0f%%", scale * 100))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        Spacer()
                        Text("大").font(.caption).foregroundStyle(Theme.textDim)
                    }
                    Text("对 ASS/SRT 等字幕生效，下次播放时应用。原生引擎的字幕大小跟随系统设置。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}
