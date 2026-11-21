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
        guard let ctx = JSContext() else {
            throw JSFailure(message: "JS 引擎创建失败")
        }
        lastException = nil
        ctx.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JS error"
        }
        installHost(ctx)
        JSRuntime.seedDriveCredentials(into: ctx)
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

    /// 猫源网盘凭证注入 (v1.77): cat/JS pan spiders read their
    /// drive credentials from the host. Seed the standard local
    /// scopes ("config" / "pan") and a __panConfig global from
    /// Settings → 网盘配置 → 猫源网盘； a cat field left empty
    /// falls back to the shared drive set.
    private static func seedDriveCredentials(into ctx: JSContext) {
        let d = UserDefaults.standard
        func pick(_ name: String) -> String {
            let cat = (d.string(forKey: "drive.cat." + name) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cat.isEmpty { return cat }
            return (d.string(forKey: "drive." + name) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var values: [String: String] = [:]
        for name in ["quark_cookie", "uc_cookie", "uc_token", "aliyun",
                     "baidu", "bili_cookie", "xunlei"] {
            let v = pick(name)
            if !v.isEmpty { values[name] = v }
        }
        // Aliases some cat rules read instead of the base key.
        var seeded = values
        if let v = values["baidu"] { seeded["baidu_cookie"] = v }
        if let v = values["xunlei"] { seeded["xunlei_token"] = v }
        // v2.07: a field the user cleared must also clear the
        // seeded local scopes. Previously only non-empty values
        // were written, so "清空" in Settings left the old
        // credential live in drpy.local.v1 and a cat rule kept
        // using a revoked cookie. __panConfig needs no clearing:
        // every rule load builds a fresh JSContext.
        let allKeys = ["quark_cookie", "uc_cookie", "uc_token", "aliyun",
                       "baidu", "baidu_cookie", "bili_cookie", "xunlei", "xunlei_token"]
        for scope in ["config", "pan"] {
            for key in allKeys {
                if let value = seeded[key] { localSet(scope, key, value) }
                else { localDelete(scope, key) }
            }
        }
        guard !seeded.isEmpty else { return }
        if let data = try? JSONSerialization.data(withJSONObject: seeded),
           let json = String(data: data, encoding: .utf8) {
            ctx.evaluateScript("globalThis.__panConfig = \(json);")
        }
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
        // v2.00: surface the real HTTP status and transport error
        // alongside content/headers — Widget.http used to report
        // a hardcoded 200, so modules reading status or headers
        // (e.g. Cloudflare challenges, redirects) misjudged.
        // status 0 = no HTTP response at all (network failure,
        // invalid URL, unreadable file).
        let empty: [String: Any] = ["content": "", "headers": [String: String](), "status": 0]
        if urlString.hasPrefix("file://") {
            let path = URL(string: urlString)?.path ?? ""
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return ["content": text, "headers": [String: String](), "status": 200,
                        "url": urlString]
            }
            return ["content": "", "headers": [String: String](), "status": 0,
                    "error": "文件读取失败"]
        }
        guard let url = URL(string: urlString) else { return empty }
        var request = URLRequest(url: url)
        request.httpMethod = (obj["method"] as? String)?.uppercased() ?? "GET"
        for (key, value) in stringKeyed(obj["headers"] as? [AnyHashable: Any]) {
            request.setValue(String(describing: value), forHTTPHeaderField: key)
        }
        // Form values must not carry & = + ? raw, or one value
        // splits into several fields (v2.07, same fix as
        // Widget.http params).
        let formAllowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=+?"))
        if let body = obj["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        } else if let rawData = obj["data"] as? [AnyHashable: Any] {
            let form = stringKeyed(rawData).map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
                let v = String(describing: value)
                    .addingPercentEncoding(withAllowedCharacters: formAllowed) ?? ""
                return "\(k)=\(v)"
            }.joined(separator: "&")
            request.httpBody = form.data(using: .utf8)
            // A form body without a Content-Type was sent bare:
            // servers expecting a form reject it. Default to
            // url-encoded unless the caller set one (v2.07).
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded",
                                 forHTTPHeaderField: "Content-Type")
            }
        } else if let data = obj["data"] as? String {
            request.httpBody = data.data(using: .utf8)
        }
        let timeoutMs = (obj["timeout"] as? NSNumber)?.doubleValue ?? 20000
        request.timeoutInterval = max(timeoutMs / 1000, 1)
        let session = (obj["redirect"] as? NSNumber)?.intValue == 0
            ? noRedirectSession : URLSession.shared
        var result = empty
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            // Transport failure (or no data): keep content empty
            // but name the cause — callers used to see an empty
            // body with a fake 200. v2.01: classify the failure
            // in Chinese and flag a timeout separately, so the
            // module layer can tell a slow source (sub-request
            // timeout) from a dead network.
            guard let data else {
                var failed = empty
                let mapped = JSRuntime.chineseTransportError(error)
                failed["error"] = mapped.message
                if mapped.timedOut { failed["timedOut"] = true }
                result = failed
                return
            }
            var headers: [String: String] = [:]
            var status = 200
            // v2.19: remember the charset the server declared, so
            // a GBK page decodes correctly even when the module
            // didn't pass encoding:"gbk" (most gbk-site modules
            // don't — they rely on the host to auto-detect).
            var declaredGBK = false
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
                declaredGBK = (http.textEncodingName ?? "")
                    .lowercased().contains("gb")
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
            } else if declaredGBK {
                // No explicit encoding, but the server declared a
                // GB charset (Content-Type: …; charset=gbk): decode
                // as GB18030 (superset of gbk/gb2312) instead of
                // lossy UTF-8, which used to turn the whole page
                // into replacement characters.
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                content = String(data: data, encoding: String.Encoding(rawValue: nsEncoding))
                    ?? String(decoding: data, as: UTF8.self)
            } else {
                content = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
            }
            result = ["content": content, "headers": headers, "status": status]
            // v2.07: the final URL after redirects, so Widget.http
            // can report where the request actually landed.
            result["url"] = response?.url?.absoluteString ?? urlString
            if let error {
                let mapped = JSRuntime.chineseTransportError(error)
                result["error"] = mapped.message
                if mapped.timedOut { result["timedOut"] = true }
            }
        }.resume()
        // v2.24 audit: this wait used to be unbounded — if the
        // session never called back (torn down mid-flight), the JS
        // serial queue hung forever. The request itself carries a
        // timeout, so cap the wait a little past it and report a
        // timeout instead of the empty fake-200 placeholder.
        if semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .timedOut {
            var failed = empty
            failed["error"] = "请求超时"
            failed["timedOut"] = true
            return failed
        }
        return result
    }

    /// Map a URLSession transport error to a deterministic
    /// Chinese message (v2.01): NSError.localizedDescription
    /// depends on device language and reads as a raw code
    /// dump on some setups, while module errors must read
    /// the same on every device. timedOut is true only for
    /// NSURLErrorTimedOut, so callers can separate a slow
    /// source from a dead network.
    static func chineseTransportError(_ error: Error?) -> (message: String, timedOut: Bool) {
        guard let error else { return ("网络请求失败", false) }
        switch (error as NSError).code {
        case NSURLErrorTimedOut: return ("请求超时", true)
        case NSURLErrorNotConnectedToInternet: return ("无网络连接", false)
        case NSURLErrorCannotFindHost: return ("找不到服务器", false)
        case NSURLErrorCannotConnectToHost: return ("无法连接服务器", false)
        case NSURLErrorNetworkConnectionLost: return ("网络连接中断", false)
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRequired:
            return ("证书验证失败", false)
        case NSURLErrorCancelled: return ("请求已取消", false)
        default:
            return ((error as NSError).localizedDescription, false)
        }
    }
}
