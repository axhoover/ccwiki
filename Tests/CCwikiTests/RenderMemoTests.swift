import Foundation
import JavaScriptCore
import Testing
@testable import CCwiki

/// The renderer's two memos (plans/render-pipeline.md, "The KaTeX memo" and
/// "The review"): `ccwiki.js` renders each formula once while the macro
/// table stands, the least recently used going first after 1,000, and
/// `reviewEntries` renders a block's HTML only when an entry shows it,
/// unless a formula could change KaTeX's table.
/// Neither may change a byte. The corpus suites render every formula of the
/// wiki through the first twice and compare each page with the same page
/// rendered by KaTeX itself, in a second context, through the patch as it
/// was before the memo; and review edits to every page with today's
/// `ccwiki-markdown.js` and with 21df5d7's (`Fixtures/legacy`).
struct RenderMemoTests {

    // MARK: - The memo's rules, on a KaTeX that counts

    /// `ccwiki.js` over a KaTeX that numbers its answers, so a formula the
    /// memo gave back reads as the call that rendered it; the patch is
    /// installed by a first render with `table`.
    private func memoScript(table: String = #"{ "\\calA": "\\mathcal{A}" }"#) throws -> MarkdownScript {
        let script = try MarkdownScript.load()
        try script.evaluate(Self.shell, named: "shell.js")
        try script.evaluate(Self.countingKatex, named: "katex.js")
        try script.evaluate(try Self.source("ccwiki.js"), named: "ccwiki.js")
        try script.evaluate(
            "var TABLE = " + table + #"; CCwiki.render({ path: "a", markdown: "", links: {}, macros: TABLE });"#,
            named: "setup.js")
        return script
    }

