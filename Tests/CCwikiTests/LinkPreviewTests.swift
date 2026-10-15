import Foundation
import Testing
@testable import CCwiki

/// Link previews: the first paragraph a card shows, the inline markdown it is
/// reduced to, where it is cut, what each kind of page's card says, and which
/// links get one (relations-explorer.md §4).
///
/// The synthetic fixtures always run. The corpus checks at the bottom are
/// gated on `CCWIKI_WIKI`, the same way `CorpusTests` is.
struct LinkPreviewTests {

    // MARK: The first paragraph

    @Test("the first paragraph is the one after the H1, its lines joined")
    func afterTheH1() {
        let body = "Text above the title.\n\n# Title\n\nFirst line\nwrapped  here.\n\nSecond."
        let paragraph = PreviewExcerpt.firstParagraph(in: body, anchor: nil)
        #expect(paragraph == "First line wrapped  here.")

        let noH1 = PreviewExcerpt.firstParagraph(in: "\nOnly prose.\n", anchor: nil)
        #expect(noH1 == "Only prose.")

        // A `#` line in fenced code is a comment, not the title.
        let fenced = "```sh\n# not a title\n```\n\nBefore.\n\n# Title\n\nAfter."
        let afterFence = PreviewExcerpt.firstParagraph(in: fenced, anchor: nil)
        #expect(afterFence == "After.")
    }

    @Test("headings, the relation-meta line, the byline and TODOs are skipped")
    func skippedParagraphs() {
        let reduction = "# A ⇒ B\n\n## Statement\n\nIf A holds, B holds."
        let statement = PreviewExcerpt.firstParagraph(in: reduction, anchor: nil)
        #expect(statement == "If A holds, B holds.")

        let spliced = "# A ⇒ B\n\nEquivalence · free reduction " + RelationMeta.marker
            + "\n\nThe statement."
        let afterMeta = PreviewExcerpt.firstParagraph(in: spliced, anchor: nil)
        #expect(afterMeta == "The statement.")

        let reference = "# [K] Title\n\n**Authors:** A | **Venue:** V | [Source](https://x.org)"
            + "\n\n## Abstract\n\nWe show it."
        let abstract = PreviewExcerpt.firstParagraph(in: reference, anchor: nil)
        #expect(abstract == "We show it.")

        let todo = "# Title\n\nTODO: syntax and security definition.\n\nReal prose."
        let afterTodo = PreviewExcerpt.firstParagraph(in: todo, anchor: nil)
        #expect(afterTodo == "Real prose.")

        // A placeholder at the end of a paragraph goes with what follows it.
        let trailing = "# Title\n\nIntroduced by [[DGI+19 - Trapdoor|DGI+19]]. TODO"
        let withoutTodo = PreviewExcerpt.firstParagraph(in: trailing, anchor: nil)
        #expect(withoutTodo == "Introduced by [[DGI+19 - Trapdoor|DGI+19]].")

        // Inside a sentence, TODO is a word: cutting there would show half a
        // sentence as if it were whole.
        let midSentence = "# Title\n\nThere are stubs and TODO, so read on."
        let wholeSentence = PreviewExcerpt.firstParagraph(in: midSentence, anchor: nil)
        #expect(wholeSentence == "There are stubs and TODO, so read on.")

        let onlyTodo = "# Title\n\nTODO — abstract."
        #expect(PreviewExcerpt.firstParagraph(in: onlyTodo, anchor: nil) == nil)
    }

    @Test("fences, display math, lists, tables, quotes, HTML and generated lists are not prose")
    func skippedBlocks() {
        let body = """
            # Title

            ```pseudocode
            \\begin{algorithm}
            # not a heading

            \\end{algorithm}
            ```

            $$
            x = y

            $$

            - a list item
              continued
            - another

            1. ordered

            | A | B |
            |---|---|
            | 1 | 2 |

            Header | Other
            --- | ---

            > A quote, or a callout.
            lazily continued

            <!-- a comment

            over two blocks -->

            <div id="macros-copy-area"></div>

            <!-- BEGIN GENERATED participates-in 1 -->

            ## Participates in

            **Builds on Title**

            Generated prose.

            <!-- END GENERATED participates-in -->

            Setext heading
            ==============

            ---

            ![[diagram.png]]

            [^1]: A footnote.

            **A bold label**

            The prose, at last.
            """
        let paragraph = PreviewExcerpt.firstParagraph(in: body, anchor: nil)
        #expect(paragraph == "The prose, at last.")
    }

