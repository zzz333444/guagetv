import SwiftUI
import UniformTypeIdentifiers

/// 设置 (Settings) — Rex-style grouped glass cards. The four quick tiles
/// open real setting pages （播放引擎 / 画面填充 / 操控步长 / 字幕大小）,
/// all persisted with AppStorage and honoured by the player.
struct SettingsView: View {
    @Binding var config: TVBoxConfig?
    @State private var configURL = ""
    @State private var status = "还没有导入配置"
    @State private var entries: [ConfigLibrary.Entry] = []
    @State private var showFileImporter = false

    /// Bump on every shipped build so screenshots self-identify.
    static let buildLabel = "v1.06 · 记录与首页"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.largeTitle.bold()).foregroundStyle(.white)
                    .onAppear {
                        if configURL.isEmpty, let saved = ConfigStore.savedSourceURL() {
                            configURL = saved
                        }
                        entries = ConfigLibrary.entries()
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

                    group(title: "万能导入") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("地址：配置 / .py / .js 规则 / 猫源 https://…", text: $configURL)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            HStack(spacing: 10) {
                                Button("导入地址") { Task { await load() } }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 18).padding(.vertical, 8)
                                    .background(.white, in: Capsule())
                                    .foregroundStyle(.black)
                                Button("从文件导入") { showFileImporter = true }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 18).padding(.vertical, 8)
                                    .background(Theme.glass, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            Text(status).font(.footnote).foregroundStyle(Theme.textDim)
                            if let config {
                                Text("已加载 \(config.sites.count) 个站点 · \(config.lives?.count ?? 0) 个直播源")
                                    .font(.footnote).foregroundStyle(Theme.textDim)
                            }
                        }
                    }

                    if !entries.isEmpty {
                        group(title: "配置库") {
                            ForEach(entries) { entry in
                                HStack(spacing: 10) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(Theme.textDim).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).foregroundStyle(.white).lineLimit(1)
                                        Text("\(entry.siteCount) 个站点")
                                            .font(.caption).foregroundStyle(Theme.textDim)
                                    }
                                    Spacer()
                                    if entry.id == ConfigLibrary.activeID() {
                                        Text("使用中")
                                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
                                    } else {
                                        Button("启用") {
                                            config = ConfigLibrary.activate(id: entry.id)
                                            entries = ConfigLibrary.entries()
                                            status = "已切换到 \(entry.name)"
                                        }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Theme.glass, in: Capsule())
                                        .foregroundStyle(.white)
                                    }
                                    Button(role: .destructive) {
                                        config = ConfigLibrary.remove(id: entry.id)
                                        entries = ConfigLibrary.entries()
                                        status = "已删除 \(entry.name)"
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.red.opacity(0.85))
                                    }
                                }
                            }
                        }
                    }

                    group(title: "使用偏好") {
                        row(icon: "paintbrush", title: "外观与交互", value: "")
                        row(icon: "square.grid.2x2", title: "模块", value: "")
                    }

                    group(title: "应用") {
                        NavigationLink { AboutView() } label: {
                            row(icon: "info.circle", title: "关于呱壳", value: "")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .background(AmbientBackground(imageURL: nil))
            .preferredColorScheme(.dark)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                Task { await importFiles(result) }
            }
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
        let pathExt = url.pathExtension.lowercased()
        if pathExt == "py" || pathExt == "js" {
            await importSingleFile(url: url, kind: pathExt)
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
                let parsed = try MaoYuanAdapter.convert(from: data)
                config = parsed
                let entry = ConfigLibrary.add(data: data, sourceURL: text, siteCount: parsed.sites.count)
                status = "猫源已转换并加入配置库：\(entry.name)"
            } else {
                let parsed = try ConfigLoader.load(from: data)
                config = parsed
                let entry = ConfigLibrary.add(data: data, sourceURL: text, siteCount: parsed.sites.count)
                status = "已加入配置库并启用：\(entry.name)"
            }
            entries = ConfigLibrary.entries()
        } catch {
            let head = String(decoding: data.prefix(60), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            status = "加载失败：内容无法识别（\(data.count) 字节，开头：\(head)）"
        }
    }

    // MARK: - 万能导入 helpers

    /// A .py / .js URL becomes a single-site line: the file is stored
    /// locally and a synthetic one-site config joins the library.
    private func importSingleFile(url: URL, kind: String) async {
        status = "下载中…"
        do {
            let data = try await NetFetch.data(from: url)
            let fileName = url.lastPathComponent.isEmpty
                ? (kind == "py" ? "spider.py" : "rule.js") : url.lastPathComponent
            try await registerSingleFile(data: data, fileName: fileName, kind: kind)
        } catch {
            status = "导入失败：\(error.localizedDescription)"
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, let fileURL = urls.first else {
            if case .failure(let error) = result {
                status = "导入失败：\(error.localizedDescription)"
            }
            return
        }
        let ext = fileURL.pathExtension.lowercased()
        do {
            guard fileURL.startAccessingSecurityScopedResource() else {
                status = "导入失败：无权读取该文件"
                return
            }
            defer { fileURL.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: fileURL)
            switch ext {
            case "py", "js":
                try await registerSingleFile(data: data, fileName: fileURL.lastPathComponent, kind: ext)
            case "json", "txt", "":
                if MaoYuanAdapter.looksLikeMaoYuan(data) {
                    let parsed = try MaoYuanAdapter.convert(from: data)
                    config = parsed
                    let entry = ConfigLibrary.add(data: data, sourceURL: "file-import://" + fileURL.lastPathComponent, siteCount: parsed.sites.count)
                    status = "猫源文件已转换并加入配置库：\(entry.name)"
                } else {
                    let parsed = try ConfigLoader.load(from: data)
                    config = parsed
                    let entry = ConfigLibrary.add(data: data, sourceURL: "file-import://" + fileURL.lastPathComponent, siteCount: parsed.sites.count)
                    status = "配置文件已加入配置库：\(entry.name)"
                }
                entries = ConfigLibrary.entries()
            default:
                status = "不支持的文件类型：.\(ext)（可导入 .json / .py / .js）"
            }
        } catch {
            status = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Store the file and add its synthetic one-site config line.
    private func registerSingleFile(data: Data, fileName: String, kind: String) async throws {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dirName = kind == "py" ? "spiders" : "jsrules"
        let dir = support.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        let base = (fileName as NSString).deletingPathExtension
        let site: [String: Any]
        if kind == "py" {
            site = ["key": "pyfile_" + base, "name": base, "type": 3,
                    "api": "local-spider://" + fileName, "searchable": 1, "quickSearch": 1]
        } else {
            site = ["key": "jsfile_" + base, "name": base, "type": 3,
                    "api": "bundled-engine.js", "ext": "local-rule://" + fileName,
                    "searchable": 1, "quickSearch": 1]
        }
        let configData = try JSONSerialization.data(withJSONObject: ["sites": [site]])
        let parsed = try ConfigLoader.load(from: configData)
        config = parsed
        let entry = ConfigLibrary.add(data: configData,
                                      sourceURL: (kind == "py" ? "py-import://" : "js-import://") + fileName,
                                      siteCount: 1)
        entries = ConfigLibrary.entries()
        status = (kind == "py" ? "py 文件已导入为单站线路：" : "JS 规则已导入为单站线路：") + entry.name
    }
}

/// 关于呱壳 — version and both runtime statuses live here (moved out
/// of the settings list at the user's request).
struct AboutView: View {
    var body: some View {
        SettingsPage(title: "关于呱壳") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    aboutRow("应用", "呱壳 GuageTV")
                    Divider().background(Color.white.opacity(0.12))
                    aboutRow("版本", SettingsView.buildLabel)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    aboutRow("Python 运行时", PythonRuntime.shared.statusText)
                    Divider().background(Color.white.opacity(0.12))
                    aboutRow("JS 运行时", "drpy2 3.9.52 · JavaScriptCore")
                }
            }
            Text("个人自用壳：内容来自你自己导入的线路与文件，呱壳不提供任何影视内容。")
                .font(.footnote).foregroundStyle(Theme.textDim)
        }
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.white)
            Spacer()
            Text(value).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.trailing)
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
