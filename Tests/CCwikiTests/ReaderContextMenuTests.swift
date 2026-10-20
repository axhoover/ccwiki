import Foundation
import Testing
@testable import CCwiki

/// The copy items at the top of the reader's right-click menu, built from
/// what `ccwiki.js` reports under the pointer. The menu is AppKit; what goes
/// into it, and in which order, is not.
struct ReaderContextMenuTests {

    private static let game = "\\begin{algorithm}\n\\caption{$\\Game(\\secpar)$}\n\\end{algorithm}"
    private static let gameExpanded = "\\begin{algorithm}\n\\caption{$\\mathsf{G}(\\lambda)$}\n\\end{algorithm}"

    @Test("a formula in prose offers its LaTeX and nothing else")
    func formulaOnly() {
        let target = ReaderContextTarget(tex: "\\calA^{F_k(\\cdot)}")
        #expect(target.copyItems.map(\.title) == ["Copy LaTeX"])
        #expect(target.copyItems.map(\.text) == ["\\calA^{F_k(\\cdot)}"])
        #expect(target.copyItems.map(\.isAlternate) == [false])
    }

    @Test("a formula in an algorithm offers the formula, then the algorithm and its Option-key alternate")
    func formulaInAlgorithm() {
        let target = ReaderContextTarget(
            tex: "\\Game(\\secpar)", algorithm: Self.game, algorithmExpanded: Self.gameExpanded)
        #expect(target.copyItems.map(\.title) == [
            "Copy LaTeX",
            "Copy Algorithm as LaTeX",
            "Copy Algorithm as LaTeX (No Macros)",
        ])
        #expect(target.copyItems.map(\.text) == ["\\Game(\\secpar)", Self.game, Self.gameExpanded])
        // The alternate has to come straight after the item it stands in for.
        #expect(target.copyItems.map(\.isAlternate) == [false, false, true])
    }

    @Test("an algorithm with no expanded form has no alternate")
    func algorithmWithoutExpansion() {
        let target = ReaderContextTarget(algorithm: Self.game)
        #expect(target.copyItems.map(\.title) == ["Copy Algorithm as LaTeX"])
        #expect(target.copyItems.map(\.isAlternate) == [false])
    }

    @Test("an expanded form on its own offers nothing: it is only ever an alternate")
    func expansionWithoutAlgorithm() {
        let target = ReaderContextTarget(algorithmExpanded: Self.gameExpanded)
        #expect(target.copyItems.isEmpty)
    }

    @Test("the bridge message is read field by field")
    func readsMessage() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "tex": "\\secpar",
            "algorithm": Self.game,
            "algorithmExpanded": Self.gameExpanded,
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target == ReaderContextTarget(
            tex: "\\secpar", algorithm: Self.game, algorithmExpanded: Self.gameExpanded))
    }

    @Test("null, empty and non-string fields are absent, so a click on prose adds nothing")
    func absentFields() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "tex": NSNull(),
            "algorithm": "",
            "algorithmExpanded": 3,
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target == ReaderContextTarget())
        #expect(target.copyItems.isEmpty)
    }

    // MARK: Links (reader-comforts §1.1, B2)

    private static let pagePath = "Primitives/pseudorandom-function.md"
    private static let pageLink = CCwikiURL.page(path: pagePath, anchor: "syntax")
    private static let linkTitles = [
        "Open Link in New Tab",
        "Open Link in New Window",
        "Open Link on cryptology.city",
    ]

    @Test("a link to a page offers a new tab, a new window and the site, in that order")
    func pageLinkItems() {
        let target = ReaderContextTarget(link: Self.pageLink)
        #expect(target.linkItems.map(\.title) == Self.linkTitles)
        #expect(target.linkItems.map(\.disposition) == [
            .newTab(inBackground: true), .newWindow, .onSite,
        ])
        let destination = CCwikiURL.Destination.page(path: Self.pagePath, anchor: "syntax")
        #expect(target.linkItems.map(\.destination) == Array(repeating: destination, count: 3))
        #expect(target.copyItems.isEmpty)
    }

    @Test("a link to a folder offers a new tab and a new window, and not the site")
    func folderLinkItems() {
        let target = ReaderContextTarget(link: CCwikiURL.folder(slug: "Primitives"))
        #expect(target.linkItems.map(\.title) == Array(Self.linkTitles.prefix(2)))
        #expect(target.linkItems.map(\.disposition) == [.newTab(inBackground: true), .newWindow])
        let folder = CCwikiURL.Destination.folder(slug: "Primitives")
        #expect(target.linkItems.map(\.destination) == [folder, folder])
    }

    @Test("a file of the wiki, the web, a place on the page or the shell offers no link items")
    func noLinkItems() {
        let links = [
            CCwikiURL.asset(path: "Files/Minicrypt.png"),
            "https://eprint.iacr.org/2015/022",
            "mailto:someone@example.com",
            "#syntax",
            "Primitives/pseudorandom-function",
            CCwikiURL.shell.absoluteString,
        ]
        for link in links {
            let target = ReaderContextTarget(link: link)
            #expect(target.linkItems.isEmpty, "\(link) is not a page to open elsewhere")
        }
        #expect(ReaderContextTarget().linkItems.isEmpty)
    }

    @Test("a formula offers no link items; a formula inside a link offers both kinds")
    func formulaAndLink() {
        #expect(ReaderContextTarget(tex: "\\secpar").linkItems.isEmpty)

        let both = ReaderContextTarget(tex: "\\mathsf{PRF}", link: Self.pageLink)
        #expect(both.copyItems.map(\.title) == ["Copy LaTeX"])
        #expect(both.linkItems.map(\.title) == Self.linkTitles)
    }

    @Test("the bridge message carries the link after the algorithm")
    func readsLink() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "tex": NSNull(),
            "algorithm": NSNull(),
            "algorithmExpanded": NSNull(),
            "link": Self.pageLink,
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target == ReaderContextTarget(link: Self.pageLink))
        #expect(target.linkItems.count == 3)
    }

    @Test("a null, empty or missing link is absent")
    func absentLink() {
        let null: [String: Any] = ["type": "contextTarget", "link": NSNull()]
        let empty: [String: Any] = ["type": "contextTarget", "link": ""]
        let missing: [String: Any] = ["type": "contextTarget", "tex": "\\secpar"]
        #expect(ReaderContextTarget(message: null).link == nil)
        #expect(ReaderContextTarget(message: empty).link == nil)
        #expect(ReaderContextTarget(message: missing).link == nil)
        #expect(ReaderContextTarget(message: missing).linkItems.isEmpty)
    }

    @Test("the link items go directly after WebKit's Open Link")
    func afterOpenLink() {
        let webKitMenu: [String?] = [
            "WKMenuItemIdentifierOpenLink",
            "WKMenuItemIdentifierCopyLink",
            "WKMenuItemIdentifierShareMenu",
        ]
        #expect(ReaderContextTarget.indexAfterOpenLink(in: webKitMenu) == 1)

        // Below the copy items and their separator, which have no identifier.
        #expect(ReaderContextTarget.indexAfterOpenLink(in: [nil, nil] + webKitMenu) == 3)
    }

    @Test("without WebKit's Open Link there is no place after it")
    func withoutOpenLink() {
        let menu: [String?] = [nil, nil, "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp"]
        #expect(ReaderContextTarget.indexAfterOpenLink(in: menu) == nil)
        #expect(ReaderContextTarget.indexAfterOpenLink(in: []) == nil)
    }

    // MARK: Corrections (plans/corrections.md §3.3, §9)

    private static func selection(text: String?) -> ReaderSelection {
        ReaderSelection(
            renderedLines: 4..<6, text: text, heading: nil, path: pagePath, revision: "ab81f02")
    }

    private static func titles(_ group: [ReaderContextTarget.CorrectionEntry]) -> [String] {
        group.compactMap { entry -> String? in
            if case .item(let title, _) = entry { return title }
            return nil
        }
    }

    @Test("with a passage, the corrections group says Passage")
    func passageGroup() {
        let group = ReaderContextTarget.correctionGroup(
            available: true, selection: Self.selection(text: "a passage"))
        #expect(Self.titles(group) == [
            "Edit This Passage…",
            "Describe a Correction…",
            "Open an Issue About This Passage…",
        ])
    }

    @Test("with a pointer or nothing, it says Page")
    func pageGroup() {
        let page = [
            "Edit This Page…",
            "Describe a Correction…",
            "Open an Issue About This Page…",
        ]
        let pointer = ReaderContextTarget.correctionGroup(
            available: true, selection: Self.selection(text: nil))
        #expect(Self.titles(pointer) == page)
        #expect(Self.titles(ReaderContextTarget.correctionGroup(available: true, selection: nil)) == page)
    }

    @Test("the group follows a separator, and each item names its route")
    func groupShape() {
        let group = ReaderContextTarget.correctionGroup(available: true, selection: nil)
        #expect(group.first == .separator)
        #expect(group.dropFirst().allSatisfy { $0 != .separator })
        let routes = group.compactMap { entry -> CorrectionRoute? in
            if case .item(_, let route) = entry { return route }
            return nil
        }
        #expect(routes == [.edit, .describe, .issue])
    }

    @Test("there are no items on a folder or the app's own pages")
    func noGroup() {
        #expect(ReaderContextTarget.correctionGroup(available: false, selection: nil).isEmpty)
        #expect(ReaderContextTarget.correctionGroup(
            available: false, selection: Self.selection(text: "a passage")).isEmpty)
    }

    // MARK: Sections (plans/efficiency.md §3.2)

    private static let section = CorrectionTarget.Section(id: "syntax", title: "Syntax", level: 2)
    private static let sectionLinks = ReaderContextTarget.SectionLinks(
        site: "https://cryptology.city/Primitives/pseudorandom-function#syntax",
        wikilink: "[[pseudorandom-function#Syntax]]",
        app: "ccwiki-dev://wiki/page/Primitives%2Fpseudorandom-function.md#syntax")

    private static func target(heading: CorrectionTarget.Section?) -> ReaderContextTarget {
        ReaderContextTarget(selection: ReaderSelection(
            renderedLines: 4..<6, text: nil, heading: heading, path: pagePath, revision: "ab81f02"))
    }

    @Test("under a heading, the section group offers the site link, the wikilink and the CCwiki link, in that order")
    func sectionGroup() {
        var asked: [String] = []
        let items = Self.target(heading: Self.section).sectionItems { path, heading in
            asked.append("\(path)#\(heading.id)")
            return Self.sectionLinks
        }
        #expect(items.map(\.title) == [
            "Copy Link to Section",
            "Copy Wikilink to Section",
            "Copy CCwiki Link to Section",
        ])
        #expect(items.map(\.text) == [
            "https://cryptology.city/Primitives/pseudorandom-function#syntax",
            "[[pseudorandom-function#Syntax]]",
            "ccwiki-dev://wiki/page/Primitives%2Fpseudorandom-function.md#syntax",
        ])
        #expect(items.allSatisfy { !$0.isAlternate })
        #expect(asked == ["\(Self.pagePath)#syntax"], "the section is the right-click's, on its page")
    }

    @Test("outside a section, or for a section the page cannot name, there is no section group")
    func noSectionGroup() {
        #expect(Self.target(heading: nil).sectionItems { _, _ in Self.sectionLinks }.isEmpty)
        #expect(ReaderContextTarget().sectionItems { _, _ in Self.sectionLinks }.isEmpty)
        #expect(ReaderContextTarget(tex: "\\secpar").sectionItems { _, _ in Self.sectionLinks }.isEmpty)
        #expect(Self.target(heading: Self.section).sectionItems { _, _ in nil }.isEmpty)
    }

    @Test("a section no wikilink reaches offers the other two")
    func sectionWithoutWikilink() {
        let links = ReaderContextTarget.SectionLinks(
            site: Self.sectionLinks.site, wikilink: nil, app: Self.sectionLinks.app)
        let items = Self.target(heading: Self.section).sectionItems { _, _ in links }
        #expect(items.map(\.title) == ["Copy Link to Section", "Copy CCwiki Link to Section"])
    }

    @Test("the bridge message carries the selection after the link")
    func readsSelection() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "tex": NSNull(),
            "algorithm": NSNull(),
            "algorithmExpanded": NSNull(),
            "link": Self.pageLink,
            "selection": [
                "start": 4, "end": 6, "text": NSNull(),
                "heading": NSNull(), "path": Self.pagePath, "revision": "ab81f02",
            ] as [String: Any],
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target == ReaderContextTarget(link: Self.pageLink, selection: Self.selection(text: nil)))
        #expect(target.selection?.isPassage == false)
    }
}
