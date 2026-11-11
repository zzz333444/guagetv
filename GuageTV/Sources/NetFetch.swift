import Foundation

/// Hardened fetcher for config files and CMS endpoints.
///
/// Real-world config hosts are flaky in specific ways: they gate on
/// browser-like headers, drop the first connection, or only answer on one
/// of http/https. A bare URLSession call surfaces all of these as one
/// opaque "network connection was lost". This helper presents a full
/// browser header set, retries, and falls back to the other scheme before
/// giving up — and the final error it throws keeps the failing URL so the
/// UI can show something diagnosable.
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

    static func data(from url: URL, extraHeader: [String: String] = [:]) async throws -> Data {
        var attempts: [URL] = [url]
        if let swapped = schemeSwapped(url) { attempts.append(swapped) }
        attempts.append(url)   // one plain retry of the original
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

    private static func schemeSwapped(_ url: URL) -> URL? {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if comp.scheme == "http" { comp.scheme = "https" }
        else if comp.scheme == "https" { comp.scheme = "http" }
        else { return nil }
        return comp.url
    }
}
