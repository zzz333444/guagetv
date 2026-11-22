import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Poster loader that goes through NetFetch (okhttp identity, retries)
/// instead of AsyncImage's bare URLSession — many CMS image hosts drop
/// requests that don't carry a TVBox-like identity, which left poster
/// grids blank. Results are cached in memory, with a disk second level
/// (Caches/posters) so grids survive relaunches.
struct PosterImage: View {
    let urlString: String
    /// Fit instead of fill: for transparent title artwork (logos),
    /// where cropping would cut the lettering.
    var fit: Bool = false
    /// Decode ceiling in pixels on the long side. Grid cells are
    /// ~120 pt wide (≤ 360 px @3x), so 480 is ample and keeps the
    /// decoded resident set ~4× smaller than the old 900 px flat
    /// ceiling; the hero passes 900 explicitly.
    var pixelSize: Int = 480
    @State private var image: UIImage?
    @State private var appeared = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .modifier(FitOrFill(fit: fit))
                    .opacity(appeared ? 1 : 0)
                    .onAppear {
                        // A short fade reads far smoother than a
                        // hard pop when posters stream in.
                        withAnimation(.easeOut(duration: 0.35)) { appeared = true }
                    }
            } else {
                Rectangle().fill(Theme.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: urlString) { _ in appeared = false }
        .task(id: urlString) {
            image = await PosterCache.shared.load(urlString, maxPixelSize: pixelSize)
        }
    }
}

private struct FitOrFill: ViewModifier {
    var fit: Bool
    func body(content: Content) -> some View {
        if fit {
            content.scaledToFit()
        } else {
            content.scaledToFill()
        }
    }
}

final class PosterCache {
    static let shared = PosterCache()
    private let memory = NSCache<NSString, UIImage>()
    private let store = PosterStore()
    private var warningObserver: NSObjectProtocol?

    init() {
        // v2.16 memory tiering: the old flat 80 MB cap starved
        // big-memory phones and squeezed small ones. Tier by
        // physical memory — 6 GiB+ gets 160 MB, 4 GiB+ 120 MB,
        // anything smaller 48 MB. Cost is supplied per image at
        // insert time, so the cap actually binds the resident set.
        memory.totalCostLimit = Self.memoryLimitBytes()
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Drop the memory level only — the disk level
                // (Caches/posters) survives, so grids reload from
                // disk instead of the network.
                self?.memory.removeAllObjects()
            }
    }

    deinit { if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) } }

    func load(_ urlString: String, maxPixelSize: Int = 480) async -> UIImage? {
        let key = "\(urlString)|\(maxPixelSize)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        var text = urlString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("//") { text = "https:" + text }
        else if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return nil }
        guard let img = await store.image(for: text, url: url, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(img, forKey: key, cost: Self.cost(of: img))
        return img
    }

    /// Drop decoded posters from memory (disk level untouched).
    func clearMemory() { memory.removeAllObjects() }

    /// v2.30: the effective memory tier, for the cache page and
    /// diagnostics — the v2.16 tiering is only real if the number
    /// on screen matches the limit the cache actually enforces.
    /// 6 GiB+ → 160 MB, 4 GiB+ → 120 MB, smaller → 48 MB.
    static var memoryLimitMB: Int { memoryLimitBytes() / 1_048_576 }

    static var memoryTierDescription: String {
        let gib: UInt64 = 1 << 30
        let mem = ProcessInfo.processInfo.physicalMemory
        let tier = mem >= 6 * gib ? "6 GiB 以上档位"
            : mem >= 4 * gib ? "4 GiB 以上档位" : "4 GiB 以下档位"
        return "\(memoryLimitMB) MB（\(tier)，本机内存 \(mem / gib) GiB）"
    }

    /// v2.16 memory tier (see init): 6 GiB+ → 160 MB, 4 GiB+ →
    /// 120 MB, smaller devices → 48 MB. Plain if/else: a switch
    /// `case 6 * gib...:` does not compile — a computed
    /// PartialRangeFrom is not a valid switch pattern for UInt64.
    private static func memoryLimitBytes() -> Int {
        let mem = ProcessInfo.processInfo.physicalMemory
        let gib: UInt64 = 1 << 30
        if mem >= 6 * gib { return 160 * 1024 * 1024 }
        if mem >= 4 * gib { return 120 * 1024 * 1024 }
        return 48 * 1024 * 1024
    }

    /// Cancellable prefetch batch (v2.16): one sequential utility
    /// task over the URLs. Cancelling the returned task stops the
    /// queue — URLs not yet started never fetch — so a fast scroll
    /// doesn't leave a fan-out downloading art the user already
    /// passed. A URL already in memory/disk returns instantly from
    /// load, so a prefetch never re-downloads. Note the single
    /// in-flight download is not aborted mid-flight (it is shared
    /// with on-screen cells through PosterStore); only the pending
    /// queue is dropped.
    func prefetch(_ urls: [String], maxPixelSize: Int = 480) -> Task<Void, Never> {
        let targets = Array(Set(urls.filter { !$0.isEmpty }))
        return Task.detached(priority: .utility) {
            for url in targets {
                guard !Task.isCancelled else { return }
                _ = await self.load(url, maxPixelSize: maxPixelSize)
            }
        }
    }

    /// Approx resident bytes of a decoded image, so totalCostLimit
    /// actually binds: width × height × scale² × 4 bytes per pixel.
    private static func cost(of img: UIImage) -> Int {
        if let cg = img.cgImage {
            return cg.bytesPerRow * cg.height
        }
        let w = Int(img.size.width * img.scale)
        let h = Int(img.size.height * img.scale)
        return max(w * h * 4, 1)
    }
}

