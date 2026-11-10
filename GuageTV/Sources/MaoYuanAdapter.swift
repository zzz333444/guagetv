import Foundation

/// 猫源 (CatVod / CatPawOpen) config adapter.
///
/// Cat sources ship a different config shape (a `spider` JS file URL plus
/// `sites` whose `api` points at exported JS spider names, and `ext` blobs
/// with source-specific fields). The spiders themselves speak a protocol
/// very close to the TVBox JS spider protocol, so this adapter normalises a
/// cat config into the same TVBoxConfig the rest of the shell consumes, and
/// the JS engine (JavaScriptCore bridge) runs both flavours.
enum MaoYuanAdapter {

    struct MaoConfig: Decodable {
        var spider: String?
        var sites: [MaoSite]?
        var lives: [TVBoxConfig.Live]?

        struct MaoSite: Decodable {
            var key: String
            var name: String
            var type: Int?
            var api: String?
            var ext: JSONValue?
            var searchable: Int?
            var quickSearch: Int?
            var filterable: Int?
            var categories: [String]?
        }
    }

    /// Heuristic: a config is treated as 猫源 when it has a `spider` JS URL
    /// and its sites reference JS spider exports rather than CMS endpoints.
    static func looksLikeMaoYuan(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: ConfigLoader.cleaned(data)) as? [String: Any],
              let spider = obj["spider"] as? String else { return false }
        return spider.lowercased().hasSuffix(".js")
    }

    static func convert(from data: Data) throws -> TVBoxConfig {
        let mao = try JSONDecoder().decode(MaoConfig.self, from: ConfigLoader.cleaned(data))
        let sites: [TVBoxConfig.Site] = (mao.sites ?? []).map { s in
            TVBoxConfig.Site(
                key: s.key, name: s.name, type: 3, api: s.api ?? "",
                searchable: s.searchable, quickSearch: s.quickSearch,
                filterable: s.filterable, changeable: nil, playerType: nil,
                ext: s.ext, jar: nil, categories: s.categories,
                click: nil, playUrl: nil, style: nil, timeout: nil, header: nil)
        }
        return TVBoxConfig(
            spider: mao.spider, wallpaper: nil, logo: nil, home: nil,
            sites: sites, lives: mao.lives, parses: nil, flags: nil,
            ads: nil, doh: nil)
    }
}
