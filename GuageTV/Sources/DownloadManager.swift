import AVFoundation
import Combine
import Foundation
import UserNotifications

/// Offline downloads. Two engines, one list:
///  - direct media files (mp4/mkv/ts…) via a plain URLSession
///    download task, stored under Application Support/downloaded-media;
///  - HLS (m3u8) via AVAssetDownloadTask, which produces a local
///    .movpkg the native player can open offline — the only sane way
///    to cache segmented streams on iOS.
/// The manifest (downloads.json) survives relaunches; a download
/// still marked "downloading" at launch died with the process and
/// is shown as failed rather than spinning forever.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    struct Item: Codable, Identifiable {
        var id: String
        var vodName: String
        var episodeName: String
        var pic: String
        var remoteURL: String
        var header: [String: String]
        var isHLS: Bool
        /// Files: file name inside the media dir. HLS: absolute path
        /// of the downloaded .movpkg.
        var localPath: String = ""
        var state: String = "downloading"   // downloading | done | failed
        var progress: Double = 0
        var totalBytes: Int64 = 0
        var createdAt: Date = Date()
    }

    @Published private(set) var items: [Item] = []

    /// v2.35 整剧下完的站内标记：vodName → 下完时间。
    /// 只在 App 内提示（下载页组头「已下完」角标 + 记录
    /// tab 圆点），不发系统通知——守用户「不主动提醒」
    /// 的口径。入队新集 / 删光已下完集时标记失效。
    private static let completedSeriesKey = "downloads.completedSeries.v1"
    private static let unseenCompletedKey = "downloads.completedSeriesUnseen.v1"
    private static let maxCompletedSeries = 20
    @Published private(set) var completedSeries: [String: Date] = [:]
    /// 下完后尚未被用户打开记录页看到的剧名；记录 tab
    /// 的圆点靠它亮，打开记录页即清。
    @Published private(set) var unseenCompletedSeries: Set<String> = []

    /// 该剧名当前是否整剧下完：有标记、且名下每一项都
    /// 是 done（至少一项）。标记只作「曾经下完」的凭证，
    /// 真正的状态以现有下载项为准。
    func isSeriesComplete(_ vodName: String) -> Bool {
        let name = vodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard completedSeries[name] != nil else { return false }
        let mine = items.filter {
            $0.vodName.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }
        return !mine.isEmpty && mine.allSatisfy { $0.state == "done" }
    }

    func markCompletedSeriesSeen() {
        guard !unseenCompletedSeries.isEmpty else { return }
        unseenCompletedSeries = []
        UserDefaults.standard.set([], forKey: Self.unseenCompletedKey)
    }

    private func loadCompletedSeries() {
        if let map = UserDefaults.standard.dictionary(forKey: Self.completedSeriesKey)
            as? [String: TimeInterval] {
            completedSeries = Dictionary(uniqueKeysWithValues:
                map.map { ($0.key, Date(timeIntervalSince1970: $0.value)) })
        }
        if let list = UserDefaults.standard.stringArray(forKey: Self.unseenCompletedKey) {
            unseenCompletedSeries = Set(list)
        }
    }

    private func saveCompletedSeries() {
        let map = Dictionary(uniqueKeysWithValues:
            completedSeries.map { ($0.key, $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(map, forKey: Self.completedSeriesKey)
        UserDefaults.standard.set(Array(unseenCompletedSeries),
                                  forKey: Self.unseenCompletedKey)
    }

    /// 一项下完后检查：同名剧是否再无未完成项（下载中 /
    /// 已暂停 / 失败都算未完成）。是则记下完标记；否则
    /// 不动（还在下的剧不算下完）。
    private func noteFinishedIfSeriesComplete(_ vodName: String) {
        let name = vodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let mine = items.filter {
            $0.vodName.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }
        guard !mine.isEmpty, mine.allSatisfy({ $0.state == "done" }) else { return }
        completedSeries[name] = Date()
        if completedSeries.count > Self.maxCompletedSeries {
            for key in completedSeries.keys.sorted(by: {
                (completedSeries[$0] ?? .distantPast) < (completedSeries[$1] ?? .distantPast)
            }).prefix(completedSeries.count - Self.maxCompletedSeries) {
                completedSeries.removeValue(forKey: key)
            }
        }
        unseenCompletedSeries.insert(name)
        saveCompletedSeries()
    }

    /// 同名剧又有了新下载任务 / 已下完的集被删光时，
    /// 下完标记失效。
    private func clearCompletedSeriesIfNeeded(_ vodName: String) {
        let name = vodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, completedSeries[name] != nil else { return }
        let mine = items.filter {
            $0.vodName.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }
        // 入队时新项 state 为 downloading；删光时 done 项归零。
        if mine.contains(where: { $0.state != "done" }) || mine.isEmpty {
            completedSeries.removeValue(forKey: name)
            unseenCompletedSeries.remove(name)
            saveCompletedSeries()
        }
    }

    /// Background session (v1.42): file downloads keep running
    /// with the app in the background or even terminated; tasks
    /// are re-mapped to manifest items on relaunch.
    private lazy var fileSession: URLSession =
        URLSession(configuration: .background(withIdentifier: "tv.guage.file-downloads"),
                   delegate: self, delegateQueue: .main)
    private lazy var hlsSession: AVAssetDownloadURLSession =
        AVAssetDownloadURLSession(configuration: .background(withIdentifier: "tv.guage.hls-downloads"),
                                  assetDownloadDelegate: self, delegateQueue: .main)
    private var fileTaskIDs: [Int: String] = [:]            // task id → item id
    private var hlsTasks: [String: AVAssetDownloadTask] = [:]
    private var progressTimer: Timer?

    /// Background-session completion handlers (S3, v1.49): when
    /// the app is relaunched in the background because a
    /// download finished, UIKit hands AppDelegate one handler
    /// per session identifier; it must be called exactly once
    /// after the session delivers its events, or the system
    /// never snapshots the app and may kill it. Keyed by
    /// session identifier because the file + HLS sessions each
    /// get their own handler. Accessed only on the main queue
    /// (both sessions use delegateQueue: .main).
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    /// Called from AppDelegate's
    /// application(_:handleEventsForBackgroundURLSession:completionHandler:).
    /// Touching both lazy sessions here guarantees they exist
    /// (with this object as delegate) before the system
    /// delivers their pending events.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void,
                                        forSessionIdentifier identifier: String) {
        backgroundCompletionHandlers[identifier] = handler
        _ = fileSession
        _ = hlsSession
    }

    private var mediaDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloaded-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var manifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloads.json")
    }

    override init() {
        super.init()
        load()
        loadCompletedSeries()
        reconnectTasks()
    }

    // MARK: resume data + relaunch reconnection

    /// Resume blobs live in a side store so the downloads.json
    /// manifest schema never has to change.
    private static let resumeKey = "downloadResumeData.v1"

    private func resumeData(for id: String) -> Data? {
        let map = UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: String] ?? [:]
        return map[id].flatMap { Data(base64Encoded: $0) }
    }

    private func storeResumeData(for id: String, data: Data?) {
        var map = UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: String] ?? [:]
        if let data {
            map[id] = data.base64EncodedString()
        } else {
            map.removeValue(forKey: id)
        }
        UserDefaults.standard.set(map, forKey: Self.resumeKey)
    }

    /// On relaunch, background-session tasks may still be alive:
    /// re-attach them to their items. An item with no live task
    /// left becomes "paused" when a resume blob exists,
    /// otherwise "failed" (the pre-v1.42 behaviour).
    ///
    /// v2.23: the HLS session is re-attached too. Previously only
    /// the file session was queried, so an HLS download still
    /// running in its own background session was marked "failed"
    /// at launch — and when it later finished, the delegate
    /// dropped the event because hlsTasks was empty, leaving an
    /// orphaned .movpkg on disk. Both sessions are queried before
    /// anything is marked failed.
    private func reconnectTasks() {
        fileSession.getAllTasks { [weak self] fileTasks in
            guard let self else { return }
            self.hlsSession.getAllTasks { [weak self] hlsTasks in
                guard let self else { return }
                var liveIDs = Set<String>()
                for task in fileTasks {
                    guard let url = task.originalRequest?.url?.absoluteString,
                          let item = self.items.first(where: {
                              $0.remoteURL == url && $0.state == "downloading"
                          }) else { continue }
                    self.fileTaskIDs[task.taskIdentifier] = item.id
                    liveIDs.insert(item.id)
                }
                var anyHLSLive = false
                for task in hlsTasks {
                    guard let assetTask = task as? AVAssetDownloadTask,
                          let item = self.items.first(where: {
                              $0.remoteURL == assetTask.urlAsset.url.absoluteString
                                  && $0.state == "downloading"
                          }) else { continue }
                    self.hlsTasks[item.id] = assetTask
                    liveIDs.insert(item.id)
                    anyHLSLive = true
                }
                if anyHLSLive { self.startProgressTimerIfNeeded() }
                var changed = false
                for item in self.items where item.state == "downloading" && !liveIDs.contains(item.id) {
                    self.update(item.id, save: false) {
                        $0.state = self.resumeData(for: item.id) != nil ? "paused" : "failed"
                    }
                    changed = true
                }
                if changed { self.save() }
            }
        }
    }

    /// Retry / resume (v1.42): file downloads resume from the
    /// stored blob when one exists (断点续传）, everything else
    /// restarts cleanly.
    func retry(_ item: Item) {
        guard item.state == "failed" || item.state == "paused" else { return }
        update(item.id) { $0.state = "downloading" }
        if item.isHLS {
            startHLS(item)
        } else if let data = resumeData(for: item.id) {
            let task = fileSession.downloadTask(withResumeData: data)
            fileTaskIDs[task.taskIdentifier] = item.id
            task.resume()
        } else {
            startFile(item)
        }
    }

    private func notifyFinished(_ item: Item) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "下载完成"
            content.body = "《\(item.vodName)》\(item.episodeName) 已下载好"
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "download-\(item.id)", content: content, trigger: nil))
        }
    }

    // MARK: public API

    func enqueue(vodName: String, episodeName: String, pic: String,
                 url remote: String, header: [String: String]) {
        guard !remote.isEmpty, URL(string: remote) != nil else { return }
        if items.contains(where: { $0.remoteURL == remote && $0.state != "failed" }) { return }
        let item = Item(id: UUID().uuidString, vodName: vodName, episodeName: episodeName,
                        pic: pic, remoteURL: remote, header: header,
                        isHLS: remote.lowercased().contains(".m3u8"))
        items.insert(item, at: 0)
        save()
        // 又有新集入队：该剧不再算整剧下完。
        clearCompletedSeriesIfNeeded(vodName)
        if item.isHLS { startHLS(item) } else { startFile(item) }
    }

    func remove(_ item: Item) {
        if let task = hlsTasks[item.id] { task.cancel(); hlsTasks[item.id] = nil }
        for (taskID, itemID) in fileTaskIDs where itemID == item.id {
            fileSession.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == taskID }?.cancel()
            }
        }
        if !item.localPath.isEmpty {
            let url = item.isHLS ? URL(fileURLWithPath: item.localPath)
                                 : mediaDir.appendingPathComponent(item.localPath)
            try? FileManager.default.removeItem(at: url)
        }
        storeResumeData(for: item.id, data: nil)
        items.removeAll { $0.id == item.id }
        save()
        // 已下完的集被删光时，下完标记失效。
        clearCompletedSeriesIfNeeded(item.vodName)
    }

    /// Batch remove (v2.10): used by the downloads multi-select bar.
    /// Cancels live tasks and deletes local files per item, same as
    /// the single-item path.
    func remove(ids: Set<String>) {
        for id in ids {
            if let item = items.first(where: { $0.id == id }) { remove(item) }
        }
    }

    /// Batch retry (v2.10): only failed / paused items restart.
    func retry(ids: Set<String>) {
        for id in ids {
            if let item = items.first(where: { $0.id == id }) { retry(item) }
        }
    }

    /// 下载前验货： media URLs (m3u8 / media file extensions) pass
    /// instantly; anything else gets a HEAD probe — if the server
    /// answers with a web page (text/html), the "stream" is a play
    /// page in disguise and cannot be downloaded. Probe failures
    /// never block a download; only a clear HTML answer does.
    static func probeDownloadable(url remote: String, header: [String: String]) async -> Bool {
        let lower = remote.lowercased()
        if lower.contains(".m3u8") { return true }
        let mediaExts = ["mp4", "mkv", "flv", "avi", "wmv", "ts", "mpg", "mpeg",
                         "m2ts", "webm", "mov", "3gp", "rmvb", "f4v"]
        if let ext = URL(string: remote)?.pathExtension.lowercased(),
           mediaExts.contains(ext) { return true }
        guard let url = URL(string: remote) else { return false }
        var request = NetFetch.request(for: url, extraHeader: header)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return true }
        if http.statusCode >= 400 { return true }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return !type.contains("text/html")
    }

    /// Playable local file URL string for a finished download.
    func localURLString(_ item: Item) -> String? {
        guard item.state == "done", !item.localPath.isEmpty else { return nil }
        if item.isHLS { return URL(fileURLWithPath: item.localPath).absoluteString }
        return mediaDir.appendingPathComponent(item.localPath).absoluteString
    }

    var activeCount: Int { items.filter { $0.state == "downloading" }.count }

    /// Actual on-disk size of the downloaded-media directory.
    func downloadedSize() async -> Int64 {
        await CacheManager.sizeOfDirectory(mediaDir)
    }

    // MARK: engines

    private func startFile(_ item: Item) {
        guard let url = URL(string: item.remoteURL) else { markFailed(item.id); return }
        var request = URLRequest(url: url)
        for (key, value) in item.header { request.setValue(value, forHTTPHeaderField: key) }
        let task = fileSession.downloadTask(with: request)
        fileTaskIDs[task.taskIdentifier] = item.id
        task.resume()
    }

    private func startHLS(_ item: Item) {
        guard let url = URL(string: item.remoteURL) else { markFailed(item.id); return }
        var options: [String: Any] = [:]
        if !item.header.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = item.header }
        let asset = AVURLAsset(url: url, options: options)
        guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: item.episodeName,
                                                          assetArtworkData: nil, options: nil)
        else { markFailed(item.id); return }
        hlsTasks[item.id] = task
        task.resume()
        startProgressTimerIfNeeded()
    }

    private func startProgressTimerIfNeeded() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollHLSProgress()
        }
    }

    private func pollHLSProgress() {
        if hlsTasks.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        for (id, task) in hlsTasks {
            update(id, save: false) {
                $0.progress = task.progress.fractionCompleted
                $0.totalBytes = task.progress.totalUnitCount
            }
        }
    }

    // MARK: state plumbing

    /// Progress ticks pass save: false — persisting the manifest on
    /// every network buffer would churn the disk for nothing; state
    /// transitions always save.
    private func update(_ id: String, save: Bool = true, _ mutate: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[i])
        if save { self.save() }
    }

    private func markFailed(_ id: String) {
        update(id) { $0.state = "failed" }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        // "downloading" survives into reconnectTasks(), which
        // decides per item: live task, paused ( resumable ), or
        // failed.
        items = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}

