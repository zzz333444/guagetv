import Foundation

/// HLS ad filtering (v1.60), in the spirit of the native HLS
/// adblock in Arcane: VOD m3u8 playback is routed through the
/// loopback proxy, which rewrites the playlist before the engine
/// ever sees it. A segment group counts as an ad pod when:
///   • it sits inside an #EXT-X-CUE-OUT … #EXT-X-CUE-IN span, or
///   • every segment URI lives on a different host than the
///     playlist itself (the classic 采集站 ad-CDN insertion), or
///   • a segment URI contains /ad/, /ads/, advert, /gg/,
///     /tuan or tuan. (conservative keyword set:宁漏勿误 —
///     each pattern is a path segment or host fragment, so a
///     content segment named e.g. "tuanjie.ts" never matches).
/// Safety valve: if the "ads" would eat more than half the total
/// runtime, the playlist passes through unfiltered — a wrong call
/// must never gut an episode. Live playlists (no ENDLIST) are
/// rewritten (segment/key URLs proxied so headers still apply)
/// but never filtered.
enum HLSAdFilter {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "player.hlsAdblock") as? Bool ?? true
    }

    // MARK: last-filter stats (v1.67)

    /// Written whenever a playlist actually loses segments, so
    /// Settings → 播放 can show "上次过滤：移除 N 段约 M 秒".
    /// Keys are read with @AppStorage in SettingsView.
    static func recordRemoval(segments: Int, seconds: Double) {
        let d = UserDefaults.standard
        d.set(segments, forKey: "hlsAdblock.lastRemovedSegments")
        d.set(seconds, forKey: "hlsAdblock.lastRemovedSeconds")
        d.set(Date().timeIntervalSince1970, forKey: "hlsAdblock.lastFilteredAt")
    }

    /// The URL the engines should load instead of `urlString`
    /// when filtering applies; the original string otherwise.
    /// Non-blocking: when the loopback server is not up yet the
    /// original URL is used (PlayerView warms the server on
    /// appear, so later loads get filtered).
    static func proxyURL(for urlString: String, header: [String: String],
                         isLive: Bool) -> String {
        guard enabled, !isLive,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https",
              url.pathExtension.lowercased() == "m3u8",
              url.host != "127.0.0.1", url.host != "localhost",
              let root = LocalProxyServer.shared.rootIfRunning else {
            return urlString
        }
        return proxied(root: root, path: "/hls/media.m3u8",
                       target: urlString, header: header)
    }

    static func proxied(root: String, path: String, target: String,
                        header: [String: String]) -> String {
        var comps = URLComponents(string: root + path)
        var items = [URLQueryItem(name: "u", value: target)]
        if !header.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: header) {
            items.append(URLQueryItem(name: "hdrs",
                                      value: data.base64EncodedString()))
        }
        comps?.queryItems = items
        return comps?.url?.absoluteString ?? target
    }

    static func decodeHeaders(_ b64: String?) -> [String: String] {
        guard let b64, let data = Data(base64Encoded: b64),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    /// Synchronous fetch used by the proxy endpoints.
    /// v2.17: the timeout is split by caller — a playlist is a
    /// few KB on the start path, so it fails fast (8s) instead of
    /// holding the first frame up to 25s; a segment keeps a
    /// longer budget (15s) but still fails before the 15s stall
    /// watchdog would fire anyway, so a dead segment 502s and the
    /// engine retries instead of hanging the whole episode.
    static func fetch(url: URL, headers: [String: String],
                      range: String?, timeout: TimeInterval = 15) -> (Int, String, Data, [String: String]) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        var out = (502, "application/octet-stream", Data(), [String: String]())
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data, let http = response as? HTTPURLResponse else { return }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            out = (http.statusCode,
                   http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                   data, headers)
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 3)
        return out
    }

    // MARK: playlist rewriting

    private struct Segment {
        var tags: [String]
        var uri: String
        var duration: Double
        var group: Int
        var inCue: Bool
    }

    /// Returns the rewritten playlist plus how much was removed.
    /// v2.66: the safety-valve trip is reported too (valveTripped
    /// + what it would have removed) — before this the trip was
    /// invisible: the counts were zeroed and nothing was logged.
    static func rewrite(playlist: String, base: URL, root: String,
                        headersB64: String?) -> (text: String, removed: Int, removedSeconds: Double,
                                                 valveTripped: Bool, valveSegments: Int, valveSeconds: Double) {
        let header = decodeHeaders(headersB64)
        let lines = playlist
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        func proxyURI(_ raw: String, playlistKind: Bool) -> String {
            let abs = URL(string: raw, relativeTo: base)?.absoluteString ?? raw
            return proxied(root: root,
                           path: playlistKind ? "/hls/media.m3u8" : "/seg/media",
                           target: abs, header: header)
        }
        /// Rewrite URI="…" inside a tag line (KEY / MAP / MEDIA).
        func rewriteTagURI(_ line: String, playlistKind: Bool) -> String {
            guard let range = line.range(of: "URI=\""),
                  let end = line.range(of: "\"", range: range.upperBound..<line.endIndex) else {
                return line
            }
            let raw = String(line[range.upperBound..<end.lowerBound])
            return String(line[..<range.upperBound]) + proxyURI(raw, playlistKind: playlistKind)
                + String(line[end.lowerBound...])
        }

        // Master playlist: point variants (and rendition
        // playlists) back at the filter.
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            let out = lines.map { line -> String in
                if line.hasPrefix("#EXT-X-MEDIA") {
                    return rewriteTagURI(line, playlistKind: true)
                }
                if !line.hasPrefix("#"), !line.isEmpty {
                    return proxyURI(line, playlistKind: true)
                }
                return line
            }
            return (out.joined(separator: "\n"), 0, 0, false, 0, 0)
        }

        // Media playlist: split header / segments.
        var headerTags: [String] = []
        var segments: [Segment] = []
        var pending: [String] = []
        var group = 0
        var inCue = false
        var sawSegment = false
        for line in lines {
            if line.hasPrefix("#EXT-X-DISCONTINUITY") { group += 1 }
            if line.hasPrefix("#EXT-X-CUE-OUT") { inCue = true }
            if line.hasPrefix("#EXT-X-CUE-IN") { inCue = false }
            if line.hasPrefix("#") {
                if sawSegment {
                    pending.append(line)
                } else {
                    headerTags.append(line)
                }
                continue
            }
            if line.isEmpty { continue }
            sawSegment = true
            var duration = 0.0
            for tag in pending where tag.hasPrefix("#EXTINF:") {
                let value = tag.dropFirst("#EXTINF:".count)
                    .components(separatedBy: ",").first ?? ""
                duration = Double(value) ?? 0
            }
            segments.append(Segment(tags: pending, uri: line,
                                    duration: duration, group: group,
                                    inCue: inCue
                                        || pending.contains { $0.hasPrefix("#EXT-X-CUE-OUT") }))
            pending = []
        }
        let trailingTags = pending
        let isLive = !lines.contains("#EXT-X-ENDLIST")

        // Group verdicts.
        var groups: [Int: [Segment]] = [:]
        for seg in segments { groups[seg.group, default: []].append(seg) }
        let baseHost = base.host ?? ""
        var adGroups: Set<Int> = []
        if !isLive {
            for (gid, members) in groups {
                if members.contains(where: { $0.inCue }) {
                    adGroups.insert(gid)
                    continue
                }
                let hosts = members.map { URL(string: $0.uri, relativeTo: base)?.host ?? baseHost }
                if !hosts.isEmpty, hosts.allSatisfy({ $0 != baseHost }) {
                    adGroups.insert(gid)
                    continue
                }
                if members.contains(where: {
                    let u = $0.uri.lowercased()
                    return u.contains("/ad/") || u.contains("/ads/") || u.contains("advert")
                        || u.contains("/gg/") || u.contains("/tuan") || u.contains("tuan.")
                }) {
                    adGroups.insert(gid)
                }
            }
            // A single-group playlist is the content itself,
            // never an ad pod.
            if groups.count <= 1 { adGroups.removeAll() }
        }
        let totalDuration = segments.reduce(0) { $0 + $1.duration }
        var removedSegments = segments.filter { adGroups.contains($0.group) }
        var removedDuration = removedSegments.reduce(0) { $0 + $1.duration }
        // v2.66: 安全阀触发时留痕——此前拟移除量被清零后无任何
        // 记录，诊断里看不出「广告段太多、整片被放行」。
        var valveTripped = false
        var valveSegments = 0
        var valveSeconds = 0.0
        if totalDuration > 0, removedDuration > totalDuration * 0.5 {
            valveTripped = true
            valveSegments = removedSegments.count
            valveSeconds = removedDuration
            adGroups.removeAll()
            removedSegments = []
            removedDuration = 0
        }

        // Rebuild.
        var out: [String] = []
        for tag in headerTags {
            if tag.hasPrefix("#EXT-X-CUE-OUT") || tag.hasPrefix("#EXT-X-CUE-IN") { continue }
            if tag.hasPrefix("#EXT-X-KEY") || tag.hasPrefix("#EXT-X-MAP")
                || tag.hasPrefix("#EXT-X-MEDIA") {
                out.append(rewriteTagURI(tag, playlistKind: tag.hasPrefix("#EXT-X-MEDIA")))
            } else {
                out.append(tag)
            }
        }
        var emittedGroups: Set<Int> = []
        for seg in segments where !adGroups.contains(seg.group) {
            for tag in seg.tags {
                if tag.hasPrefix("#EXT-X-CUE-OUT") || tag.hasPrefix("#EXT-X-CUE-IN") { continue }
                if tag.hasPrefix("#EXT-X-DISCONTINUITY") {
                    // Keep a boundary only between two kept
                    // groups, never before the first segment.
                    if !emittedGroups.isEmpty, !emittedGroups.contains(seg.group) {
                        out.append(tag)
                    }
                    continue
                }
                if tag.hasPrefix("#EXT-X-KEY") || tag.hasPrefix("#EXT-X-MAP") {
                    out.append(rewriteTagURI(tag, playlistKind: false))
                } else {
                    out.append(tag)
                }
            }
            emittedGroups.insert(seg.group)
            out.append(proxyURI(seg.uri, playlistKind: false))
        }
        out.append(contentsOf: trailingTags.filter {
            !$0.hasPrefix("#EXT-X-CUE-OUT") && !$0.hasPrefix("#EXT-X-CUE-IN")
        })
        if !removedSegments.isEmpty {
            recordRemoval(segments: removedSegments.count, seconds: removedDuration)
        }
        return (out.joined(separator: "\n"),
                removedSegments.count, removedDuration,
                valveTripped, valveSegments, valveSeconds)
    }
}
