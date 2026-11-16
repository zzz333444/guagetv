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
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .background(Theme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .redacted(reason: .placeholder)
    }
}

/// Glass placeholder for the 520pt Discover hero while TMDB is
/// still loading and no feed art has landed yet.
struct SkeletonHero: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Theme.glass)
            .frame(height: 520)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 180, height: 22)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 240, height: 13)
                }
                .padding(20)
            }
            .redacted(reason: .placeholder)
    }
}
