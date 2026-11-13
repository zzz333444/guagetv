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
    private let lock = NSLock()

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
            let (status, contentType, body, extra) = self.dispatch(target: target)
            self.send(conn, status: status, contentType: contentType, body: body,
                      extraHeaders: extra, rangeHeader: headers["range"])
        }
    }

    /// Route /proxy/<token>… into the bridge; anything else 404s.
    private func dispatch(target: String) -> (Int, String, Data, [String: String]) {
        guard let components = URLComponents(string: "http://local" + target),
              components.path.hasPrefix("/proxy/") else {
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
                payload = body.subdata(in: start...end)
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
