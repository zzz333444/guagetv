import Foundation

/// Share-sheet import (v1.38): a .py / .js / .json file sent to
/// GuageTV from Files or another app arrives via onOpenURL. The
/// file is copied into Application Support/shared-import right
/// away (the security-scoped URL dies with the callback), a
/// counter bumps, and ContentView offers the import in an alert;
/// confirming runs the same registration the Settings import uses.
enum SharedImportCenter {
    static let counterKey = "sharedImport.counter.v1"
    private static let pathKey = "sharedImport.path.v1"

    static func receive(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("shared-import")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.copyItem(at: url, to: dest)) != nil
        guard ok else { return }
        UserDefaults.standard.set(dest.path, forKey: pathKey)
        UserDefaults.standard.set(
            UserDefaults.standard.integer(forKey: counterKey) + 1, forKey: counterKey)
    }

    static var pendingFileName: String? {
        guard let path = UserDefaults.standard.string(forKey: pathKey) else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Classify + register the pending shared file. Returns a
    /// user-facing result line; the pending path is consumed
    /// either way so the alert never repeats.
    static func performImport() -> String {
        guard let path = UserDefaults.standard.string(forKey: pathKey) else {
            return "没有待导入的文件"
        }
        UserDefaults.standard.removeObject(forKey: pathKey)
        let fileName = (path as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "导入失败：读不到分享的文件"
        }
        do {
            switch ext {
            case "py", "js":
                let entry = try SingleFileLine.register(
                    data: data, fileName: fileName, kind: ext,
                    displayName: ((fileName as NSString).deletingPathExtension))
                return "已加入资源库：\(ConfigLibrary.shownName(entry))"
            case "json", "txt", "":
                let parsed: TVBoxConfig
                if MaoYuanAdapter.looksLikeMaoYuan(data) {
                    parsed = try MaoYuanAdapter.convert(from: data)
                } else {
                    parsed = try ConfigLoader.load(from: data)
                }
                let entry = ConfigLibrary.add(data: data,
                                              sourceURL: "file-import://" + fileName,
                                              siteCount: parsed.sites.count)
                return "已加入资源库：\(ConfigLibrary.shownName(entry))（\(parsed.sites.count) 个站点）"
            default:
                return "不支持的文件类型：.\(ext)（可导入 .py / .js / .json）"
            }
        } catch {
            return "导入失败：\(error.localizedDescription)"
        }
    }
}

/// The synthetic one-site line for a loose .py / .js file — the
/// storage half of Settings → 万能导入， shared with the
/// share-sheet path above.
enum SingleFileLine {
    @discardableResult
    static func register(data: Data, fileName: String, kind: String,
                         displayName: String) throws -> ConfigLibrary.Entry {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dirName = kind == "py" ? "spiders" : "jsrules"
        let dir = support.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        let base = (fileName as NSString).deletingPathExtension
        let siteName = displayName.isEmpty ? base : displayName
        let site: [String: Any]
        if kind == "py" {
            site = ["key": "pyfile_" + base, "name": siteName, "type": 3,
                    "api": "local-spider://" + fileName, "searchable": 1, "quickSearch": 1]
        } else {
            site = ["key": "jsfile_" + base, "name": siteName, "type": 3,
                    "api": "bundled-engine.js", "ext": "local-rule://" + fileName,
                    "searchable": 1, "quickSearch": 1]
        }
        let configData = try JSONSerialization.data(withJSONObject: ["sites": [site]])
        _ = try ConfigLoader.load(from: configData)
        let entry = ConfigLibrary.add(data: configData,
                                      sourceURL: (kind == "py" ? "py-import://" : "js-import://") + fileName,
                                      siteCount: 1)
        if !displayName.isEmpty, displayName != entry.name {
            ConfigLibrary.setAlias(displayName, for: entry.id)
        }
        return entry
    }
}
