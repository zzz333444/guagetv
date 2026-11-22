import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Media-server settings + WebDAV browsing + local file playback
/// (v1.41). Entry points live in Settings （媒体服务器） and in
/// the Library tab's "本地与网络" section.

// MARK: - Settings

struct MediaServerSettingsView: View {
    @AppStorage("emby.url") private var embyURL = ""
    @AppStorage("emby.user") private var embyUser = ""
    @State private var embyPassword = ""
    @State private var embyStatus = EmbyClient.configured ? "已登录" : "未登录"
    @State private var loggingIn = false
    /// All signed-in Emby servers (multi-server, v1.74).
    @State private var serverList: [EmbyClient.Server] = EmbyClient.servers

    @AppStorage("webdav.servers") private var webdavJSON = "[]"
    @State private var davName = ""
    @State private var davURL = ""
    @State private var davUser = ""
    @State private var davPassword = ""

    @AppStorage("smb.servers") private var smbJSON = "[]"
    @State private var smbName = ""
    @State private var smbHost = ""
    @State private var smbUser = ""
    @State private var smbPassword = ""

    struct DAVServer: Codable, Identifiable {
        var name: String
        var url: String
        var user: String
        var password: String
        var id: String { url }
    }

    static func davServers(from json: String) -> [DAVServer] {
        (try? JSONDecoder().decode([DAVServer].self, from: Data(json.utf8))) ?? []
    }

