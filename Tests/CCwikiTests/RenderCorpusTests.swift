import Foundation
import JavaScriptCore
import Testing
@testable import CCwiki

/// What the renderer's JavaScript costs on the real wiki, in JavaScriptCore
/// (plans/efficiency.md §2.3).
///
/// Skipped unless `CCWIKI_WIKI` points at a clone, as the other corpus suites
/// are. It loads the web view's scripts in `index.html`'s order, with the
/// real KaTeX and without pseudocode.js, under a stub of the little DOM
/// `ccwiki.js` reaches for: so its numbers are markdown-it's and prose
/// KaTeX's, not pseudocode's and not WebKit's layout. Then:
///
/// - every page body goes through `CCwiki.render` as `WebController` sends
///   it, twice, in two orders: each page twice in a row, as Back and Forward
///   and the editor's preview render, and the whole corpus twice, as a long
///   session does. Each order is the fastest of three runs, each in a fresh
///   context whose JIT is first warmed under another macro table, so a first
///   render finds nothing a memo kept (J1);
/// - `reviewEntries` gets a one-line edit to the middle non-blank line of
///   every page, as a correction's review does (J2).
///
/// No assertion is about time. One is that every page renders the same the
/// second time, and the same in either order, which J1 has to keep. Others
/// are that the figures time a renderer that works: no page fails to render,
/// and KaTeX's output is among the pages and the review's entries.
@Suite(.serialized) struct RenderCorpusTests {

    /// The page every efficiency figure names: the slowest to render.
    static let longest = "Assumptions/learning-with-errors.md"

    /// How `CCwiki.render` shows a page it could not render, whatever threw.
    /// The test's payloads carry no notices, so a page's HTML starts with
    /// this only when its render failed.
    static let renderFailed = #"<div class="notice notice-warning">Render failed"#

    /// What KaTeX's output carries and a formula it failed on does not: that
    /// shows as `math-error`, or `katex-error` when KaTeX could not parse it.
    static let katexOutput = #"class="katex""#

    /// The web view's scripts, in `index.html`'s order, without pseudocode.js.
    static let scripts = [
        "vendor/katex/katex.min.js",
        "vendor/markdown-it/markdown-it.umd.min.js",
        "vendor/markdown-it/markdown-it-footnote.min.js",
        "vendor/markdown-it/markdown-it-mark.min.js",
        "vendor/markdown-it/github-slugger.umd.js",
        "ccwiki-markdown.js",
    ]

    /// markdown-it decodes its entity tables with `atob`, which a bare
    /// JavaScriptCore context may not have. `MarkdownScript.prelude`'s, without
    /// its stand-in for KaTeX.
    static let prelude = #"""
        if (typeof atob !== "function") {
          this.atob = function (input) {
            var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            var text = String(input).replace(/[\s=]+/g, "");
            var out = "", buffer = 0, bits = 0;
            for (var i = 0; i < text.length; i++) {
              var value = alphabet.indexOf(text.charAt(i));
              if (value < 0) throw new Error("atob: not base64");
              buffer = ((buffer << 6) | value) & 0xffffff;
              bits += 6;
              if (bits >= 8) {
                bits -= 8;
                out += String.fromCharCode((buffer >> bits) & 0xff);
              }
            }
            return out;
          };
        }
        """#

    /// The DOM `ccwiki.js` reaches for while rendering, and no more: a page
    /// that keeps its HTML, listeners never called, timers that never fire.
    /// `FixesJsTests`' shell, without its stand-in for KaTeX.
    static let shell = #"""
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

