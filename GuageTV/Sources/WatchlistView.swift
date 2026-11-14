import SwiftUI

/// Re-opens a favourite/history entry's detail page on its original
/// line, routing to the loader matching the site's runtime. (Same
/// contract as the history tab's destination; jar sites report the
/// same "not directly openable" message there too.)
struct EntryDetailDestination: View {
    let entry: HistoryStore.Entry

    var body: some View {
        Group {
            if let resolved {
                let item = VodItem(id: entry.vodId, name: entry.name, pic: entry.pic,
                                   remarks: "", year: "", score: "")
                switch resolved.site.kind {
                case .cmsJSON, .cmsXML:
                    DetailLoaderView(site: resolved.site, item: item, lineID: entry.lineID, parses: resolved.parses)
                case .spiderPY:
                    PyDetailLoaderView(site: resolved.site, item: item, parses: resolved.parses)
                case .spiderJS, .drpyJS:
                    JSDetailLoaderView(site: resolved.site, item: item,
                                       ruleRef: (try? JSSiteBrowseView.resolveRuleRef(resolved.site)) ?? "",
                                       parses: resolved.parses)
                default:
                    message("该站点类型暂不支持直接打开")
                }
            } else {
                message("原线路已删除或站点不存在")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(imageURL: entry.pic))
    }

    private var resolved: (site: TVBoxConfig.Site, parses: [TVBoxConfig.Parse])? {
        let lineID = entry.lineID.isEmpty ? (ConfigLibrary.activeID() ?? "") : entry.lineID
        guard let config = ConfigLibrary.load(id: lineID),
              let site = config.sites.first(where: { $0.key == entry.siteKey })
        else { return nil }
        return (site, config.parses ?? [])
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textDim)
    }
}

/// 追剧 — every favourited series in one place: which ones have new
/// episodes (per the site's own「更新至…」remarks), where you left
/// off, and one tap back into the detail page. Update checks reuse
/// HistoryStore.checkFavouritesForUpdates (CMS favourites; py/JS
/// favourites are listed but not mass-checked).
struct WatchlistView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var checking = false
    @AppStorage("watchlistLastCheck") private var lastCheck: Double = 0
    @AppStorage("watchNotify.enabled") private var notifyEnabled = true

    private var sortedFavourites: [HistoryStore.Entry] {
        history.favourites.sorted { a, b in
            if a.hasUpdate != b.hasUpdate { return a.hasUpdate }
            return a.updatedAt > b.updatedAt
        }
    }

    private var updateCount: Int { history.favourites.filter(\.hasUpdate).count }

    var body: some View {
        Group {
            if sortedFavourites.isEmpty {
                emptyState
            } else {
                List {
                    summaryRow
                    ForEach(sortedFavourites) { entry in
                        NavigationLink {
                            EntryDetailDestination(entry: entry)
                        } label: {
                            row(entry)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AmbientBackground(imageURL: sortedFavourites.first?.pic))
        .navigationTitle("追剧")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !sortedFavourites.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        notifyEnabled.toggle()
                        if notifyEnabled { WatchNotify.requestAuthorizationIfNeeded() }
                    } label: {
                        Image(systemName: notifyEnabled ? "bell.fill" : "bell.slash")
                    }
                    .foregroundStyle(Theme.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(checking ? "检测中…" : "检测更新") { runCheck() }
                        .disabled(checking)
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .task {
            // Quiet auto-check, at most once per 6 hours.
            if !sortedFavourites.isEmpty,
               Date.now.timeIntervalSince1970 - lastCheck > 6 * 3600 {
                runCheck()
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Text("共 \(sortedFavourites.count) 部在追")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            if updateCount > 0 {
                Text("\(updateCount) 部有更新")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 2, trailing: 18))
    }

    private func row(_ entry: HistoryStore.Entry) -> some View {
        HStack(spacing: 12) {
            PosterImage(urlString: entry.pic)
                .frame(width: 46, height: 69)
                .posterFrame()
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                let meta = [entry.siteName, entry.lastRemarks]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                if !entry.episodeName.isEmpty {
                    Text("看到 \(entry.episodeName)")
                        .font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            Spacer()
            if entry.hasUpdate {
                Text("有更新")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(10)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassStroke, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.largeTitle).foregroundStyle(Theme.textDim)
            Text("还没有在追的剧")
                .font(.headline).foregroundStyle(Theme.text)
            Text("在详情页点爱心收藏，连载剧更新了会在这里标出来")
                .font(.subheadline).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runCheck() {
        guard !checking else { return }
        checking = true
        Task {
            await HistoryStore.shared.checkFavouritesForUpdates()
            lastCheck = Date.now.timeIntervalSince1970
            checking = false
        }
    }
}
