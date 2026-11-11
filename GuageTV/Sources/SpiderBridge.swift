import Foundation

/// Typed façade over the embedded Python runtime, speaking the
/// spider_runner JSON contract:
///   load_spider(path, extend) -> {"ok": true, "name": …}
///   call(method, argsJSON)    -> {"ok": true, "result": …}
/// Failures throw BridgeFailure carrying the Python traceback text, so
/// the UI can show exactly what the spider complained about.
final class SpiderBridge {
    static let shared = SpiderBridge()

    struct BridgeFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Load (or re-activate) a spider file from the sandbox; returns the
    /// spider's display name. `extend` is the site's ext payload verbatim.
    func loadSpider(path: String, extend: String) async throws -> String {
        let dict = try await invokeJSON("load_spider", [path, extend])
        return dict["name"] as? String ?? "Spider"
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
