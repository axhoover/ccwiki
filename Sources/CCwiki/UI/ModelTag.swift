import SwiftUI

/// A model a derivation step or fact uses: "quantum setting", "random oracle
/// model", "stub".
///
/// One chip for the explorer and the inspector alike (`SWIFTUI-RULES.md`
/// §5.4). Neutral, on a quaternary fill: a model is a caveat, not an error,
/// so it is never orange. The words carry the meaning, never the colour, and
/// VoiceOver reads it as what it says about the claim.
struct ModelTag: View {
    let model: String

    var body: some View {
        Text(DerivationWording.modelName(model))
            .font(Theme.Fonts.badge)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.badgePaddingHorizontal)
            .padding(.vertical, Theme.badgePaddingVertical)
            .background(.quaternary, in: .rect(cornerRadius: Theme.badgeCornerRadius))
            .fixedSize()
            .accessibilityLabel(DerivationWording.modelAccessibility(model))
    }
}

/// "3 steps", "given", "recorded": a row's trailing capsule, in the badge
/// metrics, `fixedSize` so it never compresses (`SWIFTUI-RULES.md` §2.2).
struct StepBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Fonts.badge)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.badgePaddingHorizontal)
            .padding(.vertical, Theme.badgePaddingVertical)
            .background(.quaternary, in: .rect(cornerRadius: Theme.badgeCornerRadius))
            .fixedSize()
    }
}
