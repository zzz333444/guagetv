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

    /// Load (or re-activate) a spider file from the sandbox; returns the
    /// spider's display name. `extend` is the site's ext payload verbatim.
    func loadSpider(path: String, extend: String) async throws -> String {
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
        let text = try await Task.detached(priority: .userInitiated) {
            try PythonRuntime.shared.invoke(function, args)
        }.value
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeFailure(message: "桥接返回无法解析：\(text.prefix(160))")
        }
        if (dict["ok"] as? Bool) != true {
            throw BridgeFailure(message: (dict["error"] as? String) ?? "Spider 调用失败")
        }
        return dict
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
