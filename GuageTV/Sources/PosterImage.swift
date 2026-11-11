import SwiftUI
import UIKit

/// Poster loader that goes through NetFetch (okhttp identity, retries)
/// instead of AsyncImage's bare URLSession — many CMS image hosts drop
/// requests that don't carry a TVBox-like identity, which left poster
/// grids blank. Results are cached in memory.
struct PosterImage: View {
    let urlString: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: urlString) {
            image = await PosterCache.shared.load(urlString)
        }
    }
}

final class PosterCache {
    static let shared = PosterCache()
    private let cache = NSCache<NSString, UIImage>()

    func load(_ urlString: String) async -> UIImage? {
        let key = urlString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var text = urlString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("//") { text = "https:" + text }
        else if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text),
              let data = try? await NetFetch.imageData(from: url),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
