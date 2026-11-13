import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 设置 (Settings) — Rex-style grouped glass cards. The four quick tiles
/// open real setting pages （播放引擎 / 画面填充 / 操控步长 / 字幕大小）,
/// all persisted with AppStorage and honoured by the player.
struct SettingsView: View {
    @Binding var config: TVBoxConfig?
    @AppStorage("jarProxyURL") private var jarProxyURL = ""
    @AppStorage("tmdb.enabled") private var tmdbEnabled = false
    @State private var entries: [ConfigLibrary.Entry] = []
    @State private var cacheSummary = "计算中…"

    /// 网盘入口行的摘要：任一网盘凭证非空即「已配置」（只读
    /// UserDefaults 判断，不在主页持有七个字段的绑定）。
    private var driveConfigured: Bool {
        let keys = ["drive.quark_cookie", "drive.uc_cookie", "drive.uc_token",
                    "drive.aliyun", "drive.baidu", "drive.bili_cookie", "drive.xunlei"]
        return keys.contains {
            !(UserDefaults.standard.string(forKey: $0) ?? "")
                .trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Bump on every shipped build so screenshots self-identify.
    static let buildLabel = "v1.32 · 分类直达与详情 TMDB"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.largeTitle.bold()).foregroundStyle(Theme.text)

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

                    group(title: "配置") {
                        NavigationLink { TVBoxConfigSettingsView(config: $config) } label: {
                            row(icon: "link", title: "TVBox 配置",
                                value: config.map { "\($0.sites.count) 个站点" } ?? "未导入")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { ConfigLibrarySettingsView(config: $config) } label: {
                            row(icon: "square.stack.3d.up", title: "配置库",
                                value: "\(entries.count) 条线路")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { JarProxySettingsView() } label: {
                            row(icon: "server.rack", title: "Jar 代理",
                                value: jarProxyURL.isEmpty ? "未设置" : "已设置")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { DriveSettingsView() } label: {
                            row(icon: "externaldrive", title: "网盘配置",
                                value: driveConfigured ? "已配置" : "未配置")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { TMDBSettingsView() } label: {
                            row(icon: "film", title: "TMDB 增强",
                                value: tmdbEnabled ? "开" : "关")
                        }
                        .buttonStyle(.plain)
                    }

                    group(title: "使用偏好") {
                        NavigationLink { AppearanceSettingsView() } label: {
                            row(icon: "paintbrush", title: "外观与交互", value: "")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { CacheSettingsView() } label: {
                            row(icon: "archivebox", title: "缓存管理", value: cacheSummary)
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
            .onAppear { entries = ConfigLibrary.entries() }
            .task { cacheSummary = CacheManager.format(await CacheManager.totalSize()) }
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

}

/// Titled glass-card group shared by the settings sub-pages (the
/// main page keeps its own identical helper).
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Theme.textDim)
            GlassCard { VStack(alignment: .leading, spacing: 12) { content } }
        }
    }
}

// MARK: - TVBox 配置（万能导入 + 导入确认弹窗）

/// One staged import: bytes are fetched/parsed first, then the user
/// confirms (and may edit) the line name before anything is stored.
private struct PendingImport: Identifiable {
    let id = UUID()

    enum Payload {
        /// A full config (TVBox JSON or 猫源）, from URL or file.
        case config(data: Data, sourceText: String, parsed: TVBoxConfig,
                    isMaoYuan: Bool, fromFile: Bool)
        /// A single .py spider / .js rule file, from URL or file.
        case singleFile(data: Data, fileName: String, kind: String)
    }

    var payload: Payload
}

/// 「导入确认」sheet: editable name pre-filled with the auto-detected
/// name; 导入 commits, 取消 (button or swipe) discards.
private struct ImportConfirmSheet: View {
    @Binding var name: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入确认").font(.title3.bold()).foregroundStyle(Theme.text)
            Text("导入后线路就叫这个名字，可以在这里改；之后也能在线路卡上长按改备注名。")
                .font(.footnote).foregroundStyle(Theme.textDim)
            TextField("线路名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack(spacing: 10) {
                Button("取消") { onCancel() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Theme.glass, in: Capsule())
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("导入") { onConfirm() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AmbientBackground(imageURL: nil))
        .presentationDetents([.height(280)])
    }
}

/// TVBox 配置 sub-page: the 万能导入 (address + file) and the loaded
/// config status. Imports are two-stage — fetch/parse first, then an
/// 「导入确认」sheet names the line, then it lands in the library.
struct TVBoxConfigSettingsView: View {
    @Binding var config: TVBoxConfig?
    @State private var configURL = ""
    @State private var status = "还没有导入配置"
    @State private var showFileImporter = false
    @State private var pendingImport: PendingImport?
    @State private var importName = ""
    @State private var importHandled = false

    var body: some View {
        SettingsPage(title: "TVBox 配置") {
            SettingsGroup(title: "万能导入") {
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
        }
        .onAppear {
            if configURL.isEmpty, let saved = ConfigStore.savedSourceURL() {
                configURL = saved
            }
        }
        .sheet(isPresented: $showFileImporter) {
            DocumentPicker(
                onPick: { url in Task { await importPickedFile(url) } },
                onCancel: { status = "已取消文件导入" })
                .ignoresSafeArea()
        }
        .sheet(item: $pendingImport, onDismiss: {
            if !importHandled { status = "已取消导入" }
        }) { pending in
            ImportConfirmSheet(name: $importName,
                               onConfirm: { commitImport(pending) },
                               onCancel: { pendingImport = nil })
        }
    }

    // MARK: staging

    private func stage(_ pending: PendingImport, prefill: String) {
        importName = prefill
        importHandled = false
        pendingImport = pending
        status = "待确认导入名称"
    }

    /// Address-import prefill: the URL's file name without extension,
    /// falling back to the host.
    private func prefillName(forURL url: URL) -> String {
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        if !base.isEmpty { return base }
        return url.host ?? "配置"
    }

    /// File-import prefill: the picked file's real name without its
    /// extension (a .py import shows e.g.「51X」for 51X.py).
    private func prefillName(forFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    /// The confirmed name becomes the line's name. ConfigLibrary.add
    /// derives entry.name from the source URL, so a differing user
    /// name is written through the existing alias layer — shownName
    /// (what every screen displays) picks it up, storage untouched.
    private func applyImportedName(_ name: String, to entry: ConfigLibrary.Entry) {
        guard !name.isEmpty, name != entry.name else { return }
        ConfigLibrary.setAlias(name, for: entry.id)
    }

    private func commitImport(_ pending: PendingImport) {
        importHandled = true
        let name = importName.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingImport = nil
        Task {
            switch pending.payload {
            case let .config(data, sourceText, parsed, isMaoYuan, fromFile):
                config = parsed
                let entry = ConfigLibrary.add(data: data, sourceURL: sourceText,
                                              siteCount: parsed.sites.count)
                applyImportedName(name, to: entry)
                let shown = ConfigLibrary.shownName(entry)
                switch (isMaoYuan, fromFile) {
                case (true, true): status = "猫源文件已转换并加入配置库：\(shown)"
                case (true, false): status = "猫源已转换并加入配置库：\(shown)"
                case (false, true): status = "配置文件已加入配置库：\(shown)"
                case (false, false): status = "已加入配置库并启用：\(shown)"
                }
            case let .singleFile(data, fileName, kind):
                do {
                    try await registerSingleFile(data: data, fileName: fileName,
                                                 kind: kind, displayName: name)
                } catch {
                    status = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: fetching

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
            status = "下载中…"
            do {
                let data = try await NetFetch.data(from: url)
                let fileName = url.lastPathComponent.isEmpty
                    ? (pathExt == "py" ? "spider.py" : "rule.js") : url.lastPathComponent
                stage(PendingImport(payload: .singleFile(data: data, fileName: fileName, kind: pathExt)),
                      prefill: prefillName(forFileName: fileName))
            } catch {
                status = "导入失败：\(error.localizedDescription)"
            }
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
                stage(PendingImport(payload: .config(data: data, sourceText: text, parsed: parsed,
                                                     isMaoYuan: true, fromFile: false)),
                      prefill: prefillName(forURL: url))
            } else {
                let parsed = try ConfigLoader.load(from: data)
                stage(PendingImport(payload: .config(data: data, sourceText: text, parsed: parsed,
                                                     isMaoYuan: false, fromFile: false)),
                      prefill: prefillName(forURL: url))
            }
        } catch {
            let head = String(decoding: data.prefix(60), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            status = "加载失败：内容无法识别（\(data.count) 字节，开头：\(head)）"
        }
    }

    /// The UIKit picker hands over an asCopy copy in our own tmp
    /// directory, so reading needs no security-scope dance; every
    /// outcome lands in the status line (nothing fails silently).
    /// Parsed first, then staged — the confirm sheet appears once the
    /// picker sheet has finished dismissing.
    private func importPickedFile(_ fileURL: URL) async {
        let ext = fileURL.pathExtension.lowercased()
        do {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL)
            var pending: PendingImport?
            var prefill = ""
            switch ext {
            case "py", "js":
                pending = PendingImport(payload: .singleFile(data: data,
                                                             fileName: fileURL.lastPathComponent,
                                                             kind: ext))
                prefill = prefillName(forFileName: fileURL.lastPathComponent)
            case "json", "txt", "":
                let sourceText = "file-import://" + fileURL.lastPathComponent
                if MaoYuanAdapter.looksLikeMaoYuan(data) {
                    let parsed = try MaoYuanAdapter.convert(from: data)
                    pending = PendingImport(payload: .config(data: data, sourceText: sourceText,
                                                             parsed: parsed, isMaoYuan: true,
                                                             fromFile: true))
                } else {
                    let parsed = try ConfigLoader.load(from: data)
                    pending = PendingImport(payload: .config(data: data, sourceText: sourceText,
                                                             parsed: parsed, isMaoYuan: false,
                                                             fromFile: true))
                }
                prefill = prefillName(forFileName: fileURL.lastPathComponent)
            default:
                status = "不支持的文件类型：.\(ext)（可导入 .json / .py / .js）"
            }
            if let pending {
                try? await Task.sleep(nanoseconds: 350_000_000)
                stage(pending, prefill: prefill)
            }
        } catch {
            status = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Store the file and add its synthetic one-site config line.
    /// The on-disk file name (and the site key) stay file-derived so
    /// re-imports refresh in place; displayName is what the site and
    /// the line are called.
    private func registerSingleFile(data: Data, fileName: String, kind: String,
                                    displayName: String) async throws {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dirName = kind == "py" ? "spiders" : "jsrules"
        let dir = support.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        let base = (fileName as NSString).deletingPathExtension
        let siteName = displayName.isEmpty ? base : displayName
        let site: [String: Any]
        if kind == "py" {
            site = ["key": "pyfile_" + base, "name": siteName, "type": 3,
                    "api": "local-spider://" + fileName, "searchable": 1, "quickSearch": 1]
        } else {
            site = ["key": "jsfile_" + base, "name": siteName, "type": 3,
                    "api": "bundled-engine.js", "ext": "local-rule://" + fileName,
                    "searchable": 1, "quickSearch": 1]
        }
        let configData = try JSONSerialization.data(withJSONObject: ["sites": [site]])
        let parsed = try ConfigLoader.load(from: configData)
        config = parsed
        let entry = ConfigLibrary.add(data: configData,
                                      sourceURL: (kind == "py" ? "py-import://" : "js-import://") + fileName,
                                      siteCount: 1)
        applyImportedName(displayName, to: entry)
        status = (kind == "py" ? "py 文件已导入为单站线路：" : "JS 规则已导入为单站线路：")
            + ConfigLibrary.shownName(entry)
    }
}

// MARK: - Jar 代理

struct JarProxySettingsView: View {
    @AppStorage("jarProxyURL") private var jarProxyURL = ""
    @AppStorage("jarProxyToken") private var jarProxyToken = ""
    @State private var jarTestNote = ""

    var body: some View {
        SettingsPage(title: "Jar 代理") {
            SettingsGroup(title: "Jar 代理") {
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
        }
    }
}

// MARK: - 网盘配置

struct DriveSettingsView: View {
    @AppStorage("drive.quark_cookie") private var driveQuarkCookie = ""
    @AppStorage("drive.uc_cookie") private var driveUcCookie = ""
    @AppStorage("drive.uc_token") private var driveUcToken = ""
    @AppStorage("drive.aliyun") private var driveAliyun = ""
    @AppStorage("drive.baidu") private var driveBaidu = ""
    @AppStorage("drive.bili_cookie") private var driveBiliCookie = ""
    @AppStorage("drive.xunlei") private var driveXunlei = ""

    var body: some View {
        SettingsPage(title: "网盘配置") {
            SettingsGroup(title: "网盘配置") {
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
}

// MARK: - TMDB 增强

struct TMDBSettingsView: View {
    @AppStorage("tmdb.enabled") private var tmdbEnabled = false
    @AppStorage("tmdb.base") private var tmdbBase = ""
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @State private var tmdbTestNote = ""

    var body: some View {
        SettingsPage(title: "TMDB 增强") {
            SettingsGroup(title: "TMDB 增强") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用 TMDB 增强", isOn: $tmdbEnabled)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    TextField("API 地址（留空用官方 https://api.themoviedb.org）", text: $tmdbBase)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("API 密钥（v3，在 themoviedb.org 免费申请）", text: $tmdbKey)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.footnote.monospaced())
                    HStack(spacing: 10) {
                        Button("测试连接并保存") {
                            Task { tmdbTestNote = await TMDBClient.testConnection() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(Theme.text)
                        if !tmdbTestNote.isEmpty {
                            Text(tmdbTestNote).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    Text("开启后，首页大图会用 TMDB 的高清剧照、剧情简介和 TMDB 评分来增强（按片名+年份匹配，结果缓存在本机）。密钥只保存在本机。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

// MARK: - 配置库

struct ConfigLibrarySettingsView: View {
    @Binding var config: TVBoxConfig?
    @State private var entries: [ConfigLibrary.Entry] = []
    @State private var groupsList: [ConfigLibrary.Group] = []
    @State private var status = ""
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var deletingGroup: ConfigLibrary.Group?

    var body: some View {
        SettingsPage(title: "配置库") {
            SettingsGroup(title: "配置库") {
                VStack(alignment: .leading, spacing: 12) {
                    if !status.isEmpty {
                        Text(status).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    if entries.isEmpty {
                        Text("还没有导入任何线路。先到「TVBox 配置」里导入地址或文件，导入过的线路都会存放在这里。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    HStack {
                        Spacer()
                        Button {
                            newGroupName = ""
                            showNewGroup = true
                        } label: {
                            Label("新建分组", systemImage: "plus")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.glass, in: Capsule())
                        }
                    }
                }
            }
            ForEach(sections()) { section in
                sectionBlock(section)
            }
        }
        .onAppear { reload() }
        .alert("新建分组", isPresented: $showNewGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    ConfigLibrary.addGroup(name: name)
                    status = "已新建分组「\(name)」"
                    reload()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删除分组", isPresented: Binding(get: { deletingGroup != nil },
                                                set: { if !$0 { deletingGroup = nil } })) {
            Button("删除", role: .destructive) {
                if let group = deletingGroup {
                    ConfigLibrary.removeGroup(id: group.id)
                    status = "已删除分组「\(group.name)」，组内线路已回到未分组"
                }
                deletingGroup = nil
                reload()
            }
            Button("取消", role: .cancel) { deletingGroup = nil }
        } message: {
            if let group = deletingGroup {
                Text("删除分组「\(group.name)」？组内线路不会被删，会回到未分组。")
            }
        }
    }

    private func reload() {
        entries = ConfigLibrary.entries()
        groupsList = ConfigLibrary.groups()
    }

    /// One display section: a user group (long-press its header to
    /// delete), the automatic Python 文件 group, or 未分组. Same
    /// grouping data the Library page uses (ConfigLibrary groups).
    private struct LineSection: Identifiable {
        let id: String
        let title: String
        let group: ConfigLibrary.Group?
        let items: [ConfigLibrary.Entry]
    }

    private func sections() -> [LineSection] {
        var out: [LineSection] = []
        for group in groupsList {
            let items = entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == group.id }
            if !items.isEmpty {
                out.append(LineSection(id: group.id, title: group.name, group: group, items: items))
            }
        }
        let pyItems = entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == ConfigLibrary.pyAutoGroupID }
        if !pyItems.isEmpty {
            out.append(LineSection(id: ConfigLibrary.pyAutoGroupID, title: "Python 文件", group: nil, items: pyItems))
        }
        let loose = entries.filter { ConfigLibrary.effectiveGroupID(for: $0) == nil }
        if !loose.isEmpty {
            out.append(LineSection(id: ConfigLibrary.noGroupID, title: "未分组", group: nil, items: loose))
        }
        return out
    }

    @ViewBuilder
    private func sectionBlock(_ section: LineSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.title).font(.headline).foregroundStyle(Theme.textDim)
                Spacer()
                if section.group != nil {
                    Text("长按可删除分组").font(.caption2).foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.6) {
                if let group = section.group { deletingGroup = group }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(section.items) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: ConfigLibrary.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Theme.textDim).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(ConfigLibrary.shownName(entry)).foregroundStyle(Theme.text).lineLimit(1)
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
                    reload()
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
                reload()
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
            Menu("移动到分组") {
                Button("未分组") {
                    ConfigLibrary.setGroup(entryID: entry.id, groupID: ConfigLibrary.noGroupID)
                    reload()
                }
                if ConfigLibrary.isPyFileEntry(entry) {
                    Button("Python 文件（自动）") {
                        ConfigLibrary.setGroup(entryID: entry.id, groupID: ConfigLibrary.pyAutoGroupID)
                        reload()
                    }
                }
                ForEach(groupsList) { group in
                    Button(group.name) {
                        ConfigLibrary.setGroup(entryID: entry.id, groupID: group.id)
                        reload()
                    }
                }
            }
            Button(role: .destructive) {
                config = ConfigLibrary.remove(id: entry.id)
                reload()
                status = "已删除 \(entry.name)"
            } label: { Label("删除", systemImage: "trash") }
        }
    }

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
                reload()
                if updated.id == ConfigLibrary.activeID() { config = parsed }
                status = "已刷新 \(entry.name)：\(parsed.sites.count) 个站点"
            } catch {
                status = "刷新失败：\(error.localizedDescription)"
            }
        }
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
    @AppStorage("haptics.enabled") private var hapticsEnabled = true

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
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("交互").font(.headline).foregroundStyle(Theme.text)
                    Toggle("触控反馈", isOn: $hapticsEnabled)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("切换底部导航等操作时轻震一下；关掉后全局不再震动。")
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
    @AppStorage("mpvRenderer") private var mpvRenderer = "auto"
    @AppStorage("player.showSpeed") private var showSpeed = true
    @AppStorage("player.showResolution") private var showResolution = true
    @AppStorage("player.showPiPButton") private var showPiPButton = true
    @AppStorage("player.showAirPlayButton") private var showAirPlayButton = true
    @AppStorage("player.showEpisodeButton") private var showEpisodeButton = true
    @AppStorage("player.longPressBoost") private var longPressBoost = true
    @AppStorage("player.autoNext") private var autoNext = true

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
                    Text("mpv 渲染方式").font(.headline).foregroundStyle(Theme.text)
                    Picker("渲染", selection: $mpvRenderer) {
                        Text("Metal（GPU）").tag("auto")
                        Text("软件").tag("sw")
                    }
                    .pickerStyle(.segmented)
                    Text("Metal：画面由 GPU 直出，省电不发热，4K 和 HDR 更好；个别片源画面异常时切回「软件」。下次打开播放器生效。")
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
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("按钮与功能").font(.headline).foregroundStyle(Theme.text)
                    Toggle("网速显示", isOn: $showSpeed)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("分辨率显示", isOn: $showResolution)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("画中画按钮", isOn: $showPiPButton)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("投屏按钮", isOn: $showAirPlayButton)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("选集按钮", isOn: $showEpisodeButton)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("长按倍速", isOn: $longPressBoost)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("自动播放下一集", isOn: $autoNext)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("关掉的项不再出现在播放页，对应功能同时停用；下次打开播放器生效。")
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
