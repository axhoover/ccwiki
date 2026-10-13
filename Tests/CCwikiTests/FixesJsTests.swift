import Foundation
import Testing
@testable import CCwiki

/// The web view's two scripts, fixed: the review's Rendered view, which
/// read a change to a footnote or a link definition as blank lines
/// (`ccwiki-markdown.js`, plans/corrections.md §6.3), and a page's notices,
/// which emptied the macro table pseudocode and copying read (`ccwiki.js`).
@Suite struct FixesJsTests {

    /// One review entry, as much of it as these tests read.
    struct Entry {
        let kind: String
        let side: String
        let lines: [Int]
        let html: String
        let text: String?
        let note: String?
        let flags: Int
    }

    private static let blankLinesOnly = "Only blank lines changed here. See Source."
    private static let shownAsSource = "Shown as source"

    private func entries(_ file: [String: Any]) throws -> [Entry] {
        let script = try MarkdownScript.load()
        let raw = try script.json("CCwikiMarkdown.reviewEntries(md, \(MarkdownScript.literal(file)))")
        let list = try #require(raw as? [[String: Any]])
        return try list.map { entry in
            Entry(
                kind: try #require(entry["kind"] as? String),
                side: try #require(entry["side"] as? String),
                lines: try #require(entry["lines"] as? [Int]),
                html: entry["html"] as? String ?? "",
                text: entry["text"] as? String,
                note: entry["note"] as? String,
                flags: (entry["flags"] as? [Any])?.count ?? 0)
        }
    }

