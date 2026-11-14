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

    @AppStorage("webdav.servers") private var webdavJSON = "[]"
    @State private var davName = ""
    @State private var davURL = ""
    @State private var davUser = ""
    @State private var davPassword = ""

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
                    field("服务器地址，如 http://192.168.1.10:8096", text: $embyURL)
                    field("用户名", text: $embyUser)
                    SecureField("密码", text: $embyPassword)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
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
                            Button("退出登录") {
                                EmbyClient.signOut()
                                embyStatus = "未登录"
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
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
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
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.subheadline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
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
        } catch {
            embyStatus = error.localizedDescription
        }
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
                ProgressView().tint(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地与网络").font(.headline).foregroundStyle(Theme.text)
            if EmbyClient.configured {
                NavigationLink { EmbyHomeView() } label: {
                    hubRow(icon: "play.rectangle.on.rectangle", title: "Emby 媒体库", value: EmbyClient.base)
                }
                .buttonStyle(.plain)
            }
            ForEach(MediaServerSettingsView.davServers(from: webdavJSON)) { server in
                NavigationLink { WebDAVBrowserView(server: server) } label: {
                    hubRow(icon: "externaldrive.connected.to.line.below", title: server.name, value: server.url)
                }
                .buttonStyle(.plain)
            }
            NavigationLink { LocalFilesView() } label: {
                hubRow(icon: "folder", title: "本地视频", value: "导入手机里的视频文件")
            }
            .buttonStyle(.plain)
            if !EmbyClient.configured {
                Text("Emby / WebDAV 在「设置 → 媒体服务器」里添加。")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
        }
    }

    private func hubRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Text(value).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(14)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12))
    }
}
