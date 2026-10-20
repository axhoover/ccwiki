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
    }

    /// The clone `CCWIKI_WIKI` names, read once for every test here; nil
    /// without one.
    static let corpus: Corpus? = {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty
        else { return nil }
        let content = URL(fileURLWithPath: path).appending(path: "content")
        guard FileManager.default.fileExists(atPath: content.path(percentEncoded: false))
        else { return nil }
        let index = WikiIndex.build(contentRoot: content)
        return Corpus(index: index, pages: index.pages.values.sorted { $0.path < $1.path })
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

    @Test("on the corpus, CodeMask, headings() and the backlinks are what they were")
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

        let oldBacklinks = Self.timed { Legacy.backlinkMap(of: corpus.index) }
        let newBacklinks = Self.timed { corpus.index.backlinkMap() }
        let old = Self.pairs(oldBacklinks.value)
        let new = Self.pairs(newBacklinks.value)
        #expect(new.count == old.count && new.count > 500, "\(new.count) targets, \(old.count) before")
        let targets = old.keys.filter { new[$0] != old[$0] }.sorted()
        #expect(targets.isEmpty, "backlinks differ for \(targets)")

        Self.report("L1 line ends on bytes", [
            "CodeMask.inertRanges " + Self.change(oldMasks.duration, newMasks.duration),
            "headings() " + Self.change(oldHeadings.duration, newHeadings.duration),
            "backlinkMap() " + Self.change(oldBacklinks.duration, newBacklinks.duration),
        ])
    }
}
