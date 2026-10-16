import Foundation

/// A port of `github-slugger@2.0.0`, which is what Quartz uses for heading
/// anchors (`rehype-slug`) and for the anchor half of a `[[page#heading]]`
/// wikilink (`splitAnchor`).
///
/// This is a *completely different* algorithm from `QuartzSlug.sluggify` —
/// it lowercases and deletes nearly all punctuation, where the path slugifier
/// preserves case and keeps almost everything. Mixing them produces links the
/// website does not have.
///
/// The upstream implementation is three steps and nothing else:
/// ```js
/// if (!maintainCase) value = value.toLowerCase()
/// return value.replace(regex, '').replace(/ /g, '-')
/// ```
/// There is no trimming, no collapsing of repeated `-`, and no stripping of
/// leading or trailing `-` — `"  spaced  out  "` really does become
/// `"--spaced--out--"`.
struct GithubSlugger {

    /// The non-deduplicating slug, used for *link* anchors.
    ///
    /// The kept set is generated upstream from Unicode 13.0: Alphabetic
    /// scalars (letters, letter numbers like `Ⅻ`, and symbols like `Ⓐ`),
    /// marks, decimal digits and connector punctuation (`_`, `‿`) survive,
    /// along with space and `-`. Everything else — including `.` `,` `!` `?`
    /// `'` `(` `)` `/` `:` `+` `&` `$` `#`, em/en dashes, emoji, and other
    /// numbers such as `²`, `₁` and `½` — is deleted outright.
    static func slug(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)

        for (index, scalar) in scalars.enumerated() {
            // JavaScript's `toLowerCase`: Swift's `lowercased()` maps each
            // scalar the same way, except a word-final capital sigma.
            let lower = scalar == "\u{03A3}" && isFinalSigma(scalars, at: index)
                ? "\u{03C2}" : scalar.properties.lowercaseMapping
            for mapped in lower.unicodeScalars {
                if mapped == " " {
                    out.append("-")
                } else if survives(mapped) {
                    out.append(mapped)
                }
            }
        }
        return String(out)
    }

    private static func survives(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "-" { return true }
        let properties = scalar.properties
        // Assigned after the regex was generated, so not in its kept set.
        guard let age = properties.age, (age.major, age.minor) <= (13, 0) else { return false }
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .connectorPunctuation:
            return true
        default:
            return false
        }
    }

    /// Unicode's Final_Sigma condition, as ICU tests it for `toLowerCase`:
    /// a cased letter before the sigma and none after it, skipping
    /// case-ignorable scalars (`'`, `.`, combining marks) either way.
    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let before = scalars[..<index].reversed().first { !$0.properties.isCaseIgnorable }
        let after = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }
        return before?.properties.isCased == true && after?.properties.isCased != true
    }

    // MARK: - Deduplicating instance

    /// Heading `id`s are assigned by `rehype-slug`, which uses a *deduplicating*
    /// slugger reset per document: a second `## Syntax` becomes `syntax-1`, a
    /// third `syntax-2`.
    ///
    /// Note the asymmetry, which is a real Quartz limitation rather than
    /// something to fix: wikilink anchors go through the non-deduplicating
    /// `slug(_:)`, so `[[page#Syntax]]` can only ever address the *first*
    /// `## Syntax` on a page.
    private var occurrences: [String: Int] = [:]

    init() {}

    mutating func reset() { occurrences.removeAll(keepingCapacity: true) }

    mutating func slug(_ value: String) -> String {
        let original = Self.slug(value)
        var result = original
        while occurrences[result] != nil {
            occurrences[original, default: 0] += 1
            result = original + "-" + String(occurrences[original]!)
        }
        occurrences[result] = 0
        return result
    }
}