// MARK: file downloads

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = fileTaskIDs[downloadTask.taskIdentifier],
              let item = items.first(where: { $0.id == id }) else { return }
        let ext = (downloadTask.response?.suggestedFilename).map {
            ($0 as NSString).pathExtension
        }.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: item.remoteURL)?.pathExtension ?? "dat"
        let name = "\(id).\(ext)"
        let dest = mediaDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64 ?? 0
            update(id) {
                $0.state = "done"
                $0.progress = 1
                $0.localPath = name
                $0.totalBytes = size
            }
            storeResumeData(for: id, data: nil)
            noteFinishedIfSeriesComplete(item.vodName)
            if let finished = items.first(where: { $0.id == id }) {
                notifyFinished(finished)
            }
        } catch {
            markFailed(id)
        }
        fileTaskIDs[downloadTask.taskIdentifier] = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = fileTaskIDs[downloadTask.taskIdentifier] else { return }
        update(id, save: false) {
            $0.totalBytes = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                $0.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        if let id = fileTaskIDs[task.taskIdentifier] {
            // A resume blob turns a failure into a pause: the
            // download continues where it stopped on retry.
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let resume {
                storeResumeData(for: id, data: resume)
                update(id) { $0.state = "paused" }
            } else {
                markFailed(id)
            }
            fileTaskIDs[task.taskIdentifier] = nil
        }
        let hlsIDs = hlsTasks.filter { $0.value === task }.map { $0.key }
        for id in hlsIDs {
            markFailed(id)
            hlsTasks[id] = nil
        }
    }

    /// S3 (v1.49): the system calls this once per background
    /// session after all its pending events are delivered.
    /// Call the handler UIKit gave AppDelegate for this session
    /// identifier, then clear it — calling it twice or never
    /// both break the background-launch contract (no snapshot /
    /// the app gets killed). Both sessions share this delegate,
    /// so one implementation covers file + HLS.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier,
              let handler = backgroundCompletionHandlers.removeValue(forKey: identifier)
        else { return }
        handler()
        Diagnostics.log("下载", "后台会话 \(identifier) 事件交付完毕，已调用 completion handler")
    }
}

// MARK: HLS downloads

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let finishedIDs = hlsTasks.filter { $0.value === assetDownloadTask }.map { $0.key }
        for id in finishedIDs {
            update(id) {
                $0.state = "done"
                $0.progress = 1
                $0.localPath = location.path
            }
            if let finished = items.first(where: { $0.id == id }) {
                noteFinishedIfSeriesComplete(finished.vodName)
                notifyFinished(finished)
            }
            hlsTasks[id] = nil
        }
    }
}