/// Disk + network level of the poster cache. An actor so the
/// in-flight table (one download per URL no matter how many cells ask
/// at once) and the eviction counter stay race-free; the actual file
/// IO runs in detached utility tasks, never on the main thread.
///
/// Layout: Caches/posters/<sha256(normalised URL + size)>.img holding
/// the original bytes — inside the Caches directory, so the settings
/// cache manager's "clear caches" wipes it along with everything
/// else. Decoded images are downsampled via ImageIO thumbnails
/// (per-call ceiling, 480 px for grids by default) instead of
/// full-resolution decodes.
private actor PosterStore {
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var writeCount = 0
    private static let maxBytes = 150 * 1024 * 1024
    private static let sweepEvery = 20

    func image(for key: String, url: URL, maxPixelSize: Int) async -> UIImage? {
        let flightKey = "\(key)|\(maxPixelSize)"
        if let pending = inFlight[flightKey] { return await pending.value }
        let task = Task<UIImage?, Never> { await self.fetch(key: key, url: url, maxPixelSize: maxPixelSize) }
        inFlight[flightKey] = task
        let result = await task.value
        inFlight[flightKey] = nil
        return result
    }

    private func fetch(key: String, url: URL, maxPixelSize: Int) async -> UIImage? {
        let file = Self.fileURL(for: key, maxPixelSize: maxPixelSize)
        if let data = await Self.readData(file), let img = Self.decode(data, maxPixelSize: maxPixelSize) {
            return img
        }
        guard let data = try? await NetFetch.imageData(from: url),
              let img = Self.decode(data, maxPixelSize: maxPixelSize) else { return nil }
        await persist(data, to: file)
        return img
    }

    /// Write the fetched bytes, and every `sweepEvery` writes run one
    /// eviction pass (throttled: a full directory scan per write would
    /// cost more than it saves).
    private func persist(_ data: Data, to file: URL) async {
        writeCount += 1
        let sweep = writeCount % Self.sweepEvery == 0
        await Task.detached(priority: .utility) {
            let dir = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            if sweep { Self.evict(dir: dir) }
        }.value
    }

    private static func readData(_ file: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: file)
        }.value
    }

    /// Oldest-first eviction down to the size cap.
    private static func evict(dir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in urls {
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            entries.append((url, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if total <= maxBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static var diskDir: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posters", isDirectory: true)
    }

    private static func fileURL(for key: String, maxPixelSize: Int) -> URL {
        // The size rides in the cache key: a 480 px grid decode and
        // a 900 px hero decode of the same URL are different files.
        // (Old size-less files are simply orphaned and evicted.)
        let digest = SHA256.hash(data: Data("\(key)|\(maxPixelSize)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hex + ".img")
    }

    /// Downsampled decode: ImageIO builds a ≤ maxPixelSize thumbnail
    /// straight from the encoded bytes (no full-size bitmap pass).
    /// Anything ImageIO refuses falls back to a plain UIImage decode.
    private static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
}
