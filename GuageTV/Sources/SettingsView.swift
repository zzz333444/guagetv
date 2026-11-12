import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 设置 (Settings) — Rex-style grouped glass cards. The four quick tiles
/// open real setting pages （播放引擎 / 画面填充 / 操控步长 / 字幕大小）,
/// all persisted with AppStorage and honoured by the player.
struct SettingsView: View {
    @Binding var config: TVBoxConfig?
    @State private var configURL = ""
    @State private var status = "还没有导入配置"
    @AppStorage("jarProxyURL") private var jarProxyURL = ""
    @AppStorage("jarProxyToken") private var jarProxyToken = ""
    @AppStorage("drive.quark_cookie") private var driveQuarkCookie = ""
    @AppStorage("drive.uc_cookie") private var driveUcCookie = ""
    @AppStorage("drive.uc_token") private var driveUcToken = ""
    @AppStorage("drive.aliyun") private var driveAliyun = ""
    @AppStorage("drive.baidu") private var driveBaidu = ""
    @AppStorage("drive.bili_cookie") private var driveBiliCookie = ""
    @AppStorage("drive.xunlei") private var driveXunlei = ""
    @State private var jarTestNote = ""
    @State private var entries: [ConfigLibrary.Entry] = []
    @State private var showFileImporter = false

