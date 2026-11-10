import Foundation

/// Swift side of the Python bridge.
///
/// Stage 0 status: interface + local stub. Stage 1 wires this to the embedded
/// Python.xcframework (python-apple-support): initialise the interpreter with
/// `GuageTV/Python` on sys.path, import `spider_runner`, and forward calls.
/// The JSON-in / JSON-out contract matches spider_runner.py exactly, so the
/// UI layer never changes when the real interpreter lands.
final class SpiderBridge {
    static let shared = SpiderBridge()

    private var loadedName: String?

    /// Load a .py spider file from the app sandbox (downloaded from the
    /// config's `spider` jar URL equivalent, or imported by the user).
    func loadSpider(path: String, extend: String) async throws -> String {
        // STAGE 1: replace stub with PyObject calls into spider_runner.load_spider
        _ = path; _ = extend
        throw BridgeError.notWired
    }

    func call(_ method: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        // STAGE 1: forward to spider_runner.call(method, argsJSON), decode result
        _ = method; _ = args
        throw BridgeError.notWired
    }

    // Convenience wrappers mirroring the spider protocol
    func homeContent() async throws -> [String: Any] { try await call("homeContent") }
    func categoryContent(tid: String, page: Int) async throws -> [String: Any] {
        try await call("categoryContent", args: ["tid": tid, "pg": page])
    }
    func detailContent(ids: [String]) async throws -> [String: Any] {
        try await call("detailContent", args: ["ids": ids])
    }
    func searchContent(key: String, page: Int = 1) async throws -> [String: Any] {
        try await call("searchContent", args: ["key": key, "pg": page])
    }
    func playerContent(flag: String, id: String) async throws -> [String: Any] {
        try await call("playerContent", args: ["flag": flag, "id": id])
    }

    enum BridgeError: Error { case notWired }
}