    @Test("an anchor scopes the paragraph to its section, the first heading with the id winning")
    func anchorScope() {
        let body = """
            # Page

            Intro.

            ## Syntax

            First syntax.

            ## Variants

            ### Weak

            Weak prose.

            ## Syntax

            Second syntax.
            """
        let first = PreviewExcerpt.firstParagraph(in: body, anchor: "syntax")
        let second = PreviewExcerpt.firstParagraph(in: body, anchor: "syntax-1")
        let nested = PreviewExcerpt.firstParagraph(in: body, anchor: "variants")
        let missing = PreviewExcerpt.firstParagraph(in: body, anchor: "nowhere")
        #expect(first == "First syntax.")
        #expect(second == "Second syntax.")
        #expect(nested == "Weak prose.")
        #expect(missing == nil)

        // A section with no prose of its own does not borrow the next one's.
        let empty = PreviewExcerpt.firstParagraph(in: "## A\n\n- item\n\n## B\n\nB prose.", anchor: "a")
        #expect(empty == nil)

        let scope = PreviewExcerpt.scope(of: body, anchor: "page")
        #expect(scope?.isWholePage == true)
        #expect(scope?.heading == "Page")
    }

    // MARK: Inline markdown

    @Test("links become what they show; math, emphasis and code stay")
    func inlineWithoutLinks() {
        let wikilinks = PreviewExcerpt.inlineWithoutLinks(
            "See [[pseudorandom-generator|PRGs]], [[one-way-function]] and "
                + "[[Primitives/hash-function#collision-resistance]].")
        #expect(wikilinks == "See PRGs, one-way-function and collision-resistance.")

        // As the page shows them: an alias decoded, a heading with one `#` off.
        let decoded = PreviewExcerpt.inlineWithoutLinks(
            #"[[x|IND\$-CPA]], [[x|AT&amp;T]], [[a/b##Two]] and [[p|]]."#)
        #expect(decoded == #"IND\$-CPA, AT\&T, #Two and p."#)

        let markdownLink = PreviewExcerpt.inlineWithoutLinks(
            "The [$k$-Lin](bilinear-map-assumptions#k-linear) and [IR89](<IR89 - Limits>) results.")
        #expect(markdownLink == "The $k$-Lin and IR89 results.")

        let dropped = PreviewExcerpt.inlineWithoutLinks(
            "A ![[diagram.png]] B ![alt](x.png) C[^1] <sup>2</sup> D <!-- note --> E")
        #expect(dropped == "A B C 2 D E")

        let kept = PreviewExcerpt.inlineWithoutLinks(
            "Given $[x] < y$, **bold** and _it_ and `[[code]]`, \\$5.")
        #expect(kept == "Given $[x] < y$, **bold** and _it_ and `[[code]]`, \\$5.")

        // A wikilink's text shows as written on the page, so it is escaped.
        let alias = PreviewExcerpt.inlineWithoutLinks("[[x|a*b_c $d]]")
        #expect(alias == "a\\*b\\_c \\$d")

        let lines = PreviewExcerpt.inlineWithoutLinks("One\n  two\t three")
        #expect(lines == "One two three")
    }

    @Test("plain text for the VoiceOver label")
    func plainText() {
        let plain = PreviewExcerpt.plainText("**Bold** $x^2$ `code` MIP* and \\_x")
        #expect(plain == "Bold x^2 code MIP* and _x")
    }

    // MARK: Truncation

    @Test("a short excerpt is whole; a long one ends at a sentence at or before 280")
    func sentenceCut() {
        let short = "A short paragraph."
        #expect(PreviewExcerpt.truncated(short) == short)

        let first = String(repeating: "word ", count: 30) + "e.g. More of it, end."
        let long = first + " Second sentence " + String(repeating: "more ", count: 60)
        let cut = PreviewExcerpt.truncated(long)
        #expect(cut == first)
        #expect(cut.count <= PreviewExcerpt.softLimit)
    }

    @Test("with no sentence end, the cut is at the last space before 420, with an ellipsis")
    func spaceCut() {
        let long = String(repeating: "word ", count: 120)
        let cut = PreviewExcerpt.truncated(long)
        #expect(cut.hasSuffix("word…"))
        #expect(cut.count <= PreviewExcerpt.hardLimit)

        // A sentence end in the first third of the soft limit loses to the
        // space cut.
        let early = "Short. " + String(repeating: "word ", count: 120)
        let earlyCut = PreviewExcerpt.truncated(early)
        #expect(earlyCut.hasSuffix("…"))
        #expect(earlyCut.count > 300)
    }

    @Test("truncation never splits $…$ or a code span")
    func neverSplitsMath() {
        let math = "$" + String(repeating: "x", count: 40) + "$"
        let long = String(repeating: "a ", count: 200) + math + " tail " + String(repeating: "b ", count: 20)
        let cut = PreviewExcerpt.truncated(long)
        #expect(!cut.contains("$"))
        #expect(cut.hasSuffix("a…"))

        // A period inside math is not a sentence end.
        let inside = String(repeating: "c ", count: 60) + "$a. B$ " + String(repeating: "d ", count: 200)
        let insideCut = PreviewExcerpt.truncated(inside)
        let dollars = insideCut.count(where: { $0 == "$" })
        #expect(dollars % 2 == 0)

        let code = String(repeating: "e ", count: 205) + "`" + String(repeating: "y", count: 30) + "` z"
        let codeCut = PreviewExcerpt.truncated(code)
        #expect(!codeCut.contains("`"))

        let title = String(repeating: "t ", count: 75) + "$" + String(repeating: "q", count: 30) + "$"
        let capped = PreviewExcerpt.capped(title, at: 160)
        #expect(!capped.contains("$"))
        #expect(capped.count <= 160)
    }

    @Test("an emphasis marker the cut leaves open is removed")
    func unclosedEmphasis() {
        let bold = "**" + String(repeating: "bold ", count: 100) + "end**"
        let cut = PreviewExcerpt.truncated(bold)
        #expect(!cut.contains("*"))

        let closed = "**Bold** then " + String(repeating: "word ", count: 100)
        let closedCut = PreviewExcerpt.truncated(closed)
        #expect(closedCut.hasPrefix("**Bold** then"))
    }

    // MARK: Fixture

    static let manifest = RelationsManifest.decode(Data(#"""
        {
          "version": 1,
          "classes": {
            "fully-black-box": { "title": "Fully black-box", "implies": ["relativizing"] },
            "relativizing": { "title": "Relativizing", "implies": ["free"] },
            "free": { "title": "Free", "implies": [] },
            "fixed-construction": { "title": "Fixed construction", "implies": ["free"] }
          },
          "classSentinels": ["unstated"],
          "propositions": {},
          "objects": [
            { "id": "owf", "kind": "object", "type": "primitive",
              "page": "content/Primitives/one-way-function.md", "slug": "one-way-function",
              "title": "One-way function", "aliases": [], "unlisted": false },
            { "id": "prg", "kind": "object", "type": "primitive",
              "page": "content/Primitives/pseudorandom-generator.md",
              "slug": "pseudorandom-generator", "title": "Pseudorandom generator",
              "aliases": [], "unlisted": false },
            { "id": "prg-selective", "kind": "variant", "type": "primitive",
              "page": "content/Primitives/pseudorandom-generator.md",
              "slug": "pseudorandom-generator", "anchor": "#selective-security", "of": "prg",
              "title": "Selective security", "aliases": [], "unlisted": false },
            { "id": "ot", "kind": "object", "type": "primitive",
              "page": "content/Primitives/oblivious-transfer.md", "slug": "oblivious-transfer",
              "title": "Oblivious transfer", "aliases": [], "unlisted": false },
            { "id": "ddh", "kind": "object", "type": "assumption",
              "page": "content/Assumptions/decisional-diffie-hellman.md",
              "slug": "decisional-diffie-hellman", "title": "Decisional Diffie-Hellman",
              "aliases": [], "unlisted": false }
          ],
          "reductions": [
            { "id": "red-ddh-and-owf-to-ot", "kind": "implication",
              "hypotheses": ["ddh", "owf"], "conclusion": "ot", "class": "fully-black-box",
              "model": "rom", "source": ["[[KEY - Paper Title|KEY]]"], "via": [],
              "securityLoss": "", "heuristic": false, "status": "draft",
              "page": "content/Reductions/ddh-and-owf-to-ot.md", "slug": "ddh-and-owf-to-ot",
              "title": "DDH + OWF ⇒ OT" },
            { "id": "red-owf-equiv-prg", "kind": "equivalence", "hypotheses": ["owf"],
              "conclusion": "prg", "class": "free", "model": "standard", "source": ["folklore"],
              "via": [], "securityLoss": "", "heuristic": false, "status": "draft",
              "page": "content/Reductions/owf-equiv-prg.md", "slug": "owf-equiv-prg",
              "title": "OWF ⇔ PRG" },
            { "id": "red-free-owf-to-ot", "kind": "implication", "hypotheses": ["owf"],
              "conclusion": "ot", "class": "free", "model": "standard",
              "source": ["[[BH26 - How to Steal|BH26]]"], "via": [], "securityLoss": "",
              "heuristic": false, "status": "draft",
              "page": "content/Reductions/free-owf-to-ot.md", "slug": "free-owf-to-ot",
              "title": "OWF ⇒ OT (free)" }
          ],
          "barriers": [
            { "id": "bar-owf-to-ot", "hypotheses": ["owf"], "conclusion": "ot",
              "class": "fully-black-box", "consequences": [], "strength": "unconditional",
              "conditionalOn": [], "circumventedBy": ["red-free-owf-to-ot"],
              "source": ["[[IR89 - Limits|IR89]]"], "status": "draft",
              "page": "content/Barriers/no-owf-to-ot.md", "slug": "no-owf-to-ot",
              "title": "No fully-black-box reduction from OWF to OT" },
            { "id": "bar-ddh-to-ot", "hypotheses": ["ddh"], "conclusion": "ot",
              "class": "unstated", "consequences": [], "strength": "conditional",
              "conditionalOn": ["owf"], "circumventedBy": [],
              "source": ["[[IR89 - Limits|IR89]]"], "status": "draft",
              "page": "content/Barriers/no-ddh-to-ot.md", "slug": "no-ddh-to-ot",
              "title": "No reduction from DDH to OT" },
            { "id": "bar-prg-to-ot", "hypotheses": ["prg"], "conclusion": "ot",
              "class": "fixed-construction", "consequences": [], "strength": "unconditional",
              "conditionalOn": [], "circumventedBy": [],
              "source": ["[[KEY - Paper Title|KEY]]"], "status": "draft",
              "page": "content/Barriers/no-prg-to-ot.md", "slug": "no-prg-to-ot",
              "title": "No fixed-construction reduction from PRG to OT" },
            { "id": "bar-ddh-to-prg", "hypotheses": ["ddh"], "conclusion": "prg",
              "class": "relativizing", "consequences": [], "strength": "unconditional",
              "conditionalOn": [], "circumventedBy": [], "source": ["folklore"],
              "status": "stub", "page": "content/Barriers/no-ddh-to-prg.md",
              "slug": "no-ddh-to-prg", "title": "No relativizing reduction from DDH to PRG" }
          ]
        }
        """#.utf8))

    static let fixture: [String: String] = [
        "Primitives/one-way-function.md": #"""
            ---
            type: primitive
            status: draft
            title: One-way function
            aliases: []
            ---

            # One-way function

            A **one-way function** is easy to compute and hard to invert: given $f(x)$, no
            efficient adversary finds a preimage. See [[pseudorandom-generator|PRGs]].

            ## Definition

            The definition.
            """#,
        "Primitives/pseudorandom-generator.md": #"""
            ---
            type: primitive
            status: stub
            title: Pseudorandom generator
            aliases: []
            ---

            # Pseudorandom generator

            TODO: syntax and security definition.

            ```pseudocode
            \begin{algorithm}
            \end{algorithm}
            ```

            Stretches a seed — [[HILL99 - A pseudorandom generator|HILL99]]. TODO tidy up.

            ## Selective security

            Selective prose with $\calA$.

            ## Syntax

            First syntax.

            ## Syntax

            Second syntax.
            """#,
        "Primitives/linker.md": #"""
            ---
            type: primitive
            status: draft
            title: Linker
            aliases: []
            ---

            # Linker

            [[one-way-function]], [[one-way-function|OWF]] again, a
            [[pseudorandom-generator#selective-security|section]], [[KEY - Paper Title|KEY]],
            [[https://example.com|outside]], [[Primitives]], [[#Definition]],
            [[linker#definition|here]], [[ddh-and-owf-to-ot]] and ![[diagram.png]].

            ## Definition

            Text.
            """#,
        "Reductions/ddh-and-owf-to-ot.md": #"""
            ---
            type: reduction
            status: draft
            title: "DDH + OWF ⇒ OT"
            kind: implication
            hypotheses: [ddh, owf]
            conclusion: ot
            class: fully-black-box
            model: rom
            source:
              - "[[KEY - Paper Title|KEY]]"
            security-loss: "$O(q)$ loss"
            ---

            # DDH + OWF ⇒ OT

            ## Statement

            If DDH is hard and [[one-way-function|OWFs]] exist, then OT exists — [[KEY - Paper Title|KEY]].
            """#,
        "Reductions/owf-equiv-prg.md": #"""
            ---
            type: reduction
            status: draft
            title: "OWF ⇔ PRG"
            kind: equivalence
            hypotheses: [owf]
            conclusion: prg
            class: free
            model: standard
            source: [folklore]
            ---

            # OWF ⇔ PRG

            ## Statement

            They are equivalent.
            """#,
        "Barriers/no-owf-to-ot.md": #"""
            ---
            type: barrier
            status: draft
            title: "No fully-black-box reduction from OWF to OT"
            hypotheses: [owf]
            conclusion: ot
            class: fully-black-box
            strength: unconditional
            source:
              - "[[IR89 - Limits|IR89]]"
            ---

            # No fully-black-box reduction from OWF to OT

            ## Statement

            There is no fully-black-box construction of OT from a one-way function.
            """#,
        "Barriers/no-ddh-to-ot.md": #"""
            ---
            type: barrier
            status: draft
            title: "No reduction from DDH to OT"
            hypotheses: [ddh]
            conclusion: ot
            class: unstated
            strength: conditional
            conditional-on: [owf]
            source:
              - "[[IR89 - Limits|IR89]]"
            ---

            # No reduction from DDH to OT

            ## Statement

            Some reduction is ruled out.
            """#,
        "Barriers/no-prg-to-ot.md": #"""
            ---
            type: barrier
            status: draft
            title: "No fixed-construction reduction from PRG to OT"
            hypotheses: [prg]
            conclusion: ot
            class: fixed-construction
            strength: unconditional
            source:
              - "[[KEY - Paper Title|KEY]]"
            ---

            # No fixed-construction reduction from PRG to OT

            ## Statement

            One construction fails.
            """#,
        "Barriers/no-ddh-to-prg.md": #"""
            ---
            type: barrier
            status: stub
            title: "No relativizing reduction from DDH to PRG"
            hypotheses: [ddh]
            conclusion: prg
            class: relativizing
            strength: unconditional
            source: [folklore]
            ---

            # No relativizing reduction from DDH to PRG
            """#,
        "References/KEY - Paper Title.md": #"""
            ---
            type: reference
            status: draft
            title: KEY
            authors: Alice Adams, Bob Brown, Carol Chen, Dan Doe, and Eve Evans
            venue: CRYPTO 2020
            published: 2020-01-01
            ---

            # [KEY] Paper Title

            **Authors:** Alice Adams | **Venue:** CRYPTO 2020 | [Source](https://example.com)

            ## Abstract

            We show that $x$ works.
            """#,
        "References/TODO1 - Pending Paper.md": #"""
            ---
            type: reference
            status: stub
            title: TODO1
            authors: Ann Author and Ben Author
            venue: Journal of Things
            published: 2019-05-02
            ---

            # [TODO1] Pending Paper

            **Authors:** Ann Author | **Venue:** Journal of Things | [Source](https://example.com)

            ## Abstract

            TODO — abstract.

            ## Erratum

            A later section, which is not the abstract.
            """#,
        "Files/diagram.png": "not really a PNG",
    ]

    static func makeIndex() throws -> (WikiIndex, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-link-previews-\(UUID().uuidString)")
        for (path, contents) in fixture {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (WikiIndex.build(contentRoot: root), root)
    }

    static func previews(_ index: WikiIndex) -> LinkPreviews {
        LinkPreviews(
            index: index, manifest: manifest,
            labels: RelationLabels(manifest: manifest, index: index))
    }

    // MARK: Page cards

    @Test("an object page's card: its kind, title and first paragraph")
    func objectCard() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = Self.previews(index)

        let owf = try #require(previews.preview(path: "Primitives/one-way-function.md", anchor: nil))
        #expect(owf.kind == "Primitive")
        #expect(owf.title == "One-way function")
        #expect(owf.meta.isEmpty)
        // Joined across its hard wrap, and whole: it is under the soft limit.
        #expect(owf.excerpt == "A **one-way function** is easy to compute and hard to invert: "
            + "given $f(x)$, no efficient adversary finds a preimage. See PRGs.")
        #expect(owf.label.hasPrefix("Primitive. One-way function. A one-way function is easy"))

        let prg = try #require(previews.preview(path: "Primitives/pseudorandom-generator.md", anchor: nil))
        #expect(prg.kind == "Primitive · stub")
        #expect(prg.excerpt == "Stretches a seed — HILL99.")

        let empty = LinkPreviews.empty.preview(path: "Primitives/one-way-function.md", anchor: nil)
        #expect(empty == nil)
        #expect(previews.count == index.pages.count)
    }

    @Test("a reduction's card is titled by the whole hyperedge, with the page's own meta line")
    func reductionCard() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = Self.previews(index)

        let card = try #require(previews.preview(path: "Reductions/ddh-and-owf-to-ot.md", anchor: nil))
        #expect(card.kind == "Reduction")
        #expect(card.title == "Decisional Diffie-Hellman ∧ One-way function ⇒ Oblivious transfer")
        #expect(card.meta == [
            "Fully-black-box reduction", "random oracle model", "KEY", "security loss: $O(q)$ loss",
        ])
        #expect(card.excerpt == "If DDH is hard and OWFs exist, then OT exists — KEY.")

        // The line leads with "Equivalence", which the card already says.
        let equivalence = try #require(previews.preview(path: "Reductions/owf-equiv-prg.md", anchor: nil))
        #expect(equivalence.kind == "Equivalence")
        #expect(equivalence.title == "One-way function ⇔ Pseudorandom generator")
        #expect(equivalence.meta == ["Free reduction", "standard model", "folklore"])
    }

    @Test("a barrier's card keeps an unstated class, says it is circumvented, and is qualified")
    func barrierCards() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = Self.previews(index)

        let circumvented = try #require(previews.preview(path: "Barriers/no-owf-to-ot.md", anchor: nil))
        #expect(circumvented.kind == "Barrier")
        #expect(circumvented.title == "No fully-black-box reduction from OWF to OT")
        #expect(circumvented.meta == [
            "Unconditional", "against fully-black-box reductions", "IR89", "circumvented by BH26",
        ])
        #expect(circumvented.note == nil)
        #expect(circumvented.excerpt
            == "There is no fully-black-box construction of OT from a one-way function.")

        let unstated = try #require(previews.preview(path: "Barriers/no-ddh-to-ot.md", anchor: nil))
        #expect(unstated.meta == [
            "Conditional", "against reductions of a class the wiki does not state",
            "assuming One-way function", "IR89",
        ])
        #expect(unstated.note
            == "Rules out a kind of reduction the wiki does not classify; see its statement.")

        let fixed = try #require(previews.preview(path: "Barriers/no-prg-to-ot.md", anchor: nil))
        #expect(fixed.note == "Refutes only the construction named on its page; building the "
            + "target another way is not ruled out.")

        let stub = try #require(previews.preview(path: "Barriers/no-ddh-to-prg.md", anchor: nil))
        #expect(stub.kind == "Barrier · stub")
        #expect(stub.note == "Stub: its class and consequences are not evidence.")
        #expect(stub.excerpt == nil)
        // The qualifier is read straight after the title it qualifies.
        let spokenStart: String = "Barrier · stub. No relativizing reduction from DDH to PRG. "
            + "Stub: its class and consequences are not evidence."
        #expect(stub.label.hasPrefix(spokenStart))
    }

    @Test("a reference's card: title, authors, venue and the abstract, never a TODO")
    func referenceCards() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = Self.previews(index)

        let paper = try #require(previews.preview(path: "References/KEY - Paper Title.md", anchor: nil))
        #expect(paper.kind == "Reference")
        #expect(paper.title == "Paper Title")
        #expect(paper.meta == ["Alice Adams et al.", "CRYPTO 2020"])
        #expect(paper.excerpt == "We show that $x$ works.")

        // A TODO abstract is no abstract, and a later section is not one either.
        let pending = try #require(previews.preview(path: "References/TODO1 - Pending Paper.md", anchor: nil))
        #expect(pending.meta == ["Ann Author, Ben Author", "Journal of Things", "2019"])
        #expect(pending.excerpt == nil)

        let semicolons = LinkPreviews.authorLine(
            "Corrigan-Gibbs, Henry; Henzinger, Alexandra; Wu, David J.")
        #expect(semicolons == "Henry Corrigan-Gibbs, Alexandra Henzinger, David J. Wu")
    }

    @Test("a link to page#anchor gets the section's card, or the page's when no heading matches")
    func sectionCards() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = Self.previews(index)
        let path = "Primitives/pseudorandom-generator.md"

        let variant = try #require(previews.preview(path: path, anchor: "selective-security"))
        #expect(variant.kind == "Section of Pseudorandom generator")
        #expect(variant.title == "Selective security")
        #expect(variant.excerpt == "Selective prose with $\\calA$.")

        let second = try #require(previews.preview(path: path, anchor: "syntax-1"))
        #expect(second.title == "Syntax")
        #expect(second.excerpt == "Second syntax.")

        let unknown = try #require(previews.preview(path: path, anchor: "nowhere"))
        #expect(unknown.kind == "Primitive · stub")
        let title = try #require(previews.preview(path: path, anchor: "pseudorandom-generator"))
        #expect(title.kind == "Primitive · stub")

        // A barrier's title in the kind line carries R8's qualifier there too.
        let barrierPath = "Barriers/no-prg-to-ot.md"
        let statement = try #require(previews.preview(path: barrierPath, anchor: "statement"))
        #expect(statement.kind == "Section of No fixed-construction reduction from PRG to OT")
        #expect(statement.title == "Statement")
        #expect(statement.note == "Refutes only the construction named on its page; building the "
            + "target another way is not ruled out.")
        #expect(statement.excerpt == "One construction fails.")
        let objectSection = try #require(previews.preview(path: path, anchor: "selective-security"))
        #expect(objectSection.note == nil)
    }

    @Test("caps: a title at 160, a meta part at 120, the label at 700, the excerpt at 420")
    func sizeCaps() {
        let longTitle = String(repeating: "Title ", count: 60)
        let page = WikiPage(path: "Primitives/long.md", text: """
            ---
            type: primitive
            status: draft
            title: \(longTitle)
            ---

            # Long

            \(String(repeating: "prose ", count: 200))
            """)
        let card = LinkPreviews.card(for: page, manifest: .empty, labels: .empty)
        #expect(card.title.count <= LinkPreview.titleLimit)
        #expect(card.title.hasSuffix("…"))
        let excerptLength = card.excerpt?.count ?? 0
        #expect(excerptLength <= PreviewExcerpt.hardLimit)
        #expect(card.label.count <= LinkPreview.labelLimit)

        let loss = String(repeating: "$q$ queries ", count: 30)
        let reduction = WikiPage(path: "Reductions/lossy.md", text: """
            ---
            type: reduction
            status: draft
            title: "A ⇒ B"
            kind: implication
            class: free
            model: standard
            security-loss: "\(loss)"
            ---

            # A ⇒ B
            """)
        let reductionCard = LinkPreviews.card(for: reduction, manifest: .empty, labels: .empty)
        let longest = reductionCard.meta.map(\.count).max() ?? 0
        #expect(longest <= LinkPreview.metaLimit)
        #expect(reductionCard.meta.count == 3)
    }

    @Test("the JSON a card crosses the bridge as")
    func jsonObject() {
        let card = LinkPreview(kind: "Primitive", title: "T", excerpt: nil)
        let object = card.jsonObject
        #expect(object["kind"] as? String == "Primitive")
        #expect(object["meta"] as? [String] == [])
        #expect(object["label"] as? String == "Primitive. T.")
        #expect(object["excerpt"] == nil)
        #expect(object["note"] == nil)
    }

    // MARK: The render request

    @Test("only links to other pages get a card, keyed by href; none when previews are off")
    func renderRequest() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(index.pages["Primitives/linker.md"])

        var renderer = PageRenderer(index: index)
        renderer.relations = Self.manifest
        renderer.linkPreviews = Self.previews(index)
        let request = renderer.request(for: page)

        let owf = CCwikiURL.page(path: "Primitives/one-way-function.md")
        let section = CCwikiURL.page(
            path: "Primitives/pseudorandom-generator.md", anchor: "selective-security")
        let paper = CCwikiURL.page(path: "References/KEY - Paper Title.md")
        let reduction = CCwikiURL.page(path: "Reductions/ddh-and-owf-to-ot.md")
        let keys = Set(request.previews.keys)
        #expect(keys == [owf, section, paper, reduction])
        #expect(request.previews[section]?.kind == "Section of Pseudorandom generator")

        // The links that get none are there, resolved: external, folder,
        // same page, the page itself by name, and an embedded asset.
        let kinds = Set(request.links.values.map { $0.kind })
        #expect(kinds == ["page", "external", "folder", "anchor", "asset"])
        let selfLink = request.links["[[linker#definition|here]]"]?.href
        #expect(selfLink == CCwikiURL.page(path: "Primitives/linker.md", anchor: "definition"))

        let data = Data(request.jsonPayload().utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let payload = try #require(object as? [String: Any])
        let sent = try #require(payload["previews"] as? [String: Any])
        let card = try #require(sent[reduction] as? [String: Any])
        #expect(card["kind"] as? String == "Reduction")

        renderer.buildsPreviews = false
        let off = renderer.request(for: page)
        #expect(off.previews.isEmpty)
        #expect(!off.jsonPayload().contains("\"previews\""))
    }

    // MARK: Corpus

    private struct Corpus {
        let index: WikiIndex
        let manifest: RelationsManifest
        let previews: LinkPreviews
    }

    private static func corpus() -> Corpus? {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty,
              let contentRoot = CorpusTests.contentRoot
        else { return nil }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let manifest = RelationsManifest.load(cloneRoot: URL(fileURLWithPath: path))
        let labels = RelationLabels(manifest: manifest, index: index)
        let previews = LinkPreviews(index: index, manifest: manifest, labels: labels)
        return Corpus(index: index, manifest: manifest, previews: previews)
    }

    @Test("on the corpus, a card with no excerpt is a stub's or a reference's with no abstract yet")
    func corpusExcerpts() throws {
        guard let corpus = Self.corpus() else { return }
        let index = corpus.index
        let previews = corpus.previews
        #expect(previews.count == index.pages.count)

        var withoutExcerpt: [String] = []
        var unexplained: [String] = []
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            guard let card = previews.preview(path: page.path, anchor: nil) else {
                unexplained.append(page.path + " (no card)")
                continue
            }
            guard card.excerpt == nil else { continue }
            withoutExcerpt.append(page.path)
            // A reference is excused only by its abstract itself: none, or
            // one that opens with a TODO. A TODO elsewhere on the page does
            // not excuse a real abstract the rules failed to find.
            let abstract = PreviewExcerpt.scope(of: page.body, anchor: "abstract")
            let abstractLines: [String] = (abstract?.lines ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let abstractStart: String? = abstractLines.first(where: { !$0.isEmpty })
            let abstractIsPlaceholder = abstractStart?.hasPrefix("TODO") ?? true
            let noAbstract = page.kind == .reference && abstractIsPlaceholder
            if page.status != .stub, !noAbstract { unexplained.append(page.path) }
        }
        // 239 at wiki ab81f02: 238 references with a TODO abstract or none,
        // and one stub. The number is not pinned: CI reads the wiki as it is
        // today, and it moves as abstracts and references land. The rule is
        // what holds: a draft page, or a reference with a real abstract,
        // losing its excerpt is a regression in the paragraph rules.
        #expect(unexplained.isEmpty, "cards with no excerpt:\n  \(unexplained.joined(separator: "\n  "))")
        print("link previews: \(previews.count) page cards, \(withoutExcerpt.count) without an excerpt")
    }

    @Test("on the corpus, every card keeps to its caps, and LWE's previews stay under 80 KB")
    func corpusPayload() throws {
        guard let corpus = Self.corpus() else { return }
        let index = corpus.index
        var renderer = PageRenderer(index: index)
        renderer.relations = corpus.manifest
        renderer.linkPreviews = corpus.previews

        var oversized: [String] = []
        var biggestCard = 0
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            let request = renderer.request(for: page)
            let own = CCwikiURL.page(path: page.path)
            for (href, card) in request.previews {
                if href == own || href.hasPrefix(own + "#") {
                    oversized.append("\(page.path): a card for itself")
                }
                let excerptLength = card.excerpt?.count ?? 0
                let longestMeta = card.meta.map { $0.count }.max() ?? 0
                if excerptLength > PreviewExcerpt.hardLimit || longestMeta > LinkPreview.metaLimit
                    || card.label.count > LinkPreview.labelLimit {
                    oversized.append("\(page.path) → \(href)")
                }
                let data = try JSONSerialization.data(withJSONObject: card.jsonObject)
                biggestCard = max(biggestCard, data.count)
            }
        }
        #expect(oversized.isEmpty, "cards over their caps:\n  \(oversized.joined(separator: "\n  "))")
        // About 1.2 KB at most when the caps arrived; TeX's backslashes
        // double in JSON.
        #expect(biggestCard < 2_048, "the biggest card is \(biggestCard) bytes")

        let lwe = try #require(index.pages["Assumptions/learning-with-errors.md"])
        let request = renderer.request(for: lwe)
        let cards = request.previews.mapValues { $0.jsonObject }
        let payload = try JSONSerialization.data(withJSONObject: cards)
        #expect(request.previews.count > 20)
        #expect(payload.count < 80_000, "LWE's previews are \(payload.count) bytes")
        print("link previews: LWE carries \(request.previews.count) cards, \(payload.count) bytes")
    }
}
