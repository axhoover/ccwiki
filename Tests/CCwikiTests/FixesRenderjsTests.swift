import Foundation
import Testing
@testable import CCwiki

/// The reader's Markdown, closer to the site's: a wikilink in a table, a
/// table in a code block, a link's text decoded and educated, the site's
/// dashes, ellipses and arrows, callouts and their markers, `%%` comments,
/// and how a Game block groups
/// (`ccwiki-markdown.js`, `ccwiki.js`; plans/render-pipeline.md §3).
@Suite("Renderer parity fixes")
struct FixesRenderjsTests {

    /// What Swift resolves the links below to, keyed as it keys them: by
    /// the link as written.
    private static var links: [String: Any] {
        [
            "[[pseudorandom-function|PRF]]": ["href": "/prf", "kind": "page"],
            "[[one-way-function|OWF]]": ["href": "/owf", "kind": "page"],
            #"[[pseudorandom-function\|PRF]]"#: ["href": "/prf-escaped", "kind": "page"],
            "[[pseudorandom-function#Security]]": ["href": "/prf#security", "kind": "page"],
            "[[merkle-puzzles|Merkle's puzzles]]": ["href": "/merkle", "kind": "page"],
            #"[[symmetric-key-encryption#ind-cpa-security|IND\$-CPA]]"#: ["href": "/ske", "kind": "page"],
            "[[x|AT&amp;T]]": ["href": "/x", "kind": "page"],
            "[[x|a -> b]]": ["href": "/x", "kind": "page"],
        ]
    }

    /// `markdown` rendered as the reader renders a page, with `links`.
    private func render(_ markdown: String) throws -> String {
        let script = try MarkdownScript.load()
        let call = "md.render(\(MarkdownScript.literal(markdown)), "
            + "{ links: \(MarkdownScript.literal(Self.links)) });"
        guard let html = try script.evaluate(call)?.toString() else {
            throw MarkdownScript.Failure(description: "No HTML.")
        }
        return html
    }

    // MARK: Wikilinks in a table

    @Test("aliased wikilinks in a table cell stay whole: two cells, two links")
    func aliasedLinksInTable() throws {
        let html = try render("""
            | Primitive | Implied by |
            | --------- | ---------- |
            | [[pseudorandom-function|PRF]] | [[one-way-function|OWF]] |
            """)
        #expect(html.contains(#"<td><a class="internal" href="/prf">PRF</a></td>"#))
        #expect(html.contains(#"<td><a class="internal" href="/owf">OWF</a></td>"#))
        #expect(!html.contains("[["))
        let rows = StampedBlock.all(in: html).filter { $0.tag == "tr" }.map(\.lines)
        #expect(rows == [0..<1, 2..<3], "the escape adds no line")
    }

