import Combine
import Foundation

/// One arrangeable module on the Discover (home) page.
enum HomeModule: String, CaseIterable, Identifiable {
    case hero
    case continueWatching
    case updates
    case sections
    case categories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero: return "推荐轮播"
        case .continueWatching: return "继续观看"
        case .updates: return "追剧更新"
        case .sections: return "内容行"
        case .categories: return "分类浏览"
        }
    }
}

/// Persisted home-module order + visibility — Rex's「编辑布局」:
/// the user drags modules into their own order and hides the ones
/// they don't use. Stored in UserDefaults; Discover observes it.
final class HomeLayout: ObservableObject {
    static let shared = HomeLayout()

    @Published private(set) var order: [HomeModule]
    @Published private(set) var hidden: Set<String>

    private static let orderKey = "homeLayout.order.v1"
    private static let hiddenKey = "homeLayout.hidden.v1"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        var restored = saved.compactMap(HomeModule.init(rawValue:))
        for module in HomeModule.allCases where !restored.contains(module) {
            restored.append(module)
        }
        order = restored
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    var visibleModules: [HomeModule] {
        order.filter { !hidden.contains($0.rawValue) }
    }

    func isVisible(_ module: HomeModule) -> Bool {
        !hidden.contains(module.rawValue)
    }

    func setVisible(_ module: HomeModule, _ visible: Bool) {
        if visible { hidden.remove(module.rawValue) } else { hidden.insert(module.rawValue) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenKey)
    }

    func move(from source: IndexSet, to destination: Int) {
        var next = order
        let moving = source.sorted().map { next[$0] }
        for index in source.sorted(by: >) { next.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: max(0, min(insertAt, next.count)))
        order = next
        UserDefaults.standard.set(next.map(\.rawValue), forKey: Self.orderKey)
    }
}
