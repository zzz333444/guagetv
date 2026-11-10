import SwiftUI

/// 资源库 (Library) — Rex's two-column source cards: icon, name, route line,
/// content counts, freshness + status dot. Backed by the imported config's
/// sites; counts/freshness fill in once a source has been synced.
struct LibraryView: View {
    var config: TVBoxConfig?
    var onImportTap: () -> Void = {}

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("资源库").font(.largeTitle.bold()).foregroundStyle(.white)
                    Spacer()
                    Button("编辑") { }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Theme.glass, in: Capsule())
                        .foregroundStyle(.white)
                }

                if let sites = config?.sites, !sites.isEmpty {
                    Text("点播源").font(.headline).foregroundStyle(Theme.textDim)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sites) { site in sourceCard(site) }
                    }
                } else {
                    GlassCard {
                        VStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.title2).foregroundStyle(Theme.textDim)
                            Text("还没有资源").foregroundStyle(.white)
                            Text("导入一个 TVBox 配置或猫源，站点会出现在这里")
                                .font(.footnote).foregroundStyle(Theme.textDim)
                                .multilineTextAlignment(.center)
                            Button("去导入", action: onImportTap)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let lives = config?.lives, !lives.isEmpty {
                    Text("直播源").font(.headline).foregroundStyle(Theme.textDim)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(lives, id: \.name) { live in
                            GlassCard(padding: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "tv").foregroundStyle(Theme.accent)
                                    Text(live.name).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white).lineLimit(1)
                                    Text("直播线路").font(.caption).foregroundStyle(Theme.textDim)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
        .preferredColorScheme(.dark)
    }

    private func sourceCard(_ site: TVBoxConfig.Site) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.25)).frame(width: 38, height: 38)
                        Text(String(site.name.prefix(1)))
                            .font(.headline).foregroundStyle(.white)
                    }
                    Spacer()
                    Circle().fill(site.kind == .spiderJAR ? Color.orange : Theme.ok)
                        .frame(width: 7, height: 7)
                }
                Text(site.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(routeText(site))
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Text(kindText(site.kind))
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func routeText(_ site: TVBoxConfig.Site) -> String {
        site.kind == .spiderJAR ? "主线路 · 本平台不支持" : "主线路"
    }

    private func kindText(_ kind: TVBoxConfig.Site.Kind) -> String {
        switch kind {
        case .cmsXML, .cmsJSON: return "CMS 接口"
        case .spiderPY: return "Python 源"
        case .spiderJS: return "JS 源"
        case .drpyJS: return "drpy 源"
        case .spiderJAR: return "Jar 源 · iOS 无 JVM"
        case .unknown: return "未知类型"
        }
    }
}
