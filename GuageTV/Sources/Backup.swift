import CryptoKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

/// AES-GCM envelope for backups (v2.41). The plaintext backup
/// JSON is sealed with a key derived from the user's backup
/// password (SHA-256 of salt + password; the random salt rides
/// in the envelope, the password never does). Format 2 files
/// are JSON envelopes, not raw backups — restore decrypts
/// first, then feeds the plaintext to BackupStore.restore.
enum BackupCrypto {
    static let formatVersion = 2

    static func isEncrypted(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["format"] as? NSNumber)?.intValue == formatVersion,
              root["app"] as? String == "GuageTV",
              (root["encrypted"] as? NSNumber)?.boolValue == true else { return false }
        return true
    }

    static func encrypt(_ plain: Data, password: String) throws -> Data {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        let status = saltBytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "BackupCrypto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "生成随机盐失败"])
        }
        let salt = Data(saltBytes)
        let key = SymmetricKey(data: SHA256.hash(data: salt + Data(password.utf8)))
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "BackupCrypto", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "加密失败"])
        }
        let root: [String: Any] = ["format": formatVersion,
                                   "app": "GuageTV",
                                   "encrypted": true,
                                   "salt": salt.base64EncodedString(),
                                   "sealed": combined.base64EncodedString(),
                                   "exportedAt": Date().timeIntervalSince1970]
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saltB64 = root["salt"] as? String,
              let sealedB64 = root["sealed"] as? String,
              let salt = Data(base64Encoded: saltB64),
              let combined = Data(base64Encoded: sealedB64) else {
            throw NSError(domain: "BackupCrypto", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "不是加密备份文件"])
        }
        let key = SymmetricKey(data: SHA256.hash(data: salt + Data(password.utf8)))
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw NSError(domain: "BackupCrypto", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "口令不对，解密失败"])
        }
    }
}

/// The backup password lives in the device keychain only — it
/// is never written into a backup file (BackupStore's settings
/// snapshot has no "backup." prefix) and never leaves the phone.
/// Clearing it disables auto backup until a new one is set.
enum BackupKeychain {
    private static let service = "GuageTV"
    private static let account = "backup-password"

