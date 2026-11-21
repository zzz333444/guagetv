import Foundation
import SwiftUI
import AMSMB2

/// SMB/NAS browsing + playback (v2.14). The browsing side talks
/// to the share through AMSMB2 (open-source: Swift wrapper MIT,
/// libsmb2 LGPL v2.1, linked as a dynamic framework). Neither
/// AVPlayer nor mpv can open smb:// URLs, so playback goes
/// through the loopback proxy: SMBProxy registers a dedicated
/// connection per file and LocalProxyServer serves /smb/<token>/
/// <filename> with HTTP Range replies backed by AMSMB2 ranged
/// reads. Servers are configured in 设置 → 媒体服务器， entered
/// from the Library tab's 本地与网络 section — same shape as
/// the WebDAV support in MediaServers.swift.

// MARK: - Server model

struct SMBServer: Codable, Identifiable {
    var name: String
    var host: String          // 192.168.1.10 or nas.local (no scheme)
    var user: String          // empty = guest
    var password: String
    var id: String { host + "|" + user }

    static func list(from json: String) -> [SMBServer] {
        (try? JSONDecoder().decode([SMBServer].self, from: Data(json.utf8))) ?? []
    }

    static func json(from servers: [SMBServer]) -> String {
        guard let data = try? JSONEncoder().encode(servers),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

// MARK: - Client

enum SMBClient {
    struct Entry: Identifiable {
        var name: String
        var path: String      // path inside the share, "" root joins
        var isFolder: Bool
        var size: Int64
        var id: String { path }
    }

    static func makeManager(_ server: SMBServer) throws -> SMB2Manager {
        let host = server.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let url = URL(string: "smb://" + host) else {
            throw messageError("SMB 主机地址无效：\(server.host)")
        }
        let user = server.user.isEmpty ? "guest" : server.user
        let credential = URLCredential(user: user, password: server.password,
                                       persistence: .none)
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw messageError("SMB 连接初始化失败：\(server.host)")
        }
        // v2.24: AMSMB2 单次操作默认 60 秒超时——死 NAS 要等满
        // 一分钟才报错，浏览体验太差；局域网内 30 秒绰绰有余，
        // 播放的分块读（8MB）同样够用，超时后由 describe 报中文。
        manager.timeout = 30
        return manager
    }

    /// Map a libsmb2 / AMSMB2 failure to a Chinese reason (v2.24):
    /// the raw localizedDescription is an English POSIX string on
    /// most devices ("Operation timed out") and names no cause.
    /// Callers prefix the action ("读取目录失败：…").
    static func describe(_ error: Error) -> String {
        let code: POSIXError.Code?
        if let posix = error as? POSIXError {
            code = posix.code
        } else {
            let ns = error as NSError
            code = ns.domain == NSPOSIXErrorDomain
                ? POSIXError.Code(rawValue: ns.code) : nil
        }
        switch code {
        case .ETIMEDOUT:
            return "连接超时（30 秒），请确认 NAS 已开机且在同一局域网"
        case .ECONNREFUSED:
            return "连接被拒绝，请确认 NAS 的 SMB 服务已开启、端口未被防火墙拦截"
        case .EHOSTUNREACH, .ENETUNREACH:
            return "找不到 NAS 主机，请确认 IP/主机名正确且在同一局域网"
        case .EACCES:
            return "用户名或密码不对，或该账号无权访问此共享"
        case .ENOENT:
            return "找不到该共享或文件，请确认共享名与路径"
        default:
            return error.localizedDescription
        }
    }

    static func listShares(_ manager: SMB2Manager) async throws -> [(name: String, comment: String)] {
        do {
            return try await manager.listShares()
        } catch {
            throw messageError("SMB 读取共享列表失败：\(describe(error))")
        }
    }

    static func list(_ manager: SMB2Manager, share: String, path: String) async throws -> [Entry] {
        do {
            try await manager.connectShare(name: share)
            let raw = try await manager.contentsOfDirectory(atPath: path)
            var entries: [Entry] = []
            for dict in raw {
                guard let name = dict[.nameKey] as? String else { continue }
                let isFolder = (dict[.isDirectoryKey] as? Bool) ?? false
                let size = (dict[.fileSizeKey] as? NSNumber)?.int64Value
                    ?? (dict[.fileSizeKey] as? Int64) ?? 0
                let childPath = path.isEmpty ? name : path + "/" + name
                entries.append(Entry(name: name, path: childPath,
                                     isFolder: isFolder, size: size))
            }
            return entries.sorted { ($0.isFolder ? 0 : 1, $0.name) < ($1.isFolder ? 0 : 1, $1.name) }
        } catch {
            throw messageError("SMB 读取目录失败：\(describe(error))")
        }
    }

    static func messageError(_ text: String) -> NSError {
        NSError(domain: "GuageSMB", code: -1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}

// MARK: - Playback proxy

/// One registered file = one dedicated SMB connection, so file
/// browsing can keep using its own connection while the player
/// streams. LocalProxyServer's /smb route lands in serve().
enum SMBProxy {
    private final class Session {
        let manager: SMB2Manager
        let path: String
        let size: Int64
        init(manager: SMB2Manager, path: String, size: Int64) {
            self.manager = manager
            self.path = path
            self.size = size
        }
    }

    private static var sessions: [String: Session] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()
    /// Per-reply cap: players ask for wide ranges; answering with
    /// a correct partial Content-Range keeps memory bounded and
    /// both engines simply re-request the next chunk.
    private static let maxChunk: Int64 = 8 * 1024 * 1024

    /// Connects a fresh manager to the share, sizes the file and
    /// returns the loopback URL the player should open. The file
    /// name stays as the last path component so PlayerView's
    /// extension heuristic still picks mpv for mkv & friends.
    static func prepare(server: SMBServer, share: String,
                        path: String, fileName: String) async throws -> String {
        // v2.24 audit: ensureStarted() can block up to 2s on the
        // listener handshake, and prepare() runs on the caller's
        // actor (often main) — never wait there. Fast path when
        // the server is already up; otherwise start it off-thread.
        let root: String?
        if let running = LocalProxyServer.shared.rootIfRunning {
            root = running
        } else {
            root = await Task.detached(priority: .userInitiated) {
                _ = LocalProxyServer.shared.ensureStarted()
                return LocalProxyServer.shared.rootBase
            }.value
        }
        guard let root else {
            throw SMBClient.messageError("本机代理启动失败，无法播放 SMB 文件")
        }
        let manager = try SMBClient.makeManager(server)
        do {
            try await manager.connectShare(name: share)
            let attrs = try await manager.attributesOfItem(atPath: path)
            let size = (attrs[.fileSizeKey] as? NSNumber)?.int64Value
                ?? (attrs[.fileSizeKey] as? Int64) ?? 0
            guard size > 0 else {
                throw SMBClient.messageError("SMB 文件大小为 0：\(fileName)")
            }
            let token = UUID().uuidString
            lock.lock()
            sessions[token] = Session(manager: manager, path: path, size: size)
            order.append(token)
            var evicted: [Session] = []
            while order.count > 4 {
                let old = order.removeFirst()
                if let session = sessions.removeValue(forKey: old) {
                    evicted.append(session)
                }
            }
            lock.unlock()
            for session in evicted {
                Task { try? await session.manager.disconnectShare() }
            }
            let encoded = fileName.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? fileName
            return "\(root)/smb/\(token)/\(encoded)"
        } catch let error as NSError where error.domain == "GuageSMB" {
            throw error
        } catch {
            throw SMBClient.messageError("SMB 播放准备失败：\(SMBClient.describe(error))")
        }
    }

    /// Synchronous Range serve for LocalProxyServer.dispatch;
    /// bridges the async AMSMB2 read with a semaphore (the proxy
    /// already calls dispatch on a background queue).
    static func serve(token: String, range: String?) -> (Int, String, Data, [String: String]) {
        lock.lock()
        let session = sessions[token]
        lock.unlock()
        guard let session else {
            return (404, "text/plain; charset=utf-8", Data("smb session not found".utf8), [:])
        }
        let size = session.size
        let (start, end) = parseRange(range, size: size)
        guard start < size, end >= start else {
            return (416, "text/plain; charset=utf-8", Data("range not satisfiable".utf8),
                    ["Content-Range": "bytes */\(size)"])
        }
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: Result<Data, Error>?
        let manager = session.manager
        let path = session.path
        let wanted = start..<(end + 1)
        Task {
            do {
                let data: Data = try await manager.contents(
                    atPath: path,
                    range: UInt64(wanted.lowerBound)..<UInt64(wanted.upperBound))
                fetched = .success(data)
            } catch {
                fetched = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success, let fetched else {
            return (504, "text/plain; charset=utf-8", Data("smb read timeout".utf8), [:])
        }
        switch fetched {
        case .failure(let error):
            return (502, "text/plain; charset=utf-8",
                    Data("SMB 读取失败：\(SMBClient.describe(error))".utf8), [:])
        case .success(let data):
            let ext = (path as NSString).pathExtension.lowercased()
            let type = ext == "mp4" || ext == "m4v" ? "video/mp4"
                : ext == "mp3" ? "audio/mpeg" : "application/octet-stream"
            return (206, type, data,
                    ["Content-Range": "bytes \(start)-\(start + Int64(data.count) - 1)/\(size)"])
        }
    }

    /// Inclusive (start, end) for a Range header, chunk-capped.
    private static func parseRange(_ header: String?, size: Int64) -> (Int64, Int64) {
        guard let header, header.hasPrefix("bytes=") else {
            return (0, min(maxChunk, size) - 1)
        }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (0, min(maxChunk, size) - 1) }
        if parts[0].isEmpty {
            // Suffix range: last N bytes.
            let n = Int64(parts[1]) ?? 0
            guard n > 0 else { return (0, min(maxChunk, size) - 1) }
            let start = max(0, size - n)
            return (start, min(start + maxChunk, size) - 1)
        }
        let start = Int64(parts[0]) ?? 0
        let askedEnd = parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? size - 1)
        let end = min(askedEnd, start + maxChunk - 1, size - 1)
        return (start, end)
    }
}

// MARK: - Views

private struct SMBPlay: Identifiable {
    var url: String
    var name: String
    var id: String { url }
}

struct SMBSharesView: View {
    let server: SMBServer
    @State private var manager: SMB2Manager?
    @State private var shares: [(name: String, comment: String)] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if loading {
                SkeletonRowList(count: 5)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .transition(.opacity)
            } else if let errorText {
                Text(errorText).font(.subheadline).foregroundStyle(Theme.textDim).padding(24)
            } else if let manager {
                List {
                    ForEach(shares, id: \.name) { share in
                        NavigationLink {
                            SMBBrowserView(server: server, manager: manager,
                                           share: share.name, path: "")
                        } label: {
                            HStack {
                                Label(share.name, systemImage: "externaldrive.fill")
                                Spacer()
                                if !share.comment.isEmpty {
                                    Text(share.comment)
                                        .font(.caption).foregroundStyle(Theme.textDim)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.25), value: loading)
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let created = try SMBClient.makeManager(server)
                manager = created
                shares = try await SMBClient.listShares(created)
                    .filter { !$0.name.hasSuffix("$") }
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
        }
    }
}

struct SMBBrowserView: View {
    let server: SMBServer
    let manager: SMB2Manager
    let share: String
    var path: String = ""
    @State private var entries: [SMBClient.Entry] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var playSelection: SMBPlay?
    @State private var preparing = false

    private static let videoExtensions: Set<String> = [
        "mp4", "mkv", "m3u8", "mov", "avi", "flv", "ts", "webm", "rmvb", "m4v",
    ]

    var body: some View {
        Group {
            if loading {
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
                                SMBBrowserView(server: server, manager: manager,
                                               share: share, path: entry.path)
                            } label: {
                                Label(entry.name, systemImage: "folder.fill")
                            }
                        } else if Self.videoExtensions.contains(
                            (entry.name as NSString).pathExtension.lowercased()) {
                            Button {
                                play(entry)
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
                            .disabled(preparing)
                        } else {
                            Label(entry.name, systemImage: "doc")
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if preparing {
                        Text("连接 SMB 准备播放…")
                            .font(.footnote).foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassCapsule()
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: loading)
        .navigationTitle(path.isEmpty ? share : (path.split(separator: "/").last.map(String.init) ?? share))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playSelection) { sel in
            PlayerView(episodes: [PlayerView.EpisodeRef(name: sel.name, url: sel.url)],
                       startIndex: 0, header: [:], title: sel.name)
        }
        .task {
            do {
                entries = try await SMBClient.list(manager, share: share, path: path)
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
        }
    }

    private func play(_ entry: SMBClient.Entry) {
        preparing = true
        Task {
            do {
                let url = try await SMBProxy.prepare(server: server, share: share,
                                                     path: entry.path, fileName: entry.name)
                playSelection = SMBPlay(url: url, name: entry.name)
            } catch {
                errorText = error.localizedDescription
            }
            preparing = false
        }
    }
}
