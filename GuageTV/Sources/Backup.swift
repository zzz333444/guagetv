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

    // MARK: - 本机备份列表 (v2.11)

    /// One backup file kept on this phone (Application Support,
    /// never uploaded anywhere — no cloud sync in this app).
    struct BackupFile: Identifiable {
        let url: URL
        let name: String
        let date: Date
        let size: Int64
        var id: String { name }
    }

    static func backupsDir() -> URL {
        let dir = supportDir().appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All locally kept backups, newest first. The date is the
    /// file's write time, which is the export time (a copy is
    /// written the moment a backup is generated).
    static func listBackups() -> [BackupFile] {
        let dir = backupsDir()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [BackupFile] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(BackupFile(url: url, name: name, date: date, size: size))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Keep a copy of freshly generated backup data on this phone.
    /// Returns the saved URL, or nil if the write failed.
    static func saveLocalCopy(_ data: Data) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = backupsDir()
            .appendingPathComponent("呱壳备份-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func deleteBackup(_ file: BackupFile) {
        try? FileManager.default.removeItem(at: file.url)
    }

    static func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let kb = Double(bytes) / 1_024
        if kb < 1_024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1_024
        if mb < 1_024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1_024)
    }

    /// Human-readable summary of a backup file, shown in the
    /// restore confirmation so the user sees what is about to
    /// overwrite local data. Returns nil for non-backup files.
    static func summarize(data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["format"] as? NSNumber)?.intValue == formatVersion,
              root["app"] as? String == "GuageTV" else { return nil }
        var parts: [String] = []
        if let ts = (root["exportedAt"] as? NSNumber)?.doubleValue {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append("备份于 " + formatter.string(from: Date(timeIntervalSince1970: ts)))
        }
        if let files = root["configFiles"] as? [String: Any] { parts.append("\(files.count) 条线路配置") }
        if let settings = root["settings"] as? [String: Any] { parts.append("\(settings.count) 项设置") }
        if root["historyFile"] != nil { parts.append("观看历史") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A restore waiting on the user's confirmation: the file's
/// summary is shown first so the overwrite is never a surprise.
private struct RestoreDraft: Identifiable {
    let id = UUID()
    let sourceName: String
    let data: Data
    let summary: String
}

struct BackupView: View {
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var message: String?
    /// v2.11: backups kept on this phone, newest first.
    @State private var backups: [BackupStore.BackupFile] = []
    @State private var restoreDraft: RestoreDraft?
    @State private var deleteTarget: BackupStore.BackupFile?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        SettingsPage(title: "备份与恢复") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出备份").font(.headline).foregroundStyle(Theme.text)
                    Text("把配置库（全部线路文件、分组、别名）、观看历史和设置打包成一个 JSON 文件。换机或重装后导入即可恢复。文件里含你填过的网盘/Jar 口令等凭证，只发给自己保存。生成后还会自动在本机留一份，见下方列表。")
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
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("本机备份").font(.headline).foregroundStyle(Theme.text)
                    Text("只存在这台手机上，不上传、不走云同步。点「恢复」会先显示这份备份里有什么，确认后才覆盖本机数据。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    if backups.isEmpty {
                        Text("还没有本机备份，点「生成备份文件」会同时存一份在这里。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    } else {
                        ForEach(backups) { file in
                            backupRow(file)
                            if file.id != backups.last?.id {
                                Divider().background(Theme.glassStroke)
                            }
                        }
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("从文件导入").font(.headline).foregroundStyle(Theme.text)
                    Button {
                        showImporter = true
                    } label: {
                        Label("选择备份文件恢复", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
        }
        .task { backups = BackupStore.listBackups() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                message = "读取备份文件失败"
                return
            }
            offerRestore(data: data, sourceName: url.lastPathComponent)
        }
        .alert(item: $restoreDraft) { draft in
            Alert(
                title: Text("确认恢复这份备份？"),
                message: Text("将用「\(draft.sourceName)」覆盖本机数据：\n\(draft.summary)\n\n恢复后建议重启一次 App。"),
                primaryButton: .destructive(Text("恢复")) {
                    do {
                        message = try BackupStore.restore(from: draft.data)
                    } catch {
                        message = "恢复失败：\(error.localizedDescription)"
                    }
                },
                secondaryButton: .cancel(Text("取消")))
        }
        .confirmationDialog("删除这份本机备份？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let file = deleteTarget {
                    BackupStore.deleteBackup(file)
                    backups = BackupStore.listBackups()
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        }
    }

    private func backupRow(_ file: BackupStore.BackupFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").foregroundStyle(Theme.textDim)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(Self.dateFormatter.string(from: file.date)) · \(BackupStore.sizeText(file.size))")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                ShareLink(item: file.url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button {
                    if let data = try? Data(contentsOf: file.url) {
                        offerRestore(data: data, sourceName: file.name)
                    } else {
                        message = "读取备份文件失败"
                    }
                } label: {
                    Label("恢复", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) {
                    deleteTarget = file
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.text)
        }
    }

    /// Read a backup's summary first; only files that parse as a
    /// GuageTV backup reach the confirmation dialog.
    private func offerRestore(data: Data, sourceName: String) {
        guard let summary = BackupStore.summarize(data: data) else {
            message = "不是呱壳的备份文件，或版本不符"
            return
        }
        restoreDraft = RestoreDraft(sourceName: sourceName, data: data, summary: summary)
    }

    private func makeExportFile() -> URL? {
        guard let data = try? BackupStore.makeBackupData() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("呱壳备份-\(formatter.string(from: Date())).json")
        try? data.write(to: url, options: .atomic)
        if BackupStore.saveLocalCopy(data) != nil {
            backups = BackupStore.listBackups()
            message = "已生成备份并保存在本机备份列表"
        }
        return url
    }
}
