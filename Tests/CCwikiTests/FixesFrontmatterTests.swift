import Foundation
import Testing
@testable import CCwiki

/// Frontmatter read as js-yaml reads it, so as the site and the lint do:
/// a trailing `# comment` after a plain value, a flow list or a list item is
/// dropped (R2-12, R2-13), and a value that runs on over its indented lines,
/// a block list with blank lines or comments in it, and a flow list wrapped
/// the way the wiki's formatter wraps one are read whole (R2-14). Every
/// expected value was first checked against a YAML parser, and every
/// relation-meta line against the site's own `relationMeta.ts`.
@Suite struct FixesFrontmatterTests {

    /// Frontmatter from the YAML between the fences.
    private static func parse(_ yaml: String) -> Frontmatter {
        Frontmatter.parse("---\n" + yaml + "\n---\n# X\n")
    }

    /// The relation-meta parts joined as `RelationMetaTests` joins them,
    /// with no manifest, as the site renders a page without one.
    private static func line(_ yaml: String) -> String {
        RelationMeta.parts(for: parse(yaml), manifest: .empty, labels: .empty)
            .joined(separator: " · ")
    }

    // MARK: R2-12: trailing comments

    @Test("a plain value loses its trailing comment; a # without whitespace before it stays")
    func plainComments() {
        let fm = Self.parse("""
            kind: implication # implication | inclusion | equivalence
            class: unstated # from schema/reduction-classes.yaml
            model: standard\t# js-yaml takes a tab before the hash too
            source: https://eprint.iacr.org/2020/1#page=3
            lang: C#
            title: "#P" # counting
            note: Impagliazzo's worlds # a quote in a plain value is text
            """)
        #expect(fm.string("kind") == "implication")
        #expect(fm.string("class") == "unstated")
        #expect(fm.string("model") == "standard")
        #expect(fm.string("source") == "https://eprint.iacr.org/2020/1#page=3")
        #expect(fm.string("lang") == "C#")
        #expect(fm.string("title") == "#P")
        #expect(fm.string("note") == "Impagliazzo's worlds")

        #expect(Frontmatter.plainValue("a # b") == "a")
        #expect(Frontmatter.plainValue("C# and F#") == "C# and F#")
        #expect(Frontmatter.quotedValue("#P") == nil, "unquoted values are not quoted ones")
    }

    @Test("a flow list followed by a comment is a list, and a quote mid-item is text")
    func flowComments() {
        let fm = Self.parse("""
            conditional-on: [] # required when conditional
            hypotheses: [prg] # a LIST, >= 1 — a conjunction, never a disjunction
            via: ["[[fiat-shamir-heuristic|Fiat–Shamir]]"] # a transform
            apostrophe: [it's, b]
            quoted: [a, "b, c", 'd, e', "f # g"]
            """)
        #expect(fm.fields["conditional-on"] == .list([]))
        #expect(fm.fields["hypotheses"] == .list(["prg"]))
        #expect(fm.fields["via"] == .list(["[[fiat-shamir-heuristic|Fiat–Shamir]]"]))
        #expect(fm.fields["apostrophe"] == .list(["it's", "b"]))
        #expect(fm.fields["quoted"] == .list(["a", "b, c", "d, e", "f # g"]))
    }

    @Test("a key with only a comment on its line takes its value from the lines below")
    func commentOnlyKeys() {
        let fm = Self.parse("""
            title: # nothing here
            consequences: # a list
              - kind: contradiction # contradiction | object
                target: "" # contradiction takes no target
                class: relativizing
              - kind: complexity
            strength: unconditional # unconditional | conditional
            rationale: # optional
              class: "The construction calls the PRG only as an oracle."
            bibtex: | # the entry
              @article{a,
                title={b}
              }
            status: draft
            """)
        #expect(fm.fields["title"] == .null)
        // Two items, each a mapping this parser keeps as written; the
        // nested lines of each are skipped and the list goes on.
        #expect(fm.list("consequences").count == 2)
        #expect(fm.string("strength") == "unconditional")
        #expect(fm.fields["rationale"] == .null, "a nested mapping is not read")
        #expect(fm.raw("bibtex") == "@article{a,\n  title={b}\n}")
        #expect(fm.string("status") == "draft")
    }

