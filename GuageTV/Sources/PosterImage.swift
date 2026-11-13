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
    @State private var image: UIImage?
    @State private var appeared = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(appeared ? 1 : 0)
                    .onAppear {
                        // A short fade reads far smoother than a
                        // hard pop when posters stream in.
                        withAnimation(.easeOut(duration: 0.35)) { appeared = true }
                    }
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: urlString) { _ in appeared = false }
        .task(id: urlString) {
            image = await PosterCache.shared.load(urlString)
        }
    }
}

final class PosterCache {
    static let shared = PosterCache()
    private let memory = NSCache<NSString, UIImage>()
    private let store = PosterStore()

    func load(_ urlString: String) async -> UIImage? {
        let key = urlString as NSString
        if let hit = memory.object(forKey: key) { return hit }
        var text = urlString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("//") { text = "https:" + text }
        else if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return nil }
        guard let img = await store.image(for: text, url: url) else { return nil }
        memory.setObject(img, forKey: key)
        return img
    }
}

/// Disk + network level of the poster cache. An actor so the
/// in-flight table (one download per URL no matter how many cells ask
/// at once) and the eviction counter stay race-free; the actual file
/// IO runs in detached utility tasks, never on the main thread.
///
/// Layout: Caches/posters/<sha256(normalised URL)>.img holding the
/// original bytes — inside the Caches directory, so the settings
/// cache manager's "clear caches" wipes it along with everything
/// else. Decoded images are downsampled via ImageIO thumbnails
/// (≤ 900 px on the long side), which is what poster grids actually
/// display, instead of full-resolution decodes.
private actor PosterStore {
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var writeCount = 0
    private static let maxBytes = 150 * 1024 * 1024
    private static let sweepEvery = 20

    func image(for key: String, url: URL) async -> UIImage? {
        if let pending = inFlight[key] { return await pending.value }
        let task = Task<UIImage?, Never> { await self.fetch(key: key, url: url) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func fetch(key: String, url: URL) async -> UIImage? {
        let file = Self.fileURL(for: key)
        if let data = await Self.readData(file), let img = Self.decode(data) {
            return img
        }
        guard let data = try? await NetFetch.imageData(from: url),
              let img = Self.decode(data) else { return nil }
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

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hex + ".img")
    }

    /// Downsampled decode: ImageIO builds a ≤ 900 px thumbnail
    /// straight from the encoded bytes (no full-size bitmap pass).
    /// Anything ImageIO refuses falls back to a plain UIImage decode.
    private static func decode(_ data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
}
