import Foundation
import SwiftUI

/// Cache accounting & cleanup — exactly three areas:
/// ① the app tmp directory, ② the Caches directory, ③ URLCache.
/// Config-library data lives in Application Support/configs and is
/// NOT cache — it is never touched here. Poster images additionally
/// sit in PosterCache, an in-memory cache that dies with the process
/// (see the note on the settings page); there is nothing to clear.
enum CacheManager {
    enum Area: CaseIterable, Hashable {
        case tmp
        case caches
        case urlCache

        var title: String {
            switch self {
            case .tmp: return "临时文件"
            case .caches: return "缓存目录"
            case .urlCache: return "网络缓存"
            }
        }
    }

    static func size(of area: Area) async -> Int64 {
        switch area {
        case .urlCache:
            return Int64(URLCache.shared.currentDiskUsage)
        case .tmp:
            return await detachedSize(of: FileManager.default.temporaryDirectory)
        case .caches:
            guard let dir = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return 0 }
            return await detachedSize(of: dir)
        }
    }

    static func totalSize() async -> Int64 {
        var total: Int64 = 0
        for area in Area.allCases { total += await size(of: area) }
        return total
    }

    static func clear(_ area: Area) async {
        switch area {
        case .urlCache:
            URLCache.shared.removeAllCachedResponses()
        case .tmp:
            await detachedClearContents(of: FileManager.default.temporaryDirectory)
        case .caches:
            guard let dir = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return }
            await detachedClearContents(of: dir)
        }
    }

    static func clearAll() async {
        for area in Area.allCases { await clear(area) }
    }

    /// Poster disk cache: Caches/posters (see PosterStore). Kept
    /// separate from the generic areas so the downloads page can
    /// report and clear just the posters without touching the rest.
    static var posterCacheDirectory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("posters", isDirectory: true)
    }

    static func posterCacheSize() async -> Int64 {
        await detachedSize(of: posterCacheDirectory)
    }

    /// Clears the poster disk cache and the in-memory poster cache.
    /// Downloaded videos are never touched.
    static func clearPosterCache() async {
        await detachedClearContents(of: posterCacheDirectory)
        await MainActor.run { PosterCache.shared.clearMemory() }
    }

    /// Disk-cache governance (v2.30): the three bounded disk
    /// caches and their caps — poster images 150 MB
    /// (PosterStore evicts oldest-first), module column results
    /// 5 MB / 30 files (FWDColumnCache), Discover feed one file
    /// (TMDBClient, rewritten whole on each refresh). The
    /// breakdown below is what the cache page shows; the total
    /// is the sum, not the whole Caches directory (which also
    /// holds URLCache and other system files).
    struct DiskCacheBreakdown {
        var posterBytes: Int64 = 0
        var moduleColumnBytes: Int64 = 0
        var discoverBytes: Int64 = 0
        var total: Int64 { posterBytes + moduleColumnBytes + discoverBytes }
    }

    static func diskCacheBreakdown() async -> DiskCacheBreakdown {
        async let posters = posterCacheSize()
        async let columns = FWDColumnCache.size()
        let discover = TMDBClient.discoverCacheFileSize()
        return DiskCacheBreakdown(
            posterBytes: await posters,
            moduleColumnBytes: await columns,
            discoverBytes: discover)
    }

    /// Clear the three governed disk caches + the in-memory
    /// poster cache. Downloaded videos, config lines and
    /// UserDefaults are never touched.
    static func clearDiskCaches() async {
        await clearPosterCache()
        FWDColumnCache.clearAll()
        await Task.detached(priority: .utility) { TMDBClient.clearDiscoverCache() }.value
    }

    /// Size of an arbitrary directory, off the main thread.
    static func sizeOfDirectory(_ dir: URL) async -> Int64 {
        await detachedSize(of: dir)
    }

    static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1_024)
    }

    // MARK: directory walking (off the main thread)

    private static func detachedSize(of dir: URL) async -> Int64 {
        await Task.detached(priority: .utility) { directorySize(dir) }.value
    }

    private static func detachedClearContents(of dir: URL) async {
        await Task.detached(priority: .utility) { clearContents(of: dir) }.value
    }

    private static func directorySize(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default
            .enumerator(at: dir, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Remove a directory's contents, never the directory itself.
    private static func clearContents(of dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}

/// 缓存管理 sub-page: per-area sizes with individual 清理 buttons
/// plus 清理全部. All measuring/clearing is async (detached), so the
/// page never blocks while directories are walked.
struct CacheSettingsView: View {
    @State private var sizes: [CacheManager.Area: Int64] = [:]
    @State private var loaded = false
    @State private var busy = false
    /// v2.30: the governed disk caches (poster / module columns
    /// / Discover), measured alongside the generic areas above.
    @State private var breakdown: CacheManager.DiskCacheBreakdown?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("缓存大小").font(.headline).foregroundStyle(Theme.text)
                        ForEach(CacheManager.Area.allCases, id: \.self) { area in
                            HStack(spacing: 10) {
                                Text(area.title).foregroundStyle(Theme.text)
                                Spacer()
                                Text(loaded ? CacheManager.format(sizes[area] ?? 0) : "计算中…")
                                    .foregroundStyle(Theme.textDim)
                                    .monospacedDigit()
                                Button("清理") {
                                    Task { await clear(area) }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.glass, in: Capsule())
                                .foregroundStyle(Theme.text)
                                .disabled(busy || !loaded || (sizes[area] ?? 0) == 0)
                            }
                        }
                        Divider().background(Theme.glassStroke)
                        HStack {
                            Text("总计").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(loaded ? CacheManager.format(total) : "计算中…")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                .monospacedDigit()
                        }
                        Button {
                            Task { await clearAll() }
                        } label: {
                            Text(busy ? "清理中…" : "清理全部缓存")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .disabled(busy || !loaded)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("模块与发现缓存").font(.headline).foregroundStyle(Theme.text)
                        diskRow(title: "海报磁盘缓存", bytes: breakdown?.posterBytes, cap: "上限 150 MB，自动清理最旧的")
                        diskRow(title: "模块栏目缓存", bytes: breakdown?.moduleColumnBytes, cap: "上限 5 MB / 30 条，超期自动清理")
                        diskRow(title: "发现页缓存", bytes: breakdown?.discoverBytes, cap: "单个文件，随刷新整体重写")
                        Divider().background(Theme.glassStroke)
                        HStack {
                            Text("小计").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(loaded ? CacheManager.format(breakdown?.total ?? 0) : "计算中…")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                .monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Text("内存海报缓存上限").foregroundStyle(Theme.text)
                            Spacer()
                            Text(PosterCache.memoryTierDescription)
                                .foregroundStyle(Theme.textDim)
                                .font(.footnote)
                                .multilineTextAlignment(.trailing)
                        }
                        Button {
                            Task { await clearDiskCaches() }
                        } label: {
                            Text(busy ? "清理中…" : "清理模块与发现缓存")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .disabled(busy || !loaded || (breakdown?.total ?? 0) == 0)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("说明").font(.headline).foregroundStyle(Theme.text)
                        Text("海报图片缓存在缓存区里（posters 子目录），清理「缓存区」时会一并清掉。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                        Text("配置库线路和已下载的视频不在缓存范围里，清理缓存不会动它们。")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(AmbientBackground(imageURL: nil))
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private var total: Int64 { sizes.values.reduce(0, +) }

    private func diskRow(title: String, bytes: Int64?, cap: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(title).foregroundStyle(Theme.text)
                Spacer()
                Text(loaded ? CacheManager.format(bytes ?? 0) : "计算中…")
                    .foregroundStyle(Theme.textDim)
                    .monospacedDigit()
            }
            Text(cap).font(.caption).foregroundStyle(Theme.textDim)
        }
    }

    private func refresh() async {
        var result: [CacheManager.Area: Int64] = [:]
        for area in CacheManager.Area.allCases {
            result[area] = await CacheManager.size(of: area)
        }
        sizes = result
        breakdown = await CacheManager.diskCacheBreakdown()
        loaded = true
    }

    private func clear(_ area: CacheManager.Area) async {
        busy = true
        await CacheManager.clear(area)
        await refresh()
        busy = false
    }

    private func clearAll() async {
        busy = true
        await CacheManager.clearAll()
        await refresh()
        busy = false
    }

    private func clearDiskCaches() async {
        busy = true
        await CacheManager.clearDiskCaches()
        await refresh()
        busy = false
    }
}
