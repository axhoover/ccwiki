import Foundation
import Testing
@testable import CCwiki

struct PaperResponseTests {

    private let landing = URL(string: "https://link.springer.com/chapter/10.1007/abc")!

    private func classify(_ body: String, type: String?) -> PaperResponse {
        let data = Data(body.utf8)
        return PaperResponse.classify(
            prefix: data, contentType: type, finalURL: landing,
            html: { String(decoding: data, as: UTF8.self) })
    }

    @Test("a body that starts with %PDF- is a PDF, whatever its label")
    func pdfMagic() {
        #expect(classify("%PDF-1.7\n…", type: "application/pdf") == .pdf)
        #expect(classify("%PDF-1.4\n…", type: "application/octet-stream") == .pdf)
        #expect(classify("%PDF-1.4\n…", type: nil) == .pdf)
        // Within the first 1,024 bytes, as the format allows; not after.
        #expect(classify(String(repeating: " ", count: 100) + "%PDF-1.4", type: nil) == .pdf)
        #expect(classify(String(repeating: " ", count: 1024) + "%PDF-1.4", type: nil)
            == .other(contentType: nil))
    }

    @Test("a landing page's citation_pdf_url is found in either attribute order")
    func citationMeta() {
        let pdf = URL(string: "https://link.springer.com/content/pdf/10.1007/abc.pdf")!
        let nameFirst = #"<html><head><meta name="citation_pdf_url" content="https://link.springer.com/content/pdf/10.1007/abc.pdf"></head></html>"#
        let contentFirst = #"<html><head><META CONTENT='https://link.springer.com/content/pdf/10.1007/abc.pdf' NAME='citation_pdf_url' /></head></html>"#
        #expect(classify(nameFirst, type: "text/html; charset=utf-8") == .html(pdfLink: pdf))
        #expect(classify(contentFirst, type: "text/html") == .html(pdfLink: pdf))
    }

    @Test("a relative link is resolved against the page it was on")
    func relativeLinks() {
        let relative = #"<meta name="citation_pdf_url" content="/content/pdf/10.1007/abc.pdf">"#
        #expect(PaperResponse.citationPDFURL(inHTML: relative, baseURL: landing)
            == URL(string: "https://link.springer.com/content/pdf/10.1007/abc.pdf"))

        let entities = #"<meta name="citation_pdf_url" content="https://example.org/get?id=1&amp;format=pdf">"#
        #expect(PaperResponse.citationPDFURL(inHTML: entities, baseURL: landing)
            == URL(string: "https://example.org/get?id=1&format=pdf"))
    }

    @Test("a PDF alternate link counts when there is no citation_pdf_url")
    func alternateLink() {
        let html = #"""
            <link rel="stylesheet" href="/site.css">
            <link rel="alternate" type="application/pdf" href="paper.pdf">
            """#
        #expect(PaperResponse.citationPDFURL(inHTML: html, baseURL: landing)
            == URL(string: "https://link.springer.com/chapter/10.1007/paper.pdf"))

        let both = #"""
            <link rel="alternate" type="application/pdf" href="/alternate.pdf">
            <meta name="citation_pdf_url" content="/meta.pdf">
            """#
        #expect(PaperResponse.citationPDFURL(inHTML: both, baseURL: landing)
            == URL(string: "https://link.springer.com/meta.pdf"), "the citation tag wins")
    }

    @Test("javascript: and data: links are never followed")
    func refusedSchemes() {
        for link in ["javascript:alert(1)", "data:application/pdf;base64,JVBERi0=",
                     "file:///etc/passwd", "   "] {
            let html = "<meta name=\"citation_pdf_url\" content=\"\(link)\">"
            #expect(PaperResponse.citationPDFURL(inHTML: html, baseURL: landing) == nil, "\(link)")
        }
    }

    @Test("a web page without a PDF link, and an unlabelled one, are HTML with no link")
    func htmlWithoutLink() {
        #expect(classify("<!DOCTYPE html><html><title>Sign in</title></html>", type: "text/html")
            == .html(pdfLink: nil))
        #expect(classify("<!doctype html><html></html>", type: nil) == .html(pdfLink: nil))
        #expect(classify("<html><body>Just a moment…</body></html>", type: "application/octet-stream")
            == .html(pdfLink: nil))
    }

    @Test("PostScript and other files are neither a PDF nor a page")
    func otherFiles() {
        #expect(classify("%!PS-Adobe-3.0\n", type: "application/postscript")
            == .other(contentType: "application/postscript"))
        #expect(classify("PK\u{3}\u{4}", type: "application/zip") == .other(contentType: "application/zip"))
        #expect(classify("garbage", type: "application/octet-stream")
            == .other(contentType: "application/octet-stream"))
        #expect(classify("garbage", type: nil) == .other(contentType: nil))
    }
}
