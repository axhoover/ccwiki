import Foundation
import Testing
@testable import CCwiki

/// The load path's efficiency work (plans/efficiency.md, track L), held
/// equal to the code it replaced: `Legacy`, a copy of that code at 21df5d7.
///
/// Each change is compared on fixtures for the hazards the wiki has none of
/// (CR LF, a lone CR, a combining mark after a line end) and, when
/// `CCWIKI_WIKI` names a clone, on every page of the real wiki. Equality is
/// exact: `==` on what the old and the new code return. Each corpus
/// comparison prints how long the two took, one run each beside the other
/// suites, for the record; no assertion is about time.
@Suite("Load path equivalence")
struct LoadEquivalenceCorpusTests {

    // MARK: The corpus

    struct Corpus: Sendable {
        let index: WikiIndex
        /// Every page, by path.
        let pages: [WikiPage]
        let manifest: RelationsManifest
        let labels: RelationLabels

        /// What a render of `page` reads: its body, with the relation-meta
        /// line spliced under the H1 of a reduction or a barrier.
        func markdown(of page: WikiPage) -> String {
            guard let line = RelationMeta.line(for: page.frontmatter, manifest: manifest, labels: labels)
            else { return page.body }
            return RelationMeta.insertUnderH1(line, into: page.body)
        }
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

    /// "old 812.3 ms → new 233.1 ms".
    static func change(_ old: Duration, _ new: Duration) -> String {
        "old \(LoadTimings.format(old)) → new \(LoadTimings.format(new))"
    }

    static func report(_ item: String, _ parts: [String]) {
        let pages = corpus?.pages.count ?? 0
        print("\(item), \(pages) pages, one run each (\(configuration)): "
            + parts.joined(separator: "; "))
    }

    /// The paths of the pages whose old and new results differ.
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

    /// Each target's backlinks as `[source path, context]`, in order.
    static func pairs(_ map: [String: [WikiIndex.Backlink]]) -> [String: [[String]]] {
        map.mapValues { $0.map { [$0.sourcePath, $0.context] } }
    }

    static func pairs(_ map: [String: [Legacy.Backlink]]) -> [String: [[String]]] {
        map.mapValues { $0.map { [$0.sourcePath, $0.context] } }
    }

    // MARK: Fixtures

    /// Line ends the wiki has none of, each around a heading, a fence, a
    /// code span and a link to `Primitives/b.md`: CR LF, a lone CR, a
    /// combining mark after `\n` or `\r` (its own Character, never part of
    /// the line end), `\r\r\n`, a text ending in `\r`, the empty text, and a
    /// fence closed on a CR LF line.
    static let lineEndFixtures = [
        "# A\r\n\r\n## B\r\nText [[b]] here, `[[code]]`.\r\nLast.\r\n",
        "# A\r## B\rText [[b]] here.\r```\r## Fenced [[b]]\r```\rLast [[b|again]]",
        "# A\n\u{301}## B [[b]]\n\u{301}`x`\n",
        "# A\r\u{301}## B [[b]]\r\u{301}\r",
        "# A\r\r\n## B\r\r\nText [[b]]\r\r\n",
        "## Ends [[b]] in a CR\r",
        "",
        "```\r\n## Fenced [[x]]\r\n```\r\n## After [[b]]\r\nText `[[y]]` [[b]].\r\n",
        "\r\n\r\n",
        "\n",
        "\r",
    ]

    /// Both kinds of link, and the places neither is: code, a fence, a
    /// comment, math, an embed, an image, a link inside a link's text.
    static let linkFixtures = [
        "See [[a]], [[b|B]], [$k$-Lin](bilinear-map-assumptions#k-linear) and [IR89](<IR89 - Limits>).",
        "`[[code]]` [x](`y`)\n```\n[[fenced]] [x](y)\n```\n%%[[comment]] [c](d)%%\n![[embed.png]] ![i](i.png)",
        "[outer [[inner]]](x), [a [b](c)](d), [[x#anchor]], [[#same]] and [t](u \"title\")",
        "$[[math]]$ and $[m](n)$\n$$\n[m](n)\n$$\n[after](after-page) and [[after]]",
    ] + lineEndFixtures

    // MARK: L1. Line ends on bytes

