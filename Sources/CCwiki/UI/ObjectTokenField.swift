import SwiftUI

/// The explorer's two question fields.
enum ExplorerField: Hashable {
    case from, to
}

/// A token field built from SwiftUI: the chosen objects as tokens, then a
/// plain text field to type the next one (relations-explorer.md §2.3).
///
/// Not `NSTokenField`: its completion menu is one line of text, with no room
/// for a node's type, its host page, or why a complexity class is not
/// offered. The suggestions are not here at all: they replace the explorer's
/// results while you type, palette-style, so nothing floats over the list.
/// This view only shows tokens and takes text; the explorer owns the keys.
///
/// From is one conjunction, so its tokens are joined by `∧`, and the field
/// reads to VoiceOver as "From, all of:" with each token a button that can be
/// removed.
struct ObjectTokenField: View {

    struct Token: Identifiable, Hashable {
        let id: String
        let label: String
        /// A section of a page, marked as the inspector marks one.
        let isVariant: Bool
        /// Its id left the manifest after a sync: shown struck through, and
        /// left out of the question.
        let isStale: Bool
    }

    let field: ExplorerField
    let tokens: [Token]
    @Binding var text: String
    let placeholder: String
    let accessibilityName: String
    /// From joins its tokens with `∧`; To has one.
    let isConjunction: Bool
    let selectedTokenID: String?
    var focus: FocusState<ExplorerField?>.Binding
    let onSelect: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        let layout = TokenFlowLayout(
            spacing: Theme.tokenSpacing, minFillWidth: Theme.tokenFieldMinTextWidth)
        layout {
            ForEach(Array(tokens.enumerated()), id: \.element.id) { position, token in
                if isConjunction && position > 0 {
                    Text(verbatim: DerivationWording.conjunction)
                        .font(Theme.Fonts.row)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                TokenView(
                    token: token,
                    isSelected: token.id == selectedTokenID,
                    accessibilityLabel: tokenAccessibilityLabel(token, at: position),
                    onSelect: { onSelect(token.id) },
                    onRemove: { onRemove(token.id) })
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.row)
                .focused(focus, equals: field)
                .layoutValue(key: TokenFlowFill.self, value: true)
        }
        .padding(Theme.tokenFieldPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A click on the box outside a token puts the caret in it, as in
            // Mail. On the background, so it never competes with the text
            // field's own clicks and drags.
            RoundedRectangle(cornerRadius: Theme.tokenFieldCornerRadius)
                .fill(.background)
                .onTapGesture { focus.wrappedValue = field }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.tokenFieldCornerRadius)
                .strokeBorder(.separator)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }

    /// "Hash function § Preimage resistance, premise 1 of 2".
    private func tokenAccessibilityLabel(_ token: Token, at position: Int) -> String {
        var label = token.label
        if isConjunction && tokens.count > 1 {
            label += ", premise \(position + 1) of \(tokens.count)"
        }
        if token.isStale { label += ", not in the wiki any more" }
        return label
    }
}

/// One chosen object.
private struct TokenView: View {
    let token: ObjectTokenField.Token
    let isSelected: Bool
    let accessibilityLabel: String
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            if token.isVariant {
                Image(systemName: "number")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(token.label)
                .font(Theme.Fonts.row)
                .strikethrough(token.isStale)
                .foregroundStyle(token.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            // Faded in on hover and never inserted, so the token keeps its
            // width as the pointer crosses it (SWIFTUI-RULES §4.5).
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help("Remove")
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.tokenPaddingHorizontal)
        .padding(.vertical, Theme.tokenPaddingVertical)
        .frame(maxWidth: Theme.tokenMaxWidth, alignment: .leading)
        .background(background, in: .rect(cornerRadius: Theme.tokenCornerRadius))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(token.isStale ? "Not in the wiki any more" : token.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Remove", onRemove)
    }

    /// Selected over resting, the same hue at two strengths.
    private var background: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.tint.opacity(0.12))
    }
}

// MARK: - Layout

/// Marks the subview that fills the rest of its line: the text field.
struct TokenFlowFill: LayoutValueKey {
    static let defaultValue = false
}

/// Tokens left to right, wrapping, with the typing area taking whatever is
/// left of the last line, or a line of its own when that is too narrow.
struct TokenFlowLayout: Layout {
    var spacing: CGFloat
    var minFillWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let arrangement = arrange(width: width, subviews: subviews)
        return arrangement.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for item in arrangement.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height))
        }
    }

    private struct Item {
        let index: Int
        var frame: CGRect
    }

    /// Lines of items, each vertically centred in its line.
    private func arrange(width: CGFloat, subviews: Subviews) -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        func finishLine() {
            // Centre each item of the finished line in the line's height.
            for position in lineStart..<items.count {
                let offset = (lineHeight - items[position].frame.height) / 2
                items[position].frame.origin.y = y + max(0, offset)
            }
            widest = max(widest, x - spacing)
            y += lineHeight + spacing
            x = 0
            lineHeight = 0
            lineStart = items.count
        }

        for index in subviews.indices {
            let subview = subviews[index]
            let fills = subview[TokenFlowFill.self]
            var size: CGSize
            if fills {
                // The rest of the line, or a line of its own.
                var available = width.isFinite ? width - x : minFillWidth
                if available < minFillWidth, x > 0 {
                    finishLine()
                    available = width.isFinite ? width : minFillWidth
                }
                let fitted = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
                size = CGSize(width: max(available, 0), height: fitted.height)
            } else {
                let ideal = subview.sizeThatFits(.unspecified)
                size = CGSize(width: width.isFinite ? min(ideal.width, width) : ideal.width,
                              height: ideal.height)
                if x > 0, width.isFinite, x + size.width > width {
                    finishLine()
                }
            }
            items.append(Item(index: index, frame: CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        if lineStart < items.count { finishLine() }

        let height = max(0, y - spacing)
        let totalWidth = width.isFinite ? width : widest
        return (items: items, size: CGSize(width: totalWidth, height: height))
    }
}
