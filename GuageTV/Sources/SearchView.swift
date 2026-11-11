import SwiftUI

/// Search across all imported CMS sites (py/JS site search joins once
/// their runtimes wire in). Presented from the floating search button.
struct SearchView: View {
    var config: TVBoxConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var results: [(site: TVBoxConfig.Site, items: [VodItem])] = []
    @State private var searching = false
    @State private var searched = false

    private var cmsSites: [TVBoxConfig.Site] {
        (config?.sites ?? []).filter { $0.kind == .cmsJSON || $0.kind == .cmsXML }
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .background(AmbientBackground(imageURL: nil))
            .preferredColorScheme(.dark)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("搜片名", text: $keyword)
                    .foregroundStyle(.white)
                    .submitLabel(.search)
                    .onSubmit { Task { await run() } }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.glass, in: Capsule())
            Button("搜索") { Task { await run() } }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if cmsSites.isEmpty {
            hint("先在设置里导入一个配置，搜索才能开工")
        } else if searching {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        } else if searched && results.isEmpty {
            hint("没有搜到结果")
        } else if !searched {
            hint("搜已导入的 CMS 站点；py/JS 站的搜索随运行时接入")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(results, id: \.site.id) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.site.name)
                                .font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 18)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(group.items) { item in
                                    NavigationLink {
                                        DetailLoaderView(site: group.site, item: item)
                                    } label: {
                                        PosterCell(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.subheadline).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty, !searching else { return }
        searching = true
        var out: [(site: TVBoxConfig.Site, items: [VodItem])] = []
        for site in cmsSites {
            if let items = try? await CMSClient(site: site).search(keyword: kw), !items.isEmpty {
                out.append((site, items))
            }
        }
        results = out
        searched = true
        searching = false
    }
}
