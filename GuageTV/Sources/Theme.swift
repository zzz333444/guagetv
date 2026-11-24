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
    /// Strong rim for the *active* card in a selectable set
    /// (detail 播放资源卡、直播选中态）: the old hand-written
    /// white 0.45 / 0.12 pair, now one named value so the
    /// inactive rim stays Theme.glassStroke everywhere.
    static let glassStrokeStrong = dyn(dark: UIColor.white.withAlphaComponent(0.45),
                                       light: UIColor.black.withAlphaComponent(0.45))
    /// Gradient rim light for the Rex glass recipe: bright at the
    /// top edge, fading downwards — like light catching real glass.
    static let glassEdge = LinearGradient(
        colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
        startPoint: .top, endPoint: .bottom)
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

    /// Canonical glass radii (v2.20): one set of numbers for every
    /// card in the app — 20 for top-level cards, 16 for inner
    /// cards, 12 for posters/stills. Before this round the same
    /// surfaces used 20/16/14/12 ad hoc (detail line cards were
    /// 14, media-info 16, module chips 10/12) with no shared value.
    static let cardRadius: CGFloat = 20
    static let innerCardRadius: CGFloat = 16
    static let posterRadius: CGFloat = 12
    /// Small chips / icon tiles / calendar day cells (v2.32):
    /// the 10pt radius that was hand-written in Emby, media
    /// servers, calendar and detail chips now has a name.
    static let smallRadius: CGFloat = 10
    /// Canonical animation set (v2.33): every duration in the
    /// app previously lived as a literal — 0.18 / 0.2 / 0.22 /
    /// 0.25 / 0.3 / 0.35 scattered across 16 files — so the
    /// same gesture felt different on each page. Four values
    /// now cover everything: quick for toggles, expands and
    /// segment switches; standard for content swaps and the
    /// loading ↔ content cross-fade; fade for image fade-ins;
    /// chrome for the player chrome / HUD / toast. The one
    /// deliberate exception is the Discover hero auto-advance
    /// (0.45s, a slow carousel cross-fade, not a gesture).
    static let animQuick = Animation.easeInOut(duration: 0.2)
    static let animStandard = Animation.easeOut(duration: 0.25)
    static let animFade = Animation.easeOut(duration: 0.35)
    static let animChrome = Animation.easeInOut(duration: 0.25)
    /// Tint wash over the translucent fill — the Library's
    /// LightGlassCard recipe; flat Theme.glass alone reads as a
    /// plain grey block next to it.
    static let cardTint = Color.white.opacity(0.05)
}

/// Blurred, darkened artwork glow that tints the whole screen (Rex's
/// signature ambient background). Falls back to a deep neutral gradient.
struct AmbientBackground: View {
    var imageURL: String?
    /// How strongly the artwork tints the page; the detail page
    /// pushes it higher so the cover melts into the whole screen.
    var intensity: Double = 0.45
    /// v2.55: stable cache key for the artwork (Emby image URLs
    /// carry a rotating api_key — without it the ambient glow
    /// orphans on every token rotation, the same bug v2.44
    /// fixed for the grids). Nil = key on the URL, as before.
    var cacheKey: String? = nil

    var body: some View {
        ZStack {
            Theme.bg
            if let imageURL {
                AmbientPosterImage(urlString: imageURL, cacheKey: cacheKey)
                    .blur(radius: 60)
                    .opacity(intensity)
                    .saturation(1.2)
            }
            LinearGradient(colors: [Theme.scrim, Theme.bg.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// Ambient glow image: a 240 px downsampled PosterCache decode
/// instead of the grid's 480 px — this image only ever shows blurred
/// at radius 60, so anything larger was pure decode cost and memory.
/// Shares the poster disk cache, so the detail cover is fetched once.
private struct AmbientPosterImage: View {
    let urlString: String
    var cacheKey: String? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: urlString) {
            image = await PosterCache.shared.load(urlString, maxPixelSize: 240, cacheKey: cacheKey)
        }
    }
}

/// Frosted glass card container used by every list/section in the app.
/// GlassCard carries no drop shadow (the material + hairline already
/// separate it); `shadow` exists for one-off callers that want the
/// GlassPanel depth without switching containers.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var shadow: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
            .shadow(color: shadow ? .black.opacity(0.25) : .clear, radius: shadow ? 12 : 0, x: 0, y: shadow ? 6 : 0)
    }
}

/// Rex-grade glass panel: the GlassCard layout contract (padding +
/// content) on the richer glass recipe — tint wash, gradient rim
/// light, soft deep shadow. Prefer this over GlassCard for surfaces
/// that should read as real frosted glass. `shadow` defaults on;
/// dense repeated rows pass false — a drop shadow per card forces an
/// offscreen pass per cell while scrolling.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = Theme.cardRadius
    var shadow: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassPanel(cornerRadius: cornerRadius, shadow: shadow)
    }
}

