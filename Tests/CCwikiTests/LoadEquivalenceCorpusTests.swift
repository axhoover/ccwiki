import Foundation
import Testing
@testable import CCwiki

/// The load path's efficiency work (plans/efficiency.md, track L), held to
/// what it stands for: a sweep's remembered resolutions to `resolve`, a
/// section card asked for twice to the one worked out directly, a backlink's
/// line to the context the load used to store, and a card's scope to the
/// first H1 on bodies whose first H1 is not their first line.
///
/// The copies of the code track L replaced, and the tests that held the new
/// code equal to them, went after 0.1.4 (efficiency.md §2.1). The corpus
/// tests run when `CCWIKI_WIKI` names a clone, and print how long they took,
/// one run each beside the other suites, for the record; no assertion is
/// about time.
@Suite("Load path equivalence")
struct LoadEquivalenceCorpusTests {

    // MARK: The corpus

    struct Corpus: Sendable {
        let index: WikiIndex
        /// Every page, by path.
        let pages: [WikiPage]
        let manifest: RelationsManifest
        let labels: RelationLabels
    }

    /// The clone `CCWIKI_WIKI` names, read once for every test here; nil
    /// without one.
    static let corpus: Corpus? = {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: path)
        let content = root.appending(path: "content")
        guard FileManager.default.fileExists(atPath: content.path(percentEncoded: false))
        else { return nil }
        let index = WikiIndex.build(contentRoot: content)
        let manifest = RelationsManifest.load(cloneRoot: root)
        return Corpus(
            index: index, pages: index.pages.values.sorted { $0.path < $1.path },
            manifest: manifest, labels: RelationLabels(manifest: manifest, index: index))
    }()

    #if DEBUG
    static let configuration = "debug build"
    #else
    static let configuration = "release build"
    #endif

    static func timed<T>(_ work: () throws -> T) rethrows -> (value: T, duration: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try work()
        return (value, start.duration(to: clock.now))
    }

    static func report(_ item: String, _ parts: [String]) {
        let pages = corpus?.pages.count ?? 0
        print("\(item), \(pages) pages, one run each (\(configuration)): "
            + parts.joined(separator: "; "))
    }

    /// The paths of the pages whose two results differ.
    static func differing<T: Equatable>(_ pages: [WikiPage], _ old: [T], _ new: [T]) -> [String] {
        zip(pages, zip(old, new)).filter { $0.1.0 != $0.1.1 }.map { $0.0.path }
    }

    /// An index over `pages`, as a library load assembles one.
    static func index(_ pages: [WikiPage]) -> WikiIndex {
        WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"),
            files: pages.map(\.path),
            pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }))
    }

    // MARK: L3. Backlink contexts when shown

    @Test("a backlink is its linking page's, and its line reads as the context the load used to store")
    func backlinkLines() throws {
        let a = WikiPage(path: "Primitives/a.md",
                         text: "# A\n\n- Uses [[b]] and [[b|B again]].\n\nLater, [[b]].\n")
        let c = WikiPage(path: "Primitives/c.md", text: "# C\n\n- Uses [[b]] and [[b|B again]].\n")
        let index = Self.index([a, WikiPage(path: "Primitives/b.md", text: "# B\n"), c])
        let links = try #require(index.backlinkMap()["Primitives/b.md"])
        #expect(links.map(\.id) == ["Primitives/a.md", "Primitives/c.md"])
        #expect(links.map { String($0.line) }
            == ["- Uses [[b]] and [[b|B again]].", "- Uses [[b]] and [[b|B again]]."])
        #expect(links.map(\.context) == ["Uses b and B again.", "Uses b and B again."])
    }

    // MARK: L4. Each distinct link resolved once per sweep

    @Test("a sweep resolves each distinct link once, to what it resolves to from its own page")
    func resolutionsOnFixtures() {
        let pages = [
            WikiPage(path: "Primitives/a.md",
                     text: "[[b]] [[b#Syntax]] ![[b]] [[b#^block]] [[b|B]] [[Caf\u{E9}]] [[x]] [[#Syntax]]"),
            WikiPage(path: "Primitives/b.md",
                     text: "# B\n## Syntax\n[[b]] [[b#Syntax]] [[Cafe\u{301}]] [[../b]] [[./a]] [[x]]"),
            WikiPage(path: "Notes/caf\u{E9}.md", text: "# Café\n[[b]] [[Primitives/b#syntax]] [[a]]"),
        ]
        let index = Self.index(pages)
        var resolutions = WikiIndex.LinkResolutions(index)
        var links = 0
        for page in pages.sorted(by: { $0.path < $1.path }) {
            for link in WikiIndex.outgoingLinks(in: page.body) {
                links += 1
                let target = resolutions.target(of: link, from: page.path)
                #expect(target == index.resolve(link, from: page.path), "\(page.body[link.range]) on \(page.path)")
            }
        }
        #expect(resolutions.count < links, "\(resolutions.count) distinct links of \(links)")
    }

    @Test("on the corpus, a sweep resolves each link as its own page does")
    func resolutionsOnCorpus() {
        guard let corpus = Self.corpus else { return }
        var resolutions = WikiIndex.LinkResolutions(corpus.index)
        var links = 0
        var differing: [String] = []
        for page in corpus.pages {
            for link in WikiIndex.outgoingLinks(in: page.body) {
                links += 1
                if resolutions.target(of: link, from: page.path)
                    != corpus.index.resolve(link, from: page.path) {
                    differing.append("\(page.path): \(page.body[link.range])")
                }
            }
        }
        #expect(differing.isEmpty, "resolved differently in a sweep: \(differing)")
        print("L4 resolutions per sweep: \(links) links, \(resolutions.count) resolved")
    }

    // MARK: L6. Section cards once per load

    @Test("a section card asked for twice is the one worked out directly")
    func sectionCardsOnFixtures() {
        let page = WikiPage(path: "Primitives/a.md",
                            text: "# A\n\nIntro.\n\n## Syntax\n\nThe syntax.\n\n## Syntax\n\nAgain.\n")
        let previews = LinkPreviews(index: Self.index([page]), manifest: .empty, labels: .empty)
        for anchor in ["syntax", "syntax-1", "a", "nowhere"] {
            let expected = LinkPreviews.sectionCard(for: page, anchor: anchor, manifest: .empty)
                ?? previews.preview(path: page.path, anchor: nil)
            #expect(previews.preview(path: page.path, anchor: anchor) == expected, "#\(anchor)")
            #expect(previews.preview(path: page.path, anchor: anchor) == expected, "#\(anchor), again")
        }
        #expect(previews.preview(path: page.path, anchor: "syntax-1")?.excerpt == "Again.")
        #expect(previews.preview(path: "Primitives/none.md", anchor: "syntax") == nil)
    }

    @Test("on the corpus, every section card asked for twice is the one worked out directly")
    func sectionCardsOnCorpus() {
        guard let corpus = Self.corpus else { return }
        let previews = LinkPreviews(index: corpus.index, manifest: corpus.manifest, labels: corpus.labels)
        let pages = corpus.pages
        let anchors = pages.map { $0.headings().map(\.id) }
        func cards(_ card: (WikiPage, String) -> LinkPreview?) -> [[LinkPreview?]] {
            pages.indices.map { i in anchors[i].map { card(pages[i], $0) } }
        }

        // What `preview` returned before: the section's card, else the page's.
        let direct = Self.timed {
            cards { page, anchor in
                LinkPreviews.sectionCard(for: page, anchor: anchor, manifest: corpus.manifest)
                    ?? previews.preview(path: page.path, anchor: nil)
            }
        }
        let first = Self.timed { cards { previews.preview(path: $0.path, anchor: $1) } }
        let second = Self.timed { cards { previews.preview(path: $0.path, anchor: $1) } }
        let firstDiffering = Self.differing(pages, direct.value, first.value)
        let secondDiffering = Self.differing(pages, direct.value, second.value)
        #expect(firstDiffering.isEmpty && secondDiffering.isEmpty,
                "section cards differ on \(firstDiffering + secondDiffering)")

        let count = anchors.reduce(0) { $0 + $1.count }
        Self.report("L6 section cards once per load", [
            "\(count) anchors, worked out directly \(LoadTimings.format(direct.duration))",
            "through preview(path:anchor:) the first time \(LoadTimings.format(first.duration))",
            "the second time \(LoadTimings.format(second.duration))",
        ])
    }

    // MARK: L5. Preview cards stop at the first H1

    /// Bodies whose first H1 is not simply their first line, each with what a
    /// whole page's card reads: the lines after that H1, with LF line ends,
    /// or every line without one. Empty H1s before a real one, H1s inside
    /// fences (closed by a longer run, by a marker with trailing spaces, or
    /// never), an H2 first, a `%%` the comment deletion leaves unpaired, a
    /// CR LF page and a lone CR, which the scope's lines do not end.
    static let scopeFixtures: [(body: String, read: String)] = [
        ("#\n# \n#   #\n# Real\n\nText.\n\n## Abstract\n\nThe abstract.\n",
         "\nText.\n\n## Abstract\n\nThe abstract.\n"),
        ("```\n# In a fence\n```\n# Out\n\nProse.\n", "\nProse.\n"),
        ("~~~~\n# In\n~~~\n# Still in\n~~~~~\n# Out\n\nProse.\n", "\nProse.\n"),
        ("    # Indented four\n# H\n\nProse.\n", "\nProse.\n"),
        ("   ```\n# Fenced by an indented fence\n```\n# After\n\nProse.\n", "\nProse.\n"),
        ("```js\n# x\n``` \n# y\n\nProse.\n", "\nProse.\n"),
        ("```\n# x\n```  trailing\n# y\n```\n# z\n\nProse.\n", "\nProse.\n"),
        ("```\n# Unterminated\n", "```\n# Unterminated\n"),
        ("`# code`\n# A\n\nProse.\n", "\nProse.\n"),
        ("## Two\n# One\n\nProse.\n", "\nProse.\n"),
        ("# [[]]\n# $x$ and [[page|Real]]\n\nProse.\n", "\nProse.\n"),
        ("%% unpaired\n# A\n\nProse.\n", "\nProse.\n"),
        ("%%a%% # not\n# A\n%% open\n\nProse.\n", "# A\n%% open\n\nProse.\n"),
        ("# A\r\n\r\nText.\r\n\r\n## Abstract\r\n\r\nThe abstract.\r\n",
         "\nText.\n\n## Abstract\n\nThe abstract.\n"),
        ("line\r# A\r\n# B\n\nProse.\n", "\nProse.\n"),
        ("No heading at all.\n\nMore.\n", "No heading at all.\n\nMore.\n"),
        ("", ""),
    ]

    @Test("a card's scope starts after the first H1, past fences, empty H1s and comments")
    func scopesOnFixtures() {
        for (body, read) in Self.scopeFixtures {
            let scope = PreviewExcerpt.scope(of: body, anchor: nil)
            #expect(scope?.lines.joined(separator: "\n") == read, "\(body.debugDescription)")
            #expect(scope?.isWholePage == true && scope?.heading == nil, "\(body.debugDescription)")
        }
        let paragraphs = Self.scopeFixtures.prefix(3).map { PreviewExcerpt.firstParagraph(in: $0.body, anchor: nil) }
        #expect(paragraphs == ["Text.", "Prose.", "Prose."])
        #expect(PreviewExcerpt.firstParagraph(in: "## Two\n# One\n\nProse.\n", anchor: nil) == "Prose.")
        #expect(PreviewExcerpt.firstParagraphInline(in: "# A\n\nSee [[b|B]].\n", anchor: nil) == "See B.")
    }
}