    /// KaTeX's answers are its call's number and the formula.
    private static let countingKatex = #"""
        var katexCalls = 0;
        katex.renderToString = function (expr) {
          katexCalls++;
          if (expr === "boom") throw new Error("boom");
          return katexCalls + ":" + expr;
        };
        function tex(expr, options) { return katex.renderToString(expr, options); }
        """#

    @Test("a formula renders once for each set of options")
    func remembers() throws {
        let script = try memoScript()
        #expect(try script.tex("x") == "1:x")
        #expect(try script.tex("x") == "1:x", "the first call's answer")
        #expect(try script.tex("x", "{ displayMode: true }") == "2:x")
        #expect(try script.tex("x", #"{ displayMode: "true" }"#) == "3:x", "a string is not a boolean")
        #expect(try script.tex("x", "{ displayMode: true }") == "2:x")
        // As the page's renderers ask, with the table among the options.
        #expect(try script.tex("x", #"{ macros: TABLE, output: "html" }"#) == "4:x")
        #expect(try script.tex("x", #"{ macros: TABLE, output: "html" }"#) == "4:x")
        #expect(try script.count("katexCalls") == 4)
    }

    @Test("a call KaTeX could answer otherwise next time is never remembered")
    func bypasses() throws {
        let script = try memoScript()
        let calls: [(expression: String, options: String)] = [
            (MarkdownScript.literal("x"), "{ trust: function () { return false; } }"),
            (MarkdownScript.literal("x"), "{ custom: {} }"),
            (MarkdownScript.literal("x"), "{ macros: {} }"),
            (MarkdownScript.literal(#"\@eqnsw"#), "undefined"),
            (MarkdownScript.literal(#"\text{a@b}"#), "undefined"),
            // What sets KaTeX's `\@eqnsw`, which a formula naming it reads.
            (MarkdownScript.literal(#"\begin{align}a&=b\end{align}"#), "{ displayMode: true }"),
            (MarkdownScript.literal(#"\begin{pmatrix}a\end{pmatrix}"#), "undefined"),
            (MarkdownScript.literal(#"x\nonumber"#), "undefined"),
            (MarkdownScript.literal(#"x\notag"#), "undefined"),
            // What `\gdef`s KaTeX's own `\df@tag`, which the copy area reads.
            (MarkdownScript.literal(#"x\tag{1}"#), "{ displayMode: true }"),
            (#"new String("x")"#, "undefined"),
        ]
        for call in calls {
            let before = try script.count("katexCalls")
            try script.evaluate("tex(\(call.expression), \(call.options)); tex(\(call.expression), \(call.options));")
            #expect(try script.count("katexCalls") == before + 2, "\(call.expression), \(call.options)")
        }
    }

    /// A render that installs a table other than `memoScript`'s.
    private static let otherTable = #"CCwiki.render({ path: "a", markdown: "", links: {}, macros: {} });"#

    @Test("a global definition is never remembered, empties the memo and turns it off until another table")
    func globalDefinitions() throws {
        for definition in [#"\gdef\z{1}"#, #"\xdef\z{1}"#, #"\global\let\z\relax"#, #"\global\def\z{1}"#] {
            let script = try memoScript()
            #expect(try script.tex("y") == "1:y")
            #expect(try script.tex(definition) == "2:" + definition)
            #expect(try script.tex(definition) == "3:" + definition)
            #expect(try script.tex("y") == "4:y", "rendered again after \(definition)")
            // What it defined can define more, which no formula shows.
            #expect(try script.tex("y") == "5:y", "nothing kept after \(definition)")
            try script.evaluate(Self.otherTable)
            #expect(try script.tex("y") == "6:y")
            #expect(try script.tex("y") == "6:y", "kept again with another table")
        }
        let script = try memoScript()
        // A control word that only begins like one defines nothing.
        #expect(try script.tex(#"\gdefault"#) == #"1:\gdefault"#)
        #expect(try script.tex(#"\gdefault"#) == #"1:\gdefault"#)
        #expect(try script.tex("y") == "2:y")
        // In KaTeX's global group every definition is global.
        #expect(try script.tex(#"\def\z{1}"#, "{ globalGroup: true }") == #"3:\def\z{1}"#)
        #expect(try script.tex("y") == "4:y")
        #expect(try script.tex("y") == "5:y")
    }

    @Test("a call that throws leaves nothing behind")
    func throwing() throws {
        let script = try memoScript()
        #expect(throws: MarkdownScript.Failure.self) { try script.tex("boom") }
        #expect(throws: MarkdownScript.Failure.self) { try script.tex("boom") }
        #expect(try script.count("katexCalls") == 2)
    }

    @Test("the memo keeps 1,000 formulas, and lets the least recently used go first")
    func leastRecentlyUsed() throws {
        let script = try memoScript()
        // KATEX_MEMO_LIMIT in ccwiki.js.
        try script.evaluate("for (var i = 0; i < 1000; i++) tex(\"f\" + i);")
        #expect(try script.count("katexCalls") == 1000)
        #expect(try script.tex("f0") == "1:f0", "all 1,000 kept")
        #expect(try script.tex("f1000") == "1001:f1000")
        #expect(try script.tex("f0") == "1:f0", "used since f1 was")
        #expect(try script.tex("f2") == "3:f2")
        #expect(try script.tex("f1") == "1002:f1", "the least recently used went")
    }

    @Test("a new macro table renders every formula again; the same table sent again does not")
    func newTable() throws {
        let script = try memoScript()
        let bold = #"CCwiki.render({ path: "a", markdown: "", links: {}, macros: { "\\calA": "\\mathbf{A}" } });"#
        #expect(try script.tex(#"\calA"#) == #"1:\calA"#)
        try script.evaluate(bold)
        #expect(try script.tex(#"\calA"#) == #"2:\calA"#)
        // Each render sends the table; an equal one changes nothing.
        try script.evaluate(bold)
        #expect(try script.tex(#"\calA"#) == #"2:\calA"#)
    }

    @Test("nothing is remembered while a macro could reach what one formula leaves for the next, or KaTeX changes it")
    func tableThatSharesState() throws {
        let tables: [[String: String]] = [
            [#"\g"#: #"\gdef\h{1}"#], [#"\g"#: #"\@eqnsw"#],
            [#"\g"#: #"x\nonumber"#], [#"\g"#: #"\begin{align}a\end{align}"#],
            // KaTeX deletes these two from the table after every formula.
            [#"\color"#: #"\textcolor"#], [#"\current@color"#: "blue"],
        ]
        for table in tables {
            let script = try memoScript(table: MarkdownScript.literal(table))
            try script.evaluate(#"tex("x"); tex("x");"#)
            #expect(try script.count("katexCalls") == 2, "with \(MarkdownScript.literal(table))")
            try script.evaluate(Self.otherTable)
            try script.evaluate(#"tex("x"); tex("x");"#)
            #expect(try script.count("katexCalls") == 3, "on again with a table that cannot")
        }
    }

    // MARK: - The memo against KaTeX itself

    /// `formulas` in display mode, in order, through the patch with its memo
    /// and through the patch as it was before, each in a new context with
    /// `table`: every answer must be KaTeX's. Returns the answers.
    private func sameAsKatex(_ formulas: [String], table: String) throws -> [String] {
        let patched = try Self.renderer(table: table)
        let plain = try Self.unpatched(table: table)
        var answers: [String] = []
        for formula in formulas {
            let answer = try patched.tex(formula, "{ displayMode: true }")
            #expect(try answer == plain.tex(formula, "{ displayMode: true }"), "\(formula)")
            answers.append(answer)
        }
        return answers
    }

    @Test("what one formula leaves in KaTeX's table for the next reads as KaTeX reads it")
    func sharedTable() throws {
        let table = #"{ "\\calA": "\\mathcal{A}" }"#
        // Each a case where what an earlier formula did shows.
        let defined = try sameAsKatex(
            [#"\foo"#, #"\gdef\foo{x}"#, #"\foo"#, #"\foo"#, #"\calA"#, #"\calA"#], table: table)
        #expect(defined[0] != defined[2], #"\foo, after \gdef\foo"#)
        // `\foo` defines `\bar`, which no formula's text shows.
        let unseen = try sameAsKatex(
            [#"\bar"#, #"\gdef\foo{\gdef\bar{1}}"#, #"\bar"#, #"\foo"#, #"\bar"#], table: table)
        #expect(unseen[2] != unseen[4], #"\bar, after \foo defined it"#)
        // An align sets `\@eqnsw` and `\nonumber` clears it, the second
        // time as the first.
        let align = #"\begin{align}a&=b\\c&=d\end{align}"#
        let switched = try sameAsKatex(
            [#"\@eqnsw"#, align, #"\@eqnsw"#, #"x\nonumber"#, #"\@eqnsw"#,
             align, #"\@eqnsw"#, #"x\nonumber"#, #"\@eqnsw"#],
            table: table)
        for read in stride(from: 2, through: 8, by: 2) {
            #expect(switched[read] != switched[read - 2], "\\@eqnsw, formula \(read)")
        }
        // KaTeX deletes `\color` and `\current@color` from the table after
        // every formula, so a table naming either changes at the first.
        let colored = try sameAsKatex(
            [#"\color{red}{x}y"#, #"\color{red}{x}y"#], table: #"{ "\\color": "\\textcolor" }"#)
        #expect(colored[0] != colored[1], #"\color, after a formula"#)
        let delimited = try sameAsKatex(
            [#"\left( x \right)"#, #"\left( x \right)"#], table: #"{ "\\current@color": "blue" }"#)
        #expect(delimited[0] != delimited[1], #"\right, after a formula"#)
    }

    @Test("a formula the memo gives back deletes the `\\df@tag` a `\\tag` left, as KaTeX does")
    func tagLeftForTheCopyArea() throws {
        // The web view's scripts with the vendored KaTeX, the messages
        // `ccwiki.js` posts, and Glossary/latex-macros's copy area, which
        // reads the whole table.
        let script = MarkdownScript(context: JSContext())
        try script.evaluate(MarkdownScript.prelude, named: "prelude.js")
        for name in Self.vendored + MarkdownScript.scripts {
            try script.evaluate(try Self.source(name), named: name)
        }
        try script.evaluate(Self.shell, named: "shell.js")
        try script.evaluate(#"""
            var posted = [];
            var webkit = { messageHandlers: { ccwiki: { postMessage: function (m) { posted.push(m); } } } };
            var copyArea = stubElement();
            stubPage.querySelector = function (selector) {
              return selector === "#macros-copy-area" &&
                stubPage.innerHTML.indexOf("macros-copy-area") >= 0 ? copyArea : null;
            };
            /** Each render's `ok`, or what it threw. A table of its own each
             *  time, as each payload from Swift is. */
            function show(markdown) {
              posted = [];
              try {
                CCwiki.render({ path: "p", markdown: markdown, links: {}, macros: { "\\calA": "\\mathcal{A}" } });
              } catch (e) {
                return "threw " + e;
              }
              return JSON.stringify(posted.filter(function (m) { return m.type === "rendered"; })
                .map(function (m) { return m.ok; }));
            }
            """#, named: "copy-area.js")
        try script.evaluate(try Self.source("ccwiki.js"), named: "ccwiki.js")

        // The macros page's formula comes back from the memo the second
        // time, after a page whose last formula is tagged.
        let macrosPage = #"<div id="macros-copy-area"></div>"# + "\n\nA formula $x$.\n"
        let tagged = "# Tagged\n\n$$\nE = mc^2 \\tag{1}\n$$\n"
        for (step, markdown) in [macrosPage, tagged, macrosPage].enumerated() {
            #expect(try script.text("show(\(MarkdownScript.literal(markdown)))") == "[true]",
                    "render \(step + 1)")
        }
    }

    // MARK: - The corpus

    private struct Corpus {
        /// Every page, by path.
        let pages: [WikiPage]
        /// The macro table as a script's object literal, as each render
        /// sends it.
        let table: String
    }

    private static func corpus() -> Corpus? {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty,
              let contentRoot = CorpusTests.contentRoot
        else { return nil }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let table = MacroTable.load(cloneRoot: URL(fileURLWithPath: path))
        return Corpus(
            pages: index.pages.values.sorted { $0.path < $1.path }, table: table.katexJSON())
    }

    @Test("on the corpus, every formula renders twice over as KaTeX renders it, and the hit rates")
    func corpusFormulas() throws {
        guard let corpus = Self.corpus() else { return }
        let patched = try Self.renderer(table: corpus.table)
        let plain = try Self.unpatched(table: corpus.table)
        let clock = ContinuousClock()

        var expected: [String] = []
        let started = clock.now
        for page in corpus.pages {
            expected.append(try plain.text("page(\(MarkdownScript.literal(page.body)))"))
        }
        var times = [Self.milliseconds(started.duration(to: clock.now))]
        var different: [String] = []
        for pass in 1...2 {
            let started = clock.now
            for (page, html) in zip(corpus.pages, expected) {
                let rendered = try patched.text("page(\(MarkdownScript.literal(page.body)))")
                if rendered != html { different.append("pass \(pass): \(page.path)") }
            }
            try patched.evaluate("endPass();")
            times.append(Self.milliseconds(started.duration(to: clock.now)))
        }
        #expect(different.isEmpty,
                "rendered otherwise than KaTeX renders them:\n  \(different.prefix(20).joined(separator: "\n  "))")

        let report = try #require(try patched.json("report(\(corpus.pages.count))") as? [String: Any])
        let formulas = try #require(report["formulas"] as? Int)
        let reached = try #require(report["reached"] as? [Int])
        let simulated = try #require(report["simulated"] as? Int)
        let lines = try #require(report["lines"] as? [String])
        // Whether ccwiki.js kept nothing for a while, which the model leaves
        // out: a macro that could share KaTeX's state, or a global
        // definition. Then the hit rates are the wiki's, not the code's.
        let memoOff = report["memoOff"] as? Bool ?? false
        #expect(formulas > 0)
        try #require(reached.count == 2)
        // The memo as the hit rates below model it: 1,000 formulas, the
        // least recently used going first.
        #expect(memoOff || reached.reduce(0, +) == simulated)
        #expect(memoOff || reached.allSatisfy { $0 < formulas }, "formulas the wiki repeats were remembered")

        func remembered(_ rendered: Int) -> String {
            String(format: "%.1f%%", 100 * Double(formulas - rendered) / Double(formulas))
        }
        let off: [String] = memoOff
            ? ["the memo was off for some or all of this wiki (a macro that could share KaTeX's state, "
               + "or a global definition), so the hit rates were not checked"]
            : []
        let summary: [String] = off + [
            "KaTeX through the patch before the memo: \(times[0]) ms",
            "pass 1: \(reached[0]) rendered, \(remembered(reached[0])) remembered, \(times[1]) ms",
            "pass 2: \(reached[1]) rendered, \(remembered(reached[1])) remembered, \(times[2]) ms",
            "(the times include each page's text going in and its HTML coming out)",
            "formulas remembered, by limit:",
        ]
        print("The KaTeX memo on the real wiki (plans/render-pipeline.md, \"The KaTeX memo\"), "
            + "\(corpus.pages.count) pages, \(formulas) formulas a pass:\n"
            + (summary.map { "  " + $0 } + lines.map { "    " + $0 }).joined(separator: "\n"))
    }

    // MARK: - The review's blocks, rendered when shown

    /// `ccwiki-markdown.js` as it was at 21df5d7, which rendered every
    /// block of both texts as it parsed them.
    private static let legacyMarkdown = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/legacy/ccwiki-markdown.js")
    private static let currentMarkdown = MarkdownScript.webRoot.appending(path: "ccwiki-markdown.js")

    /// A modified Markdown file of the review's payload (corrections §6.3).
    private static func modified(
        _ old: String, _ new: String, _ hunks: [([Int], [Int])], links: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "id": "x", "path": "content/X.md", "status": "modified", "isMarkdown": true,
            "old": old, "new": new, "bodyLine": ["old": 1, "new": 1],
            "hunks": hunks.map { ["old": $0.0, "new": $0.1] }, "flags": [Any](), "links": links,
        ]
    }

    private static func pageLink(_ name: String) -> [String: Any] {
        ["href": "ccwiki://wiki/page/\(name).md", "kind": "page", "external": false, "isImage": false]
    }

    /// What the corpus lacks: two destinations markdown-it makes one href
    /// of, line ends other than LF, a combining mark at a line's start,
    /// fences, comments, repeated headings, a footnote, a reference
    /// definition, math, pseudocode, a table and a callout.
    private static func hazards() -> [[String: Any]] {
        let twoTargets: [String: Any] = ["x y": pageLink("A"), "x%20y": pageLink("B")]
        return [
            modified("[a](<x y>)\n\nB.\n\nC.", "[a](x%20y)\n\nB.\n\nC.", [([0, 1], [0, 1])]),
            modified("[a](<x y>)\n\nB.\n\nC.", "[a](x%20y)\n\nB.\n\nC.", [([0, 1], [0, 1])], links: twoTargets),
            modified("[a](x%20y) and [b](<x y>)\n\nB.", "[a](<x y>) and [b](x%20y)\n\nB.",
                     [([0, 1], [0, 1])], links: twoTargets),
            modified("Keep [k](<x y>).\n\nB.\n\nC.\n\nD.", "Keep [k](<x y>).\n\nB.\n\nC, [c](x%20y).\n\nD.",
                     [([4, 5], [4, 5])], links: twoTargets),
            modified("# T\r\n\r\nOne.\r\n\r\nTwo.", "# T\r\n\r\nOne.\r\n\r\nTwo, changed.", [([4, 5], [4, 5])]),
            modified("a\rb\n\nc\n\nd", "a\rb\n\nc2\n\nd", [([2, 3], [2, 3])]),
            modified("x\n\u{0301}y\n\nz\n\nw", "x\n\u{0301}y\n\nz2\n\nw", [([3, 4], [3, 4])]),
            modified("```\ncode\n```\n\ntext\n\nmore", "```\ncode2\n```\n\ntext\n\nmore", [([1, 2], [1, 2])]),
            modified("a %%hidden%% b\n\n%%\nmulti\n%%\n\nc\n\nd", "a %%hidden%% b\n\n%%\nmulti\n%%\n\nc2\n\nd",
                     [([6, 7], [6, 7])]),
            modified("## S\n\nx\n\n## S\n\ny\n\n## S\n\nz", "## S\n\nx\n\n## S\n\ny2\n\n## S\n\nz", [([6, 7], [6, 7])]),
            modified("Text[^1].\n\nMore.\n\n[^1]: Note.", "Text[^1].\n\nMore.\n\n[^1]: Note, changed.",
                     [([4, 5], [4, 5])]),
            modified("[a][r]\n\n[r]: https://x.org\n\nEnd.", "[a][r]\n\n[r]: https://y.org\n\nEnd.", [([2, 3], [2, 3])]),
            modified("$\\calA$ and $$\\calB$$\n\n$$\nx\n$$\n\n```pseudocode\n\\State $x$\n```\n\nEnd.",
                     "$\\calA$ and $$\\calB$$\n\n$$\ny\n$$\n\n```pseudocode\n\\State $x$\n```\n\nEnd.",
                     [([3, 4], [3, 4])]),
            modified("| a | b |\n|---|---|\n| [[p\\|q]] | $\\|x\\|$ |\n\nT.",
                     "| a | b |\n|---|---|\n| [[p\\|r]] | $\\|x\\|$ |\n\nT.", [([2, 3], [2, 3])]),
            modified("> [!note] Title\n> Body.\n\nAfter.", "> [!note] Title\n> Body, changed.\n\nAfter.",
                     [([1, 2], [1, 2])]),
        ]
    }

    @Test("the review's entries are the ones it had when every block was rendered, on the hazards")
    func reviewHazards() throws {
        let table = #"{ "\\calA": "\\mathcal{A}", "\\calB": "\\mathcal{B}" }"#
        let before = try Self.reviewer(Self.legacyMarkdown, table: table)
        let after = try Self.reviewer(Self.currentMarkdown, table: table)
        for file in Self.hazards() {
            let call = "JSON.stringify(CCwikiMarkdown.reviewEntries(md, \(MarkdownScript.literal(file))))"
            #expect(try after.text(call) == before.text(call), "\(file["new"] as? String ?? "")")
        }
    }

    @Test("a link written two ways in a change keeps each side's destination")
    func reviewLinkDestinations() throws {
        let after = try Self.reviewer(Self.currentMarkdown, table: "{}")
        let file = Self.modified("[a](<x y>)\n\nB.", "[a](x%20y)\n\nB.", [([0, 1], [0, 1])])
        let raw = try after.json("CCwikiMarkdown.reviewEntries(md, \(MarkdownScript.literal(file)))")
        let entries = try #require(raw as? [[String: Any]])
        func html(_ kind: String) -> String {
            let entry = entries.first { ($0["kind"] as? String) == kind }
            return entry?["html"] as? String ?? ""
        }
        // The old block renders after the new text is parsed.
        #expect(html("removed").contains("Nothing resolves to “x y”"))
        #expect(html("added").contains("Nothing resolves to “x%20y”"))
    }

    /// `old` with its last line changed.
    private static func lastLineChanged(_ old: String) -> [String: Any] {
        let last = old.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        return modified(old, old + " changed", [([last, last + 1], [last, last + 1])])
    }

    /// Reviews in which a formula changes KaTeX's table for the formulas
    /// after it, each a table and the files reviewed with it in turn: the
    /// gaps and the order a lazy review would render in both show.
    private static func tableChanges() -> [(table: String, files: [[String: Any]])] {
        let calA = #"{ "\\calA": "\\mathcal{A}" }"#
        return [
            // A `\gdef` in a gap, and a block shown that reads it.
            (calA, [modified("$\\gdef\\foo{A}$ defines.\n\nB.\n\nC.\n\nD.\n\nUses $\\foo$ here.",
                             "$\\gdef\\foo{A}$ defines.\n\nB.\n\nC.\n\nD.\n\nUses $\\foo$ there.",
                             [([8, 9], [8, 9])])]),
            // Only the new text defines, in a block shown before an old one
            // that reads it.
            (calA, [modified("X.\n\nB.\n\nC.\n\nD.\n\nUses $\\baz$.",
                             "$\\gdef\\baz{N}$ X.\n\nB.\n\nC.\n\nD.\n\nUses $\\baz$, changed.",
                             [([0, 1], [0, 1]), ([8, 9], [8, 9])])]),
            // An align in a gap sets `\@eqnsw`, which a block shown reads.
            (calA, [lastLineChanged("$$\n\\begin{align}a\\end{align}\n$$\n\nB.\n\nC.\n\nD.\n\nRead $\\@eqnsw$ here.")]),
            // One file's `\nonumber` in a gap, and the next file's `\@eqnsw`.
            (calA, [lastLineChanged("$$\nx\\nonumber\n$$\n\nB.\n\nC.\n\nD.\n\nE."),
                    lastLineChanged("Read $\\@eqnsw$.\n\nB.")]),
            // A macro one file defines defines another where the next uses
            // it, in a gap.
            (calA, [lastLineChanged("$\\gdef\\qux{\\gdef\\quux{Q}}$\n\nB."),
                    lastLineChanged("$\\quux$ one.\n\nB.\n\nC.\n\nD.\n\n$\\qux$ two.\n\nE.\n\nF.\n\nG.\n\n"
                                    + "$\\quux$ three.")]),
            // KaTeX deletes `\color` after the first formula it renders.
            (#"{ "\\color": "\\textcolor" }"#,
             [lastLineChanged("$\\color{red}{x}y$\n\nB.\n\nC.\n\nD.\n\n$\\color{red}{x}y$ end.")]),
            // A macro of the table defines another.
            (#"{ "\\mk": "\\gdef\\made{M}" }"#,
             [lastLineChanged("$\\mk$ makes.\n\nB.\n\nC.\n\nD.\n\nUses $\\made$ here.")]),
            // A `\tag` in a gap leaves `\df@tag` in the table for what
            // reads it after the review: the copy area, `expandMacros`.
            (calA, [lastLineChanged("$$z \\tag{1}$$\n\nB.\n\nC.\n\nD.\n\nE.")]),
        ]
    }

    @Test("a review in which a formula could change KaTeX's table renders every block, in the order it did")
    func reviewTableChanges() throws {
        for (table, files) in Self.tableChanges() {
            let before = try Self.reviewer(Self.legacyMarkdown, table: table)
            let after = try Self.reviewer(Self.currentMarkdown, table: table)
            for file in files {
                let call = "blockRenders = 0; JSON.stringify(CCwikiMarkdown.reviewEntries(md, "
                    + MarkdownScript.literal(file) + "))"
                let old = file["old"] as? String ?? ""
                #expect(try after.text(call) == before.text(call), "\(old)")
                #expect(try after.count("blockRenders") == before.count("blockRenders"), "every block of \(old)")
            }
            // What the reviews left in KaTeX's table, for what reads it next.
            let names = "Object.keys(TABLE).sort().join()"
            #expect(try after.text(names) == before.text(names), "the table after \(table)")
        }
    }

    @Test("a review renders only the blocks it shows while no formula can change KaTeX's table")
    func reviewRendersShownBlocks() throws {
        let table = #"{ "\\calA": "\\mathcal{A}" }"#
        let before = try Self.reviewer(Self.legacyMarkdown, table: table)
        let after = try Self.reviewer(Self.currentMarkdown, table: table)
        // A formula that reads what another left changes nothing itself.
        let file = Self.lastLineChanged("$\\calA$ one.\n\nRead $\\@eqnsw$.\n\nC.\n\nD.\n\nE.")
        let call = "blockRenders = 0; JSON.stringify(CCwikiMarkdown.reviewEntries(md, "
            + MarkdownScript.literal(file) + "))"
        #expect(try after.text(call) == before.text(call))
        // Every block of both texts, five each, against the context and
        // the block removed and added: the three before them are a gap.
        #expect(try before.count("blockRenders") == 10)
        #expect(try after.count("blockRenders") == 3)
    }

    /// What the review is sent for an edit to `page`: its middle non-blank
    /// line changed, its first and last, the page added and the page
    /// deleted.
    private static func reviewFiles(_ page: WikiPage) -> [(name: String, file: [String: Any])] {
        let lines = page.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filled = lines.indices.filter { !lines[$0].allSatisfy(\.isWhitespace) }
        var files: [(name: String, file: [String: Any])] = []
        if let first = filled.first, let last = filled.last {
            let middle = filled[filled.count / 2]
            var edited = lines
            edited[middle] += " (edited)"
            files.append((name: "middle", file: modified(
                page.body, edited.joined(separator: "\n"), [([middle, middle + 1], [middle, middle + 1])])))
            var ends = lines
            ends[first] += " (first)"
            var hunks = [([first, first + 1], [first, first + 1])]
            if last != first {
                ends[last] += " (last)"
                hunks.append(([last, last + 1], [last, last + 1]))
            }
            files.append((name: "ends", file: modified(page.body, ends.joined(separator: "\n"), hunks)))
        }
        var added = modified("", page.body, [([0, 0], [0, lines.count])])
        added["status"] = "added"
        var deleted = modified(page.body, "", [([0, lines.count], [0, 0])])
        deleted["status"] = "deleted"
        files.append((name: "added", file: added))
        files.append((name: "deleted", file: deleted))
        return files
    }

    @Test("on the corpus, the review of edits to every page is the review it was, rendering fewer blocks")
    func corpusReview() throws {
        guard let corpus = Self.corpus() else { return }
        let before = try Self.reviewer(Self.legacyMarkdown, table: corpus.table)
        let after = try Self.reviewer(Self.currentMarkdown, table: corpus.table)
        let clock = ContinuousClock()
        var spent: [String: (before: Duration, after: Duration)] = [:]
        var renders: [String: (before: Int, after: Int)] = [:]
        var different: [String] = []
        var count = 0
        // Whether a macro could change KaTeX's table, as `mayChangeKatexTable`
        // asks: then every review renders every block. Read before the
        // reviews, whose formulas can write into the table.
        let tableShares = try after.evaluate(#"""
            Object.keys(TABLE).some(function (n) {
              var b = TABLE[n];
              return n === "\\color" || n.indexOf("@") >= 0 || typeof b !== "string" ||
                /\\(?:gdef|xdef|global|begin|nonumber|notag|tag)(?![A-Za-z@])/.test(b);
            });
            """#)?.toBool() == true
        for page in corpus.pages {
            // Each page's reviews start from the table as it was sent, both
            // before and after. Left there, what one page's formula wrote
            // (`\@eqnsw` after an align) made every later review render every
            // block, as `mayChangeKatexTable` asks, so one align on the first
            // page in path order failed the fewer-blocks check below with
            // every review the same. What one review leaves for the next is
            // `reviewTableChanges`'s to check.
            for script in [before, after] {
                try script.evaluate("resetTable();", named: "reset.js")
            }
            for (name, file) in Self.reviewFiles(page) {
                let call = "blockRenders = 0; JSON.stringify(CCwikiMarkdown.reviewEntries(md, "
                    + MarkdownScript.literal(file) + "))"
                let started = clock.now
                let old = try before.text(call)
                let halfway = clock.now
                let new = try after.text(call)
                let done = clock.now
                if new != old { different.append("\(name): \(page.path)") }
                let time = spent[name] ?? (before: .zero, after: .zero)
                spent[name] = (before: time.before + started.duration(to: halfway),
                               after: time.after + halfway.duration(to: done))
                let renderedBefore = try before.count("blockRenders")
                let renderedAfter = try after.count("blockRenders")
                let made = renders[name] ?? (before: 0, after: 0)
                renders[name] = (before: made.before + renderedBefore, after: made.after + renderedAfter)
                count += 1
            }
        }
        #expect(different.isEmpty, "reviewed otherwise:\n  \(different.prefix(20).joined(separator: "\n  "))")
        let middle = try #require(renders["middle"])
        #expect(tableShares || middle.after < middle.before, "the blocks in gaps are never rendered")
        #expect(renders["added"].map { $0.after == $0.before } == true, "a new file shows every block")

        let lines = ["middle", "ends", "added", "deleted"].compactMap { name -> String? in
            guard let made = renders[name], let time = spent[name] else { return nil }
            return "\(name): \(made.before) blocks rendered, \(Self.milliseconds(time.before)) ms before; "
                + "\(made.after), \(Self.milliseconds(time.after)) ms after"
        }
        print("The review's blocks rendered when shown, on the real wiki "
            + "(plans/render-pipeline.md, \"The review\"), \(count) files, identical:\n"
            + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    // MARK: - Contexts

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: MarkdownScript.webRoot.appending(path: name), encoding: .utf8)
    }

    /// The web view's scripts in `index.html`'s order, with the vendored
    /// KaTeX and pseudocode.js, in a document of stubs; a first render with
    /// `table` installs `ccwiki.js`'s patch. `page(markdown)` renders as
    /// `CCwiki.render` does, then the page's pseudocode.
    private static func renderer(table: String) throws -> MarkdownScript {
        let script = MarkdownScript(context: JSContext())
        try script.evaluate(MarkdownScript.prelude, named: "prelude.js")
        for name in vendored + MarkdownScript.scripts {
            try script.evaluate(try source(name), named: name)
        }
        try script.evaluate(shell, named: "shell.js")
        try script.evaluate(try source("ccwiki.js"), named: "ccwiki.js")
        try script.evaluate(shared, named: "shared.js")
        try script.evaluate("var TABLE = " + table + ";\n" + rendererSetup, named: "setup.js")
        return script
    }

    /// The same scripts with the patch as it was before the memo, which
    /// sends every call to KaTeX; `page(markdown)` renders as
    /// `renderer(table:)`'s does.
    private static func unpatched(table: String) throws -> MarkdownScript {
        let script = MarkdownScript(context: JSContext())
        try script.evaluate(MarkdownScript.prelude, named: "prelude.js")
        for name in vendored + MarkdownScript.scripts {
            try script.evaluate(try source(name), named: name)
        }
        try script.evaluate(shared, named: "shared.js")
        try script.evaluate("var TABLE = " + table + ";\n" + unpatchedSetup, named: "setup.js")
        return script
    }

    /// `file`, a `ccwiki-markdown.js`, behind the vendored KaTeX and
    /// markdown-it; `md` is made with `table` and counts in `blockRenders`
    /// the blocks it renders, and `resetTable()` puts the table back as sent.
    private static func reviewer(_ file: URL, table: String) throws -> MarkdownScript {
        let script = MarkdownScript(context: JSContext())
        try script.evaluate(MarkdownScript.prelude, named: "prelude.js")
        let libraries = [vendored[0]] + MarkdownScript.scripts.filter { $0.hasPrefix("vendor/") }
        for name in libraries {
            try script.evaluate(try source(name), named: name)
        }
        try script.evaluate(try String(contentsOf: file, encoding: .utf8), named: file.lastPathComponent)
        try script.evaluate("var TABLE = " + table + ";\n" + reviewerSetup, named: "setup.js")
        return script
    }

    private static let reviewerSetup = #"""
        var md = CCwikiMarkdown.create(TABLE);
        var blockRenders = 0;
        var renderBlocks = md.renderer.render;
        md.renderer.render = function () {
          blockRenders++;
          return renderBlocks.apply(this, arguments);
        };