    @Test("ReviewPayload's header reads a commented hypotheses list as one hypothesis")
    func reviewHeader() {
        let text = """
            ---
            type: reduction
            hypotheses: [prg] # a LIST, >= 1 — a conjunction, never a disjunction
            conclusion: prf # exactly one
            ---
            # PRG ⇒ PRF

            """
        let file = ChangedFile(
            path: "content/Reductions/prg-to-prf.md", oldPath: nil, status: .added,
            isBinary: false, oldText: nil, newText: text, hunks: [])
        let labels = RelationLabels.empty
        let header = ReviewPayload.header(for: file, labels: labels)
        #expect(header == "Hypothesis: " + labels.label("prg") + RelationMeta.separator
            + "Conclusion: " + labels.label("prf"))
    }

    // MARK: R2-13: list items

    @Test("a quoted list item followed by a comment loses its quotes and the comment")
    func itemComments() {
        let page = WikiPage(path: "Reductions/x.md", text: """
            ---
            source:
              - "[[K - T|K]]" # note
              - folklore # a plain item's comment goes too
              - 'it''s' # single quotes
            aliases:
              - "PRF" # note
            ---
            # X

            """)
        #expect(page.frontmatter.fields["source"] == .list(["[[K - T|K]]", "folklore", "it's"]))
        #expect(page.aliases == ["PRF"])
        #expect(RelationMeta.parts(for: page.frontmatter, manifest: .empty, labels: .empty).isEmpty,
                "no type, no line")
    }

    // MARK: R2-14: values over several lines

    @Test("a plain or quoted scalar runs on over its indented lines, folded as YAML folds it")
    func multiLineScalars() {
        let page = WikiPage(path: "Reductions/x.md", text: #"""
            ---
            security-loss: additive $q^2/2^n$ for $q$ queries, plus the PRF advantage
              of the underlying function
            quoted: "additive $q^2/2^n$ for $q$ queries, plus the PRF advantage
              of the underlying function" # note
            single: 'it''s
              long'
            paragraphs: first part

              second part
            escaped: "abc\
              def"
            title: X
            ---
            # X

            """#)
        let loss = "additive $q^2/2^n$ for $q$ queries, plus the PRF advantage of the underlying function"
        let fm = page.frontmatter
        #expect(fm.string("security-loss") == loss)
        #expect(fm.string("quoted") == loss)
        #expect(fm.string("single") == "it's long")
        #expect(fm.string("paragraphs") == "first part\nsecond part")
        #expect(fm.string("escaped") == "abcdef")
        #expect(page.title == "X")
        #expect(page.body == "# X\n")
    }

    @Test("blank lines and comments inside a block list do not end it")
    func blockListGaps() {
        let page = WikiPage(path: "Reductions/x.md", text: """
            ---
            source:
              # the original theorem
              - "[[GGM84 - How to Construct Random Functions|GGM84]]"

              - folklore
            # a comment at the margin
              - a long item
                that continues
            aliases:
            - PRF

            - PRFs
            title: X
            ---
            # X

            """)
        #expect(page.frontmatter.fields["source"] == .list([
            "[[GGM84 - How to Construct Random Functions|GGM84]]", "folklore",
            "a long item that continues",
        ]))
        #expect(page.aliases == ["PRF", "PRFs"])
        #expect(page.title == "X")
        #expect(page.body == "# X\n")
    }

    @Test("a flow list runs on over its lines, as the wiki's formatter wraps a long one")
    func multiLineFlowLists() {
        let fm = Self.parse("""
            conditional-on: [owf,
              a sub-exponentially hard subset-membership problem]
            wrapped:
              [owf, a sub-exponentially hard subset-membership problem with hard instances]
            source:
              [
                "[[GGM84 - On the Cryptographic Applications of Random Functions|GGM84]]",
                folklore,
              ]
            hypotheses: [a, # the first
              b] # the second
            title: X
            """)
        #expect(fm.fields["conditional-on"]
            == .list(["owf", "a sub-exponentially hard subset-membership problem"]))
        #expect(fm.fields["wrapped"]
            == .list(["owf", "a sub-exponentially hard subset-membership problem with hard instances"]))
        #expect(fm.fields["source"] == .list([
            "[[GGM84 - On the Cryptographic Applications of Random Functions|GGM84]]", "folklore",
        ]))
        #expect(fm.fields["hypotheses"] == .list(["a", "b"]))
        #expect(fm.string("title") == "X")
    }

    @Test("a flow list item over several lines folds as a scalar does, blank lines and escapes included")
    func multiLineFlowItems() {
        let fm = Self.parse(#"""
            plain: [a long
              item, b]
            blank: [abc

              def, x]
            blanks: [abc


              def, x]
            single: ['it''s

              long', x]
            escaped: ["abc\
              def", x]
            escapedBlank: ["abc\

              def", x]
            spaced: ["abc \
              def", "two
              lines"]
            gaps: [abc

              , "x"

              ]
            title: X
            """#)
        #expect(fm.fields["plain"] == .list(["a long item", "b"]))
        // A blank line inside an item is a newline, and the break before
        // it is nothing.
        #expect(fm.fields["blank"] == .list(["abc\ndef", "x"]))
        #expect(fm.fields["blanks"] == .list(["abc\n\ndef", "x"]))
        #expect(fm.fields["single"] == .list(["it's\nlong", "x"]))
        // An escaped line break joins the lines without a space; a space
        // before the `\` is text.
        #expect(fm.fields["escaped"] == .list(["abcdef", "x"]))
        #expect(fm.fields["escapedBlank"] == .list(["abc\ndef", "x"]))
        #expect(fm.fields["spaced"] == .list(["abc def", "two lines"]))
        // Between items, blank lines are only whitespace.
        #expect(fm.fields["gaps"] == .list(["abc", "x"]))
        #expect(fm.string("title") == "X")
    }

    @Test("what is not YAML, or is a nested mapping, reads as it did")
    func notYAML() {
        let page = WikiPage(path: "Primitives/x.md", text: """
            ---
            broken: [owf,
            open: "abc
            title: X
            variants:
              weak-prf: "#weak-prfs"
            status: draft
            ---
            # X

            """)
        let fm = page.frontmatter
        #expect(fm.string("broken") == "[owf,")
        #expect(fm.string("open") == "\"abc")
        #expect(page.title == "X")
        #expect(fm.fields["variants"] == .null)
        #expect(fm.string("status") == "draft")
        #expect(page.body == "# X\n")
    }

    // MARK: The relation-meta line, against the site

    @Test("CONTRIBUTING's final-form reduction reads as the site shows it")
    func contributingReduction() {
        let line = Self.line("""
            type: reduction
            status: draft
            title: PRG ⇒ PRF (GGM)
            aliases:
              - GGM construction
            id: red-prg-to-prf-ggm86 # stable while the page states this theorem
            kind: implication # implication | inclusion | equivalence
            hypotheses: [prg] # a LIST, >= 1 — a conjunction, never a disjunction
            conclusion: prf # exactly one
            class: fully-black-box # from schema/reduction-classes.yaml, or `unstated`
            model: standard # standard | rom | crs | generic-group | algebraic-group | quantum | other
            source:
              - "[[GGM86 - How to construct random functions|GGM86]]"
            security-loss: "" # free text
            # via: [] # optional: a transform, lemma or technique used (Fiat–Shamir, the switching lemma) — never a hypothesis
            # heuristic: true # optional: a candidate construction whose source gives no security reduction
            rationale: # optional: one single-line sentence per field, saying why its value was recorded
              class: "The construction calls the PRG only as an oracle, once per input bit, and the hybrid reduction runs any PRF distinguisher only as an oracle."
            """)
        #expect(line == "[[reduction-classes#fully-black-box|Fully-black-box reduction]] · "
            + "standard model · [[GGM86 - How to construct random functions|GGM86]]")
    }

    @Test("CONTRIBUTING's final-form barrier is unconditional, with no assumption")
    func contributingBarrier() {
        let line = Self.line("""
            type: barrier
            status: draft
            title: "No relativizing reduction from OWP to KE"
            aliases: []
            id: bar-owp-to-ke-ir89
            hypotheses: [owp] # the hyperedge being ruled out
            conclusion: ke
            class: relativizing # the class of reduction the barrier applies to
            consequences: # a LIST — one hyperedge can carry several framings
              - kind: contradiction # contradiction | object | complexity | reduction
                target: "" # contradiction takes no target
                class: relativizing
              - kind: complexity
                target: p-neq-np # a key of schema/propositions.yaml
                class: fully-black-box
            strength: unconditional # unconditional | conditional
            conditional-on: [] # required when conditional: the unproven assumption(s) the theorem rests on, by object id where one exists
            oracle: "a random permutation together with a PSPACE-complete oracle"
            # circumvented-by: [<reduction id>] # optional, non-empty when present: reductions that reach the conclusion outside this class or scope
            source:
              - "[[IR89 - Limits on the provable consequences of one-way permutations|IR89]]"
            rationale:
              class: "A construction and security proof that hold relative to every oracle hold relative to IR89's, under which one-way permutations exist and key agreement does not."
            """)
        #expect(line == "Unconditional · against [[reduction-classes#relativizing|relativizing reductions]] · "
            + "[[IR89 - Limits on the provable consequences of one-way permutations|IR89]]")
    }

    @Test("pages started from the templates, comments kept, read as the site shows them")
    func templates() {
        let reduction = Self.line("""
            type: reduction
            status: draft
            title: "A ⇒ B"
            aliases: []
            id: red-a-to-b-key00 # red-<hypotheses>-to-<conclusion>[-<source>]; never changes while the page states this theorem
            kind: implication # implication | inclusion | equivalence
            hypotheses: [a] # object ids, assumed together; independent sufficient assumptions are separate pages
            conclusion: b # exactly one object id
            class: unstated # from schema/reduction-classes.yaml; unstated unless the source or the proof shape fixes it
            model: standard # standard | rom | crs | generic-group | algebraic-group | quantum | other
            source:
              - "[[KEY00 - Full Title|KEY00]]" # every paper whose theorem the Statement asserts, or the bare token folklore
            security-loss: "" # free text
            """)
        #expect(reduction == "Standard model · [[KEY00 - Full Title|KEY00]]")

        let barrier = Self.line("""
            type: barrier
            status: draft
            title: "No fully-black-box reduction from A to B"
            aliases: []
            id: bar-a-to-b-key00 # bar-<hypotheses>-to-<conclusion>[-<source>]; never changes while the page states this theorem
            hypotheses: [a] # the hyperedge being ruled out
            conclusion: b
            class: fully-black-box # the class the source rules out, from schema/reduction-classes.yaml; the title names it
            consequences: # a list: what a reduction of that class would imply
              - kind: contradiction # contradiction | object | complexity | reduction
                target: "" # contradiction takes no target
                class: fully-black-box
            strength: unconditional # conditional iff the barrier theorem assumes an unproven hardness assumption
            source:
              - "[[KEY00 - Full Title|KEY00]]"
            """)
        #expect(barrier == "Unconditional · against "
            + "[[reduction-classes#fully-black-box|fully-black-box reductions]] · [[KEY00 - Full Title|KEY00]]")
    }

    @Test("a security loss over two lines and a list with a comment and a gap read whole")
    func multiLineReduction() {
        let plain = Self.line("""
            type: reduction
            kind: implication
            class: fully-black-box
            model: standard
            source:
              # the original theorem
              - "[[GGM84 - How to Construct Random Functions|GGM84]]" # the theorem

              - folklore
            security-loss: additive $q^2/2^n$ for $q$ queries, plus the PRF advantage
              of the underlying function
            """)
        #expect(plain == "[[reduction-classes#fully-black-box|Fully-black-box reduction]] · standard model · "
            + "[[GGM84 - How to Construct Random Functions|GGM84]], folklore · "
            + "security loss: additive $q^2/2^n$ for $q$ queries, plus the PRF advantage of the underlying function")

        let wrapped = Self.line("""
            type: reduction
            kind: equivalence
            class: free
            model: other
            source:
              [
                "[[GGM84 - On the Cryptographic Applications of Random Functions|GGM84]]",
                folklore,
              ]
            security-loss: "additive $q^2/2^n$ for $q$ queries, plus the PRF advantage
              of the underlying function"
            """)
        #expect(wrapped == "Equivalence · [[reduction-classes#free|free reduction]] · non-standard model · "
            + "[[GGM84 - On the Cryptographic Applications of Random Functions|GGM84]], folklore · "
            + "security loss: additive $q^2/2^n$ for $q$ queries, plus the PRF advantage of the underlying function")
    }

    @Test("a wrapped conditional-on keeps every assumption")
    func multiLineBarrier() {
        let wrapped = Self.line("""
            type: barrier
            strength: conditional
            class: fully-black-box
            conditional-on:
              [owf, a sub-exponentially hard subset-membership problem with hard instances]
            source: ["[[IR89 - Limits|IR89]]"] # the paper
            """)
        #expect(wrapped == "Conditional · against [[reduction-classes#fully-black-box|fully-black-box reductions]] · "
            + "assuming owf, a sub-exponentially hard subset-membership problem with hard instances · "
            + "[[IR89 - Limits|IR89]]")

        let commented = Self.line("""
            type: barrier
            strength: conditional # c
            conditional-on: [owf, # the first
              a sub-exponentially hard subset-membership problem]
            source:
            - "[[IR89 - Limits|IR89]]" # note
            """)
        #expect(commented == "Conditional · assuming owf, a sub-exponentially hard subset-membership problem · "
            + "[[IR89 - Limits|IR89]]")
    }
}
