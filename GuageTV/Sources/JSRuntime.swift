import Foundation
import JavaScriptCore

/// Stage 2: the drpy2 JavaScript runtime on JavaScriptCore.
///
/// The stack, evaluated per rule load inside ONE fresh JSContext, each
/// file in its own function scope (the webpack bundles collide on
/// top-level names; cross-file sharing goes through globalThis only):
///   prelude.js   — TextEncoder/TextDecoder + timer shims (JSC lacks them)
///   cheerio.js   — real cheerio DOM (patched classic build, see notes)
///   parser.js    — host parser globals: pdfh / pdfa / pd / joinUrl
///   drpy-core.js — CryptoJS, JSONPath, jinja, templates (module-fied)
///   drpy2.js     — the drpy2 engine itself → globalThis.__DRPY
///
/// Host contract the engine expects (found by reading its source):
///   req(url, obj) -> {content, headers}   synchronous HTTP
///   local.get/set/delete(rkey, key[, value])  per-rule storage
///   console.*                              logging sink
/// After init, rule.url / rule.searchUrl are absolutized against
/// rule.host: this engine build crashes in getHome() on relative URLs.
final class JSRuntime {
    struct JSFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let queue = DispatchQueue(label: "guage.jsruntime")
    private var context: JSContext?
    private var drpy: JSValue?
    private var lastException: String?

    // MARK: async boundary

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func loadRule(extReference: String) async throws {
        try await onQueue { try self.loadRuleLocked(extReference) }
    }

    func call(_ method: String, _ args: [Any]) async throws -> String {
        try await onQueue { try self.callLocked(method, args) }
    }

    // MARK: loading (queue-confined)

