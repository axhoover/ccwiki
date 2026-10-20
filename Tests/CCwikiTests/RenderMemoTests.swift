import Foundation
import JavaScriptCore
import Testing
@testable import CCwiki

/// The renderer's memo (plans/render-pipeline.md, "The KaTeX memo"):
/// `ccwiki.js` renders each formula once while the macro table stands, the
/// least recently used going first after 1,000. It must not change a byte,
/// so the corpus suite renders every formula of the wiki through it twice
/// and compares each page with the same page rendered by KaTeX itself, in
/// a second context, through the patch as it was before the memo.
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
            (#"new String("x")"#, "undefined"),
        ]
        for call in calls {
            let before = try script.count("katexCalls")
            try script.evaluate("tex(\(call.expression), \(call.options)); tex(\(call.expression), \(call.options));")
            #expect(try script.count("katexCalls") == before + 2, "\(call.expression), \(call.options)")
        }
    }

    @Test("a global definition is never remembered, and empties the memo")
    func globalDefinitions() throws {
        for definition in [#"\gdef\z{1}"#, #"\xdef\z{1}"#, #"\global\let\z\relax"#, #"\global\def\z{1}"#] {
            let script = try memoScript()
            #expect(try script.tex("y") == "1:y")
            #expect(try script.tex(definition) == "2:" + definition)
            #expect(try script.tex(definition) == "3:" + definition)
            #expect(try script.tex("y") == "4:y", "rendered again after \(definition)")
            #expect(try script.tex("y") == "4:y")
        }
        let script = try memoScript()
        #expect(try script.tex("y") == "1:y")
        // In KaTeX's global group every definition is global.
        #expect(try script.tex(#"\def\z{1}"#, "{ globalGroup: true }") == #"2:\def\z{1}"#)
        #expect(try script.tex("y") == "3:y")
        // A control word that only begins like one defines nothing.
        #expect(try script.tex(#"\gdefault"#) == #"4:\gdefault"#)
        #expect(try script.tex(#"\gdefault"#) == #"4:\gdefault"#)
        #expect(try script.tex("y") == "3:y")
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

    @Test("nothing is remembered while a macro could reach what one formula leaves for the next")
    func tableThatSharesState() throws {
        for body in [#"\gdef\h{1}"#, #"\@eqnsw"#] {
            let script = try memoScript(table: MarkdownScript.literal([#"\g"#: body]))
            try script.evaluate(#"tex("x"); tex("x");"#)
            #expect(try script.count("katexCalls") == 2, "with \(body) in the table")
            try script.evaluate(#"CCwiki.render({ path: "a", markdown: "", links: {}, macros: {} });"#)
            try script.evaluate(#"tex("x"); tex("x");"#)
            #expect(try script.count("katexCalls") == 3, "on again with a table that cannot")
        }
    }

    // MARK: - The memo against KaTeX itself

    @Test("a \\gdef, and the \\@eqnsw KaTeX keeps between formulas, read as KaTeX reads them")
    func sharedTable() throws {
        let table = #"{ "\\calA": "\\mathcal{A}" }"#
        let patched = try Self.renderer(table: table)
        let plain = try Self.unpatched(table: table)
        let formulas = [
            #"\foo"#, #"\gdef\foo{x}"#, #"\foo"#, #"\foo"#, #"\calA"#, #"\calA"#,
            #"\@eqnsw"#, #"\begin{align}a&=b\\c&=d\end{align}"#, #"\@eqnsw"#, #"x\nonumber"#, #"\@eqnsw"#,
        ]
        var answers: [String] = []
        for formula in formulas {
            let answer = try patched.tex(formula, "{ displayMode: true }")
            #expect(try answer == plain.tex(formula, "{ displayMode: true }"), "\(formula)")
            answers.append(answer)
        }
        // Each is a case where what an earlier formula did shows.
        #expect(answers[0] != answers[2], #"\foo, after \gdef\foo"#)
        #expect(answers[6] != answers[8], #"\@eqnsw, after an align"#)
        #expect(answers[8] != answers[10], #"\@eqnsw, after \nonumber"#)
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
        #expect(formulas > 0)
        try #require(reached.count == 2)
        // The memo as the hit rates below model it: 1,000 formulas, the
        // least recently used going first.
        #expect(reached.reduce(0, +) == simulated)
        #expect(reached.allSatisfy { $0 < formulas }, "formulas the wiki repeats were remembered")

        func remembered(_ rendered: Int) -> String {
            String(format: "%.1f%%", 100 * Double(formulas - rendered) / Double(formulas))
        }
        let summary: [String] = [
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
          CCwiki.render({ path: "page", markdown: markdown, links: {}, macros: TABLE });
          var html = stubPage.innerHTML;
          return html + pseudocodeOf(html);
        }

        /** The memo's key for a call, as ccwiki.js makes it; null for one it
         *  never keeps. */
        function memoKey(expr, options) {
          var merged = Object.assign({ macros: TABLE, throwOnError: false, strict: "ignore" }, options || {});
          if (typeof expr !== "string" || merged.macros !== TABLE || merged.globalGroup ||
              /\\(?:gdef|xdef|global)(?![A-Za-z@])/.test(expr) || expr.indexOf("@") >= 0) return null;
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
          return { formulas: formulaCount, reached: reachedByPass, simulated: simulated, lines: lines };
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
