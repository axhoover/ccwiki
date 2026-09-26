import Foundation

/// What the user handed CCwiki to ingest.
///
/// Either a paper the agent can fetch itself, or a PDF sitting on disk. PDFs
/// are copied into `…/CCwiki/library/` — deliberately *outside* the clone,
/// because a PDF must never enter the repo; the References page it produces
/// points at eprint, arXiv or a DOI instead.
struct IngestSubmission: Sendable, Equatable, Codable {

    enum Kind: String, Sendable, Codable {
        case url
        case pdf
    }

    /// The preprint servers the wiki actually cites, in the `source`
    /// preference order the repo's lint documents.
    enum Source: Sendable, Equatable, Codable {
        case eprint(year: String, number: String)
        case arXiv(id: String)
        case doi(String)
        case eccc(year: String, number: String)
        case other(String)

        /// The canonical landing page, which becomes the page's `source:`.
        var canonicalURL: String {
            switch self {
            case .eprint(let year, let number): "https://eprint.iacr.org/\(year)/\(number)"
            case .arXiv(let id): "https://arxiv.org/abs/\(id)"
            case .doi(let doi): "https://doi.org/\(doi)"
            case .eccc(let year, let number):
                "https://eccc.weizmann.ac.il/report/\(year)/\(number)/"
            case .other(let url): url
            }
        }

        /// Where the full text lives, when that differs from the landing page.
        /// The agent is told both, because a landing page is usually the better
        /// citation and the PDF is usually the better read.
        var fullTextURL: String? {
            switch self {
            case .eprint(let year, let number): "https://eprint.iacr.org/\(year)/\(number).pdf"
            case .arXiv(let id): "https://arxiv.org/pdf/\(id)"
            case .eccc(let year, let number):
                "https://eccc.weizmann.ac.il/report/\(year)/\(number)/download/"
            case .doi, .other: nil
            }
        }

        var label: String {
            switch self {
            case .eprint: "IACR ePrint"
            case .arXiv: "arXiv"
            case .doi: "DOI"
            case .eccc: "ECCC"
            case .other: "Web"
            }
        }
    }

    var kind: Kind
    /// The canonical URL for a `url` submission; for a PDF, the `source_url` the
    /// user supplied alongside it, if any.
    var source: Source?
    /// Where a dropped PDF was copied to.
    var localPDF: URL?
    var notes: String
    var submittedAt: Date

    var displayName: String {
        if let localPDF { return localPDF.lastPathComponent }
        return source?.canonicalURL ?? "Untitled submission"
    }

    /// A short, filesystem- and branch-safe stem for the worktree and branch.
    var slug: String {
        let base: String
        switch source {
        case .eprint(let year, let number): base = "eprint-\(year)-\(number)"
        case .arXiv(let id): base = "arxiv-\(id)"
        case .eccc(let year, let number): base = "eccc-\(year)-\(number)"
        case .doi(let doi): base = "doi-\(doi)"
        case .other, nil:
            base = localPDF?.deletingPathExtension().lastPathComponent ?? "paper"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let cleaned = base.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { result, character in
                // Collapse runs, so `10.1145/800061.808726` does not become a
                // branch name full of empty segments.
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
        return String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
    }

    /// The JSON block the prompt carries, matching the shape the wiki's own
    /// `paper_submission` workflow already accepts.
    func metadataJSON() -> String {
        var paper: [String: Any] = ["type": kind.rawValue]
        if let source {
            paper["url"] = source.fullTextURL ?? source.canonicalURL
            paper["source_url"] = source.canonicalURL
        }
        if let localPDF { paper["path"] = localPDF.path(percentEncoded: false) }

        let payload: [String: Any] = [
            "paper": paper,
            "notes": notes,
            "submitted_at": ISO8601DateFormatter().string(from: submittedAt),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

extension IngestSubmission.Source {

    /// Recognize a pasted URL.
    ///
    /// Accepts the shapes people actually paste, including bare hostnames, the
    /// `.pdf` variants, and `ia.cr` short links. Anything else that parses as a
    /// URL becomes `.other` rather than being rejected — the agent can still
    /// fetch it, and refusing a valid link because it is not one of four known
    /// hosts would be obnoxious.
    static func parse(_ raw: String) -> IngestSubmission.Source? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // `doi:10.1145/…` and a bare `10.1145/…` are both common.
        if text.lowercased().hasPrefix("doi:") {
            let doi = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return doi.isEmpty ? nil : .doi(doi)
        }
        if text.hasPrefix("10."), text.contains("/") {
            return .doi(text)
        }
        // `arXiv:2401.12345`
        if text.lowercased().hasPrefix("arxiv:") {
            let id = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : .arXiv(id: id)
        }

        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host()?.lowercased() else { return nil }

        var segments = url.path(percentEncoded: false)
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }

        func stripPDFSuffix(_ value: String) -> String {
            value.hasSuffix(".pdf") ? String(value.dropLast(4)) : value
        }

        switch host {
        case "eprint.iacr.org", "www.eprint.iacr.org", "ia.cr", "www.ia.cr":
            // /2025/375, /2025/375.pdf, /archive/2005/187
            if segments.first == "archive" { segments.removeFirst() }
            guard segments.count >= 2 else { return .other(url.absoluteString) }
            let year = segments[0]
            let number = stripPDFSuffix(segments[1])
            guard year.count == 4, Int(year) != nil, Int(number) != nil else {
                return .other(url.absoluteString)
            }
            return .eprint(year: year, number: number)

        case "arxiv.org", "www.arxiv.org", "export.arxiv.org":
            // /abs/2401.12345, /pdf/2401.12345v2, /abs/math/0309136
            guard let first = segments.first,
                  ["abs", "pdf", "html", "format"].contains(first),
                  segments.count >= 2
            else { return .other(url.absoluteString) }
            let id = stripPDFSuffix(segments.dropFirst().joined(separator: "/"))
            return id.isEmpty ? .other(url.absoluteString) : .arXiv(id: id)

        case "doi.org", "dx.doi.org", "www.doi.org":
            let doi = segments.joined(separator: "/")
            return doi.isEmpty ? .other(url.absoluteString) : .doi(doi)

        case "eccc.weizmann.ac.il", "www.eccc.weizmann.ac.il":
            // /report/2023/001/
            guard segments.first == "report", segments.count >= 3 else {
                return .other(url.absoluteString)
            }
            return .eccc(year: segments[1], number: segments[2])

        default:
            guard url.scheme == "http" || url.scheme == "https" else { return nil }
            return .other(url.absoluteString)
        }
    }
}
