import Foundation

/// Where the paper behind a reference page can be fetched from, best first
/// (plans/reader-comforts.md §2.3).
///
/// Pure: it reads only the page. The reference's own links are the only
/// candidates: `source:`, then the inline BibTeX's `eprint`, `url` and `doi`
/// where they name a different URL. There is no third-party lookup, so a
/// reference that cites only a publisher's landing page may have nothing
/// CCwiki can download, and the reader drops in their own copy instead.
///
/// The links are read with `IngestSubmission.Source.parse`, which already
/// knows every shape of ePrint, arXiv, ECCC and DOI link the wiki uses.
struct PaperSource: Equatable, Sendable {

    enum Kind: String, Sendable {
        /// IACR ePrint's full text, `/YYYY/NNN.pdf`.
        case eprint
        /// arXiv's full text, `/pdf/<id>`.
        case arXiv
        /// ECCC's full text, `/report/Y/N/download/`.
        case eccc
        /// A link that names a PDF itself.
        case pdf
        /// A page about the paper, which may name its PDF in a
        /// `citation_pdf_url` tag: a DOI, a publisher, a search.
        case landingPage
    }

    struct Candidate: Equatable, Sendable {
        let url: URL
        let kind: Kind
    }

    /// The reference page's path, which the wiki promises never to rename:
    /// the paper's identity in the library.
    let referencePath: String
    /// The citation key, the page's `title`: `BGI15`, `FGJ+25`.
    let key: String
    /// `source:` as written.
    let sourceURL: URL?
    /// Best first, every one https. Empty: nothing CCwiki can fetch.
    let candidates: [Candidate]
    /// `BGI15.pdf`: the key, made safe for a file name. `PaperStore` makes it
    /// unique among the papers kept.
    let fileName: String

    init(page: WikiPage) {
        referencePath = page.path
        key = page.title
        sourceURL = page.source.flatMap { URL(string: $0) }
        fileName = Self.fileName(forKey: page.title)

        var links: [String] = []
        if let source = page.source { links.append(source) }
        if let bibtex = page.frontmatter.raw("bibtex") {
            if let eprint = Self.bibTeXField("eprint", in: bibtex),
               let link = Self.eprintLink(
                eprint, archivePrefix: Self.bibTeXField("archivePrefix", in: bibtex)
                    ?? Self.bibTeXField("eprinttype", in: bibtex)) {
                links.append(link)
            }
            if let url = Self.bibTeXField("url", in: bibtex) { links.append(url) }
            if let doi = Self.bibTeXField("doi", in: bibtex) { links.append(doi) }
        }

        var seen: Set<String> = []
        candidates = links
            .flatMap { Self.candidates(for: $0) }
            .filter { seen.insert($0.url.absoluteString).inserted }
    }

    /// What one link offers: its full text for ePrint, arXiv and ECCC; the
    /// link itself when it names a PDF; otherwise the page it points at.
    /// Anything that is not an http(s) link offers nothing.
    static func candidates(for link: String) -> [Candidate] {
        guard let parsed = IngestSubmission.Source.parse(link) else { return [] }
        let candidate: Candidate?
        switch parsed {
        case .eprint:
            candidate = parsed.fullTextURL.flatMap { make($0, .eprint) }
        case .arXiv:
            candidate = parsed.fullTextURL.flatMap { make($0, .arXiv) }
        case .eccc:
            candidate = parsed.fullTextURL.flatMap { make($0, .eccc) }
        case .doi:
            candidate = make(parsed.canonicalURL, .landingPage)
        case .other(let raw):
            guard let url = URL(string: raw) else { return [] }
            let isPDF = url.path(percentEncoded: false).lowercased().hasSuffix(".pdf")
            candidate = make(raw, isPDF ? .pdf : .landingPage)
        }
        return candidate.map { [$0] } ?? []
    }

    /// An http(s) URL, made https: Info.plist declares no App Transport
    /// Security exception, so a plain-HTTP request would be refused.
    private static func make(_ string: String, _ kind: Kind) -> Candidate? {
        guard let url = URL(string: string).flatMap(secure) else { return nil }
        return Candidate(url: url, kind: kind)
    }

    /// `url` with an `https` scheme, or nil when it is not an http(s) URL.
    static func secure(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() ?? "" {
        case "https":
            return url
        case "http":
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            else { return nil }
            components.scheme = "https"
            return components.url
        default:
            return nil
        }
    }

    // MARK: File name

    /// The key with anything outside `[A-Za-z0-9+._-]` replaced by `-`, then
    /// `.pdf`. A leading dot would hide the file in Finder, so it goes too.
    static func fileName(forKey key: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+._-")
        var stem = String(key.trimmingCharacters(in: .whitespacesAndNewlines)
            .map { allowed.contains($0) ? $0 : "-" })
        if stem.hasPrefix(".") { stem = "-" + stem.dropFirst() }
        return (stem.isEmpty ? "paper" : stem) + ".pdf"
    }

    // MARK: BibTeX

    /// The value of one field of a BibTeX entry: `{…}` with nested braces,
    /// `"…"`, or a bare word. Nil when the field is absent or empty.
    static func bibTeXField(_ name: String, in entry: String) -> String? {
        let pattern = "(^|[,{\\s])" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*"
        guard let match = entry.range(
            of: pattern, options: [.regularExpression, .caseInsensitive])
        else { return nil }

        let rest = entry[match.upperBound...]
        guard let opening = rest.first else { return nil }
        var value = ""
        switch opening {
        case "{":
            var depth = 0
            for character in rest {
                if character == "{" {
                    depth += 1
                    if depth == 1 { continue }
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                value.append(character)
            }
        case "\"":
            value = String(rest.dropFirst().prefix { $0 != "\"" })
        default:
            value = String(rest.prefix { $0 != "," && $0 != "}" && !$0.isNewline })
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A BibTeX `eprint` as a link `IngestSubmission.Source.parse` reads:
    /// arXiv's ids (`2001.04383`, `quant-ph/0604056`) and ePrint's
    /// (`2006/165`), named by `archivePrefix` or recognised by their shape.
    static func eprintLink(_ value: String, archivePrefix: String?) -> String? {
        if value.contains("://") { return value }
        let prefix = archivePrefix?.lowercased() ?? ""
        let isArXivID = value.range(
            of: #"^(\d{4}\.\d{4,5}|[a-z-]+(\.[a-z]{2})?/\d{7})(v\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let isEPrintID = value.range(of: #"^\d{4}/\d{1,5}$"#, options: .regularExpression) != nil

        if prefix == "arxiv" || (prefix.isEmpty && isArXivID) { return "arXiv:" + value }
        if prefix.contains("iacr") || prefix.contains("eprint") || (prefix.isEmpty && isEPrintID) {
            return "https://eprint.iacr.org/" + value
        }
        return nil
    }
}
