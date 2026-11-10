import SwiftUI

/// Stage 0 home: import a TVBox config by URL, list its sites.
/// Py-backed sites (type 3) will light up once the Python runtime is wired
/// in stage 1; type 0/1 (XML/JSON CMS) sites can be browsed natively later.
struct ContentView: View {
    @State private var configURL = ""
    @State private var config: TVBoxConfig?
    @State private var status = "粘贴 TVBox 配置地址，点导入"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("https://…/config.json", text: $configURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("导入") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                List(config?.sites ?? []) { site in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(site.name)
                            Text(site.api)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(site.type == 3 ? "PY" : "CMS\(site.type)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .navigationTitle("呱壳")
        }
    }

    private func load() async {
        guard let url = URL(string: configURL.trimmingCharacters(in: .whitespaces)) else {
            status = "地址格式不对"
            return
        }
        status = "加载中…"
        do {
            let cfg = try await ConfigLoader.load(url: url)
            config = cfg
            status = "已加载 \(cfg.sites.count) 个站点"
        } catch {
            status = "加载失败：\(error.localizedDescription)"
        }
    }
}