    @Test("in a table, an escaped alias keeps its key and math keeps its \\|")
    func escapedPipesInTable() throws {
        let html = try render(#"""
            | Link | Norm |
            | ---- | ---- |
            | [[pseudorandom-function\|PRF]] | $\|x\|$ |
            | `a\|b` | x |
            """#)
        #expect(html.contains(#"<td><a class="internal" href="/prf-escaped">PRF</a></td>"#))
        #expect(html.contains(#"data-tex="\|x\|""#), "the site's KaTeX gets ‖x‖")
        #expect(html.contains("<td><code>a|b</code></td>"), "code loses the backslash, as on the site")
    }

    @Test("a table in fenced code reads as on the site: its escapes and math as written")
    func tableInFence() throws {
        let html = try render(#"""
            ```text
            | A | B |
            | --- | --- |
            | $\|x\|$ | [[a\|b]] |
            | [[a|b]] | [[p#h|q]] |
            ```

            | Link | Norm |
            | ---- | ---- |
            | [[pseudorandom-function|PRF]] | $\|x\|$ |
            """#)
        #expect(html.contains(#"| $\|x\|$ | [[a\|b]] |"#), "byte for byte")
        #expect(html.contains(##"| [[a\|b]] | [[p\#h\|q]] |"##),
                "the site's own escapes, which its code block shows")
        #expect(!html.contains(#"\\|"#))
        #expect(html.contains(#"<td><a class="internal" href="/prf">PRF</a></td>"#),
                "a table outside the fence is still rewritten")
        #expect(html.contains(#"<td><span class="math" data-tex="\|x\|">"#))
    }

    @Test("[[page#Heading]] shows the heading; in a table, the page, as the site does")
    func anchoredLinkText() throws {
        let html = try render("""
            See [[pseudorandom-function#Security]].

            | Link | Note |
            | ---- | ---- |
            | [[pseudorandom-function#Security]] | x |
            """)
        #expect(html.contains(#"See <a class="internal" href="/prf#security">Security</a>."#))
        #expect(html.contains(
            #"<td><a class="internal" href="/prf#security">pseudorandom-function</a></td>"#))
        #expect(!html.contains("›"))
    }

    // MARK: A link's text

    @Test("a wikilink's alias is shown decoded: escapes and entities")
    func decodedAlias() throws {
        let html = try render(#"""
            Is [[symmetric-key-encryption#ind-cpa-security|IND\$-CPA]] and [[x|AT&amp;T]].
            """#)
        #expect(html.contains(#"<a class="internal" href="/ske">IND$-CPA</a>"#))
        #expect(html.contains(#"<a class="internal" href="/x">AT&amp;T</a>"#))
        #expect(!html.contains(#"IND\$"#))
    }

    // MARK: Typography

    @Test("smartypants' dashes, ellipses and LaTeX quotes, and nothing else markdown-it would replace")
    func typography() throws {
        let html = try render("""
            3. (c) The first constructions

            ideal lattices -- lattices arising, robustness --- that, wait... and a..b +-

            In [[merkle-puzzles|Merkle's puzzles]] and Merkle's puzzles.

            A simpler ``toy conjecture'' variant.
            """)
        #expect(html.contains("(c) The first constructions"))
        #expect(html.contains("ideal lattices — lattices arising"))
        #expect(html.contains("robustness --- that"))
        #expect(html.contains("wait… and a..b +-"))
        #expect(html.contains("A simpler “toy conjecture” variant."))
        #expect(html.contains(#"<a class="internal" href="/merkle">Merkle’s puzzles</a> and Merkle’s puzzles."#))
        #expect(!html.contains("©") && !html.contains("–") && !html.contains("±"))

        let script = try MarkdownScript.load()
        let card = try script.evaluate(
            #"CCwikiMarkdown.createPreview({}).renderInline("a -- b, (c) -> c...");"#)?.toString()
        #expect(card == "a — b, (c) → c…", "a preview card has the page's typography")
    }

    @Test("OFM's arrows, in text and a link's text, never in math or code")
    func arrows() throws {
        let html = try render(#"""
            e: G_k -> G_T, a <= b, x <-- y, a ==> b, $x -> y$ and `a -> b`, [[x|a -> b]].
            """#)
        #expect(html.contains("e: G_k → G_T, a ⇐ b, x ⇐ y, a ⇒ b, "))
        #expect(html.contains(#"data-tex="x -&gt; y""#))
        #expect(html.contains("<code>a -&gt; b</code>"))
        #expect(html.contains(#"<a class="internal" href="/x">a → b</a>"#))
    }

    // MARK: Callouts

    @Test("a callout's title is its first line, and the lines after it its body")
    func calloutBody() throws {
        let html = try render("""
            > [!note] Remember
            > The key is secret.

            > [!caution]
            > Body here.
            """)
        #expect(html.contains(#"<div class="callout callout-note" data-source-lines="0-2">"#))
        #expect(html.contains(#"<div class="callout-title" data-source-lines="0-1">Remember</div>"#))
        #expect(html.contains(#"<p data-source-lines="1-2">The key is secret.</p>"#))
        #expect(html.contains(#"<div class="callout callout-warning" data-source-lines="3-5">"#),
                "caution is a warning")
        #expect(html.contains(#"<div class="callout-title" data-source-lines="3-4">Caution</div>"#))
        #expect(html.contains(#"<p data-source-lines="4-5">Body here.</p>"#))
    }

    @Test("a callout's title keeps its math and links, and its marker may carry metadata")
    func calloutTitle() throws {
        let html = try render(#"""
            > [!tip] Reading $\calA$ and [[one-way-function|OWF]]

            > [!summary|wide]
            > Text.
            """#)
        #expect(html.contains(#"<div class="callout-title" data-source-lines="0-1">Reading "#
            + #"<span class="math" data-tex="\calA">"#))
        #expect(html.contains(#"<a class="internal" href="/owf">OWF</a></div>"#))
        #expect(html.contains(#"<div class="callout callout-abstract""#))
        #expect(html.contains(#"<div class="callout-title" data-source-lines="2-3">Summary</div>"#))
    }

    @Test("a callout's marker runs to the first ] of the site's text node, as ofm.ts's regex does")
    func calloutMarker() throws {
        let html = try render("""
            > [!note] As shown in [HLL23], the bound holds.

            > [!note] Proof that [[one-way-function|OWF]] suffices [KL14]

            > [!tip] Remember this

            > [!note|wide] A wide one

            > [!note] A -> B [x]
            """)
        #expect(html.contains(#"<div class="callout-title" data-source-lines="0-1">, the bound holds.</div>"#),
                "the site takes `] As shown in [HLL23` for metadata")
        #expect(html.contains(#"<div class="callout-title" data-source-lines="2-3">Proof that "#
            + #"<a class="internal" href="/owf">OWF</a> suffices [KL14]</div>"#),
                "a link ends the site's text node, so the marker ends at its own ]")
        #expect(html.contains(#"<div class="callout callout-tip" data-source-lines="4-5">"#))
        #expect(html.contains(#"<div class="callout-title" data-source-lines="4-5">Remember this</div>"#))
        #expect(html.contains(#"<div class="callout-title" data-source-lines="6-7">A wide one</div>"#),
                "metadata after a | is not the title")
        #expect(html.contains(#"<div class="callout-title" data-source-lines="8-9">A → B [x]</div>"#),
                "OFM's arrow splits the site's text node too")
    }

    // MARK: Comments

    @Test("%% comments are gone, with their links, and every block keeps its lines")
    func comments() throws {
        let html = try render("""
            Visible text. %% TODO: cite [[GGM86 - How to construct random functions|GGM86]] %% More.

            Intro %% a draft

            ## Hidden heading
            %% after.

            Last.

            %% a note
            that ends here %% Text after.
            """)
        #expect(html.contains(#"<p data-source-lines="0-1">Visible text.  More.</p>"#))
        #expect(!html.contains("broken") && !html.contains("TODO") && !html.contains("Hidden"))
        #expect(html.contains(#"<p data-source-lines="2-6">Intro  after.</p>"#))
        #expect(html.contains(#"<p data-source-lines="7-8">Last.</p>"#))
        #expect(html.contains(#"<p data-source-lines="9-11">Text after.</p>"#), "a paragraph, not code")
        #expect(!html.contains("<pre"))
    }

    // MARK: Games

    /// Just enough of a document for `CCwiki.render` and `groupGames`: a
    /// page whose `innerHTML` becomes one element per block, each fence a
    /// `pre.pseudocode` and anything else a `p`; elements that move, and
    /// know their parent and their previous sibling; and a `pseudocode`
    /// that renders nothing. `layout()` reads the page back: each box as its
    /// `\algname`, `(none)` without one, and a group as a list.
    private static let documentShell = #"""
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
        function El(tag) {
          var self = this;
          this.tagName = tag.toUpperCase();
          this.children = [];
          this.parentNode = null;
          this.attributes = {};
          this.className = "";
          this.textContent = "";
          this.style = { setProperty: function () {} };
          this.classList = {
            add: function (name) { self.className = (self.className + " " + name).trim(); },
            remove: function () {},
            contains: function (name) { return (" " + self.className + " ").indexOf(" " + name + " ") >= 0; },
          };
        }
        El.prototype.getAttribute = function (name) {
          return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
        };
        El.prototype.setAttribute = function (name, value) { this.attributes[name] = String(value); };
        El.prototype.hasAttribute = function (name) {
          return Object.prototype.hasOwnProperty.call(this.attributes, name);
        };
        El.prototype.removeAttribute = function (name) { delete this.attributes[name]; };
        El.prototype.addEventListener = function () {};
        El.prototype.detach = function () {
          if (!this.parentNode) return;
          var siblings = this.parentNode.children;
          siblings.splice(siblings.indexOf(this), 1);
          this.parentNode = null;
        };
        El.prototype.insertBefore = function (node, before) {
          node.detach();
          var at = before ? this.children.indexOf(before) : this.children.length;
          this.children.splice(at, 0, node);
          node.parentNode = this;
          return node;
        };
        El.prototype.appendChild = function (node) { return this.insertBefore(node, null); };
        El.prototype.replaceWith = function (node) {
          this.parentNode.insertBefore(node, this);
          this.detach();
        };
        Object.defineProperty(El.prototype, "parentElement", { get: function () { return this.parentNode; } });
        Object.defineProperty(El.prototype, "previousElementSibling", {
          get: function () {
            if (!this.parentNode) return null;
            var at = this.parentNode.children.indexOf(this);
            return at > 0 ? this.parentNode.children[at - 1] : null;
          },
        });
        El.prototype.descendants = function () {
          var out = [];
          this.children.forEach(function (child) { out.push(child); out = out.concat(child.descendants()); });
          return out;
        };
        El.prototype.querySelectorAll = function (selector) {
          var match = /^([a-z]*)(?:\.([\w-]+))?$/.exec(selector);
          if (!match) return [];
          return this.descendants().filter(function (el) {
            return (!match[1] || el.tagName === match[1].toUpperCase()) &&
              (!match[2] || el.classList.contains(match[2]));
          });
        };
        El.prototype.querySelector = function (selector) { return this.querySelectorAll(selector)[0] || null; };
        var page = new El("main");
        Object.defineProperty(page, "innerHTML", {
          set: function (html) {
            page.children = [];
            var blocks = /<pre class="pseudocode"[^>]*>([\s\S]*?)<\/pre>|<p[^>]*>[\s\S]*?<\/p>/g, found;
            while ((found = blocks.exec(html))) {
              var el = new El(found[1] !== undefined ? "pre" : "p");
              if (found[1] !== undefined) { el.className = "pseudocode"; el.textContent = found[1]; }
              page.appendChild(el);
            }
          },
        });
        var document = {
          body: new El("body"),
          getElementById: function (id) { return id === "page" ? page : null; },
          createElement: function (tag) { return new El(tag); },
          querySelector: function () { return null; },
          querySelectorAll: function () { return []; },
          createTreeWalker: function () { return { nextNode: function () { return false; } }; },
          addEventListener: function () {},
        };
        var pseudocode = { renderElement: function () {} };
        function layout() {
          function name(el) {
            if (el.classList.contains("pseudocode-container")) {
              return el.hasAttribute("data-algname") ? el.getAttribute("data-algname") : "(none)";
            }
            return el.tagName.toLowerCase();
          }
          return page.children.map(function (el) {
            if (!el.classList.contains("game-group")) return name(el);
            return [name(el.children[0])].concat(el.children[1].children.map(name));
          });
        }
        """#

    /// A pseudocode fence, with an `\algname` and a `\caption` when given.
    private func block(_ name: String?, caption: String? = "C") -> String {
        var lines = ["```pseudocode", #"\begin{algorithm}"#]
        if let name { lines.append(#"\algname{"# + name + "}") }
        if let caption { lines.append(#"\caption{"# + caption + "}") }
        lines += [#"\begin{algorithmic}"#, #"\State $x$"#, #"\end{algorithmic}"#, #"\end{algorithm}"#, "```", ""]
        return lines.joined(separator: "\n")
    }

    @Test("a Game block groups by \\algname as the site does, never by its caption")
    func gameGroups() throws {
        let script = try MarkdownScript.load()
        try script.evaluate(Self.documentShell, named: "document.js")
        let source = try String(
            contentsOf: MarkdownScript.webRoot.appending(path: "ccwiki.js"), encoding: .utf8)
        try script.evaluate(source, named: "ccwiki.js")

        func layout(_ blocks: [String]) throws -> String {
            let markdown = MarkdownScript.literal(blocks.joined(separator: "\n"))
            try script.evaluate(#"CCwiki.render({ path: "x", links: {}, macros: {}, markdown: "# + markdown + " });")
            return try #require(try script.evaluate("JSON.stringify(layout());")?.toString())
        }

        #expect(try layout([block("Game", caption: nil), block("Oracle")]) == #"[["game","oracle"]]"#,
                "a Game with no caption still groups")
        #expect(try layout([block("Game"), block(nil)]) == #"["game","(none)"]"#,
                "a block with no algname is not an oracle")
        #expect(try layout([block("game"), block("Oracle")]) == #"[["game","oracle"]]"#)
        #expect(try layout([block("Game-1"), block("Oracle")]) == #"["game-1","oracle"]"#)
        #expect(try layout([block(" GAME "), block("Oracle"), block(""), block("Game"), block(nil)])
                == #"[["game","oracle",""],"game","(none)"]"#)
        #expect(try layout([block("Game"), block("Oracle"), "Between.\n", block("Oracle")])
                == #"[["game","oracle"],"p","oracle"]"#, "only adjacent blocks join")
    }
}
