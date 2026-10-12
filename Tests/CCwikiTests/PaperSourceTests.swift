import Foundation
import Testing
@testable import CCwiki

/// A reference page as the wiki writes one, for the paper tests.
enum PaperFixtures {

    static func reference(
        _ key: String, source: String?, bibtex: String? = nil,
        title: String = "A Paper"
    ) -> WikiPage {
        var text = "---\ntype: reference\nstatus: stub\ntitle: \"\(key)\"\n"
        if let source { text += "source: \(source)\n" }
        if let bibtex {
            text += "bibtex: |\n"
                + bibtex.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  " + $0 }.joined(separator: "\n")
                + "\n"
        }
        text += "---\n\n# [\(key)] \(title)\n"
        return WikiPage(path: "References/\(key) - \(title).md", text: text)
    }

    /// The generated one-page PDF the shots and these tests use.
    static var fixturePDF: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/papers/022.pdf")
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct PaperSourceTests {

    private typealias Candidate = PaperSource.Candidate

    private func candidate(_ string: String, _ kind: PaperSource.Kind) -> Candidate {
        Candidate(url: URL(string: string)!, kind: kind)
    }

    @Test("each kind of link the wiki cites offers its full text, its PDF, or its page")
    func candidatesPerLink() {
        let cases: [(String, [Candidate])] = [
            ("https://eprint.iacr.org/2002/022",
             [candidate("https://eprint.iacr.org/2002/022.pdf", .eprint)]),
            ("https://eprint.iacr.org/2002/022.pdf",
             [candidate("https://eprint.iacr.org/2002/022.pdf", .eprint)]),
            ("https://arxiv.org/abs/2410.19152",
             [candidate("https://arxiv.org/pdf/2410.19152", .arXiv)]),
            ("https://arxiv.org/abs/quant-ph/0604056",
             [candidate("https://arxiv.org/pdf/quant-ph/0604056", .arXiv)]),
            ("https://eccc.weizmann.ac.il/report/2003/021/",
             [candidate("https://eccc.weizmann.ac.il/report/2003/021/download/", .eccc)]),
            ("https://core.ac.uk/download/pdf/82807618.pdf",
             [candidate("https://core.ac.uk/download/pdf/82807618.pdf", .pdf)]),
            ("https://doi.org/10.1137/0217013",
             [candidate("https://doi.org/10.1137/0217013", .landingPage)]),
            ("https://dl.acm.org/doi/10.1145/800061.808726",
             [candidate("https://dl.acm.org/doi/10.1145/800061.808726", .landingPage)]),
            ("https://dblp.org/search?q=Karnin%20Greene%20Hellman",
             [candidate("https://dblp.org/search?q=Karnin%20Greene%20Hellman", .landingPage)]),
        ]
        for (link, expected) in cases {
            #expect(PaperSource.candidates(for: link) == expected, "candidates(for: \(link))")
        }
    }

    @Test("a plain-HTTP link is asked for over https, and a non-web link offers nothing")
    func secureLinks() {
        #expect(PaperSource.candidates(for: "http://ntru.org/f/ntru-20190330.pdf")
            == [candidate("https://ntru.org/f/ntru-20190330.pdf", .pdf)])
        #expect(PaperSource.candidates(for: "http://www.cs.bgu.ac.il/~beimel/pub.html")
            == [candidate("https://www.cs.bgu.ac.il/~beimel/pub.html", .landingPage)])
        #expect(PaperSource.candidates(for: "ftp://example.org/paper.pdf").isEmpty)
        #expect(PaperSource.candidates(for: "").isEmpty)
    }

    @Test("source comes first, then the BibTeX eprint, url and doi, without duplicates")
    func candidateOrder() {
        // JNVWY20: source, eprint and url all name the same arXiv paper.
        let same = PaperFixtures.reference(
            "JNVWY20", source: "https://arxiv.org/abs/2001.04383",
            bibtex: """
                @misc{JNVWY20,
                  title         = {{MIP}* = {RE}},
                  eprint        = {2001.04383},
                  archivePrefix = {arXiv},
                  url           = {https://arxiv.org/abs/2001.04383}
                }
                """)
        #expect(PaperSource(page: same).candidates
            == [candidate("https://arxiv.org/pdf/2001.04383", .arXiv)])

        // A publisher's page first, as written; the preprint the BibTeX
        // names after it; then the DOI.
        let several = PaperFixtures.reference(
            "ABC20", source: "https://link.springer.com/chapter/10.1007/abc",
            bibtex: """
                @inproceedings{ABC20,
                  doi = "10.1007/abc",
                  url = {https://eprint.iacr.org/2006/165},
                  eprint = 2101.00001,
                }
                """)
        #expect(PaperSource(page: several).candidates == [
            candidate("https://link.springer.com/chapter/10.1007/abc", .landingPage),
            candidate("https://arxiv.org/pdf/2101.00001", .arXiv),
            candidate("https://eprint.iacr.org/2006/165.pdf", .eprint),
            candidate("https://doi.org/10.1007/abc", .landingPage),
        ])
    }

    @Test("a BibTeX eprint is read as arXiv or ePrint by its prefix or its shape")
    func bibTeXEprint() {
        #expect(PaperSource.eprintLink("2001.04383", archivePrefix: "arXiv") == "arXiv:2001.04383")
        #expect(PaperSource.eprintLink("quant-ph/0604056", archivePrefix: nil)
            == "arXiv:quant-ph/0604056")
        #expect(PaperSource.eprintLink("2006/165", archivePrefix: nil)
            == "https://eprint.iacr.org/2006/165")
        #expect(PaperSource.eprintLink("2006/165", archivePrefix: "IACR")
            == "https://eprint.iacr.org/2006/165")
        #expect(PaperSource.eprintLink("hal-01234", archivePrefix: "HAL") == nil)
        #expect(PaperSource.eprintLink("something", archivePrefix: nil) == nil)

        let entry = """
            @misc{X, author = {A and B}, title = {{Nested} braces}, primaryClass = {cs.CR},
              eprinttype = {arxiv}, eprint = {1610.02518}, note = "quoted, with a comma"}
            """
        #expect(PaperSource.bibTeXField("title", in: entry) == "{Nested} braces")
        #expect(PaperSource.bibTeXField("eprint", in: entry) == "1610.02518")
        #expect(PaperSource.bibTeXField("eprinttype", in: entry) == "arxiv")
        #expect(PaperSource.bibTeXField("class", in: entry) == nil, "not primaryClass")
        #expect(PaperSource.bibTeXField("note", in: entry) == "quoted, with a comma")
        #expect(PaperSource.bibTeXField("url", in: entry) == nil)
    }

    @Test("the identity, key and file name come from the page")
    func identity() {
        let page = PaperFixtures.reference("FGJ+25", source: "https://eprint.iacr.org/2025/1")
        let source = PaperSource(page: page)
        #expect(source.referencePath == page.path)
        #expect(source.key == "FGJ+25")
        #expect(source.sourceURL == URL(string: "https://eprint.iacr.org/2025/1"))
        #expect(source.fileName == "FGJ+25.pdf", "+ is safe in a file name")

        let none = PaperSource(page: PaperFixtures.reference("NoLink", source: nil))
        #expect(none.candidates.isEmpty)
        #expect(none.sourceURL == nil)
    }

    @Test("file names keep only safe characters")
    func fileNames() {
        #expect(PaperSource.fileName(forKey: "BGI15") == "BGI15.pdf")
        #expect(PaperSource.fileName(forKey: "SW25a") == "SW25a.pdf")
        #expect(PaperSource.fileName(forKey: "A/B:C") == "A-B-C.pdf")
        #expect(PaperSource.fileName(forKey: "Ünïcode Key") == "-n-code-Key.pdf")
        #expect(PaperSource.fileName(forKey: ".hidden") == "-hidden.pdf")
        #expect(PaperSource.fileName(forKey: "  ") == "paper.pdf")
    }
}
