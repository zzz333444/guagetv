import SwiftUI

/// 设置 (Settings) — Rex-style grouped glass cards: quick tiles on top
/// （播放 / 音画 / 操控 / 字幕）, then grouped rows. The TVBox config import
/// lives here under 数据与资源.
struct SettingsView: View {
    @Binding var config: TVBoxConfig?
    @State private var configURL = ""
    @State private var status = "还没有导入配置"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置").font(.largeTitle.bold()).foregroundStyle(.white)

                HStack(spacing: 12) {
                    quickTile(icon: "slider.horizontal.3", title: "播放")
                    quickTile(icon: "play.rectangle", title: "音画")
                    quickTile(icon: "hand.tap", title: "操控")
                    quickTile(icon: "captions.bubble", title: "字幕")
                }

                group(title: "数据与资源") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("TVBox 配置地址 https://…", text: $configURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("导入配置") { Task { await load() } }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                        Text(status).font(.footnote).foregroundStyle(Theme.textDim)
                        if let config {
                            Text("已加载 \(config.sites.count) 个站点 · \(config.lives?.count ?? 0) 个直播源")
                                .font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                }

                group(title: "使用偏好") {
                    row(icon: "paintbrush", title: "外观与交互", value: "")
                    row(icon: "square.grid.2x2", title: "模块", value: "")
                }

                group(title: "应用") {
                    row(icon: "info.circle", title: "关于呱壳", value: "阶段 0")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(AmbientBackground(imageURL: nil))
        .preferredColorScheme(.dark)
    }

    private func quickTile(icon: String, title: String) -> some View {
        GlassCard(padding: 12) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(.white)
                Text(title).font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Theme.textDim)
            GlassCard { VStack(alignment: .leading, spacing: 12) { content() } }
        }
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.textDim).frame(width: 22)
            Text(title).foregroundStyle(.white)
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(Theme.textDim) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textDim)
        }
    }

    private func load() async {
        guard let url = URL(string: configURL.trimmingCharacters(in: .whitespaces)) else {
            status = "地址格式不对"
            return
        }
        status = "加载中…"
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if MaoYuanAdapter.looksLikeMaoYuan(data) {
                config = try MaoYuanAdapter.convert(from: data)
                status = "已加载（猫源配置已自动转换）"
            } else {
                config = try ConfigLoader.load(from: data)
                status = "已加载 TVBox 配置"
            }
        } catch {
            status = "加载失败：\(error.localizedDescription)"
        }
    }
}
