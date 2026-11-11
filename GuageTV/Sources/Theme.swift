import SwiftUI

/// Rex-style visual system: ambient artwork glow behind everything, frosted
/// glass cards, floating pill tab bar. All neutral surfaces derive from
/// these helpers so every screen shares one look.
enum Theme {
    static let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    static let glass = Color.white.opacity(0.08)
    static let glassStroke = Color.white.opacity(0.10)
    static let textDim = Color.white.opacity(0.55)
    static let accent = Color(red: 0.55, green: 0.45, blue: 0.95)
    static let ok = Color(red: 0.35, green: 0.85, blue: 0.45)
}

/// Blurred, darkened artwork glow that tints the whole screen (Rex's
/// signature ambient background). Falls back to a deep neutral gradient.
struct AmbientBackground: View {
    var imageURL: String?

    var body: some View {
        ZStack {
            Theme.bg
            if let imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    .blur(radius: 60)
                    .opacity(0.45)
                    .saturation(1.2)
            }
            LinearGradient(colors: [Color.black.opacity(0.25), Theme.bg.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// Frosted glass card container used by every list/section in the app.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
    }
}

extension View {
    /// Poster image with Rex's rounded corners; 2:3 by default.
    /// Clip-only poster outline. Sizing belongs to the caller: an
    /// aspectRatio modifier here negotiated with the (async, variably
    /// sized) image content and produced uneven grid cells twice —
    /// cells now size themselves from a bare Rectangle base instead.
    func posterFrame() -> some View {
        self.clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One poster card's data, mapped from any runtime's list result
/// (vod_id / vod_name / vod_pic / vod_remarks).
struct VodItem: Identifiable {
    var id: String
    var name: String
    var pic: String
    var remarks: String = ""
    var year: String = ""
    var score: String = ""
}
