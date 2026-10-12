import Foundation
import Testing
@testable import CCwiki

/// The paper candidates of every reference in a real clone.
///
/// Skipped unless `CCWIKI_WIKI` points at a checkout of the wiki, as the
/// other corpus suites are. Invariants only: the wiki's HEAD moves, so the
/// counts of each kind are printed, never held to a number.
struct PaperCorpusTests {

    @Test("every reference's candidates are well formed")
    func corpusCandidates() throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let references = contentRoot.appending(path: "References")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: references.path(percentEncoded: false))
            .filter { $0.hasSuffix(".md") }
            .sorted()
        #expect(names.count > 100, "expected the References folder, got \(names.count) pages")

        var kinds: [String: Int] = [:]
        var fileNames: [String: String] = [:]
        for name in names {
            let text = try String(contentsOf: references.appending(path: name), encoding: .utf8)
            let page = WikiPage(path: "References/\(name)", text: text)
            let source = PaperSource(page: page)

            // A source that is ePrint, arXiv or ECCC offers that full text first.
            if let link = page.source, let parsed = IngestSubmission.Source.parse(link) {
                switch parsed {
                case .eprint, .arXiv, .eccc:
                    #expect(source.candidates.first?.url.absoluteString == parsed.fullTextURL,
                            "\(page.path): \(link)")
                case .doi, .other:
                    break
                }
            }
            for candidate in source.candidates {
                #expect(candidate.url.scheme == "https", "\(page.path): \(candidate.url)")
            }

            let folded = source.fileName.lowercased()
            #expect(fileNames[folded] == nil,
                    "\(page.path) and \(fileNames[folded] ?? "") share \(source.fileName)")
            fileNames[folded] = page.path

            kinds[source.candidates.first.map { $0.kind.rawValue } ?? "none", default: 0] += 1
        }

        print("paper candidates over \(names.count) references, by the first: "
            + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }
}