        /** `TABLE` as it was sent, in place, since `md` and KaTeX hold that
         *  object: what formulas wrote there goes (`\@eqnsw` after an align,
         *  a `\gdef`'s macro), and a macro one redefined is as sent again. */
        var SENT = JSON.stringify(TABLE);
        function resetTable() {
          var sent = JSON.parse(SENT);
          Object.keys(TABLE).forEach(function (name) {
            if (!(name in sent)) delete TABLE[name];
          });
          Object.assign(TABLE, sent);
        }
        """#

    /// Ahead of `MarkdownScript.scripts`, as `index.html` loads them. They
    /// replace the prelude's stand-in `katex`.
    private static let vendored = ["vendor/katex/katex.min.js", "vendor/pseudocode/pseudocode.js"]

    /// The document `ccwiki.js` reaches for while rendering, and no more:
    /// a page that keeps its HTML, listeners never called, timers that never
    /// fire (`FixesJsTests`'s, with KaTeX left alone).
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
        """#

    /// What both contexts share: a page's pseudocode, rendered as
    /// `renderPseudocode` renders each block, without a DOM.
    private static let shared = #"""
        function pseudocodeOf(html) {
          var block = /<pre class="pseudocode"[^>]*>([\s\S]*?)<\/pre>/g;
          var out = "", found, i = 0;
          while ((found = block.exec(html))) {
            var source = found[1].replace(/&lt;/g, "<").replace(/&gt;/g, ">")
              .replace(/&quot;/g, "\"").replace(/&amp;/g, "&");
            // renderElement takes its options through JSON, which drops an
            // undefined captionCount.
            var options = JSON.parse(JSON.stringify({
              lineNumber: true, noEnd: false, commentDelimiter: "▸",
              captionCount: i === 0 ? 0 : undefined,
            }));
            try {
              out += pseudocode.renderToString(source, options);
            } catch (e) {
              out += "<pre>" + String(e && e.message) + "</pre>";
            }
            i++;
          }
          return out;
        }
        function tex(expr, options) { return katex.renderToString(expr, options); }
        """#

    /// Counts the calls that reach KaTeX, and records each formula's key,
    /// as `ccwiki.js` makes it, and its HTML's length, for `report`.
    private static let rendererSetup = #"""
        /** The table as Swift sends it with every page: a new object each
         *  time, never the one KaTeX writes into. Sent `TABLE` itself, the
         *  next page's table held what a formula had left there (`\@eqnsw`,
         *  a `\tag`'s `\df@tag`), so ccwiki.js took it for another table and
         *  emptied the memo, and its `@` turned the memo off, as the app's
         *  tables never do. */
        var SENT = JSON.stringify(TABLE);
        var reached = 0;
        var vendoredKatex = katex.renderToString;
        katex.renderToString = function () {
          reached++;
          return vendoredKatex.apply(katex, arguments);
        };
        CCwiki.render({ path: "", markdown: "", links: {}, macros: TABLE });
        var patchedKatex = katex.renderToString;
        var formulas = [];
        katex.renderToString = function (expr, options) {
          var html = patchedKatex.apply(katex, arguments);
          formulas.push([memoKey(expr, options), html.length]);
          return html;
        };

