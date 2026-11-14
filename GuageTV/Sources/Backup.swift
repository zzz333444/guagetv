import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Backup & restore (v1.41): one JSON file carrying the config
/// library (entries index + every stored config file + groups +
/// aliases), the watch history file, and the settings keys
/// (whitelisted prefixes — credentials the user typed for their
/// own services included, since the point is surviving a
/// reinstall on their own phone).
enum BackupStore {
    static let formatVersion = 1

    private static let settingsPrefixes = [
        "config", "drive.", "jarProxy", "tmdb.", "danmaku.",
        "subtitles.", "player.", "gesture.", "homeLayout.",
        "mpvRenderer", "enginePreference", "videoGravity",
        "skipIntro", "skipOutro", "subtitleScale", "seekStep",
        "themeMode", "tabShow", "appLock.", "emby.", "webdav.",
        "activeConfigID", "homeConfigID",
    ]

    private static func supportDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func makeBackupData() throws -> Data {
        var root: [String: Any] = ["format": formatVersion,
                                   "app": "GuageTV",
                                   "exportedAt": Date().timeIntervalSince1970]
        // Config files, base64 per entry id.
        let configsDir = supportDir().appendingPathComponent("configs")
        var files: [String: String] = [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: configsDir.path) {
            for name in names where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                if let data = try? Data(contentsOf: configsDir.appendingPathComponent(name)) {
                    files[id] = data.base64EncodedString()
                }
            }
        }
        root["configFiles"] = files
        if let history = try? Data(contentsOf: supportDir().appendingPathComponent("history.json")) {
            root["historyFile"] = history.base64EncodedString()
        }
        // Settings snapshot (plist-safe values only).
        var settings: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where settingsPrefixes.contains(where: { key.hasPrefix($0) }) {
            settings[key] = encodePlist(value)
        }
        root["settings"] = settings
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    private static func encodePlist(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            return ["__data": data.base64EncodedString()]
        case let array as [Any]:
            return array.map(encodePlist)
        case let dict as [String: Any]:
            return dict.mapValues(encodePlist)
        case let date as Date:
            return date.timeIntervalSince1970
        case is String, is NSNumber, is Bool:
            return value
        default:
            return String(describing: value)
        }
    }

    private static func decodePlist(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            if let b64 = dict["__data"] as? String, dict.count == 1 {
                return Data(base64Encoded: b64) ?? Data()
            }
            return dict.mapValues(decodePlist)
        }
        if let array = value as? [Any] {
            return array.map(decodePlist)
        }
        return value
    }

    /// Restore everything the backup carries. Returns a summary.
    static func restore(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["format"] as? NSNumber)?.intValue == formatVersion else {
            throw NSError(domain: "Backup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不是呱壳的备份文件，或版本不符"])
        }
        var parts: [String] = []
        if let settings = root["settings"] as? [String: Any] {
            for (key, value) in settings {
                UserDefaults.standard.set(decodePlist(value), forKey: key)
            }
            parts.append("\(settings.count) 项设置")
        }
        if let files = root["configFiles"] as? [String: String] {
            let configsDir = supportDir().appendingPathComponent("configs")
            try? FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
            var restored = 0
            for (id, b64) in files {
                if let fileData = Data(base64Encoded: b64) {
                    try? fileData.write(to: configsDir.appendingPathComponent(id + ".json"),
                                         options: .atomic)
                    restored += 1
                }
            }
            parts.append("\(restored) 条配置")
        }
        if let b64 = root["historyFile"] as? String,
           let history = Data(base64Encoded: b64) {
            try? history.write(to: supportDir().appendingPathComponent("history.json"),
                               options: .atomic)
            parts.append("观看历史")
        }
        return "已恢复：" + parts.joined(separator: "、") + "。建议重启一次 App 让所有页面刷新。"
    }
}

struct BackupView: View {
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var message: String?

    var body: some View {
        SettingsPage(title: "备份与恢复") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出备份").font(.headline).foregroundStyle(Theme.text)
                    Text("把配置库（全部线路文件、分组、别名）、观看历史和设置打包成一个 JSON 文件。换机或重装后导入即可恢复。文件里含你填过的网盘/Jar 口令等凭证，只发给自己保存。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享备份文件", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Button {
                        exportURL = makeExportFile()
                    } label: {
                        Label("生成备份文件", systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导入备份").font(.headline).foregroundStyle(Theme.text)
                    Button {
                        showImporter = true
                    } label: {
                        Label("选择备份文件恢复", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                message = try BackupStore.restore(from: data)
            } catch {
                message = "恢复失败：\(error.localizedDescription)"
            }
        }
    }

    private func makeExportFile() -> URL? {
        guard let data = try? BackupStore.makeBackupData() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("呱壳备份-\(formatter.string(from: Date())).json")
        try? data.write(to: url, options: .atomic)
        return url
    }
}
