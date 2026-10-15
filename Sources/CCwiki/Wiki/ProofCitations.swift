import Foundation

/// The works a proof cites, resolved to their reference pages, so a copy can
/// `\cite` each by a key a paper's bibliography has (plans/relations-followups.md
/// §3.3).
///
/// A reduction's `source` is the token `folklore` or the wiki's own
/// wikilinks to reference pages. Each wikilink is resolved as the reader
/// resolves it, from the reduction's page, and the page's frontmatter gives
/// what a bibliography needs: `cryptobib_key` for the works in CryptoBib, or
/// the inline `bibtex` entry for the rest, read as `ReaderView`'s reference
/// bar reads them. With no index loaded, nothing resolves, and every key
/// falls back to the wiki's own.
struct ProofCitations: Sendable {

    /// One `source` entry, with what its reference page says.
    struct Citation: Sendable, Hashable {
        /// The entry as recorded: `[[GGM86 - …|GGM86]]`, or `folklore`. A
        /// refutation's key resolves to its page's wikilink.
        let entry: String
        /// The wiki's key: `GGM86`; `folklore`.
        let key: String
        /// `References/GGM86 - How to construct random functions.md`; `nil`
        /// when the entry does not resolve.
        let referencePath: String?
        let cryptobibKey: String?
        /// The page's inline entry, verbatim.
        let bibtex: String?

        static let folklore = "folklore"

        /// The wiki has no attribution: never that none exists.
        var isFolklore: Bool { entry == Self.folklore }

        /// The inline entry's own key, read from `@type{KEY,`: not always the
        /// wiki's (KR03's entry is `KemReg03`).
        var inlineKey: String? { bibtex.flatMap(ProofCitations.entryKey) }

        /// The key to `\cite`, in order of preference: CryptoBib's, the
        /// inline entry's, the wiki's. `nil` for folklore, which has none.
        var texKey: String? {
            guard !isFolklore else { return nil }
            return cryptobibKey ?? inlineKey ?? key
        }

        /// The work's entry for Copy BibTeX of Cited Works: an inline entry
        /// of a work that is not in CryptoBib. A work in CryptoBib is listed
        /// by key instead, so an entry never clashes with the real one in a
        /// paper that loads `crypto.bib`.
        var inlineEntry: String? { cryptobibKey == nil ? bibtex : nil }

        /// `\cite` falls back to the wiki's key, which no bibliography has:
        /// the copy says so beside the step.
        var usesWikiKey: Bool { !isFolklore && cryptobibKey == nil && inlineKey == nil }
    }

    private let index: WikiIndex?

    static let empty = ProofCitations(index: nil)

    init(index: WikiIndex?) {
        self.index = index
    }

    /// A `source` list, entry by entry, resolved from the page at
    /// `relationPath`. Empty entries are dropped.
    func citations(_ source: [String], from relationPath: String) -> [Citation] {
        source.compactMap { entry -> Citation? in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed == Citation.folklore {
                return Citation(entry: trimmed, key: trimmed, referencePath: nil,
                                cryptobibKey: nil, bibtex: nil)
            }
            let key = RelationText.citationKey(trimmed) ?? trimmed
            guard let index, let link = WikilinkParser.links(in: trimmed).first,
                  case .page(let path, _) = index.resolve(link, from: relationPath),
                  let page = index.pages[path]
            else {
                return Citation(entry: trimmed, key: key, referencePath: nil,
                                cryptobibKey: nil, bibtex: nil)
            }
            return Self.citation(entry: trimmed, key: key, page: page)
        }
    }

    /// A refutation's bare key, `CD22`: its page is the one file in
    /// `References/` named `CD22 - …`, and the entry becomes that page's
    /// wikilink. A key with no page, or with two, stays bare.
    func citation(forKey key: String) -> Citation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed + " - "
        let paths = index?.pages.keys.filter {
            $0.hasPrefix("References/") && ($0 as NSString).lastPathComponent.hasPrefix(prefix)
        } ?? []
        guard paths.count == 1, let path = paths.first, let page = index?.pages[path] else {
            return Citation(entry: trimmed, key: trimmed, referencePath: nil,
                            cryptobibKey: nil, bibtex: nil)
        }
        return Self.citation(entry: page.wikilink, key: trimmed, page: page)
    }

    /// The works a refutation cites. Its `source` is one key, or a manifest
    /// refutation's keys joined by ", ".
    func citations(of refutation: DerivationCuration.Refutation) -> [Citation] {
        refutation.source.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { citation(forKey: $0) }
    }

    private static func citation(entry: String, key: String, page: WikiPage) -> Citation {
        let bibtex = page.frontmatter.raw("bibtex")
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return Citation(entry: entry, key: key, referencePath: page.path,
                        cryptobibKey: page.frontmatter.string("cryptobib_key"), bibtex: bibtex)
    }

    /// The key of a BibTeX entry, `KemReg03` in `@Article{KemReg03, …`, or
    /// `nil` when the text does not open with an entry.
    static func entryKey(_ bibtex: String) -> String? {
        guard let at = bibtex.firstIndex(of: "@"),
              let open = bibtex[at...].firstIndex(where: { $0 == "{" || $0 == "(" })
        else { return nil }
        let type = bibtex[bibtex.index(after: at)..<open].trimmingCharacters(in: .whitespaces)
        guard !type.isEmpty, type.allSatisfy({ $0.isLetter }) else { return nil }
        let rest = bibtex[bibtex.index(after: open)...]
        guard let comma = rest.firstIndex(of: ",") else { return nil }
        let key = rest[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.contains(where: { $0.isWhitespace || "{}()\"".contains($0) })
        else { return nil }
        return key
    }
}