        var rendered = [];   // each page's formulas
        var reachedByPass = [], reachedBefore = 0;
        function endPass() {
          reachedByPass.push(reached - reachedBefore);
          reachedBefore = reached;
        }
        function page(markdown) {
          formulas = [];
          rendered.push(formulas);
          CCwiki.render({ path: "page", markdown: markdown, links: {}, macros: JSON.parse(SENT) });
          var html = stubPage.innerHTML;
          return html + pseudocodeOf(html);
        }

        /** ccwiki.js keeps nothing while a macro could share KaTeX's state
         *  (`ensureMarkdown`), nor from a global definition on (`writesMacros`).
         *  Neither is modelled below, so `report` says when either applies. */
        var tableShares = Object.keys(TABLE).some(function (name) {
          var body = String(TABLE[name]);
          return name === "\\color" || name.indexOf("@") >= 0 || body.indexOf("@") >= 0 ||
            /\\(?:gdef|xdef|global|begin|nonumber|notag|tag)(?![A-Za-z@])/.test(body);
        });
        var wrote = false;

        /** The memo's key for a call, as ccwiki.js makes it; null for one it
         *  never keeps. */
        function memoKey(expr, options) {
          var merged = Object.assign({ macros: TABLE, throwOnError: false, strict: "ignore" }, options || {});
          if (merged.globalGroup || /\\(?:gdef|xdef|global)(?![A-Za-z@])/.test(String(expr))) wrote = true;
          if (typeof expr !== "string" || merged.macros !== TABLE || merged.globalGroup ||
              /\\(?:gdef|xdef|global|begin|nonumber|notag|tag)(?![A-Za-z@])/.test(expr) ||
              expr.indexOf("@") >= 0) return null;
          var parts = [];
          for (var name in merged) {
            if (name === "macros") continue;
            var value = merged[name];
            if (typeof value === "function" || (typeof value === "object" && value !== null)) return null;
            parts.push(name, typeof value, String(value));
          }
          return JSON.stringify(parts) + "\u0000" + expr;
        }