    @Test("line ends found on bytes are the ones Characters found: CR LF, a lone CR, a mark after one")
    func lineEndsOnFixtures() {
        let target = WikiPage(path: "Primitives/b.md", text: "# B\n")
        for text in Self.lineEndFixtures {
            #expect(CodeMask.inertRanges(in: text) == Legacy.CodeMask.inertRanges(in: text),
                    "CodeMask of \(text.debugDescription)")
            let page = WikiPage(path: "Primitives/a.md", text: text)
            #expect(page.headings() == Legacy.headings(of: page), "headings of \(text.debugDescription)")
            let index = Self.index([page, target])
            #expect(Self.pairs(index.backlinkMap()) == Self.pairs(Legacy.backlinkMap(of: index)),
                    "backlinks from \(text.debugDescription)")
        }
    }

    @Test("on the corpus, CodeMask and headings() find what they found before")
    func lineEndsOnCorpus() {
        guard let corpus = Self.corpus else { return }
        let pages = corpus.pages
        let bodies = pages.map(\.body)

        let oldMasks = Self.timed { bodies.map(Legacy.CodeMask.inertRanges(in:)) }
        let newMasks = Self.timed { bodies.map(CodeMask.inertRanges(in:)) }
        let masks = Self.differing(pages, oldMasks.value, newMasks.value)
        #expect(masks.isEmpty, "CodeMask differs on \(masks)")

        let oldHeadings = Self.timed { pages.map(Legacy.headings(of:)) }
        let newHeadings = Self.timed { pages.map { $0.headings() } }
        let headings = Self.differing(pages, oldHeadings.value, newHeadings.value)
        #expect(headings.isEmpty, "headings() differs on \(headings)")

        Self.report("L1 line ends on bytes", [
            "CodeMask.inertRanges " + Self.change(oldMasks.duration, newMasks.duration),
            "headings() " + Self.change(oldHeadings.duration, newHeadings.duration),
        ])
    }

    // MARK: The backlinks

    /// What a reader sees of every target's backlinks: the linking pages, in
    /// order, each with its context. Held to the old `backlinkMap`, which
    /// found the line on Characters and reduced it at load (L1, L3).
    @Test("on the corpus, every target's backlinks read as they did, one per linking page")
    func backlinksOnCorpus() {
        guard let corpus = Self.corpus else { return }
        let oldBacklinks = Self.timed { Legacy.backlinkMap(of: corpus.index) }
        let newBacklinks = Self.timed { corpus.index.backlinkMap() }
        // Every context, as the panes would read them all.
        let contexts = Self.timed { Self.pairs(newBacklinks.value) }
        let old = Self.pairs(oldBacklinks.value)
        let new = contexts.value
        #expect(new.count == old.count && new.count > 500, "\(new.count) targets, \(old.count) before")
        let targets = old.keys.filter { new[$0] != old[$0] }.sorted()
        #expect(targets.isEmpty, "backlinks differ for \(targets)")

        let repeated = newBacklinks.value.filter { Set($0.value.map(\.id)).count != $0.value.count }
        #expect(repeated.isEmpty, "ids repeat in the backlinks of \(repeated.keys.sorted())")

        let busiest = newBacklinks.value.values.max { $0.count < $1.count } ?? []
        let shown = Self.timed { busiest.map(\.context) }
        Self.report("Backlinks (L1, L3)", [
            "backlinkMap() " + Self.change(oldBacklinks.duration, newBacklinks.duration),
            "every context read afterwards \(LoadTimings.format(contexts.duration))",
            "the busiest page's \(shown.value.count) \(LoadTimings.format(shown.duration))",
        ])
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
        #expect(Self.pairs(index.backlinkMap()) == Self.pairs(Legacy.backlinkMap(of: index)))
    }

    // MARK: L2. Each page's links parsed once

    /// A render's link list as two comparable lists: the keys, and the links.
    static func split(_ keyed: [(raw: String, link: Wikilink)]) -> (raws: [String], links: [Wikilink]) {
        (keyed.map { $0.raw }, keyed.map { $0.link })
    }

    @Test("one parse finds the links both parsers found, for a page and for a render")
    func linksOnFixtures() {
        for text in Self.linkFixtures {
            #expect(WikiIndex.outgoingLinks(in: text) == Legacy.outgoingLinks(in: text),
                    "outgoing links of \(text.debugDescription)")
            let new = Self.split(PageRenderer.keyedLinks(in: text))
            let old = Self.split(Legacy.keyedLinks(in: text))
            #expect(new.raws == old.raws && new.links == old.links,
                    "the render's links in \(text.debugDescription)")
        }
    }

    @Test("on the corpus, every body's links, every relation line's, and every render's are what they were")
    func linksOnCorpus() {
        guard let corpus = Self.corpus else { return }
        let pages = corpus.pages
        let bodies = pages.map(\.body)

        let oldLinks = Self.timed { bodies.map(Legacy.outgoingLinks(in:)) }
        let newLinks = Self.timed { bodies.map(WikiIndex.outgoingLinks(in:)) }
        let bodiesDiffering = Self.differing(pages, oldLinks.value, newLinks.value)
        #expect(bodiesDiffering.isEmpty, "outgoing links differ on \(bodiesDiffering)")
        let count = newLinks.value.reduce(0) { $0 + $1.count }
        #expect(count > 3000, "only \(count) links")

        var relationLines = 0
        var linesDiffering: [String] = []
        for page in pages {
            guard let line = RelationMeta.line(
                for: page.frontmatter, manifest: corpus.manifest, labels: corpus.labels)
            else { continue }
            relationLines += 1
            if WikiIndex.outgoingLinks(in: line) != Legacy.outgoingLinks(in: line) {
                linesDiffering.append(page.path)
            }
        }
        #expect(relationLines > 250, "only \(relationLines) relation-meta lines")
        #expect(linesDiffering.isEmpty, "a relation line's links differ on \(linesDiffering)")

        let markdowns = pages.map(corpus.markdown(of:))
        let oldKeyed = Self.timed { markdowns.map(Legacy.keyedLinks(in:)).map(Self.split) }
        let newKeyed = Self.timed { markdowns.map(PageRenderer.keyedLinks(in:)).map(Self.split) }
        let raws = Self.differing(pages, oldKeyed.value.map { $0.raws }, newKeyed.value.map { $0.raws })
        let keyed = Self.differing(pages, oldKeyed.value.map { $0.links }, newKeyed.value.map { $0.links })
        #expect(raws.isEmpty && keyed.isEmpty, "a render's links differ on \(raws + keyed)")

        Self.report("L2 links parsed once", [
            "outgoingLinks(in:) over every body " + Self.change(oldLinks.duration, newLinks.duration),
            "a render's link list for every page " + Self.change(oldKeyed.duration, newKeyed.duration),
        ])
    }
}
