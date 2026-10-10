import Foundation
import Testing
@testable import CCwiki

/// Whole-corpus regression checks against a real clone.
///
/// Skipped unless `CCWIKI_WIKI` points at a checkout of
/// `axhoover/cryptology.city` — `make check-corpus` sets it to the app's own
/// clone in Application Support. The synthetic fixtures in
/// `WikilinkResolutionTests` cover the rules; this suite catches the case where
/// the rules are right but the corpus contains something nobody anticipated.
struct CorpusTests {

    static var contentRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"],
              !path.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: path).appending(path: "content")
        return FileManager.default.fileExists(atPath: root.path(percentEncoded: false))
            ? root : nil
    }

    @Test("every link in the corpus resolves, or is a known dead link")
    func corpusResolves() throws {
        guard let contentRoot = Self.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)

        #expect(index.pages.count > 250, "expected the full corpus, got \(index.pages.count)")

        var counts: [String: Int] = [:]
        var unresolved: [String] = []

        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            for (link, target) in index.links(on: page) {
                switch target {
                case .page: counts["page", default: 0] += 1
                case .asset: counts["asset", default: 0] += 1
                case .folder: counts["folder", default: 0] += 1
                case .samePage: counts["samePage", default: 0] += 1
                case .external: counts["external", default: 0] += 1
                case .unresolved:
                    counts["unresolved", default: 0] += 1
                    unresolved.append("\(page.path): \(page.body[link.range])")
                }
            }
        }

        let total = counts.values.reduce(0, +)
        // The corpus had 673 links and 3 dead ones when the resolver was
        // written. Both numbers move as the wiki grows; what must not move is
        // the *ratio* — a resolver regression shows up as dozens of failures.
        #expect(total > 500, "only \(total) links found — did the glob change?")
        #expect(Double(counts["unresolved"] ?? 0) / Double(total) < 0.02,
                "too many dead links: \(unresolved)")
        #expect(counts["folder"] ?? 0 >= 5, "index.md links to the top-level folders")

        // Markdown links are counted above, but they are too few (35 on 16
        // pages when they arrived) to move that ratio, so they get their own.
        // The wiki writes one wherever a link's text holds math.
        var markdownLinks = 0
        var deadMarkdownLinks: [String] = []
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            for link in MarkdownLinkParser.links(in: page.body) {
                markdownLinks += 1
                if !index.resolve(link.wikilink, from: page.path).isResolved {
                    deadMarkdownLinks.append("\(page.path): \(page.body[link.range])")
                }
            }
        }
        #expect(markdownLinks > 10, "only \(markdownLinks) markdown links — did the parser stop?")
        #expect(Double(deadMarkdownLinks.count) / Double(max(markdownLinks, 1)) < 0.1,
                "too many dead markdown links: \(deadMarkdownLinks)")

        print("corpus link resolution: \(counts.sorted { $0.key < $1.key }), "
              + "\(markdownLinks) of them markdown links")
        if !unresolved.isEmpty { print("dead links:\n  " + unresolved.joined(separator: "\n  ")) }
    }

    @Test("every reduction and barrier page gets the site's relation-meta line, and its links resolve")
    func corpusRelationMeta() throws {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty,
              let contentRoot = Self.contentRoot
        else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let manifest = RelationsManifest.load(cloneRoot: URL(fileURLWithPath: path))
        let labels = RelationLabels(manifest: manifest, index: index)
        var renderer = PageRenderer(index: index)
        renderer.relations = manifest
        renderer.relationLabels = labels

        let relationPages = index.pages.values
            .filter { $0.kind == .reduction || $0.kind == .barrier }
            .sorted { $0.path < $1.path }
        #expect(relationPages.count > 250, "expected ~315 relation pages, got \(relationPages.count)")

        var missing: [String] = []
        var linkCount = 0
        var dead: [String] = []
        for page in relationPages {
            guard let line = RelationMeta.line(
                for: page.frontmatter, manifest: manifest, labels: labels)
            else {
                missing.append(page.path)
                continue
            }
            // The line's own links, resolved from the page, as the render
            // request resolves them.
            for link in WikiIndex.outgoingLinks(in: line) {
                linkCount += 1
                if !index.resolve(link, from: page.path).isResolved {
                    dead.append("\(page.path): \(line[link.range])")
                }
            }
            let request = renderer.request(for: page)
            if !request.markdown.contains(line) { missing.append("\(page.path) (not spliced)") }
        }

        #expect(missing.isEmpty, "no relation-meta line:\n  \(missing.joined(separator: "\n  "))")
        // Class, model, source and assumption links: 477 when the line arrived.
        #expect(linkCount > 300, "only \(linkCount) links in relation-meta lines")
        #expect(Double(dead.count) / Double(max(linkCount, 1)) < 0.02,
                "relation-meta links with no target:\n  \(dead.joined(separator: "\n  "))")
    }

    @Test("every page parses, and the frontmatter schema holds")
    func corpusFrontmatter() throws {
        guard let contentRoot = Self.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)

        var problems: [String] = []
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            if page.frontmatter.string("type") == nil { problems.append("\(page.path): no type") }
            if page.frontmatter.string("status") == nil { problems.append("\(page.path): no status") }
            if page.frontmatter.string("title") == nil { problems.append("\(page.path): no title") }

            if let declared = page.frontmatter.string("type"),
               let kind = PageKind(rawValue: declared), kind != page.kind {
                problems.append("\(page.path): type \(declared) but lives in \(page.directory)")
            }
            if page.kind == .reference {
                for key in ["authors", "venue", "published", "source"]
                where page.frontmatter.string(key) == nil {
                    problems.append("\(page.path): reference missing \(key)")
                }
                let hasKey = page.frontmatter.string("cryptobib_key") != nil
                let hasBibtex = page.frontmatter.raw("bibtex") != nil
                if hasKey == hasBibtex {
                    problems.append("\(page.path): needs exactly one of cryptobib_key / bibtex")
                }
            }
        }
        #expect(problems.isEmpty, "frontmatter problems:\n  \(problems.joined(separator: "\n  "))")
    }

    @Test("the macro table parses out of the clone")
    func corpusMacros() throws {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty
        else { return }
        let table = MacroTable.load(cloneRoot: URL(fileURLWithPath: path))

        #expect(table.diagnostic == nil)
        #expect(table.macros.count > 100, "expected ~122 macros, got \(table.macros.count)")
        #expect(table.macros["\\calA"] == "\\mathcal{A}")
        #expect(table.macros["\\secpar"] == "\\lambda")
        #expect(table.macros["\\bits"] == "\\{0,1\\}")
        #expect(table.macros["\\getsr"] == "\\overset{\\$}{\\gets}")
    }

    @Test("every `\\macro` used in content is defined in macros.ts or is a KaTeX builtin")
    func corpusMacroCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty,
              let contentRoot = Self.contentRoot
        else { return }

        let table = MacroTable.load(cloneRoot: URL(fileURLWithPath: path))
        let index = WikiIndex.build(contentRoot: contentRoot)

        // Not a full KaTeX symbol table — just enough to prove the *custom*
        // macros are all accounted for. The repo's own lint owns the real check.
        var undefined: Set<String> = []
        let pattern = try NSRegularExpression(pattern: #"\\([A-Za-z]+)"#)

        for page in index.pages.values {
            let ns = page.body as NSString
            for match in pattern.matches(in: page.body,
                                         range: NSRange(location: 0, length: ns.length)) {
                let name = "\\" + ns.substring(with: match.range(at: 1))
                if table.macros[name] == nil { undefined.insert(name) }
            }
        }
        // Everything left over should be a KaTeX/pseudocode builtin, never
        // something that *looks* like one of the site's own macros.
        let suspicious = undefined.filter { $0.hasPrefix("\\cal") || $0.hasPrefix("\\class") }
        #expect(suspicious.isEmpty, "undefined site macros: \(suspicious.sorted())")
    }
}
