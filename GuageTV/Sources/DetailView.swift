import SwiftUI

/// 详情 (Detail) — Rex-style: ambient backdrop header, meta block, synopsis,
/// play-line chips, episode grid. Tapping an episode hands its URL (plus the
/// site's required headers) to the player; parse-needed sites resolve through
/// the config's parses in a later wiring step.
struct DetailView: View {
    let detail: VodDetail
    var header: [String: String] = [:]
    @State private var lineIndex = 0
    @State private var playingURL: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock
                if detail.playFrom.count > 1 { lineChips }
                episodeGrid
                if !detail.content.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介").font(.headline).foregroundStyle(.white)
                        Text(detail.content)
                            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 40)
        }
        .background(AmbientBackground(imageURL: detail.pic))
        .preferredColorScheme(.dark)
        .fullScreenCover(item: Binding(
            get: { playingURL.map { PlayTarget(url: $0) } },
            set: { playingURL = $0?.url })) { target in
            PlayerView(urlString: target.url, header: header)
        }
    }

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            if let url = URL(string: detail.pic) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.08))
                }
                .frame(width: 110, height: 165)
                .posterFrame()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(detail.name).font(.title3.bold()).foregroundStyle(.white)
                if !detail.remarks.isEmpty {
                    Text(detail.remarks).font(.subheadline).foregroundStyle(Theme.accent)
                }
                metaLine("类型", detail.typeName)
                metaLine("年份", detail.year)
                metaLine("地区", detail.area)
                metaLine("导演", detail.director)
                metaLine("主演", detail.actor)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        Group {
            if !value.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(label).foregroundStyle(Theme.textDim)
                    Text(value).foregroundStyle(.white.opacity(0.88)).lineLimit(2)
                }
                .font(.footnote)
            }
        }
    }

    private var lineChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(detail.playFrom.indices, id: \.self) { i in
                    Text(detail.playFrom[i])
                        .font(.subheadline.weight(lineIndex == i ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(lineIndex == i ? Color.white : Color.white.opacity(0.10), in: Capsule())
                        .foregroundStyle(lineIndex == i ? .black : .white.opacity(0.85))
                        .onTapGesture { lineIndex = i }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var episodeGrid: some View {
        let episodes = detail.playGroups.indices.contains(lineIndex) ? detail.playGroups[lineIndex] : []
        return VStack(alignment: .leading, spacing: 12) {
            Text("选集").font(.headline).foregroundStyle(.white).padding(.horizontal, 18)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(episodes) { ep in
                    Text(ep.name)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { playingURL = ep.url }
                }
            }
            .padding(.horizontal, 18)
            if episodes.isEmpty {
                Text("该线路暂无选集").font(.footnote).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 18)
            }
        }
    }
}

private struct PlayTarget: Identifiable {
    let url: String
    var id: String { url }
}
