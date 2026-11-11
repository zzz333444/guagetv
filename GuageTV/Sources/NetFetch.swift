import Foundation
import UIKit
import WebKit

/// Hardened fetcher for config files and CMS endpoints.
///
/// Real-world config hosts fail in distinct ways, so fetching is tiered —
/// each tier counters a different failure class:
///  1. Plain URLSession with full browser headers + retry + http/https
///     scheme fallback (flaky hosts, header gating, first-hit drops).
///  2. URLSession that follows redirects EXCEPT http→https upgrades —
///     some CDNs 301 plain-http API clients into an HTTPS endpoint that
///     is broken, which surfaces as "network connection was lost".
///  3. A hidden WKWebView (the exact network stack Safari uses, incl. its
///     connection reuse and fallback behaviour) reading the page text.
/// CMS fetches use tiers 1–2 via `data(from:)`; config import uses
/// `dataForConfig(from:)` which runs every tier.
enum NetFetch {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func request(for url: URL, extraHeader: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/json,application/xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        for (k, v) in extraHeader { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    // MARK: Tier 1 — URLSession, retries + scheme fallback

    static func data(from url: URL, extraHeader: [String: String] = [:]) async throws -> Data {
        var attempts: [URL] = [url]
        if let swapped = schemeSwapped(url) { attempts.append(swapped) }
        attempts.append(url)
        var lastError: Error = URLError(.unknown)
        for (i, candidate) in attempts.enumerated() {
            if i > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request(for: candidate, extraHeader: extraHeader))
                if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Full tier chain for config import

    static func dataForConfig(from url: URL) async throws -> Data {
        if let data = try? await data(from: url), !data.isEmpty { return data }
        if let data = try? await dataBlockingSchemeUpgrade(from: url), !data.isEmpty { return data }
        if let data = try? await WebFetcher.fetch(url: url), !data.isEmpty { return data }
        if let swapped = schemeSwapped(url),
           let data = try? await WebFetcher.fetch(url: swapped), !data.isEmpty { return data }
        throw URLError(.networkConnectionLost)
    }

    // MARK: Tier 2 — redirects allowed, http→https upgrades refused

    private static func dataBlockingSchemeUpgrade(from url: URL) async throws -> Data {
        let delegate = NoUpgradeRedirectDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request(for: url))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func schemeSwapped(_ url: URL) -> URL? {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if comp.scheme == "http" { comp.scheme = "https" }
        else if comp.scheme == "https" { comp.scheme = "http" }
        else { return nil }
        return comp.url
    }
}

private final class NoUpgradeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let fromScheme = task.originalRequest?.url?.scheme
        if fromScheme == "http" && request.url?.scheme == "https" {
            completionHandler(nil)   // keep the http response instead of dying on broken https
        } else {
            completionHandler(request)
        }
    }
}

/// Tier 3 — fetch through a hidden WKWebView and read the rendered text.
/// JSON/plain-text responses appear as the document body, exactly like
/// opening the address in Safari.
@MainActor
private final class WebFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?

    static func fetch(url: URL) async throws -> Data {
        let fetcher = WebFetcher()
        return try await fetcher.run(url: url)
    }

    private func run(url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            wv.navigationDelegate = self
            wv.alpha = 0.01
            self.webView = wv
            Self.keyWindow?.addSubview(wv)
            var req = URLRequest(url: url, timeoutInterval: 25)
            req.setValue(NetFetch.userAgent, forHTTPHeaderField: "User-Agent")
            wv.load(req)
            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self.finish(.failure(URLError(.timedOut)))
            }
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private func finish(_ result: Result<Data, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.removeFromSuperview()
        webView = nil
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
            guard let self else { return }
            if let text = value as? String, !text.isEmpty {
                self.finish(.success(Data(text.utf8)))
            } else {
                self.finish(.failure(URLError(.cannotParseResponse)))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
