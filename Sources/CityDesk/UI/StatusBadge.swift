import SwiftUI

/// A small tinted capsule for a page's editorial status.
///
/// One component, reused in the sidebar, the search results and the reader's
/// title bar, so a tint or shape change lands once. The color carries meaning,
/// so it is named for VoiceOver rather than relying on hue alone.
struct StatusBadge: View {
    let status: PageStatus
    var compact = false

    var body: some View {
        Group {
            if compact {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 1)
            } else {
                Text(status.label)
                    .font(Theme.Fonts.badge)
                    .foregroundStyle(tint)
                    .padding(.horizontal, Theme.badgePaddingHorizontal)
                    .padding(.vertical, Theme.badgePaddingVertical)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: Theme.badgeCornerRadius))
            }
        }
        .accessibilityLabel("Status: \(status.label)")
        .help(status.explanation)
    }

    private var tint: Color {
        switch status {
        case .stub: .orange
        case .draft: .blue
        case .complete: .green
        }
    }
}

extension PageStatus {
    /// The repo's own definitions, from `CONTRIBUTING.md`.
    var explanation: String {
        switch self {
        case .stub: "Skeletal, or missing the sections its type requires."
        case .draft: "The default working state."
        case .complete: "A human judgement: no TODOs, and every required section present."
        }
    }
}

/// The page-kind glyph shown beside a title.
struct KindIcon: View {
    let kind: PageKind

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityLabel(kind.rawValue)
    }
}
