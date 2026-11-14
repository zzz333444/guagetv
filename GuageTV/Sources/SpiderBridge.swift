import Foundation

/// Typed façade over the embedded Python runtime, speaking the
/// spider_runner JSON contract:
///   load_spider(path, extend) -> {"ok": true, "name": …}
///   call(method, argsJSON)    -> {"ok": true, "result": …}
/// Failures throw BridgeFailure carrying the Python traceback text, so
/// the UI can show exactly what the spider complained about.
final class SpiderBridge {
    static let shared = SpiderBridge()

    struct BridgeFailure: Error, CustomStringConvertible, LocalizedError {
        let message: String
        var description: String { message }
        // Without LocalizedError, surfaces that print
        // `error.localizedDescription` show the opaque
        // "The operation couldn't be completed. (…BridgeFailure error 1.)"
        // instead of the Python traceback this type exists to carry.
        var errorDescription: String? { message }
    }

    /// Memo of the last successful load. The runner holds exactly one
    /// spider, and browsing a single site hammers home / category /
    /// detail / search through the same (path, extend) — re-exec'ing
    /// the module and re-running its init on every hop is the main py
    /// latency, so an identical repeat load returns the cached name
    /// without touching the interpreter. A failed load clears the
    /// memo: the runner drops its spider on failure (_spider = None),
    /// so whatever was loaded before is gone too.
    private let memoLock = NSLock()
    private var loadedMemo: (path: String, extend: String, name: String)?

    // MARK: anti-wedge breaker （防卡死）

    /// All py calls share one serial interpreter queue, so a
    /// spider hanging in a no-timeout network call wedges every
    /// later py site behind it — and the call can never report
    /// its own timeout. A side watchdog therefore marks any
    /// invoke still in flight after 20s against the spider it
    /// belongs to; three strikes and that spider's loads fail
    /// fast with an explanation instead of queueing behind the
    /// corpse. A completed invoke clears the streak. Only the
    /// wedged spider is quarantined — the queue itself stays
    /// wedged until the app relaunches (nothing in-process can
    /// safely kill a hung C call), which the poison message and
    /// 关于 → Python 健康检查 both say out loud.
    private let breakerLock = NSLock()
    private var timeoutStreak: [String: Int] = [:]
    private var activePath: String?
    private var inFlight: [UUID: String] = [:]
    private var invokeStarted: [UUID: Date] = [:]

