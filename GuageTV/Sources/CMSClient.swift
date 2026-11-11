import Foundation

/// Full detail model shared by every runtime (CMS / py / JS / 猫源 results
/// are all normalised into this before reaching the UI).
struct VodDetail: Identifiable {
    var id: String
    var name: String
    var pic: String
    var remarks: String = ""
    var content: String = ""
    var actor: String = ""
    var director: String = ""
    var year: String = ""
    var area: String = ""
    var typeName: String = ""
    /// Play lines: vod_play_from split by $$$ — e.g. ["线路1", "线路2"]
    var playFrom: [String] = []
    /// Episodes per line, aligned with playFrom.
    var playGroups: [[Episode]] = []

    struct Episode: Identifiable {
        var name: String
        var url: String
        var id: String { name + "|" + url }
    }

    /// Parse the TVBox episode-string format: groups split by $$$,
    /// episodes by #, each "name$url".
    static func parsePlay(from: String, url: String) -> (lines: [String], groups: [[Episode]]) {
        let lines = from.isEmpty ? ["默认"] : from.components(separatedBy: "$$$")
        let rawGroups = url.components(separatedBy: "$$$")
        let groups: [[Episode]] = rawGroups.map { group in
            group.components(separatedBy: "#").compactMap { part in
                let kv = part.components(separatedBy: "$")
                guard kv.count >= 2 else { return nil }
                return Episode(name: kv[0], url: kv[1])
            }
        }
        return (lines, groups)
    }
}

/// Native client for CMS sites (TVBox type 0 = XML, type 1 = JSON) speaking
/// the MacCMS provide/vod protocol used by the overwhelming majority of
/// CMS sources: ?ac=list / ?ac=detail with t, pg, wd, ids parameters.
/// No runtime needed — this is plain HTTP, so CMS sites work even before
/// the Python/JS engines land.
final class CMSClient {
    let site: TVBoxConfig.Site

    init(site: TVBoxConfig.Site) { self.site = site }

    private func buildURL(params: [String: String]) -> URL? {
        guard var comp = URLComponents(string: site.api) else { return nil }
        var q = comp.queryItems ?? []
        if site.type == 0 { q.append(URLQueryItem(name: "at", value: "xml")) }
        for (k, v) in params where !v.isEmpty { q.append(URLQueryItem(name: k, value: v)) }
        comp.queryItems = q
        return comp.url
    }

    private func fetch(params: [String: String]) async throws -> [String: Any] {
        guard let url = buildURL(params: params) else { return [:] }
        let data = try await NetFetch.data(from: url, extraHeader: site.header ?? [:])
        if site.type == 0 {
            return Self.parseXMLResponse(data)
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    // MARK: Protocol

    func home() async throws -> (classes: [(String, String)], list: [VodItem]) {
        let r = try await fetch(params: ["ac": "list", "pg": "1"])
        let classes = (r["class"] as? [[String: Any]] ?? []).map {
            (String(describing: $0["type_id"] ?? ""), String(describing: $0["type_name"] ?? ""))
        }
        return (classes, Self.mapList(r))
    }

    func category(tid: String, page: Int) async throws -> [VodItem] {
        try await list(tid: tid, page: page)
    }

    /// Raw list call; tid nil = the site's home feed (latest updates).
    func list(tid: String?, page: Int) async throws -> [VodItem] {
        var params = ["ac": "list", "pg": String(page)]
        if let tid, !tid.isEmpty { params["t"] = tid }
        let r = try await fetch(params: params)
        return Self.mapList(r)
    }

    func search(keyword: String, page: Int = 1) async throws -> [VodItem] {
        let r = try await fetch(params: ["ac": "list", "wd": keyword, "pg": String(page)])
        return Self.mapList(r)
    }

    func detail(id: String) async throws -> VodDetail? {
        let r = try await fetch(params: ["ac": "detail", "ids": id])
        guard let first = (r["list"] as? [[String: Any]])?.first else { return nil }
        let parsed = VodDetail.parsePlay(from: first["vod_play_from"] as? String ?? "",
                                         url: first["vod_play_url"] as? String ?? "")
        return VodDetail(
            id: String(describing: first["vod_id"] ?? id),
            name: first["vod_name"] as? String ?? "",
            pic: first["vod_pic"] as? String ?? "",
            remarks: first["vod_remarks"] as? String ?? "",
            content: (first["vod_content"] as? String ?? "").htmlCleaned
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
            actor: first["vod_actor"] as? String ?? "",
            director: first["vod_director"] as? String ?? "",
            year: first["vod_year"] as? String ?? "",
            area: first["vod_area"] as? String ?? "",
            typeName: first["type_name"] as? String ?? "",
            playFrom: parsed.lines,
            playGroups: parsed.groups)
    }

    // MARK: Mapping

    private static func mapList(_ r: [String: Any]) -> [VodItem] {
        (r["list"] as? [[String: Any]] ?? []).map {
            VodItem(id: String(describing: $0["vod_id"] ?? ""),
                    name: $0["vod_name"] as? String ?? "",
                    pic: $0["vod_pic"] as? String ?? "",
                    remarks: $0["vod_remarks"] as? String ?? "",
                    year: $0["vod_year"] as? String ?? "")
        }
    }

    /// Minimal XML (type 0) extraction: the provide/vod XML schema mirrors
    /// the JSON keys, so a targeted tag scan is sufficient for list/detail.
    private static func parseXMLResponse(_ data: Data) -> [String: Any] {
        guard let xml = String(data: data, encoding: .utf8) else { return [:] }
        func tag(_ name: String, in s: String) -> String? {
            guard let r = s.range(of: "<\(name)>(.*?)</\(name)>",
                                  options: .regularExpression) else { return nil }
            return String(s[r]).replacingOccurrences(of: "<\(name)>", with: "")
                .replacingOccurrences(of: "</\(name)>", with: "")
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
        }
        var items: [[String: Any]] = []
        for chunk in xml.components(separatedBy: "<video>") where chunk.contains("</video>") {
            var item: [String: Any] = [:]
            for key in ["vod_id", "vod_name", "vod_pic", "vod_remarks", "vod_year",
                        "vod_play_from", "vod_play_url", "vod_content", "vod_actor",
                        "vod_director", "vod_area", "type_name"] {
                if let v = tag(key, in: chunk) { item[key] = v }
            }
            if !item.isEmpty { items.append(item) }
        }
        var classes: [[String: Any]] = []
        for chunk in xml.components(separatedBy: "<ty ") where chunk.contains("</ty>") {
            if let name = chunk.range(of: ">(.*?)</ty>", options: .regularExpression).map({ String(chunk[$0]) }) {
                let idPart = chunk.components(separatedBy: "\"").dropFirst().first ?? ""
                classes.append(["type_id": String(idPart),
                                "type_name": name.replacingOccurrences(of: ">", with: "")
                                    .replacingOccurrences(of: "</ty>", with: "")])
            }
        }
        return ["list": items, "class": classes]
    }
}

private extension String {
    /// CMS synopses arrive with HTML markup and entities (&nbsp;, <br>…).
    var htmlCleaned: String {
        var t = self
        t = t.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ] {
            t = t.replacingOccurrences(of: entity, with: replacement)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