    static var password: String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    static func setPassword(_ password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func clearPassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Backup & restore (v1.41): one JSON file carrying the config
/// library (entries index + every stored config file + groups +
/// aliases), the imported Forward modules (v2.36 — they live in
/// Application Support/widgets, not in the config library, so a
/// backup without them silently lost every module on restore),
/// the watch history file, and the settings keys
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
        "themeMode", "tabShow", "appLock.", "emby.", "webdav.", "smb.",
        "activeConfigID", "homeConfigID",
        // v2.36: module state — per-module storage, shared cache,
        // validation notes, saved globals, content-type overrides,
        // self-check results. The module .js sources themselves
        // ride in the fwdModules section below, not here.
        "fwd.",
        // v2.41: auto-backup schedule + encrypt-export choice ride
        // along so the schedule survives a restore. The backup
        // password itself lives in the keychain and is never a
        // UserDefaults key, so it can never land in this snapshot.
        "backup.auto.", "backup.encryptExport",
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
        // Forward modules (v2.36): widgets/index.json + every
        // module .js file, base64 per file. The column cache lives
        // in Caches and is regenerable, so it is not backed up.
        let widgetsDir = supportDir().appendingPathComponent("widgets")
        var fwdFiles: [String: String] = [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: widgetsDir.path) {
            for name in names where name.hasSuffix(".js") || name == "index.json" {
                if let data = try? Data(contentsOf: widgetsDir.appendingPathComponent(name)) {
                    fwdFiles[name] = data.base64EncodedString()
                }
            }
        }
        if !fwdFiles.isEmpty { root["fwdModules"] = fwdFiles }
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
            // v2.36: a restore is a real overwrite, not a merge —
            // drop config files the backup does not carry, so a
            // line deleted before the backup was taken does not
            // come back as a leftover file. (The entries index
            // itself rides in settings, so it cannot reference a
            // file removed here.)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: configsDir.path) {
                for name in names where name.hasSuffix(".json") {
                    let id = String(name.dropLast(5))
                    if files[id] == nil {
                        try? FileManager.default.removeItem(at: configsDir.appendingPathComponent(name))
                    }
                }
            }
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
        if let fwd = root["fwdModules"] as? [String: String] {
            let widgetsDir = supportDir().appendingPathComponent("widgets")
            try? FileManager.default.createDirectory(at: widgetsDir, withIntermediateDirectories: true)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: widgetsDir.path) {
                for name in names where (name.hasSuffix(".js") || name == "index.json") && fwd[name] == nil {
                    try? FileManager.default.removeItem(at: widgetsDir.appendingPathComponent(name))
                }
            }
            var restoredModules = 0
            for (name, b64) in fwd {
                if let fileData = Data(base64Encoded: b64) {
                    try? fileData.write(to: widgetsDir.appendingPathComponent(name),
                                         options: .atomic)
                    if name.hasSuffix(".js") { restoredModules += 1 }
                }
            }
            parts.append("\(restoredModules) 个模块")
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
        if let fwd = root["fwdModules"] as? [String: Any] {
            // Only .js files count as modules; index.json is the
            // module index, not a module (mirrors restore, which
            // counts only .js files it actually wrote back).
            let n = fwd.keys.filter { $0.hasSuffix(".js") }.count
            if n > 0 { parts.append("\(n) 个模块") }
        }
        if let settings = root["settings"] as? [String: Any] { parts.append("\(settings.count) 项设置") }
        if root["historyFile"] != nil { parts.append("观看历史") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Decrypt an encrypted (format 2) backup, then restore the
    /// plaintext exactly like a plain backup. Throws a Chinese
    /// error when the password is wrong or the file is not an
    /// encrypted backup at all.
    static func restoreEncrypted(from data: Data, password: String) throws -> String {
        let plain = try BackupCrypto.decrypt(data, password: password)
        return try restore(from: plain)
    }
}

/// Automatic encrypted backup to WebDAV (v2.41). The schedule
/// runs when the backup page is opened (and on "立即备份一次");
/// there is no background timer — iOS suspends this app in the
/// background, so a due check on foreground entry is the honest
/// trigger. Every upload is AES-GCM encrypted with the keychain
/// backup password first; without a password auto backup stays
/// off, never silently uploading a plaintext backup.
enum AutoBackup {
    static let folderName = "GuageTV-backups"