        /** A memo of `limit` formulas, the least recently used going first;
         *  `page` returns how many of a page's formulas it renders, and
         *  `most` is the most characters it held, keys and HTML. */
        function Memo(limit) {
          this.limit = limit;
          this.kept = new Map();
          this.characters = 0;
          this.most = 0;
        }
        Memo.prototype.page = function (formulas) {
          var count = 0;
          for (var i = 0; i < formulas.length; i++) {
            var key = formulas[i][0], size = formulas[i][1];
            if (key !== null && this.kept.has(key)) {
              this.kept.delete(key);
              this.kept.set(key, key.length + size);
              continue;
            }
            count++;
            if (key === null) continue;
            if (this.kept.size >= this.limit) {
              var first = this.kept.keys().next().value;
              this.characters -= this.kept.get(first);
              this.kept.delete(first);
            }
            this.kept.set(key, key.length + size);
            this.characters += key.length + size;
            this.most = Math.max(this.most, this.characters);
          }
          return count;
        };

        /** After two passes of `perPass` pages: the calls that reached KaTeX
         *  in each, what a memo of 1,000 would have rendered of both, and a
         *  line for each limit: the share of a pass's formulas remembered in
         *  the first pass, in the second, and when each page is rendered
         *  twice in a row (Back and Forward, the editor's preview). */
        function report(perPass) {
          var first = rendered.slice(0, perPass), second = rendered.slice(perPass, 2 * perPass);
          var formulaCount = 0;
          first.forEach(function (p) { formulaCount += p.length; });
          var check = new Memo(1000), simulated = 0;
          first.concat(second).forEach(function (p) { simulated += check.page(p); });
          function share(count) { return (100 * (formulaCount - count) / formulaCount).toFixed(1) + "%"; }
          var lines = ["limit   first pass   second pass   page again   most kept"];
          [250, 500, 1000, 2000, 3300, Infinity].forEach(function (limit) {
            var memo = new Memo(limit), a = 0, b = 0, again = 0;
            first.forEach(function (p) { a += memo.page(p); });
            second.forEach(function (p) { b += memo.page(p); });
            var twice = new Memo(limit);
            first.forEach(function (p) { twice.page(p); again += twice.page(p); });
            lines.push([limit === Infinity ? "none" : String(limit), share(a), share(b), share(again),
              (memo.most / 1e6).toFixed(2) + " M characters"].join("   "));
          });
          return { formulas: formulaCount, reached: reachedByPass, simulated: simulated, lines: lines,
                   memoOff: tableShares || wrote };
        }
        """#

    /// `ccwiki.js`'s patch at 21df5d7, before the memo: every call reaches
    /// KaTeX, with the table and the same defaults.
    private static let unpatchedSetup = #"""
        var currentMacros = TABLE;
        (function (global) {
          var original = global.katex.renderToString.bind(global.katex);
          global.katex.renderToString = function (expr, options) {
            // Read at call time, not captured: the table can change between renders.
            return original(expr, Object.assign(
              { macros: currentMacros || {}, throwOnError: false, strict: "ignore" }, options || {}));
          };
        })(this);
        var md = CCwikiMarkdown.create(TABLE);
        function page(markdown) {
          var html = md.render(markdown, { links: {} });
          return html + pseudocodeOf(html);
        }
        """#
}

private extension MarkdownScript {
    /// `expression`'s value, which must be a string.
    func text(_ expression: String) throws -> String {
        guard let value = try evaluate(expression), value.isString, let text = value.toString()
        else { throw Failure(description: "No string from \(expression.prefix(80))") }
        return text
    }

    /// `tex(formula, options)` in the script: KaTeX through whatever the
    /// script has made of `katex.renderToString`.
    func tex(_ formula: String, _ options: String = "undefined") throws -> String {
        try text("tex(\(MarkdownScript.literal(formula)), \(options))")
    }

    /// A global of the script that holds a whole number.
    func count(_ name: String) throws -> Int {
        guard let value = try evaluate(name), value.isNumber else {
            throw Failure(description: "\(name) is not a number")
        }
        return Int(value.toInt32())
    }
}