    var body: some View {
        SettingsPage(title: "媒体服务器") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Emby").font(.headline).foregroundStyle(Theme.text)
                    if !serverList.isEmpty {
                        ForEach(serverList) { server in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(server.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Theme.text)
                                        if server.id == EmbyClient.activeServerID {
                                            Text("当前")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Theme.ok, in: Capsule())
                                        }
                                    }
                                    Text(server.url)
                                        .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                Spacer()
                                if server.id != EmbyClient.activeServerID {
                                    Button("切换") {
                                        Haptics.tap()
                                        EmbyClient.setActiveServer(server.id)
                                        embyStatus = "已登录：\(server.name)"
                                    }
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                }
                                Button("删除") {
                                    EmbyClient.removeServer(server.id)
                                    refreshServers()
                                }
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.85))
                            }
                        }
                        Text("已登录的服务器都在这里，点「切换」换当前服务器；下面的表单可以再登录一个新服务器。")
                            .font(.caption).foregroundStyle(Theme.textDim)
                    }
                    field("服务器地址，如 http://192.168.1.10:8096", text: $embyURL)
                    field("用户名", text: $embyUser)
                    SecureField("密码", text: $embyPassword)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    HStack {
                        Button {
                            Task { await login() }
                        } label: {
                            Text(loggingIn ? "登录中…" : "登录")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(loggingIn)
                        if EmbyClient.configured {
                            Button("退出当前服务器") {
                                EmbyClient.signOut()
                                refreshServers()
                            }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        Text(embyStatus).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    if EmbyClient.configured {
                        NavigationLink { EmbyHomeView() } label: {
                            Label("打开 Emby 媒体库", systemImage: "play.rectangle.on.rectangle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("登录后从资源库页的「本地与网络」也能进。密码只在登录时发送给你的服务器，本机只存令牌。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("WebDAV").font(.headline).foregroundStyle(Theme.text)
                    ForEach(Self.davServers(from: webdavJSON)) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.subheadline).foregroundStyle(Theme.text)
                                Text(server.url).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            Spacer()
                            Button("删除") { removeDAV(server) }
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                    field("名称，如 家里 NAS", text: $davName)
                    field("地址，如 http://192.168.1.10:5005/video", text: $davURL)
                    field("用户名（可空）", text: $davUser)
                    SecureField("密码（可空）", text: $davPassword)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    Button {
                        addDAV()
                    } label: {
                        Label("添加 WebDAV", systemImage: "plus.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .disabled(davURL.isEmpty)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SMB / NAS").font(.headline).foregroundStyle(Theme.text)
                    ForEach(SMBServer.list(from: smbJSON)) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.subheadline).foregroundStyle(Theme.text)
                                Text(server.host).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            Spacer()
                            Button("删除") { removeSMB(server) }
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                    field("名称，如 家里 NAS", text: $smbName)
                    field("主机，如 192.168.1.10 或 nas.local", text: $smbHost)
                    field("用户名（可空 = guest）", text: $smbUser)
                    SecureField("密码（可空）", text: $smbPassword)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    Button {
                        addSMB()
                    } label: {
                        Label("添加 SMB 服务器", systemImage: "plus.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .disabled(smbHost.isEmpty)
                    Text("添加后从资源库页的「本地与网络」进入，选共享文件夹浏览、点视频直接播（走本机代理转发，支持拖动）。密码只存本机。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
        }
        .onAppear { refreshServers() }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.subheadline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    private func login() async {
        loggingIn = true
        defer { loggingIn = false }
        do {
            let name = try await EmbyClient.authenticate(
                base: embyURL.trimmingCharacters(in: .whitespaces),
                user: embyUser.trimmingCharacters(in: .whitespaces),
                password: embyPassword)
            UserDefaults.standard.set(embyUser, forKey: "emby.user")
            embyStatus = "已登录：\(name)"
            embyPassword = ""
            Haptics.success()
            refreshServers()
        } catch {
            embyStatus = error.localizedDescription
        }
    }

    /// Re-read the server list + status line after any change.
    private func refreshServers() {
        serverList = EmbyClient.servers
        embyStatus = EmbyClient.configured
            ? "已登录：\(EmbyClient.activeServerName)" : "未登录"
    }

    private func addDAV() {
        var servers = Self.davServers(from: webdavJSON)
        servers.append(DAVServer(
            name: davName.isEmpty ? (URL(string: davURL)?.host ?? "WebDAV") : davName,
            url: davURL.trimmingCharacters(in: .whitespaces),
            user: davUser, password: davPassword))
        if let data = try? JSONEncoder().encode(servers),
           let json = String(data: data, encoding: .utf8) {
            webdavJSON = json
        }
        davName = ""; davURL = ""; davUser = ""; davPassword = ""
    }

    private func removeDAV(_ server: DAVServer) {
        var servers = Self.davServers(from: webdavJSON)
        servers.removeAll { $0.url == server.url }
        if let data = try? JSONEncoder().encode(servers),
           let json = String(data: data, encoding: .utf8) {
            webdavJSON = json
        }
    }

    private func addSMB() {
        var servers = SMBServer.list(from: smbJSON)
        let host = smbHost.trimmingCharacters(in: .whitespaces)
        servers.append(SMBServer(
            name: smbName.isEmpty ? host : smbName,
            host: host, user: smbUser, password: smbPassword))
        smbJSON = SMBServer.json(from: servers)
        smbName = ""; smbHost = ""; smbUser = ""; smbPassword = ""
    }

    private func removeSMB(_ server: SMBServer) {
        var servers = SMBServer.list(from: smbJSON)
        servers.removeAll { $0.id == server.id }
        smbJSON = SMBServer.json(from: servers)
    }
}

// MARK: - WebDAV

enum WebDAVClient {
    struct Entry: Identifiable {
        var name: String
        var href: String      // absolute URL string
        var isFolder: Bool
        var size: Int64
        var id: String { href }
    }

    static func list(server: MediaServerSettingsView.DAVServer, path: String) async throws -> [Entry] {
        let target = path.isEmpty ? server.url : path
        guard let url = URL(string: target) else { throw messageError("地址不对") }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\" ?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>".utf8)
        if !server.user.isEmpty {
            let raw = "\(server.user):\(server.password)"
            request.setValue("Basic \(Data(raw.utf8).base64EncodedString())",
                             forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw messageError("WebDAV 返回 HTTP \(http.statusCode)")
        }
        let delegate = DAVXMLDelegate(base: target)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        // Drop the listed folder itself.
        return delegate.entries.filter { $0.href != target && $0.href != target + "/" }
    }

    static func authHeader(server: MediaServerSettingsView.DAVServer) -> [String: String] {
        guard !server.user.isEmpty else { return [:] }
        let raw = "\(server.user):\(server.password)"
        return ["Authorization": "Basic \(Data(raw.utf8).base64EncodedString())"]
    }

    private static func messageError(_ text: String) -> NSError {
        NSError(domain: "WebDAV", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private final class DAVXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [WebDAVClient.Entry] = []
    private let base: String
    private var href = ""
    private var isFolder = false
    private var size: Int64 = 0
    private var current = ""
    private var inCollection = false

    init(base: String) { self.base = base }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        current = element.lowercased()
        if current.hasSuffix("collection") { inCollection = true }
        if current.hasSuffix("response") { href = ""; isFolder = false; size = 0; inCollection = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current.hasSuffix("href") { href += string }
        if current.hasSuffix("getcontentlength") { size = Int64(string.trimmingCharacters(in: .whitespaces)) ?? size }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let tag = element.lowercased()
        if tag.hasSuffix("resourcetype") { isFolder = inCollection }
        if tag.hasSuffix("response") {
            let rawHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawHref.isEmpty else { return }
            let decoded = rawHref.removingPercentEncoding ?? rawHref
            let absolute: String
            if decoded.hasPrefix("http") {
                absolute = decoded
            } else if let baseURL = URL(string: base), let resolved = URL(string: decoded, relativeTo: baseURL) {
                absolute = resolved.absoluteString
            } else {
                absolute = decoded
            }
            let name = absolute.split(separator: "/").last.map(String.init) ?? absolute
            entries.append(WebDAVClient.Entry(
                name: name.removingPercentEncoding ?? name,
                href: absolute, isFolder: isFolder, size: size))
        }
        current = ""
    }
}

struct WebDAVBrowserView: View {
    let server: MediaServerSettingsView.DAVServer
    var path: String = ""
    @State private var entries: [WebDAVClient.Entry] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var playSelection: DAVPlay?

    private struct DAVPlay: Identifiable {
        var url: String
        var name: String
        var id: String { url }
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "mkv", "m3u8", "mov", "avi", "flv", "ts", "webm", "rmvb", "m4v",
    ]

    var body: some View {
        Group {
            if loading {
                // v2.13: bare spinner → row skeleton matching the
                // folder/file list footprint.
                SkeletonRowList(count: 6)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .transition(.opacity)
            } else if let errorText {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim).padding(24)
            } else {
                List {
                    ForEach(entries) { entry in
                        if entry.isFolder {
                            NavigationLink {
                                WebDAVBrowserView(server: server, path: entry.href)
                            } label: {
                                Label(entry.name, systemImage: "folder.fill")
                            }
                        } else if Self.videoExtensions.contains(
                            (entry.name as NSString).pathExtension.lowercased()) {
                            Button {
                                playSelection = DAVPlay(url: entry.href, name: entry.name)
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: "film")
                                    Spacer()
                                    if entry.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(Theme.textDim)
                                    }
                                }
                            }
                        } else {
                            Label(entry.name, systemImage: "doc")
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .animation(Theme.animStandard, value: loading)
        .navigationTitle(path.isEmpty ? server.name : (path.split(separator: "/").last.map(String.init) ?? server.name))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: sel.name, url: sel.url)],
                       startIndex: 0,
                       header: WebDAVClient.authHeader(server: server),
                       title: sel.name)
        }
        .task {
            do {
                entries = try await WebDAVClient.list(server: server, path: path)
                    .sorted { ($0.isFolder ? 0 : 1, $0.name) < ($1.isFolder ? 0 : 1, $1.name) }
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Local files

struct LocalFilesView: View {
    @State private var files: [URL] = []
    @State private var showImporter = false
    @State private var playSelection: LocalPlay?

    private struct LocalPlay: Identifiable {
        var url: URL
        var name: String
        var id: String { url.path }
    }

    private var mediaDir: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local-media")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("导入视频文件", systemImage: "plus.circle.fill")
                }
                Text("从「文件」App 选视频拷进呱壳（mkv/flv 等走 mpv 引擎播），拷完原文件可以删。")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
            ForEach(files, id: \.path) { url in
                Button {
                    playSelection = LocalPlay(url: url, name: url.lastPathComponent)
                } label: {
                    HStack {
                        Label(url.lastPathComponent, systemImage: "film")
                        Spacer()
                        Image(systemName: "play.circle").foregroundStyle(Theme.accent)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    try? FileManager.default.removeItem(at: files[index])
                }
                refresh()
            }
        }
        .listStyle(.plain)
        .navigationTitle("本地视频")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: sel.name, url: sel.url.absoluteString)],
                       startIndex: 0, header: [:], title: sel.name)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .audiovisualContent],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let target = mediaDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: url, to: target)
            }
            refresh()
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Library tab section: entry points into Emby / WebDAV / local
/// files. Added from LibraryView.
struct MediaHubSection: View {
    @AppStorage("webdav.servers") private var webdavJSON = "[]"
    @AppStorage("smb.servers") private var smbJSON = "[]"
    /// Emby movie/series totals for the Library card (v1.91);
    /// nil = not loaded yet, (nil, nil) = server didn't answer.
    @State private var embyCounts: (movies: Int?, series: Int?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地与网络").font(.headline).foregroundStyle(Theme.text)
            if EmbyClient.configured {
                NavigationLink { EmbyHomeView() } label: {
                    hubRow(icon: "play.rectangle.on.rectangle", title: "Emby 媒体库",
                           value: EmbyClient.servers.count > 1
                               ? "\(EmbyClient.activeServerName) · \(EmbyClient.base)"
                               : EmbyClient.base,
                           detail: embyCountsText)
                }
                .buttonStyle(.plain)
            }
            ForEach(MediaServerSettingsView.davServers(from: webdavJSON)) { server in
                NavigationLink { WebDAVBrowserView(server: server) } label: {
                    hubRow(icon: "externaldrive.connected.to.line.below", title: server.name, value: server.url)
                }
                .buttonStyle(.plain)
            }
            ForEach(SMBServer.list(from: smbJSON)) { server in
                NavigationLink { SMBSharesView(server: server) } label: {
                    hubRow(icon: "server.rack", title: server.name, value: "SMB · \(server.host)")
                }
                .buttonStyle(.plain)
            }
            NavigationLink { LocalFilesView() } label: {
                hubRow(icon: "folder", title: "本地视频", value: "导入手机里的视频文件")
            }
            .buttonStyle(.plain)
            NavigationLink { ModulesView() } label: {
                hubRow(icon: "puzzlepiece.extension", title: "模块", value: "Forward 规范 JS 模块")
            }
            .buttonStyle(.plain)
            if !EmbyClient.configured {
                Text("Emby / WebDAV / SMB 在「设置 → 媒体服务器」里添加。")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
        }
        .task {
            if EmbyClient.configured {
                embyCounts = await EmbyClient.libraryCounts()
            }
        }
    }

    /// "电影：12 · 剧集：34"；取不到的数字显示 —。
    private var embyCountsText: String? {
        guard let counts = embyCounts else { return nil }
        let movies = counts.movies.map(String.init) ?? "—"
        let series = counts.series.map(String.init) ?? "—"
        return "电影：\(movies) · 剧集：\(series)"
    }

    private func hubRow(icon: String, title: String, value: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Text(value).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
    }
}