    /// A §6.3 file: a Markdown page with no frontmatter.
    private func file(
        old: [String], new: [String], hunks: [([Int], [Int])],
        status: String = "modified", flags: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "id": "f0",
            "path": "content/Primitives/x.md",
            "title": "X",
            "status": status,
            "summary": "",
            "isMarkdown": true,
            "header": "",
            "frontmatter": [Any](),
            "old": old.joined(separator: "\n"),
            "new": new.joined(separator: "\n"),
            "bodyLine": ["old": 8, "new": 8],
            "hunks": hunks.map { ["old": $0.0, "new": $0.1] },
            "flags": flags,
            "links": [String: Any](),
        ]
    }

    // MARK: - The review's blocks

    @Test("a changed footnote is removed and added as its source, not blank lines")
    func changedFootnote() throws {
        let old = ["Para one.[^1]", "", "[^1]: old note", "", "Para two."]
        var changed = old
        changed[2] = "[^1]: new claim"
        let flag: [String: Any] = ["lines": [2, 3], "severity": "warning", "text": "A warning."]
        let found = try entries(file(old: old, new: changed, hunks: [([2, 3], [2, 3])], flags: [flag]))
        #expect(found.map(\.kind) == ["context", "removed", "added", "context"])
        #expect(!found.contains { $0.text == Self.blankLinesOnly })

        let removed = try #require(found.first { $0.kind == "removed" })
        let added = try #require(found.first { $0.kind == "added" })
        #expect(removed.side == "old" && removed.lines == [2, 3])
        #expect(added.side == "new" && added.lines == [2, 3])
        #expect(removed.html.contains("old note"))
        #expect(added.html.contains("new claim"))
        #expect(added.note == Self.shownAsSource)
        #expect(added.flags == 1, "the flag is on the changed lines, not on a gap")
    }

    @Test("a changed link definition shows the old target and the new")
    func changedLinkDefinition() throws {
        let old = ["See [r].", "", "[r]: https://good.example", "", "End."]
        var changed = old
        changed[2] = "[r]: https://evil.example"
        let found = try entries(file(old: old, new: changed, hunks: [([2, 3], [2, 3])]))
        #expect(found.map(\.kind) == ["context", "removed", "added", "context"])
        #expect(found.first { $0.kind == "removed" }?.html.contains("https://good.example") == true)
        #expect(found.first { $0.kind == "added" }?.html.contains("https://evil.example") == true)
    }

    @Test("a hunk across a paragraph and the footnote under it shows both")
    func paragraphAndFootnote() throws {
        let old = ["# T", "", "A claim.[^1]", "[^1]: old note"]
        let changed = ["# T", "", "A claim, edited.[^1]", "[^1]: new claim"]
        let found = try entries(file(old: old, new: changed, hunks: [([2, 4], [2, 4])]))
        #expect(found.map(\.kind) == ["context", "removed", "removed", "added", "added"])
        #expect(found.filter { $0.kind == "added" }.map(\.lines) == [[2, 3], [3, 4]])
        #expect(found.last?.html.contains("new claim") == true)
    }

    @Test("a new page's footnote and link definition are in its review")
    func newPageDefinitions() throws {
        let page = ["# New", "", "Body.[^1]", "", "[^1]: A note.", "", "[r]: https://x.example"]
        let found = try entries(file(old: [], new: page, hunks: [([0, 0], [0, 7])], status: "added"))
        #expect(found.map(\.lines) == [[0, 1], [2, 3], [4, 5], [6, 7]])
        #expect(found.allSatisfy { $0.kind == "added" })
        #expect(found.filter { $0.note == Self.shownAsSource }.map(\.lines) == [[4, 5], [6, 7]])
    }

    // MARK: - Notices and the macro table

    /// The DOM `ccwiki.js` reaches for while rendering, and no more: a page
    /// that keeps its HTML, listeners never called, timers that never fire.
    /// `katex.renderToString` records the macros it is given, under the
    /// patch `ccwiki.js` installs, as pseudocode.js calls it.
    private static let shell = #"""
        var window = this;
        var scrollY = 0;
        function scrollTo() {}
        function addEventListener() {}
        function getSelection() { return null; }
        function requestAnimationFrame() {}
        function setTimeout() { return 0; }
        function clearTimeout() {}
        var NodeFilter = { SHOW_COMMENT: 128 };
        var Node = { TEXT_NODE: 3 };
        function stubElement() {
          return {
            innerHTML: "",
            textContent: "",
            classList: { add: function () {}, remove: function () {} },
            querySelector: function () { return null; },
            querySelectorAll: function () { return []; },
            getAttribute: function () { return null; },
            setAttribute: function () {},
            appendChild: function () {},
            addEventListener: function () {},
          };
        }
        var stubPage = stubElement();
        var document = {
          body: stubElement(),
          getElementById: function (id) { return id === "page" ? stubPage : null; },
          createElement: stubElement,
          querySelector: function () { return null; },
          querySelectorAll: function () { return []; },
          createTreeWalker: function () { return { nextNode: function () { return false; } }; },
          addEventListener: function () {},
        };
        var macrosSeen = null;
        katex.renderToString = function (tex, options) {
          macrosSeen = (options && options.macros) || null;
          return tex;
        };
        """#

    @Test("a page with notices keeps its macros for pseudocode and copying")
    func noticesKeepMacros() throws {
        let script = try MarkdownScript.load()
        try script.evaluate(Self.shell, named: "shell.js")
        let source = try String(
            contentsOf: MarkdownScript.webRoot.appending(path: "ccwiki.js"), encoding: .utf8)
        try script.evaluate(source, named: "ccwiki.js")
        // As the editor's preview sends a page with a broken link.
        try script.evaluate(#"""
            CCwiki.render({
              path: "a", markdown: "Text.", links: {},
              macros: { "\\calA": "\\mathcal{A}" },
              notices: [{ level: "warning", text: "1 link on this page has <no> target." }],
            });
            katex.renderToString("\\calA");
            """#)

        let macros = try script.json("Object.keys(macrosSeen || {})")
        #expect(macros as? [String] == ["\\calA"], "pseudocode's KaTeX call gets the page's table")
        let value = try script.evaluate("stubPage.innerHTML;")
        let html = try #require(value?.toString())
        #expect(html.hasPrefix(
            "<div class=\"notice notice-warning\">1 link on this page has &lt;no&gt; target.</div>"))
        #expect(html.contains("Text."))
    }

    // MARK: - The context menu's links

    /// The listeners `ccwiki.js` adds to the document, the messages it
    /// posts, and a right-click on a link, which reports the two link
    /// fields of the `contextTarget` message.
    private static let menuShell = #"""
        var listeners = {};
        document.addEventListener = function (type, listener) {
          (listeners[type] = listeners[type] || []).push(listener);
        };
        var posted = [];
        var webkit = { messageHandlers: { ccwiki: { postMessage: function (m) { posted.push(m); } } } };
        function anchor(href, broken) {
          return {
            nodeType: 1,
            classList: { contains: function (name) { return name === "broken" && broken; } },
            getAttribute: function (name) { return name === "href" ? href : null; },
            closest: function (selector) { return selector === "a" ? this : null; },
          };
        }
        function rightClick(href, broken) {
          posted = [];
          listeners.contextmenu[0]({ target: anchor(href, broken) });
          var message = posted.filter(function (m) { return m.type === "contextTarget"; })[0];
          return { link: message.link, externalLink: message.externalLink };
        }
        """#

    @Test("a right-click on a web or mail link sends it for the app's Open Link")
    func contextMenuWebLink() throws {
        let script = try MarkdownScript.load()
        try script.evaluate(Self.shell, named: "shell.js")
        try script.evaluate(Self.menuShell, named: "menu.js")
        let source = try String(
            contentsOf: MarkdownScript.webRoot.appending(path: "ccwiki.js"), encoding: .utf8)
        try script.evaluate(source, named: "ccwiki.js")

        func rightClick(_ href: String, broken: Bool = false) throws -> MenuLinks {
            let raw = try script.json("rightClick(\(MarkdownScript.literal(href)), \(broken))")
            let fields = try #require(raw as? [String: Any])
            return MenuLinks(link: fields["link"] as? String, web: fields["externalLink"] as? String)
        }

        let web = "https://eprint.iacr.org/2015/022"
        #expect(try rightClick(web) == MenuLinks(link: nil, web: web))
        let mail = "mailto:someone@example.com"
        #expect(try rightClick(mail) == MenuLinks(link: nil, web: mail))
        let page = CCwikiURL.page(path: "Primitives/prf.md")
        #expect(try rightClick(page) == MenuLinks(link: page, web: nil), "a page is the app's to open")
        let none = MenuLinks(link: nil, web: nil)
        #expect(try rightClick(web, broken: true) == none, "a dead link opens nothing")
        #expect(try rightClick("#syntax") == none, "a place on the page keeps WebKit's")
    }

    /// The two link fields of a `contextTarget` message.
    struct MenuLinks: Equatable {
        let link: String?
        let web: String?
    }
}
