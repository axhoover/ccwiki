import Foundation
import Testing
@testable import CCwiki

/// Find on Page's "3 of 17": what the find bar says, and how `ccwiki.js`
/// counts. The counting runs in JavaScriptCore, over a stand-in for the
/// DOM with what the count reads, and a selection where `WKWebView.find`
/// leaves one.
@Suite struct FindCountTests {

    // MARK: - The bar's words

    @Test("the bar says which match, or how many, or that there is none")
    func labels() {
        #expect(FindCount.label(found: true, count: FindCount(total: 17, current: 3)) == "3 of 17")
        #expect(FindCount.label(found: true, count: FindCount(total: 17, current: 0)) == "17 matches")
        #expect(FindCount.label(found: true, count: FindCount(total: 1, current: 0)) == "1 match")
        #expect(FindCount.label(found: true, count: FindCount(total: 1, current: 1)) == "1 of 1")
        #expect(FindCount.label(found: false, count: nil) == "No matches")
        #expect(FindCount.label(found: false, count: FindCount(total: 2, current: 0)) == "No matches",
            "find found nothing, whatever the page counted")
        #expect(FindCount.label(found: true, count: nil) == nil,
            "a page that could not count says nothing")
        #expect(FindCount.label(found: true, count: FindCount(total: 0, current: 0)) == nil,
            "a match the page did not count is not called none")
    }

    @Test("the page's answer is read whole or not at all")
    func json() {
        #expect(FindCount(json: #"{"total":17,"current":3}"#) == FindCount(total: 17, current: 3))
        #expect(FindCount(json: #"{"current":0,"total":2}"#) == FindCount(total: 2, current: 0))
        #expect(FindCount(json: "null") == nil)
        #expect(FindCount(json: #"{"total":2}"#) == nil)
        #expect(FindCount(json: #"{"total":2,"current":3}"#) == nil, "a place past the total")
        #expect(FindCount(json: #"{"total":-1,"current":0}"#) == nil)
    }

    // MARK: - Counting on the page

    /// A stand-in for the DOM the count reads. `h(tag, attributes, …)`
    /// makes an element whose children are elements or strings, which
    /// become text nodes. `getComputedStyle` knows a tag's display, that
    /// `pre` keeps its spaces, that `.katex-mathml` is out of the flow and
    /// clipped (katex.min.css), and two ways to hide a box. `page(…)` puts
    /// a body in the document, and `select(…)` makes the selection, as
    /// `WKWebView.find` leaves it on its match.
    static let dom = #"""
        var MATHML = { math: 1, semantics: 1, mrow: 1, mi: 1, mn: 1, mo: 1, annotation: 1 };
        var DISPLAY = {
          body: "block", div: "block", p: "block", pre: "block",
          table: "table", tr: "table-row", td: "table-cell", script: "none",
          math: "math", semantics: "math", mrow: "math", mi: "math", mn: "math",
          mo: "math", annotation: "math",
        };
        var CLASS_STYLE = {
          "katex-mathml": { position: "absolute" },
          "byline": { display: "none" },
          "veiled": { visibility: "hidden" },
        };
        function h(tag, attributes) {
          var element = {
            nodeType: 1,
            nodeName: MATHML[tag] ? tag : tag.toUpperCase(),
            className: (attributes && attributes["class"]) || "",
            parentNode: null, firstChild: null, lastChild: null, nextSibling: null,
          };
          element.classList = {
            contains: function (name) {
              return (" " + element.className + " ").indexOf(" " + name + " ") >= 0;
            },
          };
          for (var i = 2; i < arguments.length; i++) {
            var child = arguments[i];
            if (typeof child === "string") child = { nodeType: 3, data: child, nextSibling: null };
            child.parentNode = element;
            if (element.lastChild) element.lastChild.nextSibling = child;
            else element.firstChild = child;
            element.lastChild = child;
          }
          return element;
        }
        function getComputedStyle(element) {
          var parent = element.parentNode ? getComputedStyle(element.parentNode) : null;
          var tag = element.nodeName.toLowerCase();
          var style = {
            display: DISPLAY[tag] || "inline", position: "static", cssFloat: "none",
            visibility: parent ? parent.visibility : "visible",
            whiteSpace: tag === "pre" ? "pre" : (parent ? parent.whiteSpace : "normal"),
          };
          element.className.split(" ").forEach(function (name) {
            var rules = CLASS_STYLE[name] || {};
            for (var key in rules) style[key] = rules[key];
          });
          return style;
        }
        var selection = null;
        getSelection = function () { return selection; };
        function page() {
          var children = Array.prototype.slice.call(arguments);
          document.body = h.apply(null, ["body", null].concat(children));
          selection = null;
        }
        function select(startNode, startOffset, endNode, endOffset) {
          selection = {
            rangeCount: 1,
            isCollapsed: false,
            getRangeAt: function () {
              return {
                startContainer: startNode, startOffset: startOffset,
                endContainer: endNode, endOffset: endOffset,
              };
            },
          };
        }
        """#

    /// `ccwiki.js` over the render tests' shell, then the stand-in DOM.
    private func script() throws -> MarkdownScript {
        let script = try MarkdownScript.load()
        try script.evaluate(RenderCorpusTests.shell, named: "shell.js")
        let source = try String(
            contentsOf: MarkdownScript.webRoot.appending(path: "ccwiki.js"), encoding: .utf8)
        try script.evaluate(source, named: "ccwiki.js")
        try script.evaluate(Self.dom, named: "dom.js")
        return script
    }

    /// `CCwiki.findCount(needle)` on the page `script` built last.
    private func count(_ needle: String, _ script: MarkdownScript) throws -> FindCount? {
        let value = try script.evaluate("CCwiki.findCount(\(MarkdownScript.literal(needle)));")
        guard let json = value?.toString() else { return nil }
        return FindCount(json: json)
    }

    @Test("plain text: every match, one inside a longer word too")
    func plainText() throws {
        let script = try script()
        try script.evaluate(#"page(h("p", null, "A cat and a cat. Concatenate."));"#)
        #expect(try count("cat", script) == FindCount(total: 3, current: 0))
        #expect(try count("dog", script) == FindCount(total: 0, current: 0))
        #expect(try count("", script) == FindCount(total: 0, current: 0))

        try script.evaluate(#"page(h("p", null, "aaaa"));"#)
        #expect(try count("aa", script) == FindCount(total: 2, current: 0),
            "matches do not overlap: find steps on from the end of one")
    }

    @Test("case, accents, quotes and ligatures fold as find folds them")
    func folding() throws {
        let script = try script()
        try script.evaluate(#"page(h("p", null, "PRF, prf and Prf; a café, a cafe"));"#)
        #expect(try count("prf", script) == FindCount(total: 3, current: 0))
        #expect(try count("PRF", script) == FindCount(total: 3, current: 0))
        #expect(try count("cafe", script) == FindCount(total: 2, current: 0),
            "a needle without an accent finds the word with one")
        #expect(try count("café", script) == FindCount(total: 1, current: 0),
            "a needle with an accent finds only the word with it")

        try script.evaluate(#"page(h("p", null, "don’t “quote” ﬁnd x² soft­hyphen"));"#)
        #expect(try count("don't", script) == FindCount(total: 1, current: 0))
        #expect(try count("\"quote\"", script) == FindCount(total: 1, current: 0))
        #expect(try count("find", script) == FindCount(total: 1, current: 0))
        #expect(try count("x2", script) == FindCount(total: 1, current: 0))
        #expect(try count("softhyphen", script) == FindCount(total: 1, current: 0))
    }

    @Test("a match runs across inline elements and collapsed spaces")
    func acrossInlineElements() throws {
        let script = try script()
        try script.evaluate(#"""
            var em = h("em", null, "random");
            var paragraph = h("p", null, "pseudo", em, " functions");
            page(paragraph);
            """#)
        #expect(try count("pseudorandom", script) == FindCount(total: 1, current: 0))
        #expect(try count("random functions", script) == FindCount(total: 1, current: 0))
        try script.evaluate("select(paragraph.firstChild, 0, em.firstChild, 6);")
        #expect(try count("pseudorandom", script) == FindCount(total: 1, current: 1),
            "a match spanning <em> is placed by where its selection starts and ends")

        try script.evaluate(#"page(h("p", null, "one\n", h("em", null, "two"), "  three"));"#)
        #expect(try count("one two three", script) == FindCount(total: 1, current: 0))
    }

    @Test("a block, a line break or a table cell ends a run")
    func blocks() throws {
        let script = try script()
        try script.evaluate(#"page(h("p", null, "end"), "\n", h("p", null, "start"));"#)
        #expect(try count("endstart", script) == FindCount(total: 0, current: 0))
        #expect(try count("end start", script) == FindCount(total: 0, current: 0))
        #expect(try count("end", script) == FindCount(total: 1, current: 0))

        try script.evaluate(#"page(h("p", null, "line", h("br", null), "break"));"#)
        #expect(try count("line break", script) == FindCount(total: 0, current: 0))

        try script.evaluate(#"""
            page(h("table", null, h("tr", null, h("td", null, "left"), h("td", null, "right"))));
            """#)
        #expect(try count("leftright", script) == FindCount(total: 0, current: 0))
    }

    @Test("text that is not shown is not counted")
    func hiddenText() throws {
        let script = try script()
        try script.evaluate(#"""
            page(
              h("div", { "class": "byline" }, "needle"),
              h("p", { "class": "veiled" }, "needle"),
              h("script", null, "needle"),
              h("p", null, "needle"));
            """#)
        #expect(try count("needle", script) == FindCount(total: 1, current: 0))
    }

    /// The page's own math, rendered `output: "html"`: KaTeX's HTML, and no
    /// MathML.
    @Test("a match in a formula is counted, and the count gives only the total")
    func mathWithoutMathML() throws {
        let script = try script()
        try script.evaluate(#"""
            var prose = h("p", null, "Enc and ",
              h("span", { "class": "math" },
                h("span", { "class": "katex" },
                  h("span", { "class": "katex-html" },
                    h("span", { "class": "mord mathsf" }, "Enc")))));
            page(prose);
            select(prose.firstChild, 0, prose.firstChild, 3);
            """#)
        #expect(try count("Enc", script) == FindCount(total: 2, current: 0),
            "the selected match is in prose, but another is in a formula")
        try script.evaluate("select(prose.firstChild, 4, prose.firstChild, 7);")
        #expect(try count("and", script) == FindCount(total: 1, current: 1),
            "a needle with no match in a formula keeps its place")
    }

    /// Pseudocode's math, in KaTeX's default output: MathML clipped out of
    /// sight, which find reads, with its TeX annotation, which `<semantics>`
    /// does not render, then the HTML.
    @Test("pseudocode's MathML is counted, and its TeX annotation is not")
    func mathWithMathML() throws {
        let script = try script()
        try script.evaluate(#"""
            page(h("p", null, "Return ",
              h("span", { "class": "katex" },
                h("span", { "class": "katex-mathml" },
                  h("math", null,
                    h("semantics", null,
                      h("mrow", null, h("mi", null, "E"), h("mi", null, "n"), h("mi", null, "c")),
                      h("annotation", null, "\\mathsf{Enc}")))),
                h("span", { "class": "katex-html" },
                  h("span", { "class": "mord mathsf" }, "Enc")))));
            """#)
        #expect(try count("Enc", script) == FindCount(total: 2, current: 0),
            "once in the MathML and once in the HTML, as find reads it")
        #expect(try count("mathsf", script) == FindCount(total: 0, current: 0),
            "the annotation is not rendered, so not read")
        #expect(try count("Return", script) == FindCount(total: 1, current: 0))
    }

    @Test("a code block keeps its spaces and its line breaks")
    func codeBlocks() throws {
        let script = try script()
        try script.evaluate(#"page(h("pre", null, h("code", null, "x  =  1\ny = 2\n")));"#)
        #expect(try count("x  =", script) == FindCount(total: 1, current: 0))
        #expect(try count("x = 1", script) == FindCount(total: 0, current: 0))
        #expect(try count("1 y", script) == FindCount(total: 0, current: 0))
        #expect(try count("y = 2", script) == FindCount(total: 1, current: 0))
    }

    @Test("the selected match is placed among the others")
    func indexAfterSelection() throws {
        let script = try script()
        try script.evaluate(#"""
            var words = h("p", null, "one cat, two cats, three cats");
            page(words);
            select(words.firstChild, 13, words.firstChild, 16);
            """#)
        #expect(try count("cat", script) == FindCount(total: 3, current: 2))
        try script.evaluate("select(words.firstChild, 14, words.firstChild, 17);")
        #expect(try count("cat", script) == FindCount(total: 3, current: 0),
            "a selection that is not a match places none")

        try script.evaluate(#"""
            var cat = h("em", null, "cat");
            var sentence = h("p", null, "a ", cat, " and a cat");
            page(sentence);
            select(sentence.firstChild, 2, cat.firstChild, 3);
            """#)
        #expect(try count("cat", script) == FindCount(total: 2, current: 1),
            "a selection may start at the end of the text before its match")
        try script.evaluate("select(sentence.lastChild, 7, sentence.lastChild, 10);")
        #expect(try count("cat", script) == FindCount(total: 2, current: 2))
        #expect(try count("CAT", script) == FindCount(total: 2, current: 2))
    }
}
