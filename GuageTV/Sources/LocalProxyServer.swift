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
        // v2.17: playlist fetch on the start path — 8s budget.
        let (status, type, data, _) = HLSAdFilter.fetch(url: url, headers: headers, range: nil, timeout: 8)
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
        // v2.17: segment fetch — 15s budget (was a flat 20s for
        // both playlist and segment); a dead segment 502s and the
        // engine retries instead of hanging the episode.
        let (status, type, data, responseHeaders) =
            HLSAdFilter.fetch(url: url, headers: headers, range: range, timeout: 15)
        var extra: [String: String] = [:]
        for (key, value) in responseHeaders
        where ["content-range", "accept-ranges"].contains(key.lowercased()) {
            extra[key] = value
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
