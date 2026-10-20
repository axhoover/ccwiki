import Foundation
import Testing
@testable import CCwiki

/// Section links (plans/efficiency.md §3.2): a section of a page as a link
/// to it on cryptology.city, a wikilink and a CCwiki link, each of which
/// must read back to the section it names.
///
/// The fixtures carry what makes a form fail: a repeated heading, a heading
/// a wikilink cannot hold, a stem another page or an alias shares, and an
/// id that is not ASCII. When `CCWIKI_WIKI` names a clone, as the other
/// corpus suites read it, every heading of every page is read back.
struct SectionLinkCorpusTests {

    // MARK: Fixtures

    /// An index over `pages`, as a library load assembles one.
    static func index(_ pages: [WikiPage]) -> WikiIndex {
        WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"),
            files: pages.map(\.path),
            pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }))
    }

    static let prf = WikiPage(path: "Primitives/prf.md", text: """
        # PRF

        ## Syntax

        ## [GGM86] construction

        ## Σ-protocols

        ## Syntax
        """)

    /// The heading of `page` whose id is `id`.
    static func heading(_ id: String, of page: WikiPage) throws -> WikiPage.Heading {
        try #require(page.headings().first { $0.id == id }, "no heading \(id) on \(page.path)")
    }

    static func links(
        _ id: String, of page: WikiPage, in index: WikiIndex,
        channel: BuildIdentity.Channel = .release
    ) throws -> ReaderContextTarget.SectionLinks {
        let heading = try Self.heading(id, of: page)
        return ReaderContextTarget.SectionLinks(
            page: page, id: heading.id, text: heading.text, index: index, channel: channel)
    }

    @Test("a heading that reads back is named by its text; a repeated one, or one with brackets, by its id")
    func sectionForms() throws {
        let index = Self.index([Self.prf])
        #expect(Self.prf.headings().map(\.id)
            == ["prf", "syntax", "ggm86-construction", "σ-protocols", "syntax-1"])
        #expect(try Self.links("syntax", of: Self.prf, in: index).wikilink == "[[prf#Syntax]]")
        #expect(try Self.links("syntax-1", of: Self.prf, in: index).wikilink == "[[prf#syntax-1]]")
        #expect(try Self.links("ggm86-construction", of: Self.prf, in: index).wikilink
            == "[[prf#ggm86-construction]]")
        #expect(try Self.links("σ-protocols", of: Self.prf, in: index).wikilink == "[[prf#Σ-protocols]]")
    }

    @Test("a page whose stem another page or an alias shares is named by its path")
    func pageForms() throws {
        let twin = WikiPage(path: "Notes/prf.md", text: "# Another PRF\n\n## Syntax\n")
        let owf = WikiPage(path: "Notes/owf.md", text: "# OWF note\n\n## Syntax\n")
        let aliased = WikiPage(
            path: "Primitives/one-way-function.md",
            text: "---\naliases:\n  - owf\n---\n# One-way function\n")
        let index = Self.index([Self.prf, twin, owf, aliased])
        #expect(try Self.links("syntax", of: Self.prf, in: index).wikilink == "[[Primitives/prf#Syntax]]")
        #expect(try Self.links("syntax", of: twin, in: index).wikilink == "[[Notes/prf#Syntax]]")
        #expect(try Self.links("syntax", of: owf, in: index).wikilink == "[[Notes/owf#Syntax]]")
    }

    @Test("the site link's fragment is the id, and the CCwiki link opens the build it was copied from")
    func siteAndApp() throws {
        let index = Self.index([Self.prf])
        let release = try Self.links("σ-protocols", of: Self.prf, in: index, channel: .release)
        let site = try #require(release.site.flatMap(URLComponents.init(string:)))
        #expect(site.host == "cryptology.city")
        #expect(site.fragment == "σ-protocols")
        #expect(release.app.hasPrefix("ccwiki://wiki/page/Primitives%2Fprf.md#"))
        #expect(release.app.unicodeScalars.allSatisfy(\.isASCII), "\(release.app)")

        let dev = try Self.links("σ-protocols", of: Self.prf, in: index, channel: .dev)
        #expect(dev.app == "ccwiki-dev" + String(release.app.dropFirst("ccwiki".count)))
        for (channel, links) in [(BuildIdentity.Channel.release, release), (.dev, dev)] {
            let url = try #require(URL(string: links.app))
            #expect(CCwikiURL.destination(of: CCwikiURL.internalString(for: url, channel: channel))
                == .page(path: "Primitives/prf.md", anchor: "σ-protocols"), "\(channel)")
        }
    }

    @Test("an external page link without an anchor is the internal one in the build's scheme")
    func externalPage() {
        #expect(CCwikiURL.external(page: "Primitives/prf.md", anchor: nil, channel: .release)
            == CCwikiURL.page(path: "Primitives/prf.md"))
        #expect(CCwikiURL.external(page: "Primitives/prf.md", anchor: "syntax", channel: .dev)
            == "ccwiki-dev://wiki/page/Primitives%2Fprf.md#syntax")
    }

    // MARK: The corpus

    /// The clone `CCWIKI_WIKI` names, read once for every test here; nil
    /// without one.
    static let corpus: WikiIndex? = {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty
        else { return nil }
        let content = URL(fileURLWithPath: path).appending(path: "content")
        guard FileManager.default.fileExists(atPath: content.path(percentEncoded: false))
        else { return nil }
        return WikiIndex.build(contentRoot: content)
    }()

    /// The wikilink the plan gives section `heading` of `page`: the page by
    /// its stem when `[[stem]]` resolves to it, else by its path without
    /// `.md`; the section by its text when that reads back, else by its id.
    static func expectedWikilink(
        to heading: WikiPage.Heading, of page: WikiPage, in index: WikiIndex
    ) -> String {
        let stem = Wikilink(
            target: page.stem, rawAnchor: nil, alias: nil, isEmbed: false,
            range: page.path.startIndex..<page.path.startIndex)
        let name = index.resolve(stem, from: page.path) == .page(path: page.path, anchor: nil)
            ? page.stem : String(page.path.dropLast(".md".count))
        let section = WikiIndex.namesSection(heading.text, id: heading.id) ? heading.text : heading.id
        return "[[\(name)#\(section)]]"
    }

    @Test("on the corpus, every heading's site link, wikilink and CCwiki link read back to its section")
    func sectionLinksOnCorpus() {
        guard let index = Self.corpus else { return }
        var headings = 0
        var byText = 0
        var byPath = 0
        var failures: [String] = []
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            for heading in page.headings() {
                headings += 1
                let place = "\(page.path)#\(heading.id)"
                let links = ReaderContextTarget.SectionLinks(
                    page: page, id: heading.id, text: heading.text, index: index, channel: .release)

                if links.site.flatMap(URLComponents.init(string:))?.fragment != heading.id {
                    failures.append("site \(place): \(links.site ?? "none")")
                }

                let expected = Self.expectedWikilink(to: heading, of: page, in: index)
                guard let wikilink = links.wikilink, wikilink == expected else {
                    failures.append("wikilink \(place): \(links.wikilink ?? "none"), not \(expected)")
                    continue
                }
                let parsed = WikilinkParser.links(in: wikilink)
                if parsed.count != 1
                    || index.resolve(parsed[0], from: page.path) != .page(path: page.path, anchor: heading.id) {
                    failures.append("wikilink \(place): \(wikilink) resolves elsewhere")
                }
                if wikilink.contains("#\(heading.text)]]") { byText += 1 }
                if !wikilink.hasPrefix("[[\(page.stem)#") { byPath += 1 }

                for channel in [BuildIdentity.Channel.release, .dev] {
                    let app = CCwikiURL.external(page: page.path, anchor: heading.id, channel: channel)
                    let destination = URL(string: app).flatMap {
                        CCwikiURL.destination(of: CCwikiURL.internalString(for: $0, channel: channel))
                    }
                    if destination != .page(path: page.path, anchor: heading.id) {
                        failures.append("\(channel) link \(place): \(app)")
                    }
                }
            }
        }
        #expect(headings > 1000, "only \(headings) headings")
        #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(10))")
        print("Section links (F2): \(headings) headings, \(byText) named by their text, "
            + "\(headings - byText) by their id, \(byPath) on a page named by its path")
    }
}