    /// What the test calls, one page or file at a time: each payload is
    /// parsed in the call, as `WebController`'s script literal is. A review
    /// starts as `CCwiki.renderReview` does, by making its macro table the
    /// current one, which installs `ccwiki.js`'s KaTeX patch, and builds its
    /// markdown-it over that same parsed table, as `ensureMarkdown` does: so
    /// KaTeX is handed the object `ccwiki.js` holds as current, not an equal
    /// copy that a memo keyed on that object would pass over. The warm-up's
    /// table and the measured one differ, so each call makes its own current.
    static let harness = #"""
        var pagePayloads = [];
        var warmUpPayloads = [];
        var firstRenders = [];
        var reviewFiles = [];
        var reviewResults = [];
        var reviewMarkdown = null;
        function addPage(payload, warmUp) {
          pagePayloads.push(payload);
          warmUpPayloads.push(warmUp);
        }
        function warmAt(i) { CCwiki.render(JSON.parse(warmUpPayloads[i])); }
        function renderAt(i) { CCwiki.render(JSON.parse(pagePayloads[i])); }
        function keep(i) { firstRenders[i] = stubPage.innerHTML; }
        function same(i) { return stubPage.innerHTML === firstRenders[i]; }
        function firstHTML(i) { return firstRenders[i]; }
        function addReview(file) { reviewFiles.push(file); }
        function useReviewMacros(macros) {
          var table = JSON.parse(macros);
          CCwiki.render({ path: "", markdown: "", links: {}, notices: [], macros: table });
          reviewMarkdown = CCwikiMarkdown.create(table);
        }
        function reviewAt(i) {
          reviewResults[i] = CCwikiMarkdown.reviewEntries(reviewMarkdown, JSON.parse(reviewFiles[i]));
          return reviewResults[i].length;
        }
        // The entries whose HTML contains `containing`; "" counts every one with HTML.
        function reviewHTMLCount(containing) {
          var count = 0;
          reviewResults.forEach(function (entries) {
            entries.forEach(function (entry) {
              if (entry.html && entry.html.indexOf(containing) >= 0) count++;
            });
          });
          return count;
        }
        """#

    // MARK: The context

    /// A fresh context: the prelude, the scripts, the shell, `ccwiki.js`, then
    /// the harness.
    static func freshScript() throws -> MarkdownScript {
        let context: JSContext = JSContext()
        let script = MarkdownScript(context: context)
        try script.evaluate(prelude, named: "prelude.js")
        for name in scripts {
            let source = try String(
                contentsOf: MarkdownScript.webRoot.appending(path: name), encoding: .utf8)
            try script.evaluate(source, named: name)
        }
        try script.evaluate(shell, named: "shell.js")
        let ccwiki = try String(
            contentsOf: MarkdownScript.webRoot.appending(path: "ccwiki.js"), encoding: .utf8)
        try script.evaluate(ccwiki, named: "ccwiki.js")
        try script.evaluate(harness, named: "harness.js")
        return script
    }

    /// The harness's `function` called with `arguments`; throws with the
    /// exception it raised, if any.
    @discardableResult
    static func call(_ script: MarkdownScript, _ function: String, _ arguments: [Any] = []) throws
        -> JSValue? {
        script.context.exception = nil
        let value = script.context.objectForKeyedSubscript(function)?.call(withArguments: arguments)
        if let exception = script.context.exception {
            throw MarkdownScript.Failure(
                description: "\(function): \(exception.toString() ?? "an exception")")
        }
        return value
    }

    /// `call`, timed.
    static func timedCall(_ script: MarkdownScript, _ function: String, _ arguments: [Any]) throws
        -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try call(script, function, arguments)
        return start.duration(to: clock.now)
    }

    // MARK: The corpus

    /// One page as the test sends it: its render payload; the same under
    /// the warm-up's macro table; and its review file, for a page with a
    /// non-blank line.
    struct Page {
        let path: String
        let payload: String
        let warmUp: String
        let review: String?
    }

    /// Every page, by path, and the macro table as JSON, with the warm-up's.
    struct Corpus {
        let pages: [Page]
        let macros: String
        let warmUpMacros: String
    }

    static func corpus(in source: URL) throws -> Corpus {
        let index = WikiIndex.build(contentRoot: source.appending(path: "content"))
        let macros = MacroTable.load(cloneRoot: source).macros
        // One macro more: a table of its own, so the warm-up's renders are
        // cached, if anything is, under a table the measured ones never use.
        var warmUpMacros = macros
        warmUpMacros["\\ccwikiTimingWarmUp"] = "x"
        var pages: [Page] = []
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            let links = Self.links(on: page, index: index)
            var payload: [String: Any] = [
                "path": page.path, "markdown": page.body, "links": links,
                "notices": [String](), "macros": macros,
            ]
            let json = try Self.json(payload)
            payload["macros"] = warmUpMacros
            let warmUp = try Self.json(payload)
            let review = try Self.reviewFile(for: page, links: links).map { try Self.json($0) }
            pages.append(Page(path: page.path, payload: json, warmUp: warmUp, review: review))
        }
        let table = try Self.json(macros)
        let warmUpTable = try Self.json(warmUpMacros)
        return Corpus(pages: pages, macros: table, warmUpMacros: warmUpTable)
    }

    /// The page's wikilinks to pages, as `PageRenderer` sends them: keyed by
    /// the raw `[[…]]`, each with its href. A markdown link stays out, and
    /// renders as one with no target, which costs the renderer the same.
    static func links(on page: WikiPage, index: WikiIndex) -> [String: Any] {
        var links: [String: Any] = [:]
        for link in WikiIndex.outgoingLinks(in: page.body) {
            let raw = String(page.body[link.range])
            guard raw.hasPrefix("[[") || raw.hasPrefix("![["),
                  case .page(let path, let anchor) = index.resolve(link, from: page.path)
            else { continue }
            links[raw] = [
                "href": CCwikiURL.page(path: path, anchor: anchor), "kind": "page",
                "external": false, "isImage": false,
            ] as [String: Any]
        }
        return links
    }

    /// The review's file for a one-line edit to `page`'s middle non-blank
    /// line, as the review payload carries one; nil for a page with none.
    static func reviewFile(for page: WikiPage, links: [String: Any]) -> [String: Any]? {
        var lines = page.body.components(separatedBy: "\n")
        let nonBlank = lines.indices.filter { line in lines[line].contains { !$0.isWhitespace } }
        guard !nonBlank.isEmpty else { return nil }
        let edited = nonBlank[nonBlank.count / 2]
        lines[edited] += " (edited)"
        let hunk: [String: [Int]] = ["old": [edited, edited + 1], "new": [edited, edited + 1]]
        return [
            "id": "f", "path": page.path, "status": "modified", "isMarkdown": true,
            "old": page.body, "new": lines.joined(separator: "\n"),
            "bodyLine": ["old": 1, "new": 1], "hunks": [hunk], "flags": [String](), "links": links,
        ]
    }

    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Renders

    /// The two orders a page is rendered again in.
    enum Order: String, CaseIterable {
        case eachTwice = "each page twice in a row"
        case corpusTwice = "the whole corpus twice"
    }

    /// One run of an order: the corpus's first renders and its renders
    /// again, summed, and the longest page's.
    struct Run {
        var first = Duration.zero
        var again = Duration.zero
        var longestFirst = Duration.zero
        var longestAgain = Duration.zero

        mutating func add(first: Duration, again: Duration, isLongest: Bool) {
            self.first += first
            self.again += again
            if isLongest {
                longestFirst = first
                longestAgain = again
            }
        }
    }

    @Test("every page through CCwiki.render, first and again, in both orders")
    func renders() throws {
        guard let source = IncrementalCorpusTests.source else { return }
        let corpus = try Self.corpus(in: source)
        let pages = corpus.pages
        let longest = pages.firstIndex { $0.path == Self.longest }
        func ms(_ duration: Duration) -> String { LoadTimings.format(duration) }
        var lines: [String] = []
        var unlike: [String] = []
        var unlikeAcrossOrders: [String] = []
        var firstHTML: [String] = []
        // A render that throws is caught and shown as a notice, so a broken
        // renderer would render every page the same twice: these say it ran.
        var failed: Set<String> = []
        var withKaTeX = 0

        for order in Order.allCases {
            var runs: [Run] = []
            for attempt in 0..<3 {
                let script = try Self.freshScript()
                for page in pages { try Self.call(script, "addPage", [page.payload, page.warmUp]) }
                for i in pages.indices { try Self.call(script, "warmAt", [i]) }

                var run = Run()
                var again: [Bool] = []
                switch order {
                case .eachTwice:
                    for i in pages.indices {
                        let first = try Self.timedCall(script, "renderAt", [i])
                        try Self.call(script, "keep", [i])
                        let second = try Self.timedCall(script, "renderAt", [i])
                        run.add(first: first, again: second, isLongest: i == longest)
                        again.append(try Self.call(script, "same", [i])?.toBool() == true)
                    }
                case .corpusTwice:
                    var firsts: [Duration] = []
                    for i in pages.indices {
                        firsts.append(try Self.timedCall(script, "renderAt", [i]))
                        try Self.call(script, "keep", [i])
                    }
                    for i in pages.indices {
                        let second = try Self.timedCall(script, "renderAt", [i])
                        run.add(first: firsts[i], again: second, isLongest: i == longest)
                        again.append(try Self.call(script, "same", [i])?.toBool() == true)
                    }
                }
                runs.append(run)
                guard attempt == 0 else { continue }

                for i in pages.indices where !again[i] {
                    unlike.append("\(order.rawValue): \(pages[i].path)")
                }
                let html = try pages.indices.map { i in
                    try Self.call(script, "firstHTML", [i])?.toString() ?? ""
                }
                for i in pages.indices where html[i].hasPrefix(Self.renderFailed) {
                    failed.insert(pages[i].path)
                }
                withKaTeX = html.count(where: { $0.contains(Self.katexOutput) })
                if firstHTML.isEmpty {
                    firstHTML = html
                } else {
                    for i in pages.indices where html[i] != firstHTML[i] {
                        unlikeAcrossOrders.append(pages[i].path)
                    }
                }
            }
            func fastest(_ figure: (Run) -> Duration) -> String {
                ms(runs.map(figure).min() ?? .zero)
            }
            var line = "\(order.rawValue): first \(fastest(\.first)), again \(fastest(\.again))"
            if longest != nil {
                line += "; \(Self.longest) first \(fastest(\.longestFirst)), "
                    + "again \(fastest(\.longestAgain))"
            }
            lines.append(line)
        }

        #expect(failed.isEmpty, "every page renders: \(failed.sorted().prefix(10))")
        #expect(withKaTeX > 0, "KaTeX renders the wiki's math")
        #expect(unlike.isEmpty, "a page renders the same the second time: \(unlike.prefix(10))")
        #expect(unlikeAcrossOrders.isEmpty,
                "a page's first render is the same in either order: \(unlikeAcrossOrders.prefix(10))")
        lines.append("\(pages.count - failed.count) of \(pages.count) pages rendered, "
            + "\(withKaTeX) with KaTeX's output, \(failed.count) failed")
        lines.append(unlike.isEmpty && unlikeAcrossOrders.isEmpty
            ? "every page rendered the same the second time, and the same in either order"
            : "\(unlike.count) pages rendered differently the second time, "
                + "\(unlikeAcrossOrders.count) differently in the other order")
        print("The renderer on the real wiki in JavaScriptCore (plans/efficiency.md §2.3): "
            + "\(pages.count) pages through CCwiki.render with the real KaTeX and no pseudocode.js, "
            + "the fastest of 3 runs, each in a fresh context warmed under another macro table, "
            + "\(IncrementalCorpusTests.measuredOn(source)):\n"
            + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    // MARK: The review

    @Test("reviewEntries for a one-line edit to every page")
    func reviews() throws {
        guard let source = IncrementalCorpusTests.source else { return }
        let corpus = try Self.corpus(in: source)
        let files = corpus.pages.compactMap { page in page.review.map { (path: page.path, file: $0) } }
        var totals: [Duration] = []
        var longest: [Duration] = []
        var entries = 0
        var shown = 0
        var withKaTeX = 0

        for attempt in 0..<3 {
            let script = try Self.freshScript()
            for file in files { try Self.call(script, "addReview", [file.file]) }
            try Self.call(script, "useReviewMacros", [corpus.warmUpMacros])
            for i in files.indices { try Self.call(script, "reviewAt", [i]) }
            try Self.call(script, "useReviewMacros", [corpus.macros])

            var total = Duration.zero
            var count = 0
            let clock = ContinuousClock()
            for i in files.indices {
                let start = clock.now
                let value = try Self.call(script, "reviewAt", [i])
                let duration = start.duration(to: clock.now)
                total += duration
                if files[i].path == Self.longest { longest.append(duration) }
                count += Int(value?.toInt32() ?? 0)
            }
            totals.append(total)
            if attempt == 0 {
                entries = count
                let withHTML = try Self.call(script, "reviewHTMLCount", [""])
                shown = Int(withHTML?.toInt32() ?? 0)
                let math = try Self.call(script, "reviewHTMLCount", [Self.katexOutput])
                withKaTeX = Int(math?.toInt32() ?? 0)
            }
        }

        #expect(entries >= files.count, "every edited page has at least its edit to show")
        // A block that fails to render shows its lines, and a formula that
        // fails shows its source, so a broken renderer still makes entries.
        #expect(withKaTeX > 0, "KaTeX renders the review's math")
        var line = "reviewEntries, a one-line edit to the middle non-blank line of each of "
            + "\(files.count) pages: \(LoadTimings.format(totals.min() ?? .zero)) "
            + "(\(entries) entries, \(shown) with HTML, \(withKaTeX) with KaTeX's output)"
        if let fastest = longest.min() {
            line += "; \(Self.longest) \(LoadTimings.format(fastest))"
        }
        print("The review on the real wiki in JavaScriptCore (plans/efficiency.md §2.3), the fastest "
            + "of 3 runs, each in a fresh context warmed under another macro table, "
            + "\(IncrementalCorpusTests.measuredOn(source)):\n  " + line)
    }
}
