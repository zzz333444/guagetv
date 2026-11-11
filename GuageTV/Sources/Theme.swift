import SwiftUI
import UIKit

/// Rex-style visual system: ambient artwork glow behind everything, frosted
/// glass cards, floating pill tab bar. All neutral surfaces derive from
/// these helpers so every screen shares one look.
enum Theme {
    /// Adaptive surfaces: identical to the original palette in dark
    /// mode (the app's native look), light counterparts in light mode.
    /// The mode itself is chosen in 外观与交互 (system / light / dark)
    /// and applied once at the app root.
    private static func dyn(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    static let bg = dyn(dark: UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
                        light: UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
    static let glass = dyn(dark: UIColor.white.withAlphaComponent(0.08),
                           light: UIColor.black.withAlphaComponent(0.05))
    static let glassStroke = dyn(dark: UIColor.white.withAlphaComponent(0.10),
                                 light: UIColor.black.withAlphaComponent(0.08))
    static let text = dyn(dark: .white, light: UIColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1))
    static let textDim = dyn(dark: UIColor.white.withAlphaComponent(0.55),
                             light: UIColor.black.withAlphaComponent(0.55))
    /// Section / category titles sit directly on the ambient
    /// background, not on a card — in light mode the 55% dim grey
    /// washed out there, so titles get a stronger tone.
    static let section = dyn(dark: UIColor.white.withAlphaComponent(0.55),
                             light: UIColor.black.withAlphaComponent(0.85))
    static let scrim = dyn(dark: UIColor.black.withAlphaComponent(0.25),
                           light: UIColor.white.withAlphaComponent(0.25))
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
            LinearGradient(colors: [Theme.scrim, Theme.bg.opacity(0.88)],
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
