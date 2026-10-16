import Foundation
import Testing
@testable import CCwiki

/// The Swift half of the reader's parity fixes: a folder listing in the
/// site's order with the site's letter groups, and a relative link resolved
/// as the site resolves it.
@Suite("Render and resolution fixes")
struct FixesRenderswiftTests {

    /// An index over `pages`, as a library load assembles one.
    private static func index(_ pages: [WikiPage]) -> WikiIndex {
        WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"),
            files: pages.map(\.path).sorted(),
            pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }))
    }

    private static func page(_ path: String, title: String, body: String = "") -> WikiPage {
        WikiPage(path: path, text: "---\ntitle: \"\(title)\"\nstatus: draft\n---\n# \(title)\n\(body)")
    }

    /// The listing's groups in page order, each its letter followed by the
    /// titles of its rows.
    private static func groups(in html: String) -> [[String]] {
        let heading = #"<h2 class="folder-letter">"#
        var groups: [[String]] = []
        for line in html.split(separator: "\n") {
            if line.hasPrefix(heading) {
                groups.append([String(line.dropFirst(heading.count).dropLast("</h2>".count))])
            } else if line.hasPrefix("<li>"), let end = line.range(of: "</a>"),
                      let start = line[..<end.lowerBound].range(of: "\">", options: .backwards) {
                if groups.isEmpty { groups.append(["(no heading)"]) }
                groups[groups.count - 1].append(String(line[start.upperBound..<end.lowerBound]))
            }
        }
        return groups
    }

    // MARK: Folder listings

    @Test("a folder listing is in the site's order, grouped as the site groups it")
    func folderOrder() {
        // Shuffled; the expected order is what `localeCompare` on the
        // lower-cased titles gives in node, and the groups are
        // `FolderContent.tsx`'s.
        let titles = [
            "Φ-Hiding ⇒ cPIR",
            "IND-CPA PKE ⇒ IND-CCA KEM (Fujisaki–Okamoto)",
            "DDH + Sparse Learning Parity with Noise ⇒ Somewhat homomorphic encryption (SHE)",
            "CRHF + One-time signature ⇒ DS",
            "ABE ⇒ BE",
            "$k$-Linear assumption ⇒ ABE",
            "CRHF ⇒ STARK",
            "DDH ⇒ PKE",
            "IND-CPA ⇔ Semantic security",
            "CRHF ⇒ PCS",
            "$d$-th Composite Residuosity ⇒ Additively homomorphic encryption",
            "DDH ⇒ CDH",
            "IND-CCA security ⇒ IND-CPA KEM",
            "CRHF ⇒ Constant-round ZK argument (Barak)",
        ]
        let pages = titles.enumerated().map {
            Self.page("Reductions/r\($0.offset).md", title: $0.element)
        }
        let request = PageRenderer(index: Self.index(pages)).folderRequest(slug: "Reductions")

        #expect(Self.groups(in: request.html ?? "") == [
            ["#",
             "$d$-th Composite Residuosity ⇒ Additively homomorphic encryption",
             "$k$-Linear assumption ⇒ ABE",
             "Φ-Hiding ⇒ cPIR"],
            ["A", "ABE ⇒ BE"],
            ["C",
             "CRHF ⇒ Constant-round ZK argument (Barak)",
             "CRHF ⇒ PCS",
             "CRHF ⇒ STARK",
             "CRHF + One-time signature ⇒ DS"],
            ["D",
             "DDH ⇒ CDH",
             "DDH ⇒ PKE",
             "DDH + Sparse Learning Parity with Noise ⇒ Somewhat homomorphic encryption (SHE)"],
            ["I",
             "IND-CCA security ⇒ IND-CPA KEM",
             "IND-CPA ⇔ Semantic security",
             "IND-CPA PKE ⇒ IND-CCA KEM (Fujisaki–Okamoto)"],
        ])
    }

    @Test("a page files under its first letter A–Z, and under # otherwise")
    func dividerLetters() {
        let cases: [(title: String, letter: String)] = [
            ("ABE ⇒ BE", "A"), ("cPIR", "C"), ("zk-SNARK", "Z"),
            ("Φ-Hiding ⇒ cPIR", "#"), ("$k$-Linear assumption ⇒ ABE", "#"),
            ("#P", "#"), ("3SUM", "#"), ("Évasive", "#"), ("", "#"),
        ]
        for (title, letter) in cases {
            #expect(PageRenderer.dividerLetter(title) == letter, "\(title)")
        }
    }

    @Test("titles that compare equal keep one order, by path")
    func tieBreak() {
        let order = PageRenderer.listingOrder([
            Self.page("Reductions/b.md", title: "Same"),
            Self.page("Reductions/c.md", title: "same"),
            Self.page("Reductions/a.md", title: "Same"),
        ])
        #expect(order.map(\.path) == ["Reductions/a.md", "Reductions/b.md", "Reductions/c.md"])
    }

    // MARK: Relative links

    /// The home page, a page in Primitives, and two reductions a level and
    /// two levels down, one with a `../` markdown link.
    private static func relativeIndex() -> WikiIndex {
        index([
            page("index.md", title: "Cryptology City"),
            page("Primitives/pseudorandom-function.md", title: "Pseudorandom function",
                 body: "## Definition\n"),
            page("Reductions/x.md", title: "X",
                 body: "See [the PRF page](../Primitives/pseudorandom-function).\n"),
            page("Reductions/sub/y.md", title: "Y"),
        ])
    }

    private static func resolve(
        _ text: String, from source: String, in index: WikiIndex
    ) throws -> WikiIndex.Target {
        let link = try #require(WikilinkParser.links(in: text).first, "no wikilink in \(text)")
        return index.resolve(link, from: source)
    }

    @Test("a ../ link names the page the site's URL resolution reaches")
    func relativeLinks() throws {
        let index = Self.relativeIndex()
        let prf = WikiIndex.Target.page(path: "Primitives/pseudorandom-function.md", anchor: nil)
        let home = WikiIndex.Target.page(path: "index.md", anchor: nil)
        let cases: [(link: String, source: String, target: WikiIndex.Target)] = [
            ("[[../Primitives/pseudorandom-function|PRF]]", "Reductions/x.md", prf),
            ("[[../Primitives/pseudorandom-function]]", "Reductions/sub/y.md", prf),
            ("[[../../Primitives/pseudorandom-function]]", "Reductions/x.md", prf),
            ("[[../Primitives/pseudorandom-function#Definition]]", "Reductions/x.md",
             .page(path: "Primitives/pseudorandom-function.md", anchor: "definition")),
            ("[[./pseudorandom-function]]", "Reductions/x.md", prf),
            ("[[../Primitives/]]", "Reductions/x.md", .folder(slug: "Primitives")),
            ("[[..]]", "Reductions/x.md", home),
            ("[[../]]", "Reductions/x.md", home),
        ]
        for (link, source, target) in cases {
            #expect(try Self.resolve(link, from: source, in: index) == target, "\(link) from \(source)")
        }
        // The site joins this to the root, where there is no such page.
        #expect(try Self.resolve("[[../pseudorandom-function]]", from: "Reductions/x.md", in: index)
            .isResolved == false)
    }

    @Test("a ../ markdown link renders as a link, not as a broken one")
    func relativeMarkdownLink() throws {
        let index = Self.relativeIndex()
        let page = try #require(index.pages["Reductions/x.md"])
        let request = PageRenderer(index: index).request(for: page)
        let link = request.links["../Primitives/pseudorandom-function"]
        #expect(link?.href == CCwikiURL.page(path: "Primitives/pseudorandom-function.md"))
        #expect(link?.kind == "page")
        #expect(request.notices.isEmpty)
    }
}
