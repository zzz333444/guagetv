import AVFoundation
import Combine
import Foundation

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

    private lazy var fileSession: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private lazy var hlsSession: AVAssetDownloadURLSession =
        AVAssetDownloadURLSession(configuration: .background(withIdentifier: "tv.guage.hls-downloads"),
                                  assetDownloadDelegate: self, delegateQueue: .main)
    private var fileTaskIDs: [Int: String] = [:]            // task id → item id
    private var hlsTasks: [String: AVAssetDownloadTask] = [:]
    private var progressTimer: Timer?

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
        items.removeAll { $0.id == item.id }
        save()
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
              var list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        for i in list.indices where list[i].state == "downloading" {
            list[i].state = "failed"
        }
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
            markFailed(id)
            fileTaskIDs[task.taskIdentifier] = nil
        }
        let hlsIDs = hlsTasks.filter { $0.value === task }.map { $0.key }
        for id in hlsIDs {
            markFailed(id)
            hlsTasks[id] = nil
        }
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
            hlsTasks[id] = nil
        }
    }
}
