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
    /// The deleted set is generated upstream from Unicode categories: letters,
    /// marks and numbers survive, along with space, `-` and `_`. Everything
    /// else — including `.` `,` `!` `?` `'` `(` `)` `/` `:` `+` `&` `$` `#`,
    /// em/en dashes and emoji — is deleted outright.
    static func slug(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(value.unicodeScalars.count)

        for scalar in value.lowercased().unicodeScalars {
            if scalar == " " {
                out.append("-")
            } else if survives(scalar) {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func survives(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "-" || scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
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
