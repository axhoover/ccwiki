import Foundation

/// What a successful answer to a paper request turned out to be
/// (plans/reader-comforts.md §2.4). Pure.
///
/// The body decides, not the label: plenty of servers send a PDF as
/// `application/octet-stream`, and some send a bot check as `200 OK`.
enum PaperResponse: Equatable, Sendable {
    /// The body starts with `%PDF-` within its first 1,024 bytes, as the PDF
    /// format allows.
    case pdf
    /// A web page, and the PDF it names, if it names one.
    case html(pdfLink: URL?)
    /// Anything else: PostScript, an archive, a file nobody labelled.
    case other(contentType: String?)

    /// - Parameters:
    ///   - prefix: the start of the body; only the first 1,024 bytes count.
    ///   - contentType: the response's media type, without parameters.
    ///   - finalURL: where the body came from, after redirects, to resolve a
    ///     relative link against.
    ///   - html: the body as text, read only when it is a web page.
    static func classify(
        prefix: Data, contentType: String?, finalURL: URL, html: () -> String?
    ) -> PaperResponse {
        let head = prefix.prefix(1024)
        if head.range(of: Data("%PDF-".utf8)) != nil { return .pdf }

        let type = contentType?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let labelledHTML = type == "text/html" || type == "application/xhtml+xml"
        let unlabelled = type == nil || type == "application/octet-stream" || type == "text/plain"
        guard labelledHTML || (unlabelled && looksLikeHTML(head)) else {
            return .other(contentType: type)
        }
        return .html(pdfLink: html().flatMap { citationPDFURL(inHTML: $0, baseURL: finalURL) })
    }

    /// The PDF a landing page names: `<meta name="citation_pdf_url"
    /// content="…">` (the Highwire tag most publishers emit), in either
    /// attribute order, else `<link rel="alternate" type="application/pdf"
    /// href="…">`. Resolved against `baseURL`; http(s) only, so a
    /// `javascript:` or `data:` link is never followed.
    static func citationPDFURL(inHTML html: String, baseURL: URL) -> URL? {
        var alternate: URL?
        for tag in tags(in: html) {
            let attributes = tag.attributes
            if tag.name == "meta" {
                let name = (attributes["name"] ?? attributes["property"])?.lowercased()
                if name == "citation_pdf_url",
                   let content = attributes["content"],
                   let url = resolve(content, against: baseURL) {
                    return url
                }
            } else if alternate == nil {
                let relations = attributes["rel"]?.lowercased()
                    .split(whereSeparator: \.isWhitespace) ?? []
                if relations.contains("alternate"),
                   attributes["type"]?.lowercased() == "application/pdf",
                   let href = attributes["href"] {
                    alternate = resolve(href, against: baseURL)
                }
            }
        }
        return alternate
    }

    // MARK: Reading HTML

    private static func looksLikeHTML(_ head: Data) -> Bool {
        let text = String(decoding: head, as: UTF8.self).lowercased()
        return text.contains("<!doctype html") || text.contains("<html") || text.contains("<head")
    }

    private struct Tag {
        let name: String
        let attributes: [String: String]
    }

    /// Every `<meta>` and `<link>` tag, with its attributes by lowercased
    /// name. The first of a repeated attribute wins, as in a browser.
    private static func tags(in html: String) -> [Tag] {
        guard let tagPattern = try? NSRegularExpression(
                pattern: #"<(meta|link)\b([^>]*)>"#, options: [.caseInsensitive]),
              let attributePattern = try? NSRegularExpression(
                pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
        else { return [] }

        let whole = NSRange(html.startIndex..., in: html)
        return tagPattern.matches(in: html, range: whole).compactMap { match -> Tag? in
            guard let nameRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html)
            else { return nil }
            let body = String(html[bodyRange])
            var attributes: [String: String] = [:]
            let all = NSRange(body.startIndex..., in: body)
            for attribute in attributePattern.matches(in: body, range: all) {
                guard let keyRange = Range(attribute.range(at: 1), in: body) else { continue }
                let value = (2...4).lazy
                    .compactMap { Range(attribute.range(at: $0), in: body) }
                    .first.map { String(body[$0]) } ?? ""
                let key = body[keyRange].lowercased()
                if attributes[key] == nil { attributes[key] = decodeEntities(value) }
            }
            return Tag(name: html[nameRange].lowercased(), attributes: attributes)
        }
    }

    /// The character references that turn up in URLs in attribute values.
    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&#x2F;", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&#x3A;", with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: "&#58;", with: ":")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func resolve(_ value: String, against base: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
