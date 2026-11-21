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
    static let buildLabel = "v2.16 · 滚动与图片二轮"

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
                                value: "v1.86") {
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
                Text(title).font(.subheadline).foregroundStyle(Theme.text.opacity(0.85))
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
                    Divider().background(Color.white.opacity(0.12))
                    aboutRow("JS 运行时", "drpy2 3.9.52 · JavaScriptCore")
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("诊断日志").font(.headline).foregroundStyle(Theme.text)
                    Text("记录最近的 py 蜘蛛报错与播放失败（最多 200 条）。哪个站挂了，把日志导出发出来就能直接定位。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
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
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
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
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
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
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
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
