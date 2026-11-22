import Foundation
import Network

/// Loopback HTTP server for py spiders' localProxy (v1.38).
/// FongMi-class shells run a proxy on 127.0.0.1 that spiders
/// address through getProxyUrl(); until now ours returned "", so
/// spiders that hand out proxy URLs (segmented m3u8, decrypted
/// images, key relays) produced dead links. The server accepts
/// /proxy/<token>?… requests, forwards the query to the owning
/// spider's localProxy via the bridge, and streams the result
/// back — including single-range replies for media fetches.
final class LocalProxyServer {
    static let shared = LocalProxyServer()

    private var listener: NWListener?
    private(set) var baseURL: String?
    private(set) var rootBase: String?
    private let lock = NSLock()

    /// The server root (no path) when it is already running —
    /// the HLS filter checks this without ever blocking a view.
    var rootIfRunning: String? {
        lock.lock()
        defer { lock.unlock() }
        return rootBase
    }

    /// Fire-and-forget warm-up (PlayerView calls this on appear
    /// so the HLS filter is ready by the time playback starts).
    func startInBackground() {
        if rootIfRunning != nil { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.ensureStarted()
        }
    }

    /// Idempotent and cheap once running. Waits briefly for the
    /// ephemeral port on first start; nil when the listener
    /// could not come up (callers then leave getProxyUrl empty,
    /// which is the pre-v1.38 behaviour).
    func ensureStarted() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let baseURL { return baseURL }
        guard listener == nil else { return baseURL }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let created = try? NWListener(using: params, on: .any) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        created.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = created.port?.rawValue {
                self?.rootBase = "http://127.0.0.1:\(port)"
                self?.baseURL = "http://127.0.0.1:\(port)/proxy"
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        created.newConnectionHandler = { [weak self] conn in
            self?.serve(conn)
        }
        created.start(queue: DispatchQueue(label: "guage.localproxy.listener"))
        listener = created
        _ = ready.wait(timeout: .now() + 2)
        return baseURL
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "guage.localproxy.conn"))
        receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: 0..<range.lowerBound)
                self.respond(conn, head: head)
                return
            }
            if isComplete || error != nil || buffer.count > 131072 {
                conn.cancel()
                return
            }
            self.receive(conn, accumulated: buffer)
        }
    }

    private func respond(_ conn: NWConnection, head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let target = lines.first?.components(separatedBy: " ").dropFirst().first ?? "/"
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, contentType, body, extra) = self.dispatch(target: target,
                                                                   range: headers["range"])
            self.send(conn, status: status, contentType: contentType, body: body,
                      extraHeaders: extra, rangeHeader: headers["range"])
        }
    }

    /// Routes: /proxy/<token>… into the spider bridge, /hls and
    /// /seg into the HLS ad filter; anything else 404s.
    private func dispatch(target: String, range: String?) -> (Int, String, Data, [String: String]) {
        guard let components = URLComponents(string: "http://local" + target) else {
            return (404, "text/plain; charset=utf-8", Data("not found".utf8), [:])
        }
        if components.path == "/hls/media.m3u8" {
            return handleHLS(components)
        }
        if components.path.hasPrefix("/seg/") {
            return handleSegment(components, range: range)
        }
        if components.path.hasPrefix("/smb/") {
            // SMB/NAS playback (v2.14): /smb/<token>/<filename>,
            // served from the registered AMSMB2 connection.
            let token = String(components.path.dropFirst("/smb/".count))
                .components(separatedBy: "/").first ?? ""
            guard !token.isEmpty else {
                return (404, "text/plain; charset=utf-8", Data("missing token".utf8), [:])
            }
            return SMBProxy.serve(token: token, range: range)
        }
        guard components.path.hasPrefix("/proxy/") else {
            return (404, "text/plain; charset=utf-8", Data("not found".utf8), [:])
        }
        let token = String(components.path.dropFirst("/proxy/".count))
            .components(separatedBy: "/").first ?? ""
        guard !token.isEmpty else {
            return (404, "text/plain; charset=utf-8", Data("missing token".utf8), [:])
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }
        let rest = components.path.dropFirst("/proxy/\(token)".count)
        if !rest.isEmpty { params["_path"] = String(rest) }
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            let result = try SpiderBridge.shared.proxyDispatch(token: String(token),
                                                               paramsJSON: paramsJSON)
            let status = result["status"] as? Int ?? 200
            let type = result["type"] as? String ?? "application/octet-stream"
            let body = (result["body_b64"] as? String)
                .flatMap { Data(base64Encoded: $0) } ?? Data()
            let extra = (result["headers"] as? [String: String]) ?? [:]
            return (status, type, body, extra)
        } catch {
            return (502, "text/plain; charset=utf-8",
                    Data("localProxy 失败：\(error.localizedDescription)".utf8), [:])
        }
    }

    // MARK: HLS ad filter endpoints

    /// v2.31 HLS 缓存：播放列表与分片各一份内存缓存。
    /// 播放列表：直播 2 秒 TTL（引擎轮询频繁，上游每次都
    /// 重拉既慢又费请求；2 秒仍跟得上直播边缘），点播
    /// 300 秒（播放列表静态）。分片按上游地址缓存整段
    /// （上限 32 段 / 48 MB，最旧先淘汰，300 秒 TTL；分片
    /// 地址本身不可变，直播/点播都可缓存）。Range 请求命中
    /// 整段缓存时由 send() 再按 Range 切片，无需另存分片。
    private struct CachedPlaylist { var text: String; var savedAt: Date; var isLive: Bool }
    private struct CachedSegment { var data: Data; var type: String; var status: Int; var savedAt: Date }
    private var playlistCache: [String: CachedPlaylist] = [:]
    private var segmentCache: [String: CachedSegment] = [:]
    private var segmentCacheOrder: [String] = []
    private let hlsCacheLock = NSLock()

    private func playlistCached(for key: String) -> String? {
        hlsCacheLock.lock()
        defer { hlsCacheLock.unlock() }
        guard let entry = playlistCache[key] else { return nil }
        let ttl: TimeInterval = entry.isLive ? 2 : 300
        guard Date().timeIntervalSince(entry.savedAt) < ttl else {
            playlistCache.removeValue(forKey: key)
            return nil
        }
        return entry.text
    }

    private func storePlaylist(key: String, text: String, isLive: Bool) {
        hlsCacheLock.lock()
        defer { hlsCacheLock.unlock() }
        playlistCache[key] = CachedPlaylist(text: text, savedAt: Date(), isLive: isLive)
    }

    private func segmentCached(for key: String) -> CachedSegment? {
        hlsCacheLock.lock()
        defer { hlsCacheLock.unlock() }
        guard let entry = segmentCache[key],
              Date().timeIntervalSince(entry.savedAt) < 300 else {
            segmentCache.removeValue(forKey: key)
            segmentCacheOrder.removeAll { $0 == key }
            return nil
        }
        return entry
    }

    private func storeSegment(key: String, data: Data, type: String, status: Int) {
        hlsCacheLock.lock()
        defer { hlsCacheLock.unlock() }
        if segmentCache[key] == nil { segmentCacheOrder.append(key) }
        segmentCache[key] = CachedSegment(data: data, type: type, status: status, savedAt: Date())
        var totalBytes = segmentCache.values.reduce(0) { $0 + $1.data.count }
        while (segmentCache.count > 32 || totalBytes > 48 * 1024 * 1024),
              let oldest = segmentCacheOrder.first {
            segmentCacheOrder.removeFirst()
            if let removed = segmentCache.removeValue(forKey: oldest) {
                totalBytes -= removed.data.count
            }
        }
    }

    /// Prefetch the first 3 segments of a freshly rewritten
    /// playlist into the segment cache, so the engine's first
    /// segment requests hit memory instead of the upstream.
    /// Fire-and-forget on a background queue; a slow upstream
    /// here never blocks the playlist response itself.
    private func prefetchSegments(playlistText: String, base: URL, headers: [String: String]) {
        let lines = playlistText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let targets = Array(lines.prefix(3)).compactMap {
            URL(string: $0, relativeTo: base)?.absoluteString
        }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for target in targets {
                if self.segmentCached(for: target) != nil { continue }
                guard let url = URL(string: target) else { continue }
                let (status, type, data, _) = HLSAdFilter.fetch(url: url, headers: headers, range: nil, timeout: 15)
                if status == 200, !data.isEmpty {
                    self.storeSegment(key: target, data: data, type: type, status: status)
                }
            }
        }
    }

    private func queryMap(_ components: URLComponents) -> [String: String] {
        var map: [String: String] = [:]
        for item in components.queryItems ?? [] {
            map[item.name] = item.value ?? ""
        }
        return map
    }

    private func handleHLS(_ components: URLComponents) -> (Int, String, Data, [String: String]) {
        let query = queryMap(components)
        guard let target = query["u"], let url = URL(string: target),
              let root = rootIfRunning else {
            return (400, "text/plain; charset=utf-8", Data("bad hls request".utf8), [:])
        }
        let headers = HLSAdFilter.decodeHeaders(query["hdrs"])
        // v2.31: live playlists are re-polled by the engine every
        // few seconds — serve a 2s-old rewrite from memory instead
        // of re-fetching upstream each time. A slow playlist fetch
        // never blocks segment fetches: each connection runs on
        // its own global-queue thread (see respond/dispatch), so
        // playlist and /seg requests proceed concurrently.
        let cacheKey = target + "|" + (query["hdrs"] ?? "")
        if let cached = playlistCached(for: cacheKey) {
            Diagnostics.recordHLSPlaylistCacheHit()
            return (200, "application/vnd.apple.mpegurl",
                    Data(cached.utf8), [:])
        }
        let started = Date()
        // v2.17: playlist fetch on the start path — 8s budget.
        let (status, type, data, _) = HLSAdFilter.fetch(url: url, headers: headers, range: nil, timeout: 8)
        Diagnostics.recordHLSPlaylist(ms: Int(Date().timeIntervalSince(started) * 1000))
        guard status == 200 else {
            return (status, type, data, [:])
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let result = HLSAdFilter.rewrite(playlist: text, base: url,
                                         root: root, headersB64: query["hdrs"])
        if result.removed > 0 {
            Diagnostics.log("去广告", "移除 \(result.removed) 段（约 \(Int(result.removedSeconds)) 秒）：\(target)")
        }
        let isLive = !text.contains("#EXT-X-ENDLIST")
        storePlaylist(key: cacheKey, text: result.text, isLive: isLive)
        // Master playlists list variants, not segments — only
        // prefetch from a media playlist.
        if !isLive, !text.contains("#EXT-X-STREAM-INF") {
            prefetchSegments(playlistText: text, base: url, headers: headers)
        }
        return (200, "application/vnd.apple.mpegurl",
                Data(result.text.utf8), [:])
    }

    private func handleSegment(_ components: URLComponents,
                               range: String?) -> (Int, String, Data, [String: String]) {
        let query = queryMap(components)
        guard let target = query["u"], let url = URL(string: target) else {
            return (400, "text/plain; charset=utf-8", Data("bad segment request".utf8), [:])
        }
        let headers = HLSAdFilter.decodeHeaders(query["hdrs"])
        // v2.31: whole-segment memory cache (see the cache note
        // above); a Range request that hits the full entry is
        // sliced by send() afterwards.
        if let cached = segmentCached(for: target) {
            Diagnostics.recordSegmentCacheHit()
            return (cached.status, cached.type, cached.data, [:])
        }
        let started = Date()
        // v2.17: segment fetch — 15s budget (was a flat 20s for
        // both playlist and segment); a dead segment 502s and the
        // engine retries instead of hanging the episode.
        let (status, type, data, responseHeaders) =
            HLSAdFilter.fetch(url: url, headers: headers, range: range, timeout: 15)
        Diagnostics.recordHLSSegment(ms: Int(Date().timeIntervalSince(started) * 1000))
        var extra: [String: String] = [:]
        for (key, value) in responseHeaders
        where ["content-range", "accept-ranges"].contains(key.lowercased()) {
            extra[key] = value
        }
        if range == nil, status == 200, !data.isEmpty {
            storeSegment(key: target, data: data, type: type, status: status)
        }
        return (status, type, data, extra)
    }

    private func send(_ conn: NWConnection, status: Int, contentType: String,
                      body: Data, extraHeaders: [String: String], rangeHeader: String?) {
        var payload = body
        var statusLine = "HTTP/1.1 \(status)"
        var headers: [String: String] = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Connection": "close",
        ]
        for (k, v) in extraHeaders
        where !["content-type", "content-length"].contains(k.lowercased()) {
            headers[k] = v
        }
        if let rangeHeader, status == 200,
           let match = rangeHeader.range(of: #"bytes=(\d+)-(\d*)"#,
                                          options: .regularExpression) {
            let spec = String(rangeHeader[match])
                .dropFirst("bytes=".count).components(separatedBy: "-")
            let start = Int(spec[0]) ?? 0
            let end = spec.count > 1 && !spec[1].isEmpty
                ? min(Int(spec[1]) ?? body.count - 1, body.count - 1)
                : body.count - 1
            if start >= 0, start <= end, start < body.count {
                payload = body.subdata(in: start..<(end + 1))
                statusLine = "HTTP/1.1 206"
                headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
            }
        }
        headers["Content-Length"] = "\(payload.count)"
        var head = statusLine + "\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