extension View {
    /// The shared Rex glass recipe on any insettable shape:
    /// ultra-thin material at the back, a white 0.07 tint wash above
    /// it, a 1pt gradient edge stroke (bright at the top, fading
    /// down), and a soft black drop shadow. Pass shadow: false for
    /// dense repeated rows — the shadow is the per-cell offscreen
    /// pass that makes long lists drop frames.
    func glassSurface<S: InsettableShape>(_ shape: S, shadow: Bool = true) -> some View {
        self
            .background(Color.white.opacity(0.07), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
            .shadow(color: shadow ? .black.opacity(0.25) : .clear, radius: shadow ? 12 : 0, x: 0, y: shadow ? 6 : 0)
    }

    /// Glass panel surface (rounded rect, 20pt corners by default).
    func glassPanel(cornerRadius: CGFloat = Theme.cardRadius, shadow: Bool = true) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), shadow: shadow)
    }

    /// Glass capsule surface (floating bars, chips, pills).
    func glassCapsule() -> some View {
        glassSurface(Capsule())
    }

    /// Glass circle surface (round floating buttons).
    func glassCircle() -> some View {
        glassSurface(Circle())
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous))
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
    /// Content type (CMS `type_name` / `vod_class`, e.g. 电影/电视剧):
    /// empty when the source sends none — the search filter only
    /// offers types the result set actually carries. (v2.09)
    var typeName: String = ""
}

/// Five stars for a 0–10 score (v2.12, shared): the same fill
/// rule DetailView.starBar has used since v1.78 — each star fills
/// by clamp(score/2 − index, 0, 1) — so Emby and module detail
/// pages show the identical star bar instead of each inventing one.
struct StarBarView: View {
    var value: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                let fill = min(max(value / 2 - Double(i), 0), 1)
                ZStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.white.opacity(0.25))
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: 13 * fill, height: 13)
                        }
                }
                .font(.system(size: 13))
                .frame(width: 13, height: 13)
            }
        }
    }
}

/// Expandable glass 媒体信息卡 (v2.12, shared): the DetailView
/// v1.78 card, factored out so Emby and module detail pages match
/// its spec — header with chevron, label column 64pt, only the
/// rows the caller passes (empty fields are the caller's job to
/// drop, never invented); hidden entirely when rows is empty.
struct MediaInfoCard: View {
    var rows: [(label: String, value: String)]
    @State private var expanded = false

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    Haptics.selection()
                    withAnimation(Theme.animQuick) { expanded.toggle() }
                } label: {
                    HStack {
                        Text("媒体信息").font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.label) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Text(row.label)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textDim)
                                    .frame(width: 64, alignment: .leading)
                                Text(row.value)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.text.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 7)
                            if row.label != rows.last?.label {
                                Divider().background(Theme.glassStroke)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.cardTint, in: RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous))
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.innerCardRadius, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
    }
}

/// 演职员横滑行 (v2.12, shared): "演职员" header plus one chip
/// per person — initial-letter circle, name, role. DetailView
/// keeps its own photo version (v1.41); Emby and module detail
/// pages have no portrait URLs, so initials stand in — same
/// header, same spacing, same glass language.
struct CastRowView: View {
    // v2.27: avatar added (Rex guide peoples: {id, title,
    // avatar, role}). Callers without avatars pass "" and
    // get the old initial-letter circle.
    var people: [(name: String, role: String, avatar: String)]

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("演职员").font(.headline).foregroundStyle(Theme.text)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(people.enumerated()), id: \.offset) { pair in
                            let person = pair.element
                            VStack(spacing: 5) {
                                if person.avatar.isEmpty {
                                    Text(String(person.name.prefix(1)))
                                        .font(.headline)
                                        .foregroundStyle(Theme.text)
                                        .frame(width: 58, height: 58)
                                        .background(Circle().fill(Theme.glass))
                                        .clipShape(Circle())
                                } else {
                                    PosterImage(urlString: person.avatar, pixelSize: 120)
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 58, height: 58)
                                        .background(Circle().fill(Theme.glass))
                                        .clipShape(Circle())
                                }
                                Text(person.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                if !person.role.isEmpty {
                                    Text(person.role)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 64)
                        }
                    }
                }
            }
        }
    }
}
