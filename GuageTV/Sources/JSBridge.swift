import Foundation

/// Typed façade over JSRuntime for drpy sites — same result shapes as
/// SpiderBridge (home/category/detail/play return the standard vod
/// JSON), so the browse UI maps results with the shared helpers.
final class JSBridge {
    static let shared = JSBridge()

    struct BridgeFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let runtime = JSRuntime()

    /// reference: absolute http(s) URL of the rule file, or a file://
    /// URL for a locally imported rule. The engine fetches it itself.
    func loadRule(reference: String) async throws {
        try await runtime.loadRule(extReference: reference)
    }

    private func callJSON(_ method: String, _ args: [Any]) async throws -> [String: Any] {
        let text = try await runtime.call(method, args)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            if text.isEmpty { return [:] }
            throw BridgeFailure(message: "JS 返回无法解析：\(String(text.prefix(200)))")
        }
        return dict
    }

    func home() async throws -> [String: Any] { try await callJSON("home", [true]) }
    func homeVod() async throws -> [String: Any] { try await callJSON("homeVod", []) }
    func category(tid: String, pg: Int) async throws -> [String: Any] {
        try await callJSON("category", [tid, String(pg), true, [String: Any]()])
    }
    func detail(id: String) async throws -> [String: Any] { try await callJSON("detail", [id]) }
    func play(flag: String, id: String) async throws -> [String: Any] {
        try await callJSON("play", [flag, id, [String]()])
    }
    func search(key: String, pg: Int = 1) async throws -> [String: Any] {
        try await callJSON("search", [key, false, String(pg)])
    }
}