    private static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "backup.auto.enabled")
    }
    private static var frequency: String {
        UserDefaults.standard.string(forKey: "backup.auto.frequency") ?? "daily"
    }
    private static var retention: Int {
        let n = UserDefaults.standard.integer(forKey: "backup.auto.retention")
        return n <= 0 ? 3 : n
    }
    private static var serverURL: String {
        UserDefaults.standard.string(forKey: "backup.auto.serverURL") ?? ""
    }

    private static var interval: TimeInterval {
        frequency == "weekly" ? 7 * 24 * 3_600 : 24 * 3_600
    }

    /// The server auto backup uploads to: the one the user picked
    /// on the backup page, else the first configured WebDAV server.
    static func targetServer() -> MediaServerSettingsView.DAVServer? {
        let servers = MediaServerSettingsView.davServers(
            from: UserDefaults.standard.string(forKey: "webdav.servers") ?? "[]")
        if !serverURL.isEmpty, let picked = servers.first(where: { $0.url == serverURL }) {
            return picked
        }
        return servers.first
    }

    static var lastSummary: String? {
        let at = UserDefaults.standard.double(forKey: "backup.auto.lastAt")
        guard at > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let when = formatter.string(from: Date(timeIntervalSince1970: at))
        let ok = UserDefaults.standard.bool(forKey: "backup.auto.lastSuccess")
        let result = UserDefaults.standard.string(forKey: "backup.auto.lastResult") ?? ""
        return "上次自动备份：\(when) · \(ok ? "成功" : "失败：\(result)")"
    }

    /// Run now if due (or forced by the "立即备份一次" button).
    /// Returns a Chinese one-line result; the outcome is also
    /// stored for the backup page to show. "未到时间" is not an
    /// error and does not overwrite the last stored result.
    @discardableResult
    static func runIfDue(force: Bool = false) async -> String {
        if !force && !enabled { return "自动备份未开启" }
        guard let password = BackupKeychain.password, !password.isEmpty else {
            return recordFailure("未设置备份口令，自动备份未启用")
        }
        guard let server = targetServer() else {
            return recordFailure("未配置 WebDAV 服务器")
        }
        if !force {
            let last = UserDefaults.standard.double(forKey: "backup.auto.lastAt")
            let lastOK = UserDefaults.standard.bool(forKey: "backup.auto.lastSuccess")
            if last > 0 && lastOK && Date().timeIntervalSince1970 - last < interval {
                return "未到备份时间"
            }
        }
        do {
            let plain = try BackupStore.makeBackupData()
            let encrypted = try BackupCrypto.encrypt(plain, password: password)
            guard let base = URL(string: server.url) else {
                throw NSError(domain: "WebDAV", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址不对"])
            }
            let folder = base.appendingPathComponent(folderName)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let fileName = "呱壳备份-\(formatter.string(from: Date())).guagebak"
            let fileURL = folder.appendingPathComponent(fileName)
            // Most servers need the collection first; a 405
            // (already exists) is fine and ignored.
            try? await WebDAVClient.makeCollection(server: server, url: folder)
            do {
                try await WebDAVClient.upload(server: server, url: fileURL, data: encrypted)
            } catch let error as NSError where error.code == 409 {
                try await WebDAVClient.makeCollection(server: server, url: folder)
                try await WebDAVClient.upload(server: server, url: fileURL, data: encrypted)
            }
            try? await prune(server: server, folder: folder)
            return recordSuccess("已上传 \(fileName)")
        } catch {
            return recordFailure(error.localizedDescription)
        }
    }

    /// Keep only the newest `retention` backup files in the
    /// folder; older ones are deleted. Failures here never fail
    /// the backup itself.
    private static func prune(server: MediaServerSettingsView.DAVServer,
                            folder: URL) async throws {
        let entries = try await WebDAVClient.list(server: server, path: folder.absoluteString)
        let backups = entries
            .filter { !$0.isFolder && $0.name.hasPrefix("呱壳备份-") }
            .sorted { $0.name > $1.name }
        for extra in backups.dropFirst(retention) {
            guard let url = URL(string: extra.href) else { continue }
            try? await WebDAVClient.delete(server: server, url: url)
        }
    }

    private static func recordSuccess(_ detail: String) -> String {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.auto.lastAt")
        UserDefaults.standard.set(true, forKey: "backup.auto.lastSuccess")
        UserDefaults.standard.set(detail, forKey: "backup.auto.lastResult")
        Diagnostics.log("自动备份", "成功：\(detail)")
        return detail
    }

    private static func recordFailure(_ reason: String) -> String {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.auto.lastAt")
        UserDefaults.standard.set(false, forKey: "backup.auto.lastSuccess")
        UserDefaults.standard.set(reason, forKey: "backup.auto.lastResult")
        Diagnostics.log("自动备份", "失败：\(reason)")
        return reason
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
    /// v2.41: automatic encrypted backup to WebDAV.
    @AppStorage("webdav.servers") private var webdavJSON = "[]"
    @AppStorage("backup.auto.enabled") private var autoEnabled = false
    @AppStorage("backup.auto.frequency") private var autoFrequency = "daily"
    @AppStorage("backup.auto.retention") private var autoRetention = 3
    @AppStorage("backup.auto.serverURL") private var autoServerURL = ""
    @AppStorage("backup.encryptExport") private var encryptExport = true
    @State private var hasPassword = false
    @State private var newPassword = ""
    @State private var autoRunning = false
    @State private var autoSummary: String?
    /// An encrypted file waiting on its password before restore.
    @State private var pendingRestore: (data: Data, sourceName: String)?
    @State private var restorePassword = ""
    @State private var restorePasswordError: String?

    private var davServers: [MediaServerSettingsView.DAVServer] {
        MediaServerSettingsView.davServers(from: webdavJSON)
    }

    /// The toggle stays greyed out until both prerequisites
    /// exist: a WebDAV server and a backup password. An
    /// unencrypted auto upload is never an option.
    private var autoBlockedReason: String? {
        if davServers.isEmpty { return "先去「设置 → 媒体服务器」添加一个 WebDAV 服务器" }
        if !hasPassword { return "先在下方设置备份口令（自动备份只上传加密后的文件）" }
        return nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        SettingsPage(title: "备份与恢复") {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("自动备份到 WebDAV").font(.headline).foregroundStyle(Theme.text)
                    Text("到时间自动把加密后的备份传到你的 WebDAV 服务器（GuageTV-backups 文件夹），只留最近几份。App 在后台会被系统挂起，所以到时检查在你打开本页时做，不会悄悄在后台跑。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Toggle("自动备份", isOn: $autoEnabled)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .disabled(autoBlockedReason != nil)
                    if let reason = autoBlockedReason {
                        Text(reason).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    Picker("频率", selection: $autoFrequency) {
                        Text("每天").tag("daily")
                        Text("每周").tag("weekly")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!autoEnabled)
                    Stepper("保留最近 \(autoRetention) 份", value: $autoRetention, in: 1...10)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text)
                        .disabled(!autoEnabled)
                    if davServers.count > 1 {
                        Picker("服务器", selection: $autoServerURL) {
                            Text("第一个服务器").tag("")
                            ForEach(davServers) { server in
                                Text(server.name).tag(server.url)
                            }
                        }
                        .font(.subheadline)
                        .disabled(!autoEnabled)
                    } else if let server = davServers.first {
                        Text("服务器：\(server.name)（\(server.url)）")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    HStack(spacing: 16) {
                        Button {
                            Haptics.medium()
                            autoRunning = true
                            Task {
                                let result = await AutoBackup.runIfDue(force: true)
                                autoSummary = AutoBackup.lastSummary
                                message = result
                                autoRunning = false
                            }
                        } label: {
                            Label(autoRunning ? "备份中…" : "立即备份一次",
                                  systemImage: "arrow.up.doc")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                        }
                        .disabled(autoRunning || autoBlockedReason != nil)
                        Spacer()
                    }
                    if let autoSummary {
                        Text(autoSummary)
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("备份口令").font(.headline).foregroundStyle(Theme.text)
                    Text(hasPassword
                         ? "已设置。口令只存在本机钥匙串里，不进备份文件；忘口令则加密备份无法恢复，换机前请记好。"
                         : "自动备份与加密导出都用这个口令加密（AES-GCM）。没设口令时自动备份打不开，导出的也是明文文件。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    SecureField("备份口令（至少 4 位）", text: $newPassword)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    HStack(spacing: 16) {
                        Button {
                            Haptics.medium()
                            let trimmed = newPassword.trimmingCharacters(in: .whitespaces)
                            guard trimmed.count >= 4 else {
                                message = "口令至少 4 位"
                                return
                            }
                            if BackupKeychain.setPassword(trimmed) {
                                hasPassword = true
                                newPassword = ""
                                message = "备份口令已保存到本机钥匙串"
                            } else {
                                message = "口令保存失败"
                            }
                        } label: {
                            Label(hasPassword ? "更换口令" : "设置口令", systemImage: "key.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                        }
                        if hasPassword {
                            Button(role: .destructive) {
                                Haptics.tap()
                                BackupKeychain.clearPassword()
                                hasPassword = false
                                autoEnabled = false
                                message = "已清除备份口令，自动备份已关闭"
                            } label: {
                                Label("清除口令", systemImage: "trash")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.red.opacity(0.85))
                        }
                        Spacer()
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出备份").font(.headline).foregroundStyle(Theme.text)
                    Text("把配置库（全部线路文件、分组、别名）、已导入的模块、观看历史和设置打包成一个 JSON 文件。换机或重装后导入即可恢复。文件里含你填过的网盘/Jar 口令等凭证，只发给自己保存。生成后还会自动在本机留一份，见下方列表。")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                    Toggle("加密导出（用上面的备份口令）", isOn: $encryptExport)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .disabled(!hasPassword)
                    if !hasPassword {
                        Text("未设备份口令时只能导出明文文件，恢复加密备份时要输口令。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享备份文件", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Button {
                        Haptics.medium(); exportURL = makeExportFile()
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
                        Haptics.tap(); showImporter = true
                    } label: {
                        Label("选择备份文件恢复", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
        }
        .task {
            backups = BackupStore.listBackups()
            hasPassword = BackupKeychain.password != nil
            autoSummary = AutoBackup.lastSummary
            // Due check: auto backup has no background timer
            // (iOS suspends the app), so entering this page is
            // the trigger. A not-due run is a silent no-op.
            if autoEnabled {
                _ = await AutoBackup.runIfDue()
                autoSummary = AutoBackup.lastSummary
            }
        }
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
        .sheet(isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } })) {
            if let pending = pendingRestore {
                SettingsPage(title: "输入备份口令") {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("「\(pending.sourceName)」是加密备份，输入当时设置的备份口令才能解密恢复。口令不对会直接报错，不会覆盖本机数据。")
                                .font(.footnote).foregroundStyle(Theme.textDim)
                            SecureField("备份口令", text: $restorePassword)
                                .font(.subheadline)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(10)
                                .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                            if let restorePasswordError {
                                Text(restorePasswordError)
                                    .font(.footnote).foregroundStyle(.red.opacity(0.85))
                            }
                            HStack(spacing: 16) {
                                Button {
                                    Haptics.medium()
                                    do {
                                        let plain = try BackupCrypto.decrypt(
                                            pending.data, password: restorePassword)
                                        guard let summary = BackupStore.summarize(data: plain) else {
                                            restorePasswordError = "解密成功但内容不是呱壳的备份"
                                            return
                                        }
                                        restoreDraft = RestoreDraft(
                                            sourceName: pending.sourceName,
                                            data: plain, summary: summary)
                                        pendingRestore = nil
                                    } catch {
                                        restorePasswordError = error.localizedDescription
                                    }
                                } label: {
                                    Label("解密并恢复", systemImage: "lock.open")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text)
                                }
                                .disabled(restorePassword.isEmpty)
                                Button("取消") { pendingRestore = nil }
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textDim)
                                Spacer()
                            }
                        }
                    }
                }
            }
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
                    Haptics.medium()
                    if let data = try? Data(contentsOf: file.url) {
                        offerRestore(data: data, sourceName: file.name)
                    } else {
                        message = "读取备份文件失败"
                    }
                } label: {
                    Label("恢复", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) {
                    Haptics.tap(); deleteTarget = file
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
    /// GuageTV backup reach the confirmation dialog. Encrypted
    /// backups ask for their password first, then decrypt and
    /// summarize the plaintext the same way.
    private func offerRestore(data: Data, sourceName: String) {
        if BackupCrypto.isEncrypted(data) {
            pendingRestore = (data: data, sourceName: sourceName)
            restorePassword = ""
            restorePasswordError = nil
            return
        }
        guard let summary = BackupStore.summarize(data: data) else {
            message = "不是呱壳的备份文件，或版本不符"
            return
        }
        restoreDraft = RestoreDraft(sourceName: sourceName, data: data, summary: summary)
    }

    private func makeExportFile() -> URL? {
        guard var data = try? BackupStore.makeBackupData() else { return nil }
        if encryptExport {
            guard let password = BackupKeychain.password, !password.isEmpty else {
                message = "已勾选加密导出，但未设备份口令"
                return nil
            }
            guard let encrypted = try? BackupCrypto.encrypt(data, password: password) else {
                message = "加密备份失败"
                return nil
            }
            data = encrypted
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("呱壳备份-\(formatter.string(from: Date())).json")
        try? data.write(to: url, options: .atomic)
        if BackupStore.saveLocalCopy(data) != nil {
            backups = BackupStore.listBackups()
            message = encryptExport && BackupKeychain.password != nil
                ? "已生成加密备份并保存在本机备份列表"
                : "已生成备份并保存在本机备份列表"
        }
        return url
    }
}