    /// Bump on every shipped build so screenshots self-identify.
    static let buildLabel = "v1.24 · 网盘播放修复"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.largeTitle.bold()).foregroundStyle(Theme.text)
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
                                    .foregroundStyle(Theme.text)
                            }
                            Text(status).font(.footnote).foregroundStyle(Theme.textDim)
                            if let config {
                                Text("已加载 \(config.sites.count) 个站点 · \(config.lives?.count ?? 0) 个直播源")
                                    .font(.footnote).foregroundStyle(Theme.textDim)
                            }
                        }
                    }

                    group(title: "Jar 代理") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("JarProxy 地址：http://192.168.1.8:9977", text: $jarProxyURL)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            TextField("口令（服务器开启校验时填，平时留空）", text: $jarProxyToken)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.footnote.monospaced())
                            HStack(spacing: 10) {
                                Button("测试连接") {
                                    Task { jarTestNote = await JarProxyClient.healthCheck() }
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Theme.glass, in: Capsule())
                                .foregroundStyle(Theme.text)
                                if !jarTestNote.isEmpty {
                                    Text(jarTestNote).font(.footnote).foregroundStyle(Theme.textDim)
                                }
                            }
                            Text("Jar（csp_）站点不在手机上跑，而是转发到你自己部署的 JarProxy 服务器（JDK）上执行。填好地址后，资源库里的 Jar 站点直接解锁。")
                                .font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }

                    group(title: "网盘配置") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("网盘线路解析分享链接时要用你自己网盘的登录凭证，和 FongMi「配置中心」里填的是同一套。只保存在本机，打开 Jar 站点时经加密连接发给你的 JarProxy 使用；不用的盘留空即可。")
                                .font(.footnote).foregroundStyle(Theme.textDim)
                            driveField("夸克 Cookie", $driveQuarkCookie)
                            driveField("UC Cookie", $driveUcCookie)
                            driveField("UC Token", $driveUcToken)
                            driveField("阿里云盘 Refresh Token", $driveAliyun)
                            driveField("百度网盘 Cookie", $driveBaidu)
                            driveField("Bilibili Cookie", $driveBiliCookie)
                            driveField("迅雷 Token", $driveXunlei)
                            Button("清空全部网盘配置", role: .destructive) {
                                driveQuarkCookie = ""; driveUcCookie = ""; driveUcToken = ""
                                driveAliyun = ""; driveBaidu = ""; driveBiliCookie = ""; driveXunlei = ""
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }

                    if !entries.isEmpty {
                        group(title: "配置库") {
                            ForEach(entries) { entry in
                                HStack(spacing: 10) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(Theme.textDim).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).foregroundStyle(Theme.text).lineLimit(1)
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
                                        .foregroundStyle(Theme.text)
                                    }
                                    Button {
                                        refreshEntry(entry)
                                    } label: {
                                        Image(systemName: "arrow.clockwise").foregroundStyle(Theme.textDim)
                                    }
                                    Button(role: .destructive) {
                                        config = ConfigLibrary.remove(id: entry.id)
                                        entries = ConfigLibrary.entries()
                                        status = "已删除 \(entry.name)"
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.red.opacity(0.85))
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        if let source = ConfigLibrary.sourceURL(id: entry.id) {
                                            UIPasteboard.general.string = source
                                            status = "已复制 \(entry.name) 的地址"
                                        }
                                    } label: { Label("复制地址", systemImage: "doc.on.doc") }
                                    Button { refreshEntry(entry) } label: {
                                        Label("刷新", systemImage: "arrow.clockwise")
                                    }
                                    Button(role: .destructive) {
                                        config = ConfigLibrary.remove(id: entry.id)
                                        entries = ConfigLibrary.entries()
                                        status = "已删除 \(entry.name)"
                                    } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                        }
                    }

                    group(title: "使用偏好") {
                        NavigationLink { AppearanceSettingsView() } label: {
                            row(icon: "paintbrush", title: "外观与交互", value: "")
                        }
                        .buttonStyle(.plain)
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
            .sheet(isPresented: $showFileImporter) {
                DocumentPicker(
                    onPick: { url in Task { await importPickedFile(url) } },
                    onCancel: { status = "已取消文件导入" })
                    .ignoresSafeArea()
            }
        }
    }

    private func quickTile(icon: String, title: String) -> some View {
        GlassCard(padding: 12) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.text)
                Text(title).font(.footnote).foregroundStyle(Theme.text.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func driveField(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(Theme.text)
            TextField(title, text: value)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote.monospaced())
        }
    }

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Theme.section)
            GlassCard { VStack(alignment: .leading, spacing: 12) { content() } }
        }
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.textDim).frame(width: 22)
            Text(title).foregroundStyle(Theme.text)
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
    /// 刷新一条线路：按原地址重新拉取、校验、覆盖本地副本；
    /// 正在用的线路刷新后立即换上新内容。
    private func refreshEntry(_ entry: ConfigLibrary.Entry) {
        guard let source = ConfigLibrary.sourceURL(id: entry.id),
              let url = URL(string: source) else {
            status = "这条线路没有来源地址，刷新不了"
            return
        }
        status = "正在刷新 \(entry.name)…"
        Task {
            do {
                let data = try await NetFetch.dataForConfig(from: url)
                let parsed = try ConfigLoader.load(from: data)
                let updated = ConfigLibrary.add(data: data, sourceURL: source, siteCount: parsed.sites.count)
                entries = ConfigLibrary.entries()
                if updated.id == ConfigLibrary.activeID() { config = parsed }
                status = "已刷新 \(entry.name)：\(parsed.sites.count) 个站点"
            } catch {
                status = "刷新失败：\(error.localizedDescription)"
            }
        }
    }

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

    /// The UIKit picker hands over an asCopy copy in our own tmp
    /// directory, so reading needs no security-scope dance; every
    /// outcome lands in the status line (nothing fails silently).
    private func importPickedFile(_ fileURL: URL) async {
        let ext = fileURL.pathExtension.lowercased()
        do {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
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

/// UIKit document picker (asCopy). SwiftUI's .fileImporter left
/// files un-tappable for this app's side-loaded installs, so file
/// picking goes through UIDocumentPickerViewController directly:
/// any file type is selectable, the copy lands in our sandbox, and
/// cancel is reported like any other outcome.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

/// 外观与交互 — theme mode first (the app's surfaces are adaptive;
/// the player itself always stays dark).
struct AppearanceSettingsView: View {
    @AppStorage("themeMode.v1") private var themeMode = "dark"
    @AppStorage("tabShowRecords") private var showRecordsTab = true
    @AppStorage("tabShowLibrary") private var showLibraryTab = true

    var body: some View {
        SettingsPage(title: "外观与交互") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("外观模式").font(.headline).foregroundStyle(Theme.text)
                    Picker("外观", selection: $themeMode) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Text("播放器始终用深色，不受这里影响。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("底部导航栏").font(.headline).foregroundStyle(Theme.text)
                    Toggle("显示「记录」", isOn: $showRecordsTab)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("显示「资源库」", isOn: $showLibraryTab)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("「发现」和「设置」固定显示。关掉正在看的页会自动回到发现。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
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
            Text(title).foregroundStyle(Theme.text)
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 播放： default player engine — "auto" picks by file extension.
struct PlaySettingsView: View {
    @AppStorage("enginePreference") private var engine = "auto"
    @AppStorage("skipIntroSeconds") private var skipIntroSeconds = 0
    @AppStorage("skipOutroSeconds") private var skipOutroSeconds = 0

    var body: some View {
        SettingsPage(title: "播放") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("默认播放引擎").font(.headline).foregroundStyle(Theme.text)
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
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("跳过片头片尾").font(.headline).foregroundStyle(Theme.text)
                    SkipSecondsEditor(title: "片头跳过", seconds: $skipIntroSeconds)
                    SkipSecondsEditor(title: "片尾跳过", seconds: $skipOutroSeconds)
                    Text("每集开始自动快进片头设定的秒数；片尾剩余不足设定秒数时自动切下一集。0 = 关闭。续播时以续播位置为准，不再叠加跳片头。")
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
                    Text("画面填充（mpv 引擎）").font(.headline).foregroundStyle(Theme.text)
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
                    Text("双击快进/快退（mpv 引擎）").font(.headline).foregroundStyle(Theme.text)
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
                    Text("字幕大小（mpv 引擎）").font(.headline).foregroundStyle(Theme.text)
                    Slider(value: $scale, in: 0.5...2.0, step: 0.1)
                        .tint(Theme.text)
                    HStack {
                        Text("小").font(.caption).foregroundStyle(Theme.textDim)
                        Spacer()
                        Text(String(format: "%.0f%%", scale * 100))
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
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

/// Per-second skip editor: a 0–300 s slider (1 s steps) plus preset
/// chips. Used by 播放 settings and by the in-player skip sheet, both
/// bound to the same AppStorage keys, so a change anywhere applies
/// everywhere (outro checks read the value live).
struct SkipSecondsEditor: View {
    let title: String
    @Binding var seconds: Int
    private let presets = [0, 30, 60, 90, 120, 180]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.text)
                Spacer()
                Text(seconds == 0 ? "关" : "\(seconds) 秒")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { Double(seconds) },
                                  set: { seconds = Int($0.rounded()) }),
                   in: 0...300, step: 1)
                .tint(Theme.accent)
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button(preset == 0 ? "关" : "\(preset)") { seconds = preset }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(seconds == preset ? Theme.accent : Theme.glass, in: Capsule())
                        .foregroundStyle(seconds == preset ? .white : Theme.text)
                }
            }
        }
    }
}
