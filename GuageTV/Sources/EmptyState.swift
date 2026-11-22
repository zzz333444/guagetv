import SwiftUI

/// U1 (v1.68): one shared empty-state + skeleton language for every
/// page, in the Rex glass recipe — ambient-friendly, no solid blocks.
/// Card form for full-page empties; compact form for inline spots
/// (inside a section, under a search field). Every empty state gets
/// an icon, one human sentence, and a retry/action button wherever
/// an action makes sense.
struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var compact: Bool = false

    var body: some View {
        if compact {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3).foregroundStyle(Theme.textDim)
                Text(title)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Text(message)
                    .font(.footnote).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            GlassPanel {
                VStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 56, height: 56)
                        .glassCircle()
                    Text(title)
                        .font(.headline).foregroundStyle(Theme.text)
                    Text(message)
                        .font(.subheadline).foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                    if let actionTitle, let action {
                        Button(action: action) {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Canonical empty/error copy (v2.33): the same situation
/// gets the same sentence on every page. Before this round
/// one load failure read "模块没拉到数据" on the module
/// page, "媒体库没拉到" / "剧集没拉到" in Emby, "直播列表
/// 打不开" on the live page and "今天的放送没拉到" on the
/// calendar — and one empty result read "没有搜到结果" in
/// search but "这个栏目暂时没有内容" in a module column.
/// The page's own navigation title already says where you
/// are, so the state titles no longer repeat it. The retry
/// action is "重新加载" everywhere it exists.
enum EmptyStateCopy {
    /// A remote list failed to load: the cause goes in the
    /// message, the retry re-runs the same load.
    static func loadFailed(message: String, retry: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(icon: "wifi.exclamationmark",
                       title: "没拉到数据",
                       message: message,
                       actionTitle: "重新加载",
                       action: retry)
    }

    /// A search / column came back with zero rows.
    static func noResults(message: String = "换个关键词或栏目试试",
                          retry: (() -> Void)? = nil,
                          compact: Bool = false) -> EmptyStateView {
        EmptyStateView(icon: "magnifyingglass",
                       title: "没有搜到结果",
                       message: message,
                       actionTitle: retry == nil ? nil : "重新加载",
                       action: retry,
                       compact: compact)
    }
}

/// Glass placeholder shapes shown while a poster grid is loading:
/// the same footprint as the real cards, redacted so they read as
/// "content incoming" instead of a bare spinner.
struct SkeletonPosterGrid: View {
    var count = 6

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                  spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Theme.glass)
                        .aspectRatio(2/3, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.glass)
                        .frame(height: 12)
                        .padding(.trailing, 24)
                }
            }
        }
        .redacted(reason: .placeholder)
        // v2.33: the transition lives on the skeleton itself, so
        // every call site cross-fades instead of popping — the
        // v2.24 "19 places unified" claim was only true where
        // the parent added it by hand (Discover/Jar); the rest
        // (Emby, CMS/py/JS browse, search, calendar) popped.
        .transition(.opacity)
    }
}

/// Glass placeholder rows for list-style loading states (episode
/// rows, resume/favourite rows, search results).
struct SkeletonRowList: View {
    var count = 4

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.glass)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.glass)
                            .frame(height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.glass)
                            .frame(height: 11)
                            .padding(.trailing, 60)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous))
            }
        }
        .redacted(reason: .placeholder)
        // v2.33: see SkeletonPosterGrid — transition on the
        // skeleton itself, not the call site.
        .transition(.opacity)
    }
}

/// Glass placeholder for the 520pt Discover hero while TMDB is
/// still loading and no feed art has landed yet.
struct SkeletonHero: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.glass)
            .frame(height: 520)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        // v2.33: was hard white 0.25 — invisible
                        // on a light-mode glass background; the
                        // theme text colour is white in dark mode
                        // (identical look) and near-black in light.
                        .fill(Theme.text.opacity(0.25))
                        .frame(width: 180, height: 22)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.text.opacity(0.18))
                        .frame(width: 240, height: 13)
                }
                .padding(20)
            }
            .redacted(reason: .placeholder)
            // v2.33: see SkeletonPosterGrid — transition on the
            // skeleton itself, not the call site.
            .transition(.opacity)
    }
}
