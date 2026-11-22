import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 设置 (Settings) — Rex-style grouped glass cards. The four quick tiles
/// open real setting pages （播放引擎 / 画面填充 / 操控步长 / 字幕大小）,
/// all persisted with AppStorage and honoured by the player.
struct SettingsView: View {
    @Binding var config: TVBoxConfig?
    /// v2.15 startup: mounted at launch in a hidden tab — the
    /// cache-size walk (totalSize walks URLCache/tmp/caches) used
    /// to run before the first frame. It now waits for isActive.
    var isActive: Bool = false
    @State private var cacheWalkStarted = false
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
    static let buildLabel = "v2.36 · 稳定扫荡与备份补全"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .center)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 12) {
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
                        linkRow(icon: "link", title: "TVBox 配置",
                                value: config.map { "\($0.sites.count) 个站点" } ?? "未导入") {
                            TVBoxConfigSettingsView(config: $config)
                        }
                        rexDivider()
                        linkRow(icon: "square.stack.3d.up", title: "配置库",
                                value: "\(entries.count) 条线路") {
                            ConfigLibrarySettingsView(config: $config)
                        }
                        rexDivider()
                        linkRow(icon: "server.rack", title: "Jar 代理",
                                value: jarProxyURL.isEmpty ? "未设置" : "已设置") {
                            JarProxySettingsView()
                        }
                        rexDivider()
                        linkRow(icon: "stethoscope", title: "配置体检") {
                            HealthCheckView()
                        }
                        rexDivider()
                        linkRow(icon: "externaldrive", title: "网盘配置",
                                value: driveConfigured ? "已配置" : "未配置") {
                            DriveSettingsView()
                        }
                        rexDivider()
                        linkRow(icon: "film", title: "TMDB 增强",
                                value: tmdbEnabled ? "开" : "关") {
                            TMDBSettingsView()
                        }
                    }

                    group(title: "使用偏好") {
                        linkRow(icon: "paintbrush", title: "外观与交互") {
                            AppearanceSettingsView()
                        }
                        rexDivider()
                        linkRow(icon: "externaldrive.badge.timemachine", title: "备份与恢复") {
                            BackupView()
                        }
                        rexDivider()
                        linkRow(icon: "lock.shield", title: "安全（App 锁）") {
                            SecuritySettingsView()
                        }
                        rexDivider()
                        linkRow(icon: "tv.and.hdd", title: "媒体服务器（Emby / WebDAV）") {
                            MediaServerSettingsView()
                        }
                        rexDivider()
                        linkRow(icon: "archivebox", title: "缓存管理", value: cacheSummary) {
                            CacheSettingsView()
                        }
                        rexDivider()
                        linkRow(icon: "square.grid.2x2", title: "模块") {
                            ModulesView()
                        }
                    }

                    group(title: "应用") {
                        linkRow(icon: "clock.arrow.circlepath", title: "更新日志",
                                // v2.20: was hardcoded "v1.86" since the
                                // page was added — the row lagged 34
                                // versions behind the real changelog.
                                // Derive it from buildLabel so it can
                                // never go stale again.
                                value: Self.buildLabel.components(separatedBy: " ").first ?? "v2.21") {
                            ChangelogView()
                        }
                        rexDivider()
                        linkRow(icon: "info.circle", title: "关于呱壳") {
                            AboutView()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .background(AmbientBackground(imageURL: nil))
            .onAppear { entries = ConfigLibrary.entries() }
            .onChange(of: isActive) { active in
                // v2.15: the cache-size disk walk starts only when
                // the settings tab is actually opened, not at cold
                // start while this view is mounted hidden.
                if active, !cacheWalkStarted {
                    cacheWalkStarted = true
                    Task { cacheSummary = CacheManager.format(await CacheManager.totalSize()) }
                }
            }
        }
    }

    private func quickTile(icon: String, title: String) -> some View {
        GlassCard(padding: 16) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.text)
                Text(title).font(.subheadline).foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Rex-style row link: line icon + title + value + chevron.
    private func linkRow<Destination: View>(icon: String, title: String, value: String = "",
                                            @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            row(icon: icon, title: title, value: value)
        }
        .buttonStyle(.plain)
    }

    /// Rex-style inset separator: starts where the row text starts
    /// (icon 22pt + 10pt gap), not at the card edge.
    private func rexDivider() -> some View {
        Rectangle().fill(Theme.glassStroke).frame(height: 1).padding(.leading, 32)
    }

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Theme.section)
            GlassCard { VStack(alignment: .leading, spacing: 10) { content() } }
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
            // v2.20: was Theme.textDim while the main page's group
            // titles use Theme.section — sub-page titles sat a
            // shade dimmer than the main page for no reason.
            Text(title).font(.headline).foregroundStyle(Theme.section)
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
    @AppStorage("configAutoRefresh") private var configAutoRefresh = true
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
                    Button {
                        Haptics.tap()
                        configURL = "https://raw.githubusercontent.com/qist/tvbox/master/jsm.json"
                        Task { await load() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                            Text("一键导入推荐配置（qist jsm）")
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassCapsule()
                        .foregroundStyle(Theme.text)
                    }
                    .buttonStyle(.plain)
                    Text("推荐配置已验活：162 个站点（Jar 113 · JS 25 · py 9 · CMS 15）+ 29 条解析 + 3 个直播源，点上面按钮直接走导入确认。")
                        .font(.caption).foregroundStyle(Theme.textDim)
                    Text(status).font(.footnote).foregroundStyle(Theme.textDim)
                    if let config {
                        Text("已加载 \(config.sites.count) 个站点 · \(config.lives?.count ?? 0) 个直播源")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                }
            }
            SettingsGroup(title: "配置更新") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("配置自动更新", isOn: $configAutoRefresh)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("订阅地址导入的配置（蝴蝶、jsm 这类）每 12 小时自动拉一次新版，内容确实变了而且能正常解析才替换，备注名和分组不受影响。从文件导入的配置不参与。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
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
                onPick: { urls in
                    Task {
                        if urls.count == 1, let first = urls.first {
                            await importPickedFile(first)
                        } else {
                            await importPickedFiles(urls)
                        }
                    }
                },
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

    /// Multi-file import (picker allows multiple selection): every
    /// file goes in directly under its file-derived name — the
    /// rename sheet is a single-file courtesy and would be unusable
    /// per file in a batch. Outcomes are summarised in one line.
    private func importPickedFiles(_ urls: [URL]) async {
        status = "批量导入中（\(urls.count) 个文件）…"
        var okNames: [String] = []
        var failed: [String] = []
        for fileURL in urls {
            let ext = fileURL.pathExtension.lowercased()
            do {
                let scoped = fileURL.startAccessingSecurityScopedResource()
                let data = try Data(contentsOf: fileURL)
                if scoped { fileURL.stopAccessingSecurityScopedResource() }
                switch ext {
                case "py", "js":
                    try await registerSingleFile(data: data,
                                                 fileName: fileURL.lastPathComponent,
                                                 kind: ext,
                                                 displayName: prefillName(forFileName: fileURL.lastPathComponent))
                    okNames.append(fileURL.lastPathComponent)
                case "json", "txt", "":
                    let parsed: TVBoxConfig
                    if MaoYuanAdapter.looksLikeMaoYuan(data) {
                        parsed = try MaoYuanAdapter.convert(from: data)
                    } else {
                        parsed = try ConfigLoader.load(from: data)
                    }
                    let entry = ConfigLibrary.add(
                        data: data,
                        sourceURL: "file-import://" + fileURL.lastPathComponent,
                        siteCount: parsed.sites.count)
                    applyImportedName(prefillName(forFileName: fileURL.lastPathComponent), to: entry)
                    okNames.append(fileURL.lastPathComponent)
                default:
                    failed.append("\(fileURL.lastPathComponent)（不支持 .\(ext)）")
                }
            } catch {
                failed.append(fileURL.lastPathComponent)
            }
        }
        var parts = ["批量导入完成：成功 \(okNames.count) 个"]
        if !okNames.isEmpty { parts.append(okNames.joined(separator: "、")) }
        if !failed.isEmpty { parts.append("失败 \(failed.count) 个：\(failed.joined(separator: "、"))") }
        status = parts.joined(separator: " · ")
    }

    /// Store the file and add its synthetic one-site config line.
    /// The on-disk file name (and the site key) stay file-derived so
    /// re-imports refresh in place; displayName is what the site and
    /// the line are called.
    private func registerSingleFile(data: Data, fileName: String, kind: String,
                                    displayName: String) async throws {
        let entry = try SingleFileLine.register(data: data, fileName: fileName,
                                                kind: kind, displayName: displayName)
        config = ConfigLibrary.load(id: entry.id)
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
    // 猫源 (CatPawOpen) drive credentials: a separate set so cat
    // lines can use different accounts; empty fields fall back
    // to the shared set above at injection time (v1.77).
    @AppStorage("drive.cat.quark_cookie") private var catQuarkCookie = ""
    @AppStorage("drive.cat.uc_cookie") private var catUcCookie = ""
    @AppStorage("drive.cat.uc_token") private var catUcToken = ""
    @AppStorage("drive.cat.aliyun") private var catAliyun = ""
    @AppStorage("drive.cat.baidu") private var catBaidu = ""
    @AppStorage("drive.cat.bili_cookie") private var catBiliCookie = ""
    @AppStorage("drive.cat.xunlei") private var catXunlei = ""

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
            SettingsGroup(title: "猫源网盘") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("猫源（CatPawOpen）线路专用的网盘凭证，加载猫源站时注入它的 JS 引擎。和上面同一套账号就点「复制上面的配置」；留空的项自动用上面的配置兜底。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    driveField("夸克 Cookie", $catQuarkCookie)
                    driveField("UC Cookie", $catUcCookie)
                    driveField("UC Token", $catUcToken)
                    driveField("阿里云盘 Refresh Token", $catAliyun)
                    driveField("百度网盘 Cookie", $catBaidu)
                    driveField("Bilibili Cookie", $catBiliCookie)
                    driveField("迅雷 Token", $catXunlei)
                    Button("复制上面的配置") {
                        catQuarkCookie = driveQuarkCookie; catUcCookie = driveUcCookie
                        catUcToken = driveUcToken; catAliyun = driveAliyun
                        catBaidu = driveBaidu; catBiliCookie = driveBiliCookie
                        catXunlei = driveXunlei
                        Haptics.success()
                    }
                    .font(.footnote.weight(.semibold))
                    Button("清空猫源网盘配置", role: .destructive) {
                        catQuarkCookie = ""; catUcCookie = ""; catUcToken = ""
                        catAliyun = ""; catBaidu = ""; catBiliCookie = ""; catXunlei = ""
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
                            Haptics.tap()
                            Task {
                                tmdbTestNote = await TMDBClient.testConnection()
                                // v2.21: the note is the verdict —
                                // success gets the success buzz, any
                                // failure the error buzz.
                                if tmdbTestNote.hasPrefix("连接成功") { Haptics.success() }
                                else { Haptics.error() }
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(Theme.text)
                        if !tmdbTestNote.isEmpty {
                            Text(tmdbTestNote).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    Button {
                        Haptics.tap()
                        tmdbBase = "https://jarproxy.onrender.com/tmdb"
                        tmdbEnabled = true
                        Task { tmdbTestNote = await TMDBClient.testConnection() }
                    } label: {
                        Label("一键用 JarProxy 转发（免梯子）", systemImage: "arrow.triangle.swap")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.glass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Text("开启后，首页大图会用 TMDB 的高清剧照、剧情简介和 TMDB 评分来增强（按片名+年份匹配，结果缓存在本机）。密钥只保存在本机。地址填 JarProxy 转发（…/tmdb）时，海报图片自动走同一台服务器的 /tmdbimg 转发，数据和图片都不用梯子。")
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
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
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
    @AppStorage("tabCompact.v1") private var compactTab = false
    @AppStorage("tabShowSearch") private var showSearchTab = true
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
                    Toggle("紧凑底栏（仅图标）", isOn: $compactTab)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("显示搜索按钮", isOn: $showSearchTab)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("「发现」和「设置」固定显示。关掉正在看的页会自动回到发现；搜索按钮关掉后仍可从发现页「跨线搜索」进入。")
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

/// 更新日志 — 内置近几版改动清单（v1.86 新增）。只列已交付的
/// 改动，不写计划与未上线内容；每条一行，当前版本置顶高亮。
struct ChangelogView: View {
    private struct Entry: Identifiable {
        let version: String
        let title: String
        let lines: [String]
        var id: String { version }
    }

    private static let entries: [Entry] = [
        Entry(version: "v2.36", title: "稳定扫荡与备份补全", lines: [
            "全仓强制解包复查：try!/as! 与显式 ! 仍为零（仅剩 WKWebView 协议签名的隐式解包与 required init 的 fatalError 桩）；DLNA 的 SSDP 端口此前是唯一一处真强制解包（NWEndpoint.Port(rawValue: 1900)!），现改 guard，拿不到端口直接返回空结果、不再赌它一定合法",
            "备份补上模块：此前备份只含线路、历史与设置，恢复后已导入的模块会静默丢失（模块存在 Application Support/widgets，不在配置库里）；现备份同时打包模块 index.json 与全部 .js 源码 + fwd.* 设置（各模块存储、自检结果、内容类型自选等），恢复时写回并清掉备份里没有的旧模块文件；恢复确认框的概要数字与实际恢复内容对齐（线路按实际写回数、模块只计 .js 文件）",
            "恢复改为真覆盖：此前恢复只往 configs 目录里写文件，备份里删掉的线路文件会残留在本机；现恢复前先清掉备份里没有的旧线路文件",
            "诊断页可见性：崩溃自愈、蜘蛛错误分类、起播三段耗时此前只在导出文本里能查到，App 内只能看到一条汇总与计数；现设置 → 关于的诊断卡下方直接列出最近 8 条折叠记录（分类、次数、时间），不用导出也能定位",
            "主线程阻塞复核通过：四处信号量等待均不在主线程（JS 专用串行队列、代理后台队列、SMB 代理线程、2 秒封顶的本地代理启动，SpiderBridge 与 SMB 的 ensureStarted 调用点已在 v2.24 改走后台）；海报缓存分级（160/120/48 MB）、mpv 分级缓存、JarProxy patient 重试三条路径代码级核查通过，无改动",
            "模块运行时回归通过：JS 异常分类（超时/网络/脚本/其他四类，中文）、单次调用 60 秒封顶（定时器异常探针提前失败）、子请求 20 秒封顶、存储按模块 id 隔离（sharedCache 按命名空间共享，符合规范），均逐项核对无改动",
        ]),
        Entry(version: "v2.35", title: "播出日历与追剧联动", lines: [
            "播出日历今日标记：周条上今天所在的周芯片下方挂强调色圆点，一眼能定位今天；选中态切换走 animQuick，不再瞬间跳变；日历条目点按进模块详情的链路复核通过（FWDDetailView 既有链路），详情加载失败时除重试外新增「跨线搜索」兜底——拿片名直接去全局搜索找其他线路的同名资源",
            "追剧联动：追剧的剧在 bangumi 每日放送有当日更新时，追剧页卡片挂绿色「今日更新」胶囊，汇总行同步计数；与站点备注变化的「有更新」是两个独立信号，两者同时成立时并列显示；无 bangumi 模块时静默不显示、不报错；标题比对只做归一化相等或包含（较短一方 ≥4 字才认包含），不做模糊猜测",
            "下载页与追剧页信息互通：追剧卡片的副行显示「已下载 N 集」（按 vodName 与下载页分组同一口径精确匹配，0 集不显示）；下载页多集分组整剧下完时组头挂绿色「已下完」角标",
            "下载完成提醒只在 App 内：整剧下完时在下载页组头与记录 tab 右上角红点提示，打开记录页即视为已读、红点消失；不发系统通知（守用户「不主动提醒」的口径）；入队新集或删光已下完集时下完标记失效；单集下载行此前已有「已下载 · 大小」状态行，本轮不另加角标",
            "直播回看入口：线路 lives 带 catchup 字段的频道（用户线路 571 条里 16 条带该字段，如最强国内直播系列，模板为 append + ${b/e} 起止时间）显示回看入口——频道行挂「可回看」角标，节目单里已播完的节目出现「回看」按钮，按节目起止时刻（UTC）展开模板拼出回看地址、走同一播放器播；正在播与未开播的节目没有回看；不带 catchup 的线路维持原样。M3U 文件内的 catchup-source 逐频道属性本轮未接（需运行时抓包验证，见计划记录）",
        ]),
        Entry(version: "v2.34", title: "模块搜索并入全局搜索", lines: [
            "全局搜索新增模块来源：已导入且带 searchFunction 的模块并行参与跨线搜索，结果按模块单独成组、排在站点海报网格上方同一滚动页内；卡片复用搜索页海报样式（橙色角标改挂模块名），点按走模块既有链路 FWDDetailView（loadDetail → loadResource），不新造页面",
            "模块结果组可折叠/展开：每组带模块名与结果数角标，默认只展开第一组、其余折叠；0 结果的模块收进组底「模块无结果」折叠行（与站点无结果区同一口径），超时/失败的模块不进该区、只计入底部汇总",
            "超时与熔断沿用搜索框架口径：模块阶段在 CMS/py/JS/Jar 之后串行跑，每模块硬 15 秒上限、连续 3 个超时或失败跳过剩余模块；单模块报错只记该模块一次 miss，不污染整页；模块数计入 (已搜/总数) 进度与「搜完 N 个来源」汇总，命中数含模块结果",
            "关键词转义复核：关键词以 Swift 字符串进参数表、由 FWDRuntime.call 经 JSON 序列化后再拼进 JS 调用，引号/反斜杠/换行等符号出不了字符串字面量；官方 harness 实测：带引号、反斜杠、空格与单引号的关键词原样到达模块、issues 为 []；tmdb.js 官方示例同法复测通过",
            "点播链路端到端复核：自写 R9 测试模块（search + loadDetail + loadResource）跑官方 run-module.mjs 离线全通、issues 全为 []——搜索出条目、详情带集数与相关推荐、取流回两条线路（system/app 各一）；validate.mjs 校验该模块 0 问题",
            "模块搜索调用与模块页自身搜索同一套参数组合（fwdCombineParams：keyword/query/searchKeyword 三别名、第 1 页、已保存全局参数），模块在哪个搜索框被搜到、行为一致；无搜索入口的模块不参与；只有模块、没有站点配置时搜索页也可正常工作",
        ]),
        Entry(version: "v2.33", title: "播放器与动效收尾", lines: [
            "动画时长全仓统一：此前 0.18 / 0.2 / 0.22 / 0.25 / 0.3 / 0.35 六档字面量散在 16 个文件，同一手势各页手感不一；现收进 Theme 四个常量（animQuick 0.2 展开/切换、animStandard 0.25 内容切换与加载交叉淡入淡出、animFade 0.35 图片淡入、animChrome 0.25 播放器 chrome/HUD/toast），数值与旧版一致、只换名；唯一例外是发现页 hero 自动轮播的 0.45 秒慢切（定时轮播，不参与手势统一）",
            "播放器 chrome 复核：横屏控制层与选集态逐项核对——竖屏紧凑度量（图标 32pt、间距收窄）与横屏宽松度量此前 v1.57 已分档，本轮复核无溢出；chrome/HUD/toast 此前用无参 withAnimation（系统默认曲线），现统一走 animChrome；选集面板的分段 chips 与正倒序切换此前瞬间跳变，现加 animQuick 过渡；详情页选集分段与正倒序同步加动画",
            "骨架屏闪烁点清零：v2.24「19 处统一加淡出」核查发现只在发现页与 jar 页真正落地，其余骨架分支（Emby、CMS/py/JS 浏览页、搜索页、播出日历）出现与消失都是硬切；现过渡直接长在三个骨架组件本体上（SkeletonPosterGrid / SkeletonRowList / SkeletonHero），各父页已有的 loading 动画驱动交叉淡入淡出；骨架 hero 的浅色占位条此前手写白 0.25/0.18（浅色底上几乎看不见），改走主题文字透明度",
            "触感矩阵复核：播放器此前整条底栏与顶栏按钮都没有触感（播放/切集/换引擎/倍速/画质/选集/截图/PiP/设置），现按五类补齐（播放/投屏等主操作 medium、切集/选集/倍速 selection、普通点按 tap）；设置页的倍速行、线路行、快进快退与画质选项同步补上；缓存页三处清理（点按 tap、清完 success）、DLNA 设备行、SMB 视频行、备份生成/恢复此前零触感一并补上；复核无双震：历史页分支内 tap/medium 只走其一、模块 chips 与直播分组各只震一次；语音搜索是纯识别类、无界面按钮，不补",
            "空态与错误态文案统一：同一情况同一句——加载失败六处（模块页、Emby 媒体库/剧集页、直播页、播出日历）此前各写各的（「模块没拉到数据」「媒体库没拉到」「直播列表打不开」「今天的放送没拉到」），现统一为「没拉到数据」，原因进正文、重试统一「重新加载」；无结果三处统一为「没有搜到结果」（Emby 搜索的关键词保留在正文里）；JS/py/Jar 三类浏览页的错误前缀此前是「加载失败\\n\\n原因」双行，现统一为「XX 加载失败：原因」单行；Emby「没连上」是服务器不可达、与列表拉取失败不是同一情况，文案保留",
            "玻璃对比度复核：播放器顶栏线路名（白 0.7）与状态条分辨率（白 0.75）在亮画面上偏淡，各提亮一档到 0.85；其余小字抽查通过——Theme.textDim 0.55 在深色环境光底上对比约 6:1、浅色底上约 7:1，均在可读线之上，未动全局值",
        ]),
        Entry(version: "v2.32", title: "Rex 细节核查", lines: [
            "发现页 hero 补播放入口：Rex hero 有白色播放胶囊，旧版只有点按进详情、长按菜单才有跨线搜索；现简介下方直接放白色「播放」胶囊，点即跨线搜索该片",
            "详情页播放资源卡规格行合并：集数与画质/格式原来是两行小字，现合成一行「共 12 集 · HLS · 1080P」；卡面改走共享 glassPanel，选中态描边改用新常量 Theme.glassStrokeStrong，不再手写 0.45/0.12 两档白边",
            "玻璃规格全仓收编：Theme 新增 smallRadius（10）、glassStrokeStrong（选中描边）两个常量；全仓手写圆角 10/12/14/16/20 共 30 余处全部改成 Theme.cardRadius/innerCardRadius/posterRadius/smallRadius（数值不变，只换名）；手写白底 0.05/0.07/0.08、Divider 白 0.12、播放器 chrome 描边白 0.15 全部改走 Theme.cardTint/Theme.glass/Theme.glassStroke；详情页删掉与 Theme 共用的 starBar 私有实现，改调共享 StarBarView",
            "资源库源卡复核：LightGlassCard 的手写 20pt 圆角与 0.05 白底改走 Theme.cardRadius/Theme.cardTint；选中描边圆角同步常量化；状态点（绿点=当前线路）与新鲜度、站点计数三处逐项核对无改动，规格已达标",
            "设置四宫格复核：图标与文案（播放/音画/操控/字幕）与子页对应关系逐项核对无误；标题色由 text 85% 提为全色，与图标同级；关于页两处手写 Divider 白 0.12 改走 Theme.glassStroke",
            "模块页对标：自检面板与模块卡的自检行此前全是灰字、通过失败一眼看不出；现按状态着色（✓ 绿 / ✗ 红 / △ 黄，未自检仍灰）；模块卡与官方目录卡的 12pt 手写圆角改走 Theme.posterRadius",
            "我的页对标复核：热力格空格与图例此前手写白 0.07（浅色模式下几乎看不见），改走 Theme.glass；周历非当日文字此前手写白字（浅色模式白底上看不见），改走主题文字；分割线改走 Theme.glassStroke；热力格、周历、连续天数与近 7 天柱状图的排版密度逐项核对，与 Rex 个人页口径一致无改动",
            "直播页观感统一：频道行此前是扁平 Theme.glass 底 + 手写 14pt 圆角，现改走共享 glassPanel（无阴影，密集行不掉帧）；搜索框圆角改走 Theme.posterRadius；分组折叠圆钮改走 glassCircle；台标（PosterImage 240px 限流缓存）、当前节目进度条（主题色填充）与分组头三处逐项核对，与全 App 玻璃规格一致",
        ]),
        Entry(version: "v2.31", title: "播放与网络深挖", lines: [
            "起播三段打点落地：解析（spider playerContent / 解析接口整段）、首帧（打开播放器到首次进入播放状态）、HLS 代理（播放列表与分片上游取回）三段耗时分别计数进诊断聚合（慢阈值：解析 >3 秒、首帧 >5 秒、HLS >2 秒），设置 → 关于新增一行起播打点汇总（各段平均耗时、缓存命中数、最慢一段一目了然），诊断导出文本顶部同步带上这行汇总；最慢一段针对性优化见下两条",
            "HLS 去广告代理加缓存与预取：播放列表内存缓存（直播 2 秒、点播 300 秒，引擎高频轮询不再每次重拉上游）；分片整段内存缓存（上限 32 段 / 48 MB、最旧先淘汰、300 秒 TTL，Range 请求命中整段缓存后由代理再切片）；点播播放列表改写完即后台预取前 3 个分片（预取失败不阻塞播放列表返回）；分片与播放列表请求各走独立后台线程，直播播放列表刷新不再阻塞分片取回（逐项复核：分片请求不在串行队列上）",
            "自动换线打点：换线触发记一次尝试（原因分类：加载超时 / 网络 / 解码 / 引擎报错，看门狗的「加载超时」单独成桶不再被误读成解码错），新线路解析出播放地址记一次成功；诊断汇总显示尝试次数、成功次数与各原因计数，换线成功率可查；误判口径：无解析器的裸地址线路换线即记成功（换线本身就是成功），有解析器时以解析出地址为准",
            "弱网自适应复核与实修：原生与 mpv 的 HLS 码率档位此前并不对齐——原生在建 item 时就读保存的画质上限，mpv 只在播放器内切换画质时才生效，设置里存好的 720p 上限在 mpv 首载时被忽略；现 mpv 启动配置里同样读保存的上限（两引擎同档：1080=8Mbps、720=4.5Mbps、480=1.8Mbps，auto 时两边都自由适配）；原生 startsOnFirstEligibleVariant（低码率先出首帧）与 mpv 自适应选档、原生 automaticallyWaitsToMinimizeStalling 与 mpv cache-pause 逐项核对一致，无需再改",
            "JarProxy 冷启动衔接补齐：跨线搜索此前从不预热（浏览与详情页进页都预热），首个 jar 搜索调用直接撞上冷代理的两轮预算；现搜索开始即预热当前线路（TTL 门控，不重复发）；jar 详情页的播放解析（playerContent）改走 patient 模式（300 秒重试预算，与浏览类调用同口径），冷代理唤醒期间不再两次尝试就判死",
        ]),
        Entry(version: "v2.30", title: "启动内存与缓存治理", lines: [
            "模块栏目缓存改文件化：原来 30 条 × 30 行整坨写进 UserDefaults（每次栏目访问整 blob 重编码重写、启动时整份 plist 跟着加载），现在每条一个小文件存 Caches/fwd-columns/，本时段命中只读内存、写盘走后台单文件；上限 30 条 / 5 MB、最旧先淘汰、超 24 小时自动清理；旧 blob 首次访问时一次性迁移后删除",
            "TMDB 搜索缓存加 200 条上限：此前无上限整表重写，满 200 时清掉最早 50 条，blob 不再无限长大",
            "资源库首帧：单文件线路的直开路由原来在卡片 body 里逐卡解析配置（每求值一次解析一次），现在每次刷新时预计算一次、body 只查表",
            "缓存管理页新增「模块与发现缓存」区：海报磁盘 / 模块栏目 / 发现页三项分开显示占用与上限，可一键清理；内存海报缓存上限按本机内存档位实测显示（6 GiB 以上 160 MB、4 GiB 以上 120 MB、以下 48 MB）",
            "启动链路二轮盘点：配置解析、历史解码、发现缓存读取、设置/记录页磁盘统计此前几轮已全部移出主线程或加 isActive 门，本轮逐项复核无新增主线程同步工作；双引擎内存回收复核通过（mpv 切走/退出即销毁句柄与渲染上下文、原生引擎 teardown 摘掉时间观察者）；模块 JSContext 复核通过（原生回调均不强引上下文、异常处理弱引 self，用完即释）",
        ]),
        Entry(version: "v2.29", title: "模块内容类型与多语言对齐", lines: [
            "内容类型按 Rex 官方规范（guide 0.0.7 内容类型章）落地：模块声明的 contentType（video/music/audiobook/shortDrama）在模块卡上显示角标；未声明时由用户长按卡片自选（声明有效时声明优先，自选不生效）；albumMotionArtwork 解码进详情媒体信息行",
            "多语言按 guide i18n 章落地：模块标题、栏目名、参数名、选项与占位提示按完整语言代码 → 文字体系（zh-TW → zh-Hant）→ 基础语言 → 原文的顺序取词典译文；返回数据本身不翻译；运行时补 Widget.i18n(\"文案\")（真实 JS 已用 Node 抽测：zh-TW 取 zh-Hant、en 取 en、缺词回原文）",
            "音乐模块按 guide 音乐章落地：官方 music-demo.js 全入口 harness 实测通过（专辑 tracks/兼容双格式、歌单、流派、电台、歌手资料与搜索）；详情页专辑/歌单的曲目区改称「曲目」，曲行显示歌手与时长（秒数转 m:ss）；流派/电台/歌手卡片点按钻进模块自身的 genreId/radioId/peopleId 入口，不再错进跨线搜索；albumList 详情区改称「专辑」",
            "连播偏好落地：模块声明 continuousPlay 或内容类型为音乐/听书时，本次播放会话强制自动连播（播放器新增单会话覆盖，不动用户全局「自动播放下一集」开关；声明 false 是 guide 默认值，不会关掉用户设置）",
            "官方示例进模块目录：music-demo / tmdb.js / danmu.js 三个示例一键导入，自检覆盖全部已导入模块（含示例）；订阅（.fwd）批量导入改为逐链路结果：重复 id 覆盖同名旧版、失败链接不拖垮其余、导入结果逐条列出（导入个数/覆盖个数/失败原因）",
            "全量回归：validate.mjs 对 tmdb.js、danmu.js、music-demo.js、bangumi.js 均为 0 问题；rex-tmdb.js 官方静态校验仍跑不起来（元数据非字面量，R1 已记，以 App 侧校验为准）；harness 离线跑通 tmdb.js 三入口与 danmu.js 三段链；bangumi 官方 live 脚本在本机沙箱被代理 DNS 拦截，未复跑（v2.06 自建 harness 曾 5/5 通过）；rex-tmdb live 需用户 TMDB 密钥，本轮未复跑",
        ]),
        Entry(version: "v2.28", title: "模块资源字幕与弹幕对齐", lines: [
            "资源与字幕按 Rex 官方规范（guide 0.0.7 资源与字幕章）逐项对齐：loadResource 只认 id/functionName/type 三元组全对的入口（裸 type: stream 换名入口不再被调用）；返回的播放线路数组全解析（name/url/description/playerType/customHeaders），多线路时详情页弹出线路选择器；playerType 落实到播放器（system 走原生引擎、app 走 mpv，手动切引擎与失败换引擎仍优先）；取流参数按 guide 上下文表全改字符串、缺字段不传、title 只给字幕与弹幕入口",
            "字幕接通播放器：条目 externalSubtitles 与 loadSubtitle 入口（三元组识别）合并去重进播放器，isDefault 轨道自动加载（否则首条），字幕菜单新增「模块自带字幕」分组置于在线搜索之上（优先级：模块自带 > OpenSubtitles），点任意轨道即下载（带 customHeaders）解析显示；loadSubtitle 返回 {subtitles:[…]} 包裹也认",
            "弹幕按 guide 弹幕章重写三段链：searchDanmu → getDetail（按集号匹配 episodeId，缺集号字段时取首集）→ getComments（commentId 终于传分集 id，不再错传番剧 id）；另支持 getCommentsWithSegmentTime 分段探针与旧版 getCommentsById/getDanmuWithSegmentTime 兜底；{danmuku:[[时间,位置,颜色,\"\",文本]]} 形状此前在字幕解析字典分支被丢掉，已补上",
            "弹幕设置复核：偏移秒数新增（-5~+5 秒滑杆，正在播放的弹幕立即生效），屏蔽词（DanmakuStore.load 过滤）与显示区域（DanmakuView 车道数）核查确认对模块弹幕同样生效；官方 harness 实测 danmu.js 三段链全通、资源/字幕测试模块 0 issues，validate.mjs 对 danmu.js 与测试模块均为 0 问题",
        ]),
        Entry(version: "v2.27", title: "模块·返回字段与详情搜索对齐", lines: [
            "返回字段按 Rex 官方规范（guide 0.0.7 返回数据章）逐项补齐解码：subtitle（卡片副标题）、backdropPaths（剧照组）、detailPoster、coverRatio、duration（秒数）、genreItems、language、season、previewUrl、trailers、playerType、customHeaders/headers、外挂字幕 externalSubtitles、音乐 tracks；peoples 补 id 与 avatar，演职员行有头像时显示头像、无头像时仍显示首字圆圈",
            "详情按 guide 详情章复核：loadDetail 只收裸 link 字符串（已是现状，harness 实测 argument 为纯字符串）；TMDB 条目带 link 时详情结果合并进列表条目、不再整项替换（旧逻辑会丢掉海报与评分）；loadDetail 返回空数组 [] 视为“无补充详情”不再弹错，只返回 null 才报错；详情页集数优先用 tracks、回退 episodeItems/childItems",
            "搜索按 guide 搜索章复核：keyword/page 经同一组合规则传入（harness 实测 argument {keyword, page: \"1\", language}）；修掉搜索后“加载更多”错跑栏目翻页的 bug——搜索翻页走自己的 searchPage，失败回滚页码；搜索无 page 参数声明时不显示加载更多",
            "详情页加料：集数卡加副行（集副标题或时长）、相关推荐卡无年份评分时用卡片副标题兜底不留空、详情标题下显示副标题、媒体信息加语言行；列表卡显示卡片副标题；直出 videoUrl 与 loadResource/loadDetail 取流时带上条目自带的 customHeaders",
            "官方 harness（离线 fixtures）实测 tmdb.js 三入口全通：loadPopular / loadDetail / search 均 0 issues，validate.mjs 校验 0 问题；loadDetail 返回的 backdropPaths、genreItems、relatedItems 三个字段是本轮之前未解码的，已补齐",
        ]),
        Entry(version: "v2.26", title: "模块·元数据与参数规则对齐", lines: [
            "模块元数据与参数按 Rex 官方规范（guide 0.0.7）逐条对齐：belongTo 分组（隐藏参数不显示、不补默认值，显式保存值仍传入）、enumeration/input/count/page/offset/folder/constant 各类默认值、globalParams 注入顺序、language/timezone 仅声明时注入、page 按 startPage 换算、全部参数值改传字符串",
            "参数组合收进统一函数 fwdCombineParams，栏目、自检、搜索三处同规则；栏目参数 UI 按 belongTo 隐藏；搜索入口同样走组合规则，不再只拼 keyword/page",
            "元数据解析补齐 requiredVersion/contentType/detailCacheDuration/continuousPlay/i18n，入口补 subtitle/iconurl 与每入口 cacheDuration（栏目缓存 TTL 改按入口声明值，旧顶层误读移除；应用默认仍 30 分钟，与 guide 默认 86400 的偏差已记录）",
            "导入模块时即跑元数据校验（App 侧，官方 validate.mjs 因 rex-tmdb 元数据非字面量解析不了）：错误级阻断导入并给中文三段式清单（哪个字段、什么问题、怎么改），警告级留在模块卡上提示；bangumi 官方校验 0 问题通过",
        ]),
        Entry(version: "v2.25", title: "收官·全量复查与更新日志", lines: [
            "更新日志补齐第七次通宵全部 11 轮（v2.15–v2.25）：性能三轮、模块对标 Rex 两轮、UI 对标 Rex 两轮、功能补强两轮、稳定扫荡一轮，当前版本置顶高亮",
            "全量复查：版本号三处一致（project.yml 2.25 / 225、buildLabel、更新日志首条），11 轮进度记录齐全；本轮不再加新功能，只做收官修正",
            "最终包全项验包：Info.plist 版本与最低 iOS 18.0、buildLabel 新旧计数、主程序 LC_LOAD_DYLIB 的 13 个 @rpath framework 与 Payload/*.app/Frameworks/ 清单逐个对照（含 AMSMB2）",
        ]),
        Entry(version: "v2.24", title: "稳定扫荡三轮", lines: [
            "全仓强制解包复查：try!/as!/显式 ! 仍为零（仅剩 required init?(coder:) 里那个约定俗成的 fatalError 桩）；SMB.swift 与 AMSMB2 调用点专项检查——AMSMB2 单次操作默认 60 秒超时，现建连接时改 30 秒，死 NAS 不再等满一分钟才报错；超时/拒连/找不到主机/账号无权/共享不存在五类失败改报中文原因，不再是英文 POSIX 原文",
            "主线程阻塞审计：四处信号量等待逐个核过——JS 串行队列（guage.jsruntime）与 HLS 代理后台队列、SMB 60 秒分块读（代理全局后台队列）均不在主线程；揪出一处真问题：本机代理首次启动的 2 秒封顶等待被两个调用点直接同步等在主线程上（py 蜘蛛首次加载的 ensureProxyBase、SMB 播放准备的 prepare），现改为后台启动、就绪后再绑定/再取地址，首屏与点按不再有最长 2 秒的卡顿窗口；JS 同步取数的等待此前无上限（会话中途被拆会永久卡住 JS 串行队列），现按请求超时 +5 秒封顶、超时报中文「请求超时」而不是空的假 200",
            "低内存与弱网三条路径回归：海报缓存内存分级（6GB 以上 160MB、4GB 以上 120MB、其余 48MB）与内存警告只清内存层、磁盘 150MB 最旧优先淘汰均复核无误；mpv 缓存按内存分级（≥4GB 用 256MiB、以下 128MiB）与 120 秒缓存、cache-pause 均复核无误；JarProxy 冷启动 patient 模式（浏览类调用 300 秒重试预算、其余两次尝试）复核无误",
        ]),
        Entry(version: "v2.23", title: "直播与下载补强", lines: [
            "直播 EPG 进度条刷新对齐到整分钟：节目起止都在整分钟上，此前 TimelineView 从进页那一刻起每 60 秒一拍，「正在播」在节目交接后最多晚一分钟才翻页、进度条也跟着跳变；现节拍从下一个整分钟起拍，交接时刻正好重绘",
            "直播分组折叠与当前分组按源分别持久化：此前全源共用一个折叠开关，在 A 源折叠会把 B 源也折叠起来、选中分组每次进页都回到第一组；现每个直播源各存各的折叠状态与选中分组（源名 + 源地址区分同名源），重进回到上次停的分组",
            "下载断点续传补上 HLS 重连：重启 App 时只重连了文件下载会话，HLS 下载即使还在后台会话里跑也被误判「失败」，跑完后完成事件还因任务表是空的被丢掉、.movpkg 孤儿留在磁盘；现重启时两个会话都查、HLS 任务重新挂回并恢复进度轮询，无任务的才按有无断点 blob 标暂停或失败",
            "追剧更新检查节流收到一处：追剧页与记录页收藏分段各管各的、每次进页都全量重拉一遍 CMS 详情，来回切换等于反复打全套请求；现 6 小时节流统一放在 HistoryStore 里，两处自动检查共用一把锁，手动点「检测更新」仍立即跑（两页的手动按钮都已改 force）",
            "已核查无需改动：全集下载 3 并发分块解析 + 单集失败重试一次（DetailView.downloadWholeLine 逐段核对）；批量重试/删除（v2.10）与单条点按重试、断点续传文案；文件下载断点 blob 存取与重启后标暂停的路径；热力格点按当天时长、继续观看重看即置顶（v2.22 已做）",
        ]),
        Entry(version: "v2.22", title: "搜索与历史补强", lines: [
            "跨线搜索慢站不再拖整页：未知类型站点的嗅探由串行改 6 路并行（每站仍 6 秒超时），一个死站此前要卡 6 秒才放行 py/JS 搜索、多个死站能拖近一分钟，现并行嗅探、逐站回进度；Jar 串行池补上与 py/JS 同款熔断——连续 3 个超时或失败即跳过剩余 Jar 站，JarProxy 卡住时不再逐站烧满 25 秒",
            "搜索进度提示细化到站数与阶段：每站回答后进度行都带阶段名与「已搜 d/t 站」，CMS 长阶段此前只有「已找到 N 部 · 已搜 d/t 站」、看不出在搜哪类站，现四阶段（CMS / 识别站点 / py / JS / Jar）全程带名",
            "搜索历史三件套补齐最后一件：上限 10 条、单条删除早已有，点「清空」此前一点即删、无确认，现弹确认框再清",
            "历史页继续观看排序：重看一部旧剧现在立即浮到顶部——此前 record() 只原地合并、要等播放心跳 5 秒后才浮顶，刚重看完打开记录页会发现它还埋在下面；进度条仍按 position/duration 显示",
            "已核查无需改动：搜索结果逐站到达即上屏（CMS 12 并发、每站 12 秒超时）、无结果折叠区随回答实时长大、py/JS 3 连 miss 熔断、热搜与历史 chips、热力格点按出当天时长（有看显示「M月d日 · 观看 X 分钟/小时」，没看显示「没看」）",
        ]),
        Entry(version: "v2.21", title: "动效与手感", lines: [
            "页面转场：发现页 TMDB 详情 sheet 的内容 0.3 秒淡入（sheet 本身仍走系统滑入，不硬造共享元素过渡）；发现页 hero 轮播 0.45 秒缓动、点按海报已有轻触感均复核无误；资源库三处 NavigationLink（Python 分组卡、点播源卡、直播源卡）与追剧页行跳转此前点按无触感，现补轻触感",
            "触感统一：点按用轻触感、选择类（分类 chips、筛选值、季选择、模块 chips、Emby 类型筛选）用 selection 刻度、播放类（播放/续播/Emby 集数播放）用 medium、完成用 success、失败用 error；补上此前全仓漏掉的：底栏与 iPad 侧栏的搜索悬浮钮、线路卡点按、分类/筛选 chips、搜索热搜与历史 chips（含单条删除 ×）、追剧页提醒开关与检测更新、热力格点按、播放器剩余时间切换、Emby 搜索/清空/排序/播放、TMDB 测试连接（成功 success、失败 error）、播放失败阶梯走到头（换线也无路可走时）补 error 震动",
            "滥用收敛：播放器视频区点按显隐 chrome 不加震动——这是全 App 点得最频繁的手势，每次都震是噪音；其余 HistoryView 的 14 处轻触感逐条核对，均在真实点按/选择动作上，无空转调用",
            "底栏与胶囊复核：切换 0.22 秒 easeInOut、紧凑模式（只图标）、搜索悬浮钮开关均已实现且无改动；胶囊选中态在切换动画内同步变色",
            "骨架屏不闪烁：全 App 19 处骨架统一加淡出——SkeletonHero / SkeletonPosterGrid / SkeletonRowList / ColdStartSpinner 出现与消失均为 0.25 秒 easeOut 交叉淡入淡出；覆盖发现页、CMS/py/JS/jar 四个浏览页（含详情加载骨架）、搜索页、模块页、直播页、Emby 首页/搜索/媒体库/剧集页/播放取流页、播出日历、WebDAV、DLNA、SMB 两页",
        ]),
        Entry(version: "v2.20", title: "Rex 细节核查三轮", lines: [
            "玻璃规格收进同一套 Theme 值：新增 cardRadius 20 / innerCardRadius 16 / posterRadius 12 与 cardTint 淡白覆膜，GlassCard、GlassPanel、posterFrame 与媒体信息卡全部走这套常量；详情页「播放资源」线路卡由 14 改 16、补淡白覆膜，媒体信息卡同样补覆膜——之前两处是扁平 Theme.glass + 细描边，放在资源库的 LightGlassCard 旁边像灰色实块",
            "发现页 hero 指示点改当前页拉长胶囊（18×7），其余仍为 7pt 圆点；一排等大圆点扫一眼看不出停在哪页",
            "设置子页的分组标题由 Theme.textDim 改 Theme.section，与设置主页面分组标题同色；之前子页标题无故暗一档",
            "设置页「更新日志」行的版本号由写死的 v1.86 改成从 buildLabel 自动取，之前落后了 34 个版本；更新日志页本身的「当前版本」置顶高亮仍按 entries 首条判定，补 v2.20 条目后自动跟上",
            "评分红线复查：发现页与详情页的评分只走 TMDB vote_average、0 分隐藏，Emby 评分标「Emby 评分」；模块详情页把无依据的「TMDB 评分」改回中性「评分」——模块的 rating 字段是模块自带数字，只有 rex-tmdb 那路恰好是 TMDB vote_average，不能给所有模块都盖 TMDB 的章",
            "已核查无需改动：播放器 chrome 按 Rex 参考播放器有意平铺白字、无玻璃（注释已写明，黑底胶囊只用于视频上的 toast/亮度音量 HUD）；资源库双列源卡与线路卡已是 LightGlassCard 全套玻璃配方；环境光浓度发现/资源库 0.45、详情页 0.65 是按页有意的分档；详情页播放钮两行、动作胶囊三键、播放资源双列卡、选集轨 176×99 均符合 Rex 规格",
        ]),
        Entry(version: "v2.19", title: "模块兼容加固三轮", lines: [
            "Widget.http 四路径逐一桩测补齐：重定向跟随回报最终 URL、redirect: 0 时回 3xx 与 Location（响应头同时给原大小写与小写两份，两种读法都命中）；Set-Cookie 解析进 cookies[] 字段、跨请求自动带回（共享 cookie jar），多条 Set-Cookie 不再被逗号拼坏；GBK 页面没传 encoding 时按响应 charset 自动解码、传了则按指定编码；表单 POST 的 data 字典与预编码字符串两种形态都发得出、值里的 & = + ? 不再拆字段",
            "自写测试模块 + 本地服务器端到端跑通 loadDetail 与 loadResource：列表 2 条、搜索 1 条、详情带 videoUrl 与 2 集、取流 POST 回流地址与 Referer，全 20 项桩测通过（含重定向/Set-Cookie/GBK/表单）",
            "模块页体验收口：搜索失败后「重新加载」重跑同一关键词的搜索（原来是重载栏目、失败原样回来）；详情页 loadDetail 失败不再静默——页面内显中文原因横幅、可点重试",
            "已核查无需改动：栏目加载骨架、空结果空态、加载更多失败回滚页码与报错横幅（v2.06 已有，规格与 App 其余页面一致）",
        ]),
        Entry(version: "v2.18", title: "Rex 官方模块全量自测三轮", lines: [
            "Node 沙盒全量复测两官方模块 17 个栏目：bangumi 5/5 通过（每日播出 23 条、近期注目 22 条、排行榜 47 条、年度新番 41 条、分类 47 条）；rex-tmdb 走 Widget.http 的 5 栏全过（地区剧集/综艺各 40 条、热门/最新电影各 20 条，片单 0 条是 TMDB 官网对服务器抓取回 Cloudflare 挑战页的老问题）",
            "rex-tmdb 其余 7 个 tmdb.get 栏目无密钥时仍报中文「未配置 TMDB 密钥（设置 → TMDB）」、0–1ms 快速失败，没有英文 TypeError；用无效密钥桩测有密钥路径：直连与 JarProxy 转发两路都返回 TMDB 401「Invalid API key」，错误对象被原样抛出、不再是 TypeError；转发线路实测可达（401 证明代理已通 TMDB）",
            "模块自检升级为逐栏自检：原来只测每模块首栏、其余栏目死掉也看不见，现全部栏目逐个实跑、逐栏计时（毫秒/秒），结果行带「✓/△/✗ 栏目名：N 条 · 用时」，模块卡片留「X/Y 栏 · 共 N 条 · 总用时」；逐栏明细随自检结果持久化，重启后仍在",
            "官方模块源与 11 月 21 日版逐字节一致（md5 相同），本次无模块自身改动；harness 逐栏耗时已记入 result.json",
        ]),
        Entry(version: "v2.17", title: "播放器起播与切集二轮", lines: [
            "mpv 起播探测按容器分流：HLS（.m3u8）播放列表是纯文本、TS 分片几 KB 即可探明，探测收紧到 512KB / 1 秒，首帧更快；MP4 等容器保持 2MB / 2 秒，探测过浅漏流反而要重试",
            "下集预解析失败不再整集作废：进度到阈值 +15%（短剧 65%、长剧 85%）时重试一次，重试也失败才放弃，切集不再等同步解析；失败记一条诊断日志，命中率可查",
            "HLS 去广告代理超时分开算：播放列表 8 秒、分片 15 秒（原来统一 20 秒），死链分片快速 502、引擎重试接手，不再拖满整段播放；分片多连接仍由代理后台队列并发拉取",
            "已核查无需改动：短集 50% / 长剧 70% 预解析阈值、原生引擎 10 秒起播后回长到 60 秒前向缓冲、mpv 内存分级缓存上限与 60 秒预读（均为 v2.05 已实现，数值复核无误）",
        ]),
        Entry(version: "v2.16", title: "滚动与图片二轮", lines: [
            "海报按显示尺寸分级解码：详情大图、TMDB 详情横幅与模块详情背景升到 900px；演职员头像、模块图标、直播台标与 46pt 小缩略图降到 240px；其余网格保持 480px，环境光仍为 240px",
            "海报内存缓存按设备物理内存分级：6GB 以上 160MB、4GB 以上 120MB、其余 48MB；内存警告仍整清内存层、磁盘层不受影响",
            "长列表预取改方向感知：发现页行出现时预取滚动方向上的下一行、hero 轮播预取下一页大图，离开页面或新批次到达时取消未开始的预取；资源库 Emby 预取同样走可取消批次",
        ]),
        Entry(version: "v2.15", title: "冷启动与首屏二轮", lines: [
            "启动路径再审计：设置页的缓存容量统计与记录页的存储用量统计不再冷启动时跑，点开对应 tab 才算；App 启动时的崩溃自愈目录清理改后台线程",
            "发现页缓存策略复核：过期缓存照样先出屏（不再先看骨架）、缓存读写离主线程；六个 TMDB 栏目到一个上屏一个，不再等最慢的那个；hero 标题图改并发拉取",
            "历史记录与每日观看台账合并成单个 history-store.json：冷启动一次读盘一次解码，旧两文件首次启动自动迁移；播放心跳写盘节流到 30 秒一次",
            "已核查无需改动：配置后台加载、JarProxy 预热后台化、订阅配置后台刷新、发现页 12 小时分级加载与海报预取节流（均为 v2.03 已实现）",
        ]),
        Entry(version: "v2.14", title: "SMB/NAS 播放", lines: [
            "新增 SMB/NAS 支持：设置 → 媒体服务器里添加 SMB 服务器（主机/用户名/密码，只存本机），资源库「本地与网络」出现入口",
            "进服务器先列共享文件夹，逐层浏览目录，视频文件带大小显示，点按直接播放",
            "播放走本机代理转发（AMSMB2 开源库，LGPL 合规动态链接）：按 HTTP Range 分块取流，支持拖动进度；mkv 等格式仍自动走 mpv 引擎",
            "SMB 服务器配置纳入备份与恢复范围",
        ]),
        Entry(version: "v2.13", title: "稳定扫荡与更新日志", lines: [
            "全仓复查：强制解包与 try!/as! 仍为零（仅剩 WKWebView 协议签名的隐式解包）；三处信号量等待均不在主线程（JS 专用串行队列、代理后台队列、2 秒封顶的本地代理启动）",
            "WebDAV 文件夹浏览与 Emby 单片解析页的整页裸转圈换成与页面结构一致的骨架屏；其余加载态已在前面各轮统一",
            "更新日志补齐 v2.03–v2.13 全部版本条目，当前版本置顶高亮",
        ]),
        Entry(version: "v2.12", title: "底栏设置与详情页对齐", lines: [
            "外观与交互新增底栏设置：紧凑底栏（仅图标）、搜索按钮显隐；记录/资源库开关不变，搜索关掉后仍可从发现页「跨线搜索」进入",
            "Emby 剧集详情页对齐点播详情页规格：评分五星条、展开式「媒体信息」卡（服务器/类型/年份/评分/分级/季数/片长）、「演职员」横滑行",
            "模块详情页同样对齐：评分五星条、「媒体信息」卡（来源模块/类型/年份/评分/时长）、「演职员」改带标题的横滑行（原为一行纯文本）",
            "加载态最后一轮统一：CMS/py/JS 浏览页、详情加载页、直播页、DLNA 搜索页、搜索页的裸转圈全部换成与页面结构一致的骨架屏；加载更多与状态行转圈不变",
        ]),
        Entry(version: "v2.11", title: "备份列表与历史批量清理", lines: [
            "备份页新增「本机备份」列表：每次生成备份自动在本机留一份，每条带备份时间与大小，可分享、恢复、删除；只存本机，不走云同步",
            "恢复前先确认：点恢复会先显示这份备份的内容（备份时间、线路条数、设置项数、有无观看历史），确认后才覆盖本机数据；从文件导入同样先确认",
            "历史页新增批量管理：多选后批量删除；「清已看完」一键清理看到 95% 以上的记录，已收藏的剧不受影响",
            "追剧页有更新的剧海报右上角挂红点；排序复核：有更新的置顶，其余按最近观看排序；进详情页后红点清除",
        ]),
        Entry(version: "v2.10", title: "弹幕外观与批量管理", lines: [
            "弹幕外观独立成页：字号、透明度、滚动速度、显示区域、描边，改动立即生效（正在播放的弹幕也会跟着变），附实时预览",
            "直播页新增频道搜索：输入名字跨全部分组找频道；分组 chips 可折叠收起",
            "下载页新增批量管理：多选后批量删除、批量重试失败/暂停的任务；分组头可整组勾选",
        ]),
        Entry(version: "v2.09", title: "播出日历与搜索筛选", lines: [
            "模块页新增「播出日历」：bangumi 每日放送周视图（今天 + 周一…周日），点哪天拉哪天，栏目结果 30 分钟缓存，重进即出屏",
            "搜索页新增年份/类型筛选：只在结果确实带年份或类型时出现，筛空后有清除筛选入口",
            "详情页「播放资源」卡补规格行：线路名带画质（如 1080P）或首集是 m3u8/MP4 时显示，数据里没有就不显示；媒体信息卡同步补「画质」行",
        ]),
        Entry(version: "v2.08", title: "Rex 细节核查与玻璃修正", lines: [
            "发现页 hero 与 TMDB 详情页评分徽章由实色蓝块改玻璃胶囊",
            "我的页周历修真 bug：按行号标星期跨月会算错，改真日期推算；热力格定宽改 flexible 列，窄屏不再溢出",
            "详情选集轨当前集加白边高亮，刚开播没有已看勾时也能定位",
        ]),
        Entry(version: "v2.07", title: "模块兼容加固", lines: [
            "Widget.http 透传 encoding/buffer/redirect/data：gbk 站不再乱码、redirect: 0 能拿到 3xx 与 Location、表单 POST 能发出去；响应新增最终重定向后地址",
            "设置页清空网盘凭证后猫源不再用旧 cookie；删模块时同步清其存储与栏目缓存",
            "FWENC 加密模块拒绝提示补原因与出路",
        ]),
        Entry(version: "v2.06", title: "模块全量自测与栏目缓存", lines: [
            "Node 沙盒全量复跑两官方模块：bangumi 5/5 栏目、rex-tmdb 走 http 的 5 栏全过（片单 0 条是 TMDB 官网 Cloudflare 挑战，已知）",
            "Widget.tmdb.get 遇 TMDB 错误对象直接报中文原因，不再是看不懂的 TypeError",
            "栏目结果缓存 30 分钟：重进栏目即出屏，手动重新加载绕缓存；加载更多失败回滚页码并出横幅报错重试",
        ]),
        Entry(version: "v2.05", title: "播放器起播与弱网", lines: [
            "mpv 探测收窄、缓存上限按内存分级；原生引擎起播前向缓冲 10 秒、起播 1 秒后长回 60 秒",
            "卡死看门狗分层：首卡 15 秒、恢复中 25 秒即触发恢复；拖动手势更灵敏（最小距离与方向锁定收窄，亮度/音量满程缩短）",
            "短集（15 分钟内）下一集预解析阈值 70% 提前到 50%",
        ]),
        Entry(version: "v2.04", title: "滚动流畅度与海报管线", lines: [
            "海报按尺寸分级解码（网格 480px、hero 900px、环境光背景 240px）；资源库玻璃卡去每卡阴影，滚动少一次离屏渲染",
            "直播重名分组不再折叠；CMS 跨线搜索并发上限 12，取消即停",
        ]),
        Entry(version: "v2.03", title: "启动提速与首屏分级加载", lines: [
            "配置改后台异步加载，预热/刷新延后 1.5 秒，历史记录启动解码改后台；冷启动到首屏可交互的阻塞点逐个拆掉",
            "发现页 12 小时磁盘缓存分级加载：先出旧数据、后台再刷新；海报预取 14 张减到 10 张；启动屏加深色底",
        ]),
        Entry(version: "v2.02", title: "官方模块目录预置", lines: [
            "模块页新增「官方模块目录」：未下载的 Rex 官方模块（Rex TMDB、动漫数据）先展示卡片，含作者、版本、栏目数与简介，点「下载」一键启用",
            "已导入的模块不再出现在目录里；Rex TMDB 卡片会提示需先在设置 → TMDB 填入自己的密钥",
        ]),
        Entry(version: "v2.01", title: "模块超时分层与错误分类", lines: [
            "Widget.http 单请求超时封顶 20 秒，超时与断网分开报错，不再转满 60 秒才报",
            "模块报错带【网络失败/脚本异常/超时】分类前缀；定时器回调异常不再闷满 60 秒",
        ]),
        Entry(version: "v2.00", title: "模块 HTTP 真实状态码", lines: [
            "Widget.http 不再恒报 200：返回真实 HTTP 状态码与响应头，404/403/Cloudflare 挑战页不再被误判为成功",
            "请求失败（断网/超时）返回状态 0 并带中文错误原因；正常返回的 body 解析行为不变",
        ]),
        Entry(version: "v1.99", title: "更新日志与全量复查", lines: [
            "更新日志补齐本轮全部版本条目（v1.90–v1.99），当前版本置顶高亮",
            "全量复查：底部胶囊四入口与设置页各行入口均有目标页；全仓无占位文案，面向用户英文仅剩专有名词",
        ]),
        Entry(version: "v1.98", title: "稳定扫荡", lines: [
            "全仓复查：强制解包与 try!/as! 已清零（仅剩 WKWebView 协议签名的隐式解包），主线程阻塞点逐项核过",
            "截图不再卡界面：mpv Metal 截图等文件时改异步等待，点截图后播放器操作不再卡住约半秒",
            "各页空状态与中文文案已统一走共享空状态，英文提示已清查",
        ]),
        Entry(version: "v1.97", title: "选集卡集标题副行", lines: [
            "播放器选集面板集卡：主行只显示集数，原始集名里的标题部分（如「第1集 归来」里的「归来」）显示为小字副行",
            "无标题数据的线路（纯数字/EP 编号）只显示集名，不再把原始编号当副行",
        ]),
        Entry(version: "v1.96", title: "搜索无结果折叠", lines: [
            "搜索左侧栏新增「无结果」折叠区：有响应但 0 结果的站点收在这里，默认折叠只露一行计数，点按展开看站名",
            "每站结果数橙色徽标与「全部」进度计数不变；超时/失败的站不进无结果区，仍只计入底部汇总",
        ]),
        Entry(version: "v1.95", title: "下载按剧分组", lines: [
            "下载页同剧多集收进一组（剧名 · 共 N 集 · 已下载 M 集），点按展开/折叠",
            "单集的剧仍是原来一条；组内集数按创建时间排序，左滑删除单集不变",
        ]),
        Entry(version: "v1.94", title: "模块卡自检结果", lines: [
            "模块卡副行已有作者 · 版本 · 栏目数；自检结果现留在卡上（上次自检时间 + 结论）",
            "自检结果按模块持久化，重启仍在；删除模块时一并清除",
        ]),
        Entry(version: "v1.93", title: "观看统计加强", lines: [
            "我的页新增连续观看天数（按每日观看台账往回数，今天没看从昨天起算）",
            "近 7 天观看时长柱状图（今天高亮，分钟数标在柱顶）",
        ]),
        Entry(version: "v1.92", title: "直播节目进度条", lines: [
            "直播频道行底部加当前节目细进度条（按 EPG 起止算已播比例，60 秒一拍推进）",
            "无当前节目时不显示进度条",
        ]),
        Entry(version: "v1.91", title: "Emby 服务器计数", lines: [
            "资源库「Emby 媒体库」卡片新增「电影：x · 剧集：y」计数行（Emby /Items/Counts 取数）",
            "服务器取不到数时对应位置显示 —",
        ]),
        Entry(version: "v1.90", title: "演职员跨线搜索", lines: [
            "详情页点演职员头像/名字 → 在自有线路上跨线搜索该演员",
            "与「相似推荐」点按共用同一搜索弹窗",
        ]),
        Entry(version: "v1.87", title: "线路长按更新", lines: [
            "资源库长按线路卡 →「更新线路」：立即拉取远程配置并给出结果提示",
            "资源库右上角 ↻ 一键更新全部远程线路，汇总已更新/已是最新/失败条数",
            "线路卡新鲜度改按上次更新时间显示；我的页热力格点按某天显示当天观看时长",
        ]),
        Entry(version: "v1.86", title: "更新日志与全量复查", lines: [
            "设置页新增「更新日志」页，内置近几版改动清单",
            "全量复查：各页空状态、图标与文案一致性（媒体服务器图标去重）",
        ]),
        Entry(version: "v1.85", title: "稳定扫荡与空状态补齐", lines: [
            "全仓强制解包清零，播放器图层改可选链/guard",
            "历史/下载/搜索/直播空状态统一共享 EmptyStateView",
            "直播台标改走 PosterImage 限流缓存",
        ]),
        Entry(version: "v1.84", title: "下载页存储用量", lines: [
            "存储用量卡：已下载总大小 + 海报缓存大小",
            "一键清理缓存（只清海报与内存缓存，不动已下载视频）",
        ]),
        Entry(version: "v1.83", title: "模块角标与相关推荐", lines: [
            "带弹幕模块的卡片加玻璃胶囊「弹幕」角标",
            "详情页相关推荐卡补年份·★评分行",
        ]),
        Entry(version: "v1.82", title: "播放器画质与画面", lines: [
            "右下角画质文本钮：显示当前分辨率，点开切 HLS 质量上限",
            "「画面」文本钮：适应/填充一键切，点播与直播共用同一入口",
        ]),
        Entry(version: "v1.81", title: "资源库排序与站点数", lines: [
            "配置排序切换：名称 / 站点数 / 最近使用",
            "分组头显示站点数（「分组名 · N 站」）",
        ]),
        Entry(version: "v1.80", title: "搜索页热搜与历史", lines: [
            "热搜 chips：TMDB 当日热门前 10，点即搜",
            "搜索历史单条删除（清空按钮保留）",
        ]),
        Entry(version: "v1.79", title: "我的页观看热力格", lines: [
            "近 12 周热力格按每日观看时长渲染（5 档强度）",
            "本周/本月观看统计：总时长 + 看了几天",
        ]),
        Entry(version: "v1.78", title: "详情页收尾", lines: [
            "底部「媒体信息」玻璃展开卡（来源站点/线路/集数/类型/年份等）",
            "TMDB 评分改五星条可视化",
        ]),
    ]

    var body: some View {
        SettingsPage(title: "更新日志") {
            Text("更新日志页内置近几版改动清单，只列已交付的内容。")
                .font(.footnote).foregroundStyle(Theme.textDim)
            ForEach(Self.entries) { entry in
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(entry.version).font(.headline).foregroundStyle(Theme.text)
                            Text(entry.title).font(.subheadline).foregroundStyle(Theme.textDim)
                            Spacer()
                            if entry.version == Self.entries.first?.version {
                                Text("当前版本").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Theme.glass, in: Capsule())
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        ForEach(entry.lines, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("·").foregroundStyle(Theme.textDim)
                                Text(line).font(.footnote).foregroundStyle(Theme.text)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 关于呱壳 — version and both runtime statuses live here (moved out
/// of the settings list at the user's request).
/// Result box for the Python ping race in AboutView: the ping
/// itself can hang forever on a wedged queue, so the checker
/// polls the box after a fixed sleep instead of awaiting it.
final class PingBox: @unchecked Sendable {
    var done = false
    var ok = false
}

struct AboutView: View {
    @State private var diagCount = Diagnostics.entries().count
    @State private var pyHealth = ""
    /// v2.36: short clock for the in-app recent-log list below.
    private static let diagTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        SettingsPage(title: "关于呱壳") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    aboutRow("应用", "呱壳 GuageTV")
                    Divider().background(Theme.glassStroke)
                    aboutRow("版本", SettingsView.buildLabel)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    aboutRow("Python 运行时", PythonRuntime.shared.statusText)
                    HStack(spacing: 10) {
                        Button("Python 健康检查") {
                            pyHealth = "检查中…"
                            Task {
                                let box = PingBox()
                                Task.detached {
                                    box.ok = (try? PythonRuntime.shared.invoke("ping", [])) != nil
                                    box.done = true
                                }
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                if !box.done {
                                    pyHealth = "3 秒无响应：队列可能被某个蜘蛛占死，重启呱壳恢复"
                                } else {
                                    pyHealth = box.ok ? "响应正常" : "调用失败（看诊断日志）"
                                }
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(Theme.text)
                        Button("重置蜘蛛熔断") {
                            SpiderBridge.shared.resetBreaker()
                            pyHealth = "熔断已重置"
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(Theme.text)
                    }
                    if !pyHealth.isEmpty {
                        Text(pyHealth).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    Divider().background(Theme.glassStroke)
                    aboutRow("JS 运行时", "drpy2 3.9.52 · JavaScriptCore")
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("诊断日志").font(.headline).foregroundStyle(Theme.text)
                    Text("记录最近的 py 蜘蛛报错、模块失败、播放失败与崩溃自愈（最多 200 条，重复的折叠成一行）。哪个站挂了，把日志导出发出来就能直接定位。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Text(Diagnostics.timingSummary())
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    // v2.36: the log used to be export-only — the
                    // self-heal record, the spider error class and
                    // the R6 playback timing were all "in the
                    // diagnostics" but invisible in the app. Show
                    // the latest folded groups here so a failure
                    // names itself without an export round-trip.
                    let recentDiag = Diagnostics.foldedEntries()
                        .sorted { $0.last > $1.last }.prefix(8)
                    if !recentDiag.isEmpty {
                        Divider().background(Theme.glassStroke)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近记录").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            ForEach(Array(recentDiag.enumerated()), id: \.offset) { _, f in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(f.c).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                                        if f.count > 1 {
                                            Text("×\(f.count)").font(.caption).foregroundStyle(Theme.textDim)
                                        }
                                        Spacer()
                                        Text(Self.diagTime.string(from: Date(timeIntervalSince1970: f.last)))
                                            .font(.caption).foregroundStyle(Theme.textDim)
                                    }
                                    Text(f.m).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                                }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        ShareLink(item: Diagnostics.exportText()) {
                            Text("导出日志").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Theme.glass, in: Capsule())
                                .foregroundStyle(Theme.text)
                        }
                        Button("清除") {
                            Diagnostics.clear()
                            diagCount = 0
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(Theme.text)
                        Text("当前 \(diagCount) 条").font(.footnote).foregroundStyle(Theme.textDim)
                    }
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

struct SettingsPage<Content: View>: View {
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
    @AppStorage("player.showClock") private var showClock = true
    @AppStorage("player.showScreenshot") private var showScreenshot = true
    @AppStorage("player.showGravity") private var showGravity = true
    @AppStorage("player.showRate") private var showRate = true
    @AppStorage("player.showEpisodeSwitch") private var showEpisodeSwitch = true
    @AppStorage("player.showStats") private var showStats = false
    @AppStorage("player.backgroundAudio") private var backgroundAudio = true
    @AppStorage("player.hlsAdblock") private var hlsAdblock = true
    @AppStorage("hlsAdblock.lastRemovedSegments") private var lastRemovedSegments = 0
    @AppStorage("hlsAdblock.lastRemovedSeconds") private var lastRemovedSeconds = 0.0
    @AppStorage("hlsAdblock.lastFilteredAt") private var lastFilteredAt = 0.0
    @AppStorage("gesture.boostRate") private var boostRate = 2.0
    @AppStorage("danmaku.enabled") private var danmakuEnabled = false
    @AppStorage("danmaku.apiTemplate") private var danmakuAPI = ""
    @AppStorage("danmaku.blockWords") private var danmakuBlockWords = ""

    /// 上次去广告过滤的统计行（v1.67）；无记录时提示尚未过滤过。
    private var lastAdFilterText: String {
        guard lastRemovedSegments > 0, lastFilteredAt > 0 else {
            return "尚未过滤过广告段——打开一部点播片后，这里会显示上次过滤结果。"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let when = formatter.string(from: Date(timeIntervalSince1970: lastFilteredAt))
        return "上次过滤：移除 \(lastRemovedSegments) 段（约 \(Int(lastRemovedSeconds)) 秒）· \(when)"
    }

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
                    Toggle("当前时间显示", isOn: $showClock)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("截图按钮", isOn: $showScreenshot)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("画面适配按钮", isOn: $showGravity)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("倍速按钮", isOn: $showRate)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("切集按钮（上一集/下一集）", isOn: $showEpisodeSwitch)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("播放统计浮层", isOn: $showStats)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Toggle("后台音频播放", isOn: $backgroundAudio)
                    Toggle("HLS 去广告", isOn: $hlsAdblock)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("点播 m3u8 经本地代理过滤广告片段（异域名插播 / 标记广告段）；某部片播不了时关掉它再试。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Text(lastAdFilterText)
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Text("关掉的项不再出现在播放页，对应功能同时停用；下次打开播放器生效。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("手势").font(.headline).foregroundStyle(Theme.text)
                    Text("长按倍速的倍数").font(.subheadline).foregroundStyle(Theme.text)
                    Picker("倍速", selection: $boostRate) {
                        Text("1.5x").tag(1.5)
                        Text("2x").tag(2.0)
                        Text("3x").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("弹幕").font(.headline).foregroundStyle(Theme.text)
                    Toggle("弹幕总开关", isOn: $danmakuEnabled)
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Text("在线弹幕接口模板").font(.subheadline).foregroundStyle(Theme.text)
                    TextField("https://…/danmaku?title={title}&ep={ep}", text: $danmakuAPI)
                        .font(.footnote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    Text("填一个返回弹幕数据的接口地址，用 {title} 和 {ep} 占位剧名和集数；返回 B 站式 XML 或 JSON 数组都能解析。留空则只能在播放页手动加载弹幕文件。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    // v2.10: 字号/透明度/速度/区域/描边移入独立的
                    // 弹幕外观页，这里只留开关、接口与屏蔽词。
                    NavigationLink { DanmakuSettingsView() } label: {
                        HStack {
                            Text("弹幕外观").font(.subheadline).foregroundStyle(Theme.text)
                            Spacer()
                            Text("字号 · 透明度 · 区域 · 描边").font(.caption).foregroundStyle(Theme.textDim)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textDim)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("屏蔽词").font(.subheadline).foregroundStyle(Theme.text)
                    TextField("词与词之间用逗号隔开，含词的弹幕不显示", text: $danmakuBlockWords)
                        .font(.footnote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                }
            }
        }
    }

}

/// 音画： kernel choice cards on top (the same enginePreference
/// key the 播放 page writes), then the 画面 rows — fit mode, the
/// player's own brightness, and the two HDR behaviours the mpv
/// GPU path honours. Layout follows the reference settings page:
/// one card of selectable kernel rows with descriptions and a
/// checkmark, quiet footnote explanations under each card.
struct AVSettingsView: View {
    @AppStorage("enginePreference") private var engine = "auto"
    @AppStorage("videoGravity") private var gravity = "aspect"
    @AppStorage("player.keepBrightness") private var keepBrightness = false
    @AppStorage("player.brightness") private var playerBrightness = 0.7
    @AppStorage("player.hdrMapping") private var hdrMapping = "auto"
    @AppStorage("player.hdrLayer") private var hdrLayer = "auto"

    var body: some View {
        SettingsPage(title: "音画") {
            GlassCard {
                VStack(spacing: 0) {
                    kernelRow(tag: "auto", title: "自动选择",
                              desc: "按片源格式自动选引擎：m3u8/mp4 走直通引擎，其余走 App 内核；某个引擎播不了时会自动回退另一个。")
                    Divider().overlay(Theme.glassStroke)
                    kernelRow(tag: "mpv", title: "内核 1.0",
                              desc: "使用 App 自带播放内核（mpv），支持音轨、字幕和更完整的播放控制，格式兼容最全，推荐默认使用。")
                    Divider().overlay(Theme.glassStroke)
                    kernelRow(tag: "native", title: "内核 2.0",
                              desc: "新一代直通引擎：原生杜比视界与杜比全景声、更快的拖动响应；异常时自动回退 App 内核。")
                }
            }
            Text("不同播放内核对起播速度、格式兼容性和字幕能力的表现不同，切换后重新进入播放器生效。")
                .font(.footnote).foregroundStyle(Theme.textDim)

            Text("画面").font(.headline).foregroundStyle(Theme.text)
                .padding(.top, 4)
            GlassCard {
                VStack(spacing: 0) {
                    menuRow(title: "画面适配方式",
                            value: gravity == "fill" ? "填充屏幕" : "适应屏幕") {
                        Button("适应屏幕") { gravity = "aspect" }
                        Button("填充屏幕") { gravity = "fill" }
                    }
                    Divider().overlay(Theme.glassStroke)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("单独调整播放亮度", isOn: $keepBrightness)
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                        Text("播放时使用独立亮度；结束播放后，恢复原来的屏幕亮度。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        if keepBrightness {
                            HStack(spacing: 10) {
                                Image(systemName: "sun.min").foregroundStyle(Theme.textDim)
                                Slider(value: $playerBrightness, in: 0.1...1.0, step: 0.05)
                                    .tint(Theme.accent)
                                Image(systemName: "sun.max.fill").foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    Divider().overlay(Theme.glassStroke)
                    menuRow(title: "HDR 动态映射",
                            value: hdrModeLabel(hdrMapping)) {
                        Button("自动") { hdrMapping = "auto" }
                        Button("开") { hdrMapping = "on" }
                        Button("关") { hdrMapping = "off" }
                    }
                    Divider().overlay(Theme.glassStroke)
                    menuRow(title: "HDR 增强层",
                            value: hdrModeLabel(hdrLayer)) {
                        Button("自动") { hdrLayer = "auto" }
                        Button("开") { hdrLayer = "on" }
                        Button("关") { hdrLayer = "off" }
                    }
                }
            }
            Text("HDR 动态映射与增强层需要逐帧处理，仅对 App 内核（mpv · GPU 渲染）生效，播放时更耗电、更易发热；选「自动」时按片源决定。")
                .font(.footnote).foregroundStyle(Theme.textDim)
        }
    }

    private func hdrModeLabel(_ value: String) -> String {
        switch value { case "on": return "开"; case "off": return "关"; default: return "自动" }
    }

    /// One selectable kernel row: title, honest description, and
    /// a blue checkmark on the current choice.
    private func kernelRow(tag: String, title: String, desc: String) -> some View {
        Button { engine = tag } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.medium)).foregroundStyle(Theme.text)
                    Text(desc).font(.subheadline).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if engine == tag {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold)).foregroundStyle(.blue)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A settings row whose value is picked from a menu, value
    /// and up/down chevron on the right (reference-page style).
    private func menuRow<Content: View>(title: String, value: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 10) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Spacer()
                Text(value).font(.subheadline).foregroundStyle(Theme.textDim)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
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
    @AppStorage("subtitles.osKey") private var osKey = ""

    var body: some View {
        SettingsPage(title: "字幕") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("外挂字幕 · OpenSubtitles").font(.headline).foregroundStyle(Theme.text)
                    SecureField("API Key", text: $osKey)
                        .font(.footnote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    Text("播放页 → 播放设置 → 外挂字幕 → 在线搜索字幕 用它搜字幕。Key 在 opensubtitles.com 免费注册后、于 API consumers 里自建，只存本机。本地字幕文件（srt/vtt/ass）不需要 Key。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
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