    private func beginInvoke(path: String?) -> UUID {
        let token = UUID()
        breakerLock.lock()
        inFlight[token] = path ?? activePath ?? ""
        invokeStarted[token] = Date()
        breakerLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkStuck(token)
        }
        return token
    }

    private func checkStuck(_ token: UUID) {
        breakerLock.lock()
        guard let path = inFlight[token], !path.isEmpty else {
            breakerLock.unlock()
            return
        }
        let streak = (timeoutStreak[path] ?? 0) + 1
        timeoutStreak[path] = streak
        breakerLock.unlock()
        Diagnostics.log("py", "蜘蛛 20 秒无响应（第 \(streak) 次）：\((path as NSString).lastPathComponent)")
    }

    private func endInvoke(_ token: UUID, success: Bool) {
        breakerLock.lock()
        let path = inFlight.removeValue(forKey: token)
        let started = invokeStarted.removeValue(forKey: token)
        if success, let path, !path.isEmpty { timeoutStreak[path] = 0 }
        breakerLock.unlock()
        if let path, !path.isEmpty, let started {
            let name = (path as NSString).lastPathComponent
            let stem = name.hasSuffix(".py") ? String(name.dropLast(3)) : name
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            SiteHealth.record("py:" + stem, ok: success, ms: ms)
        }
    }

    func isPoisoned(path: String) -> Bool {
        breakerLock.lock()
        defer { breakerLock.unlock() }
        return (timeoutStreak[path] ?? 0) >= 3
    }

    func resetBreaker() {
        breakerLock.lock()
        timeoutStreak.removeAll()
        breakerLock.unlock()
    }

    /// One-time proxy base hand-off: once the loopback server is
    /// up, the runner binds getProxyUrl() for every spider (new
    /// and already loaded). Retried on each real load until sent.
    private var proxyBaseSent = false

    private func ensureProxyBase() {
        guard !proxyBaseSent, let base = LocalProxyServer.shared.ensureStarted() else { return }
        proxyBaseSent = (try? PythonRuntime.shared.invoke("set_proxy_base", [base])) != nil
    }

    /// localProxy dispatch for LocalProxyServer; returns the
    /// runner's normalized {status, type, headers, body_b64}.
    func proxyDispatch(token: String, paramsJSON: String) throws -> [String: Any] {
        let text = try PythonRuntime.shared.invoke("proxy_dispatch", [token, paramsJSON])
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeFailure(message: "桥接返回无法解析：\(text.prefix(160))")
        }
        if (dict["ok"] as? Bool) != true {
            throw BridgeFailure(message: (dict["error"] as? String) ?? "localProxy 调用失败")
        }
        return dict
    }

    /// Load (or re-activate) a spider file from the sandbox; returns the
    /// spider's display name. `extend` is the site's ext payload verbatim.
    func loadSpider(path: String, extend: String) async throws -> String {
        if isPoisoned(path: path) {
            throw BridgeFailure(message: "这个蜘蛛已连续多次 20 秒无响应，已暂停调用（防卡死）。若所有 py 站都这样，多半是某个蜘蛛把 Python 队列占死了，重启呱壳后恢复；单个站这样则是它自己挂了。")
        }
        breakerLock.lock()
        activePath = path
        breakerLock.unlock()
        memoLock.lock()
        let memo = loadedMemo
        memoLock.unlock()
        if let memo, memo.path == path, memo.extend == extend {
            return memo.name
        }
        do {
            let dict = try await invokeJSON("load_spider", [path, extend])
            let name = dict["name"] as? String ?? "Spider"
            memoLock.lock()
            loadedMemo = (path, extend, name)
            memoLock.unlock()
            return name
        } catch {
            memoLock.lock()
            loadedMemo = nil
            memoLock.unlock()
            throw error
        }
    }

    /// Call one protocol method on the currently loaded spider.
    func call(_ method: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let dict = try await invokeJSON("call", [method, argsJSON])
        return dict["result"] as? [String: Any] ?? [:]
    }

    private func invokeJSON(_ function: String, _ args: [String]) async throws -> [String: Any] {
        let token = beginInvoke(path: function == "load_spider" ? args.first : nil)
        do {
            let text = try await Task.detached(priority: .userInitiated) { [self] in
                // Inside the detached task on purpose: the first call
                // boots the interpreter, which must not block the UI.
                if function == "load_spider" { ensureProxyBase() }
                return try PythonRuntime.shared.invoke(function, args)
            }.value
            guard let data = text.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                endInvoke(token, success: false)
                throw BridgeFailure(message: "桥接返回无法解析：\(text.prefix(160))")
            }
            if (dict["ok"] as? Bool) != true {
                endInvoke(token, success: false)
                let message = (dict["error"] as? String) ?? "Spider 调用失败"
                Diagnostics.log("py", "\(function)：\(message)")
                throw BridgeFailure(message: message)
            }
            endInvoke(token, success: true)
            return dict
        } catch let error as BridgeFailure {
            throw error
        } catch {
            endInvoke(token, success: false)
            throw error
        }
    }

    // MARK: Protocol conveniences

    func homeContent() async throws -> [String: Any] { try await call("homeContent") }
    func homeVideoContent() async throws -> [String: Any] { try await call("homeVideoContent") }
    func categoryContent(tid: String, pg: Int) async throws -> [String: Any] {
        try await call("categoryContent", args: ["tid": tid, "pg": pg])
    }
    func detailContent(ids: [String]) async throws -> [String: Any] {
        try await call("detailContent", args: ["ids": ids])
    }
    func searchContent(key: String, pg: Int = 1) async throws -> [String: Any] {
        try await call("searchContent", args: ["key": key, "pg": pg])
    }
    func playerContent(flag: String, id: String) async throws -> [String: Any] {
        try await call("playerContent", args: ["flag": flag, "id": id])
    }
}
