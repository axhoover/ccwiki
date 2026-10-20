import Foundation
import Testing
@testable import CCwiki

/// Backlinks that land on the mention (plans/efficiency.md §3.1). A linking
/// page keeps every line that mentions its target, a click counts which
/// line of the body that is, and the body-relative line map takes it to the
/// line the render drew it on, past the relation-meta line a reduction's
/// render splices in.
///
/// The corpus tests run when `CCWIKI_WIKI` names a clone, as the other
/// corpus suites do. They hold each target's linking pages, and the first
/// line each shows, to `Legacy.backlinkMap`, the copy of the code before
/// track L, and count the mentions apart from `backlinkMap`.
struct BacklinkMentionTests {

    // MARK: Fixtures

    /// An index over `pages`, as a library load assembles one.
    static func index(_ pages: [WikiPage]) -> WikiIndex {
        WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"),
            files: pages.map(\.path),
            pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }))
    }

    static let targetPath = "Primitives/b.md"

    /// The backlinks to `Primitives/b.md` from one page whose body is `body`.
    static func backlinks(from body: String) -> [WikiIndex.Backlink] {
        let index = Self.index([
            WikiPage(path: "Primitives/a.md", text: body),
            WikiPage(path: Self.targetPath, text: "# B\n"),
        ])
        return index.backlinkMap()[Self.targetPath] ?? []
    }

    /// Each mention's line of the body, in order.
    static func bodyLines(_ link: WikiIndex.Backlink) -> [Int] {
        link.mentions.indices.compactMap { link.bodyLine(ofMention: $0) }
    }

    // MARK: Mentions

    @Test("two links on one line make one mention, and each other line one more, in source order")
    func mentionsAreLines() throws {
        let links = Self.backlinks(from: "# A\n\nSee [[b]] and [[b|B]].\n\nLater, [[b]].\n")
        #expect(links.count == 1, "one backlink per linking page")
        let link = try #require(links.first)
        #expect(link.mentions == ["See [[b]] and [[b|B]].", "Later, [[b]]."])
        #expect(link.line == "See [[b]] and [[b|B]].")
        #expect(link.context == "See b and B.")
        #expect(Self.bodyLines(link) == [2, 4])
    }

    @Test("a link inside code or a comment is not a mention")
    func codeIsNotAMention() throws {
        let body = "# A\n\n`[[b]]` in a span.\n\n```\n[[b]]\n```\n\n%% [[b]] %%\n\nOnly [[b]] here.\n"
        let link = try #require(Self.backlinks(from: body).first)
        #expect(link.mentions == ["Only [[b]] here."])
        #expect(Self.bodyLines(link) == [10])
        #expect(Self.backlinks(from: "# A\n\n`[[b]]` alone.\n```\n[[b]]\n```\n").isEmpty)
    }

    @Test("a markdown link to the page is a mention, on its own line or beside a wikilink")
    func markdownLinks() throws {
        let body = "# A\n\n[$k$-B](b) and [[b]].\n\nThen [B again](b#syntax).\n"
        let link = try #require(Self.backlinks(from: body).first)
        #expect(link.mentions == ["[$k$-B](b) and [[b]].", "Then [B again](b#syntax)."])
    }

    @Test("one mention is the backlink L3 built, and there is no line past the mentions")
    func oneMention() {
        let link = WikiIndex.Backlink(sourcePath: "Primitives/a.md", line: "See [[b]].")
        #expect(link == WikiIndex.Backlink(sourcePath: "Primitives/a.md", mentions: ["See [[b]]."]))
        #expect(link.line == "See [[b]].")
        #expect(link.id == "Primitives/a.md")
        #expect(link.bodyLine(ofMention: 0) == 0)
        #expect(link.bodyLine(ofMention: 1) == nil)
        #expect(link.bodyLine(ofMention: -1) == nil)
    }

    // MARK: Landing

    @Test("a mention's rendered line is its own line, with LF, CR LF or a lone CR")
    func landingOnEachLineEnd() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let body = ["# A", "", "Intro.", "", "See [[b]] and [[b|B]].", "", "Again [[b]] here.", ""]
                .joined(separator: ending)
            let link = try #require(Self.backlinks(from: body).first, "\(ending.debugDescription)")
            #expect(link.mentions == ["See [[b]] and [[b|B]].", "Again [[b]] here."],
                    "the mentions with \(ending.debugDescription)")
            #expect(Self.bodyLines(link) == [4, 6], "the lines with \(ending.debugDescription)")

            let map = SourceLineMap(body: body, renderedMarkdown: body)
            let rendered = SourceLineMap.lines(of: Substring(body))
            for (ordinal, line) in Self.bodyLines(link).enumerated() {
                let landing = try #require(map.renderedLine(forBodyLine: line))
                #expect(rendered[landing] == link.mentions[ordinal],
                        "mention \(ordinal) with \(ending.debugDescription)")
            }
        }
    }

    @Test("a mention below the relation-meta splice lands past the inserted lines, one in the H1 before it")
    func landingPastTheSplice() throws {
        let body = "\n# Title, from [[b]]\n\nFirst [[b]].\n\nSecond paragraph.\n"
        let link = try #require(Self.backlinks(from: body).first)
        #expect(Self.bodyLines(link) == [1, 3])

        let meta = "Reduction · from [[owf]] <!-- relation-meta -->"
        let spliced = RelationMeta.insertUnderH1(meta, into: body)
        let map = SourceLineMap(body: body, renderedMarkdown: spliced)
        #expect(map.bodyOffset == 0)
        #expect(map.inserted.count == 3)
        let rendered = SourceLineMap.lines(of: Substring(spliced))

        let title = try #require(map.renderedLine(forBodyLine: 1))
        #expect(title == 1, "above the splice, nothing moves")
        #expect(rendered[title] == link.mentions[0])
        let first = try #require(map.renderedLine(forBodyLine: 3))
        #expect(first == 3 + 3)
        #expect(rendered[first] == link.mentions[1])
    }

    @Test("a window opened on a mention carries its line to the page it opens; a restored one does not")
    func windowCarriesTheLine() {
        let opening = AppModel.Location.page(path: "Primitives/a.md", anchor: nil)
        let window = ReaderWindow(opening: opening, revealing: 12)
        let plan = SessionStartPlan.plan(
            restored: nil, window: window, pending: nil, launchDocument: nil,
            isColdStart: false, lastPage: nil)
        #expect(plan.opensOnLoad == opening)
        #expect(plan.revealing == 12)

        let restored = ReaderSessionState(
            history: NavigationHistory(), inspectorTab: "Outline",
            showsInspector: true, expandedFolders: [])
        let again = SessionStartPlan.plan(
            restored: restored, window: window, pending: nil, launchDocument: nil,
            isColdStart: false, lastPage: nil)
        #expect(again.revealing == nil)
        #expect(ReaderWindow().revealing == nil)
    }

    // MARK: Groups

    @Test("the groups: prose, then reductions and barriers, then references, each in its own order")
    func groups() {
        let paths = [
            "Assumptions/lwe.md", "Barriers/no-bb.md", "Primitives/prf.md",
            "References/GGM86 - How to construct random functions.md",
            "Reductions/owf-to-prg.md", "index.md",
        ]
        let links = paths.map { WikiIndex.Backlink(sourcePath: $0, line: "[[b]]") }
        let pages = Dictionary(uniqueKeysWithValues: paths.map { ($0, WikiPage(path: $0, text: "# X\n")) })
        let groups = WikiIndex.BacklinkGroup.grouping(links) { pages[$0]?.kind }
        #expect(groups[.mentionedIn]?.map(\.sourcePath)
            == ["Assumptions/lwe.md", "Primitives/prf.md", "index.md"])
        #expect(groups[.reductionsAndBarriers]?.map(\.sourcePath)
            == ["Barriers/no-bb.md", "Reductions/owf-to-prg.md"])
        #expect(groups[.references]?.map(\.sourcePath)
            == ["References/GGM86 - How to construct random functions.md"])
        #expect(WikiIndex.BacklinkGroup.allCases.map(\.title)
            == ["Mentioned in", "Reductions and Barriers", "References"])

        let unknown = WikiIndex.BacklinkGroup.grouping(links) { _ in nil }
        #expect(unknown.keys.sorted { $0.title < $1.title } == [.mentionedIn], "a page it cannot find is prose")
    }

    @Test("the prose starts open, and on a page no prose mentions, the first group there does")
    func groupsOpenByDefault() {
        /// The groups that start open on a page with backlinks in `present`,
        /// in the tab's order.
        func opened(_ present: Set<WikiIndex.BacklinkGroup>) -> [WikiIndex.BacklinkGroup] {
            WikiIndex.BacklinkGroup.allCases.filter {
                present.contains($0) && $0.opensByDefault(among: present)
            }
        }
        #expect(opened([.mentionedIn, .reductionsAndBarriers, .references]) == [.mentionedIn])
        #expect(opened([.mentionedIn, .references]) == [.mentionedIn])
        #expect(opened([.mentionedIn]) == [.mentionedIn])
        #expect(opened([.reductionsAndBarriers, .references]) == [.reductionsAndBarriers],
                "a page only reductions, barriers and references link to opens on the first")
        #expect(opened([.reductionsAndBarriers]) == [.reductionsAndBarriers])
        #expect(opened([.references]) == [.references])
    }

    // MARK: The corpus

    struct Corpus: Sendable {
        let content: URL
        let index: WikiIndex
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
            content: content, index: index,
            pages: index.pages.values.sorted { $0.path < $1.path },
            manifest: manifest, labels: RelationLabels(manifest: manifest, index: index))
    }()

    /// The 0-based line `index` is on, counted on scalars, apart from the
    /// `MarkdownLineEnd` the app counts with: `\n`, `\r\n` or a lone `\r`
    /// ends a line.
    static func lineNumber(of index: String.Index, in body: String) -> Int {
        var line = 0
        var previous: Unicode.Scalar?
        for scalar in body.unicodeScalars[..<index] {
            if scalar == "\r" || (scalar == "\n" && previous != "\r") { line += 1 }
            previous = scalar
        }
        return line
    }

    /// What a render of `page` draws: its body, with the relation-meta line
    /// spliced in on a reduction or a barrier.
    static func renderedMarkdown(of page: WikiPage, in corpus: Corpus) -> String {
        var renderer = PageRenderer(index: corpus.index)
        renderer.relations = corpus.manifest
        renderer.relationLabels = corpus.labels
        renderer.buildsPreviews = false
        return renderer.request(for: page).markdown
    }

    @Test("on the corpus, every target's linking pages are the legacy ones, in order, and each shows the legacy line")
    func backlinksOnCorpus() {
        guard let corpus = Self.corpus else { return }
        let new = corpus.index.backlinkMap()
        let old = Legacy.backlinkMap(of: corpus.index)
        #expect(Set(new.keys) == Set(old.keys) && new.count > 500, "\(new.count) targets, \(old.count) before")
        let differing = old.keys.filter { target in
            (new[target] ?? []).map { [$0.sourcePath, $0.context] }
                != (old[target] ?? []).map { [$0.sourcePath, $0.context] }
        }.sorted()
        #expect(differing.isEmpty, "the linking pages or their first lines differ for \(differing)")

        // Every (source, target, line), counted from the links and how they
        // resolve, without backlinkMap.
        var triples: Set<[String]> = []
        for page in corpus.pages {
            for link in WikiIndex.outgoingLinks(in: page.body) {
                guard case .page(let target, _) = corpus.index.resolve(link, from: page.path),
                      target != page.path
                else { continue }
                let line = Self.lineNumber(of: link.range.lowerBound, in: page.body)
                triples.insert([page.path, target, String(line)])
            }
        }
        let backlinks = new.values.reduce(0) { $0 + $1.count }
        let mentions = new.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.mentions.count } }
        #expect(mentions == triples.count, "\(mentions) mentions, \(triples.count) lines that link")
        print("Backlink mentions (F1): \(backlinks) backlinks to \(new.count) pages, "
            + "\(mentions) mentions, \(mentions - backlinks) beyond each page's first")
    }

    @Test("on the corpus, each mention's line is the line its own links are on, and its rendered line draws it")
    func mentionLinesOnCorpus() {
        guard let corpus = Self.corpus else { return }
        var byPath: [String: [WikiIndex.Backlink]] = [:]
        for backlinks in corpus.index.backlinkMap().values {
            for link in backlinks { byPath[link.sourcePath, default: []].append(link) }
        }
        var checked = 0
        var miscounted: [String] = []
        var misplaced: [String] = []
        for page in corpus.pages {
            guard let links = byPath[page.path] else { continue }
            let markdown = Self.renderedMarkdown(of: page, in: corpus)
            let map = SourceLineMap(body: page.body, renderedMarkdown: markdown)
            let bodyLines = SourceLineMap.lines(of: Substring(page.body))
            let rendered = SourceLineMap.lines(of: Substring(markdown))
            for link in links {
                for (ordinal, mention) in link.mentions.enumerated() {
                    checked += 1
                    let line = link.bodyLine(ofMention: ordinal)
                    guard let line, line == Self.lineNumber(of: mention.startIndex, in: page.body),
                          mention.hasPrefix(bodyLines[line])
                    else {
                        miscounted.append("\(page.path) mention \(ordinal)")
                        continue
                    }
                    guard let landing = map.renderedLine(forBodyLine: line),
                          rendered.indices.contains(landing), rendered[landing] == bodyLines[line]
                    else {
                        misplaced.append("\(page.path) mention \(ordinal)")
                        continue
                    }
                }
            }
        }
        #expect(checked > 1000, "only \(checked) mentions")
        #expect(miscounted.isEmpty, "counted on another line: \(miscounted.prefix(10))")
        #expect(misplaced.isEmpty, "rendered on another line: \(misplaced.prefix(10))")
    }

    @Test("on the corpus, the body's line map is the file's, past the frontmatter, for every line")
    func lineMapOnCorpus() throws {
        guard let corpus = Self.corpus else { return }
        var lines = 0
        var differing: [String] = []
        for page in corpus.pages {
            let data = try Data(contentsOf: corpus.content.appending(path: page.path))
            guard let fileText = String(data: data, encoding: .utf8) else { continue }
            let markdown = Self.renderedMarkdown(of: page, in: corpus)
            let byBody = SourceLineMap(body: page.body, renderedMarkdown: markdown)
            let byFile = SourceLineMap(fileText: fileText, renderedMarkdown: markdown)
            for line in SourceLineMap.lines(of: Substring(page.body)).indices {
                lines += 1
                if byBody.renderedLine(forBodyLine: line)
                    != byFile.renderedLine(forFileLine: byFile.bodyOffset + line + 1) {
                    differing.append("\(page.path):\(line)")
                    break
                }
            }
        }
        #expect(lines > 5000, "only \(lines) lines")
        #expect(differing.isEmpty, "the maps differ at \(differing.prefix(10))")
    }
}