    private func loadRuleLocked(_ extReference: String) throws {
        let ctx = JSContext()!
        lastException = nil
        ctx.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JS error"
        }
        installHost(ctx)
        for file in ["prelude.js", "cheerio.js", "parser.js", "drpy-core.js", "drpy2.js"] {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil,
                                            subdirectory: "JSBundle"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw JSFailure(message: "JS 资源缺失：\(file)")
            }
            lastException = nil
            ctx.evaluateScript("(function(){\n" + source + "\n})();")
            if let lastException {
                throw JSFailure(message: "drpy 引擎加载失败（\(file)）：\(lastException)")
            }
        }
        guard let engine = ctx.objectForKeyedSubscript("__DRPY"), !engine.isUndefined else {
            throw JSFailure(message: "drpy 引擎未就绪（__DRPY 缺失）")
        }
        context = ctx
        drpy = engine
        lastException = nil
        engine.invokeMethod("init", withArguments: [extReference])
        if let lastException {
            throw JSFailure(message: "规则初始化失败：\(lastException)")
        }
        // Absolutize relative url/searchUrl against rule.host — this
        // engine build crashes in getHome() on relative URLs.
        ctx.evaluateScript("""
        (function () {
            var r = __DRPY.getRule();
            var host = (r.host || "").replace(/\\/$/, "");
            if (!host) return;
            ["url", "searchUrl"].forEach(function (k) {
                var v = r[k];
                if (typeof v === "string" && v && v.indexOf("http") !== 0) {
                    r[k] = host + (v.charAt(0) === "/" ? v : "/" + v);
                }
            });
        })();
        """)
        drainTimers(ctx)
    }

    private func callLocked(_ method: String, _ args: [Any]) throws -> String {
        guard let ctx = context, let drpy else {
            throw JSFailure(message: "JS 运行时尚未加载规则")
        }
        lastException = nil
        let result = drpy.invokeMethod(method, withArguments: args)
        if let lastException {
            throw JSFailure(message: "\(method) 执行失败：\(lastException)")
        }
        drainTimers(ctx)
        guard let result, !result.isUndefined, !result.isNull else { return "" }
        if result.isString { return result.toString() ?? "" }
        ctx.setObject(result, forKeyedSubscript: "__res" as NSString)
        return ctx.evaluateScript("JSON.stringify(__res)")?.toString() ?? ""
    }

    private func drainTimers(_ ctx: JSContext) {
        ctx.evaluateScript("if (typeof __drainTimers === 'function') __drainTimers();")
    }

    // MARK: host functions

    private func installHost(_ ctx: JSContext) {
        let logBlock: @convention(block) (String) -> Void = { _ in }
        ctx.setObject(logBlock, forKeyedSubscript: "__nativeLog" as NSString)

        let getBlock: @convention(block) (String, String) -> JSValue? = { rkey, key in
            guard let ctx = JSContext.current() else { return nil }
            if let value = JSRuntime.localGet(rkey, key) {
                return JSValue(object: value, in: ctx)
            }
            return JSValue(nullIn: ctx)
        }
        ctx.setObject(getBlock, forKeyedSubscript: "__localGet" as NSString)
        let setBlock: @convention(block) (String, String, String) -> Void = { rkey, key, value in
            JSRuntime.localSet(rkey, key, value)
        }
        ctx.setObject(setBlock, forKeyedSubscript: "__localSet" as NSString)
        let deleteBlock: @convention(block) (String, String) -> Void = { rkey, key in
            JSRuntime.localDelete(rkey, key)
        }
        ctx.setObject(deleteBlock, forKeyedSubscript: "__localDelete" as NSString)

        let reqBlock: @convention(block) (JSValue, JSValue) -> JSValue? = { urlValue, objValue in
            let url = urlValue.toString() ?? ""
            // JSValue.toDictionary() yields [AnyHashable: Any] — the
            // fetch helper normalizes keys itself.
            let obj = objValue.isUndefined ? [:] : (objValue.toDictionary() ?? [:])
            let result = JSRuntime.syncFetch(urlString: url, obj: obj)
            guard let ctx = JSContext.current() else { return nil }
            return JSValue(object: result, in: ctx)
        }
        ctx.setObject(reqBlock, forKeyedSubscript: "req" as NSString)

        ctx.evaluateScript("""
        globalThis.console = (function () {
            function fmt(args) {
                var parts = [];
                for (var i = 0; i < args.length; i++) {
                    var a = args[i];
                    try { parts.push(typeof a === "object" ? JSON.stringify(a) : String(a)); }
                    catch (e) { parts.push("[object]"); }
                }
                return parts.join(" ");
            }
            return {
                log: function () { __nativeLog(fmt(arguments)); },
                error: function () { __nativeLog(fmt(arguments)); },
                warn: function () { __nativeLog(fmt(arguments)); },
                info: function () { __nativeLog(fmt(arguments)); }
            };
        })();
        globalThis.local = {
            get: function (r, k) { return __localGet(r, k); },
            set: function (r, k, v) { __localSet(r, k, String(v)); },
            delete: function (r, k) { __localDelete(r, k); }
        };
        """)
    }

    // MARK: local storage (per-rule, persisted)

    private static var localCache: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "drpy.local.v1") as? [String: String]) ?? [:]

    private static func localGet(_ rkey: String, _ key: String) -> String? {
        localCache[rkey + "\u{1}" + key]
    }

    private static func localSet(_ rkey: String, _ key: String, _ value: String) {
        localCache[rkey + "\u{1}" + key] = value
        UserDefaults.standard.set(localCache, forKey: "drpy.local.v1")
    }

    private static func localDelete(_ rkey: String, _ key: String) {
        localCache.removeValue(forKey: rkey + "\u{1}" + key)
        UserDefaults.standard.set(localCache, forKey: "drpy.local.v1")
    }

    // MARK: synchronous HTTP for req()

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let noRedirectSession = URLSession(
        configuration: .default, delegate: NoRedirectDelegate(), delegateQueue: nil)

    /// The engine's transport: req(url, {method, headers, body/data,
    /// timeout(ms), redirect, buffer, encoding}) -> {content, headers}.
    /// Blocks the JS queue thread on a semaphore — the engine is
    /// synchronous by design, exactly like the desktop shells.
        static func syncFetch(urlString: String, obj: [AnyHashable: Any]) -> [String: Any] {
        func stringKeyed(_ dict: [AnyHashable: Any]?) -> [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict ?? [:] {
                if let key = key as? String { out[key] = value }
            }
            return out
        }
        let obj = stringKeyed(obj)
        let empty: [String: Any] = ["content": "", "headers": [String: String]()]
        if urlString.hasPrefix("file://") {
            let path = URL(string: urlString)?.path ?? ""
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return ["content": text, "headers": [String: String]()]
        }
        guard let url = URL(string: urlString) else { return empty }
        var request = URLRequest(url: url)
        request.httpMethod = (obj["method"] as? String)?.uppercased() ?? "GET"
        for (key, value) in stringKeyed(obj["headers"] as? [AnyHashable: Any]) {
            request.setValue(String(describing: value), forHTTPHeaderField: key)
        }
        if let body = obj["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        } else if let rawData = obj["data"] as? [AnyHashable: Any] {
            let form = stringKeyed(rawData).map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let v = String(describing: value)
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return "\(k)=\(v)"
            }.joined(separator: "&")
            request.httpBody = form.data(using: .utf8)
        } else if let data = obj["data"] as? String {
            request.httpBody = data.data(using: .utf8)
        }
        let timeoutMs = (obj["timeout"] as? NSNumber)?.doubleValue ?? 20000
        request.timeoutInterval = max(timeoutMs / 1000, 1)
        let session = (obj["redirect"] as? NSNumber)?.intValue == 0
            ? noRedirectSession : URLSession.shared
        var result = empty
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            var headers: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
            }
            let content: String
            if (obj["buffer"] as? NSNumber)?.intValue == 2 {
                content = data.base64EncodedString()
            } else if let encoding = (obj["encoding"] as? String)?.lowercased(),
                      encoding.contains("gb") {
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                content = String(data: data, encoding: String.Encoding(rawValue: nsEncoding))
                    ?? String(decoding: data, as: UTF8.self)
            } else {
                content = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
            }
            result = ["content": content, "headers": headers]
        }.resume()
        semaphore.wait()
        return result
    }
}
