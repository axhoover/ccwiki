import Foundation
import Testing
@testable import CCwiki

/// The relation-meta line under the H1 of reduction and barrier pages: the
/// cases of the wiki's `quartz/plugins/transformers/relationMeta.test.ts`,
/// ported, plus the splice into a render request.
///
/// The site's tests join the parts with " · "; the real separator has a
/// no-break space in front, which `line(_:)` leaves out the same way.
struct RelationMetaTests {

    // MARK: Fixture

    /// The site test's objects (`fac`, `ip`, `owf`), its math-titled ones,
    /// and a variant from a clone that predates heading titles, whose title is
    /// still its id.
    static let manifest = RelationsManifest.decode(Data(#"""
        {
          "version": 1,
          "classSentinels": ["unstated"],
          "objects": [
            { "id": "fac", "kind": "object", "type": "assumption",
              "page": "content/Assumptions/factoring.md", "slug": "factoring",
              "title": "Factoring", "aliases": [], "unlisted": false },
            { "id": "ip", "kind": "object", "type": "complexity-class",
              "page": "content/Complexity/interactive-proofs.md", "slug": "interactive-proofs",
              "title": "IP", "aliases": [], "unlisted": false },
            { "id": "hash", "kind": "object", "type": "primitive",
              "page": "content/Primitives/hash-function.md", "slug": "hash-function",
              "title": "Hash function", "aliases": [], "unlisted": false },
            { "id": "owf", "kind": "variant", "type": "primitive",
              "page": "content/Primitives/hash-function.md", "slug": "hash-function",
              "anchor": "#preimage-resistance-one-wayness", "of": "hash",
              "title": "Preimage resistance (one-wayness)", "aliases": [], "unlisted": false },
            { "id": "q-sdh", "kind": "object", "type": "assumption",
              "page": "content/Assumptions/q-strong-diffie-hellman.md",
              "slug": "q-strong-diffie-hellman",
              "title": "$q$-Strong Diffie-Hellman assumption", "aliases": [], "unlisted": false },
            { "id": "abs", "kind": "variant", "type": "primitive",
              "page": "content/Primitives/x.md", "slug": "x", "anchor": "#bounded", "of": "hash",
              "title": "$|x| \\le [B]$-bounded", "aliases": [], "unlisted": false },
            { "id": "ind-dollar", "kind": "variant", "type": "primitive",
              "page": "content/Primitives/symmetric-key-encryption.md",
              "slug": "symmetric-key-encryption", "anchor": "#ind-cpa-security", "of": "hash",
              "title": "IND$-CPA Security", "aliases": [], "unlisted": false },
            { "id": "legacy-variant", "kind": "variant", "type": "primitive",
              "page": "content/Primitives/hash-function.md", "slug": "hash-function",
              "anchor": "#legacy", "of": "hash",
              "title": "legacy-variant", "aliases": [], "unlisted": false }
          ]
        }
        """#.utf8))

    static let labels = RelationLabels(manifest: manifest, index: nil)

    /// Frontmatter from the YAML between the fences.
    private func frontmatter(_ yaml: String) -> Frontmatter {
        Frontmatter.parse("---\n" + yaml + "\n---\n")
    }

    private func parts(
        _ yaml: String, manifest: RelationsManifest = RelationMetaTests.manifest
    ) -> [String] {
        RelationMeta.parts(for: frontmatter(yaml), manifest: manifest, labels: Self.labels)
    }

    /// The parts joined as the site's tests write them.
    private func line(_ yaml: String) -> String {
        parts(yaml).joined(separator: " · ")
    }

    private static let dlo24 = "[[DLO24 - Breaking RSA Generically|DLO24]]"

    // MARK: Reductions

    @Test("kind, class, model and sources in order; implication and unstated left out")
    func reductionOrder() {
        let equivalence = line("""
            type: reduction
            kind: equivalence
            class: free
            model: other
            conclusion: fac
            source: ["\(Self.dlo24)"]
            """)
        #expect(equivalence
            == "Equivalence · [[reduction-classes#free|free reduction]] · non-standard model · \(Self.dlo24)")

        let plain = line("""
            type: reduction
            kind: implication
            class: unstated
            model: standard
            source: [folklore]
            """)
        #expect(plain == "Standard model · folklore")
    }

    @Test("idealised models link to their pages; the others are text")
    func models() {
        let base = "type: reduction\nkind: implication\nclass: unstated\n"
        let rom = line(base + "model: rom")
        let genericGroup = line(base + "model: generic-group")
        let algebraicGroup = line(base + "model: algebraic-group")
        let crs = line(base + "model: crs")
        let quantum = line(base + "model: quantum")
        #expect(rom == "[[random-oracle-model|Random oracle model]]")
        #expect(genericGroup == "[[generic-group-model|Generic group model]]")
        #expect(algebraicGroup == "[[algebraic-group-model|Algebraic group model]]")
        #expect(crs == "CRS model")
        #expect(quantum == "Quantum setting")
    }

    @Test("the class phrase is written attributively, as in page titles")
    func classPhrase() {
        let base = "type: reduction\nkind: implication\nmodel: standard\n"
        let blackBox = line(base + "class: fully-black-box")
        let forallExists = line(base + "class: forall-exists-semi-black-box")
        #expect(blackBox
            == "[[reduction-classes#fully-black-box|Fully-black-box reduction]] · standard model")
        #expect(forallExists
            == "[[reduction-classes#forall-exists-semi-black-box|∀∃-semi-black-box reduction]] · standard model")
    }

    @Test("heuristic, via, then sources, then security loss with its math intact")
    func heuristicViaSourcesLoss() {
        let full = line(#"""
            type: reduction
            kind: implication
            class: fully-black-box
            model: standard
            heuristic: true
            via: ["[[switching-lemma|Switching Lemma]]"]
            source: ["[[BKR94 - The Security of CBC|BKR94]]", folklore]
            security-loss: 'additive   $q(q-1)/(2|\calD|)$ for $q$ queries'
            """#)
        let expected = [
            "[[reduction-classes#fully-black-box|Fully-black-box reduction]]",
            "standard model",
            "heuristic candidate",
            "via [[switching-lemma|Switching Lemma]]",
            "[[BKR94 - The Security of CBC|BKR94]], folklore",
            #"security loss: additive $q(q-1)/(2|\calD|)$ for $q$ queries"#,
        ].joined(separator: " · ")
        #expect(full == expected)
    }

    @Test("a containment of complexity classes drops the class and standard-model axes")
    func complexityContainment() {
        let base = "type: reduction\nkind: inclusion\nclass: free\nconclusion: ip\nsource: [folklore]\n"
        let standard = line(base + "model: standard")
        let quantum = line(base + "model: quantum")
        #expect(standard == "Inclusion · folklore")
        #expect(quantum == "Inclusion · quantum setting · folklore")

        // An equivalence of assumptions keeps both.
        let assumptions = line("""
            type: reduction
            kind: equivalence
            class: free
            conclusion: fac
            model: standard
            source: [folklore]
            """)
        #expect(assumptions
            == "Equivalence · [[reduction-classes#free|free reduction]] · standard model · folklore")
    }

    @Test("without the manifest, an inclusion still counts as a containment")
    func containmentWithoutManifest() {
        let yaml = "type: reduction\nkind: inclusion\nclass: free\nconclusion: ip\nmodel: standard\nsource: [folklore]"
        let withoutManifest = parts(yaml, manifest: .empty).joined(separator: " · ")
        #expect(withoutManifest == "Inclusion · folklore")
    }

    @Test("malformed fields are left out, never printed as structure")
    func malformedFields() {
        let base = "type: reduction\nkind: implication\nclass: unstated\n"
        // A model with no display name reads as "<value> model".
        let constructor = line(base + "model: constructor")
        let proto = line(base + "model: __proto__")
        #expect(constructor == "Constructor model")
        #expect(proto == "__proto__ model")

        let reduction = line("""
            type: reduction
            kind: { a: 1 }
            class: [a, b]
            model: null
            via: { a: 1 }
            source: [{ k: 1 }, "", "  "]
            security-loss: [a]
            rationale:
              class: Calls the oracle once.
            """)
        #expect(reduction == "")

        let barrier = line("""
            type: barrier
            strength: true
            conditional-on: { a: 1 }
            """)
        #expect(barrier == "")
    }

    @Test("an empty security loss and missing fields are left out")
    func emptyFields() {
        let empty = line("""
            type: reduction
            kind: implication
            class: unstated
            security-loss: ""
            """)
        #expect(empty == "")
    }

    // MARK: Barriers

    @Test("strength, class ruled out, conditional-on, sources")
    func barrier() {
        let conditional = line("""
            type: barrier
            strength: conditional
            class: fixed-construction
            conditional-on: [owf, fac, no-such-id]
            source: ["[[GK03 - On the (In)security of the Fiat-Shamir Paradigm|GK03]]"]
            """)
        #expect(conditional == """
            Conditional · against [[reduction-classes#fixed-construction|fixed-construction reductions]] · \
            assuming [[hash-function#preimage-resistance-one-wayness|preimage resistance (one-wayness)]], \
            [[factoring|Factoring]], no-such-id · \
            [[GK03 - On the (In)security of the Fiat-Shamir Paradigm|GK03]]
            """)
    }

    @Test("a title with math is linked as a markdown link, so the math renders")
    func mathTitles() {
        let barrier = parts("""
            type: barrier
            strength: conditional
            conditional-on: [q-sdh, abs, ind-dollar, ind-dollar]
            """)
        // A lone dollar is escaped, so two of them cannot pair into math.
        let indDollar = #"[IND\$-CPA Security](<symmetric-key-encryption#ind-cpa-security>)"#
        let assumed = [
            "[$q$-Strong Diffie-Hellman assumption](<q-strong-diffie-hellman>)",
            #"[$|x| \le [B]$-bounded](<x#bounded>)"#,
            indDollar,
            indDollar,
        ]
        let expected = ["Conditional", "assuming " + assumed.joined(separator: ", ")]
        #expect(barrier == expected)
    }

    @Test("free-text conditional-on stays text; an unstated class is left out")
    func freeTextAssumption() {
        let barrier = line("""
            type: barrier
            strength: conditional
            class: unstated
            conditional-on: [a sub-exponentially hard subset-membership problem]
            source: ["\(Self.dlo24)"]
            """)
        #expect(barrier
            == "Conditional · assuming a sub-exponentially hard subset-membership problem · \(Self.dlo24)")
    }

    @Test("a variant titled by its id, from an older clone, is named by the app's own label")
    func legacyVariant() {
        let barrier = parts("""
            type: barrier
            strength: conditional
            conditional-on: [legacy-variant]
            """)
        let label = Self.labels.label("legacy-variant")
        #expect(barrier == ["Conditional", "assuming [[hash-function#legacy|\(label)]]"])
    }

    @Test("other page types get no line")
    func otherTypes() {
        let primitive = parts("type: primitive")
        let line = RelationMeta.line(
            for: frontmatter("type: primitive"), manifest: Self.manifest, labels: Self.labels)
        #expect(primitive.isEmpty)
        #expect(line == nil)
    }

    // MARK: Pieces

    @Test("a wrapped line never starts with a separator, and the line ends in its marker")
    func separatorAndMarker() throws {
        #expect(RelationMeta.separator == "\u{00A0}· ")
        let barrier = frontmatter("type: barrier\nstrength: unconditional\nsource: [folklore]")
        let built = RelationMeta.line(for: barrier, manifest: Self.manifest, labels: Self.labels)
        let line = try #require(built)
        #expect(line == "Unconditional\u{00A0}· folklore <!-- relation-meta -->")
    }

    @Test("renderSource shows the citation key")
    func renderSource() {
        let bare = RelationMeta.renderSource("[[RSA78 - A method for obtaining digital signatures]]")
        let aliased = RelationMeta.renderSource(Self.dlo24)
        let folklore = RelationMeta.renderSource("folklore")
        #expect(bare == "[[RSA78 - A method for obtaining digital signatures|RSA78]]")
        #expect(aliased == Self.dlo24)
        #expect(folklore == "folklore")
    }

    @Test("escapeOutsideMath keeps math and code spans and escapes the rest")
    func escapeOutsideMath() {
        let cases: [(String, String)] = [
            ("$k$-Linear", "$k$-Linear"),
            ("IND$-CPA", #"IND\$-CPA"#),
            ("a $x$ b $", #"a $x$ b \$"#),
            ("$$x$ $y$$", "$$x$ $y$$"),
            (#"IND\$-CPA"#, #"IND\$-CPA"#),
            ("`$` [B]", #"`$` \[B\]"#),
            ("$[B]$", "$[B]$"),
        ]
        for (input, expected) in cases {
            let escaped = RelationMeta.escapeOutsideMath(input)
            #expect(escaped == expected, "escaping \(input)")
        }
    }

    @Test("an ordinary capitalised heading is lower-cased; an acronym is kept")
    func variantDisplay() {
        let ordinary = RelationMeta.variantDisplay("Collision resistance")
        let acronym = RelationMeta.variantDisplay("CCA1 Security")
        let lowerFirst = RelationMeta.variantDisplay("IND-CPA security")
        #expect(ordinary == "collision resistance")
        #expect(acronym == "CCA1 Security")
        #expect(lowerFirst == "IND-CPA security")
    }

    // MARK: Splicing

    @Test("the line goes directly under the H1, as its own paragraph")
    func insertUnderH1() {
        let underH1 = RelationMeta.insertUnderH1("LINE", into: "\n# A ⇒ B\n## Statement\n\nText.")
        #expect(underH1 == "\n# A ⇒ B\n\nLINE\n\n## Statement\n\nText.")

        // It does not merge with a paragraph that follows the H1 directly.
        let beforeIntro = RelationMeta.insertUnderH1("LINE", into: "# T\nIntro.")
        #expect(beforeIntro == "# T\n\nLINE\n\nIntro.")

        // A `#` line inside fenced code is not the H1.
        let fenced = RelationMeta.insertUnderH1("LINE", into: "```sh\n# not a heading\n```\n# Title\n")
        #expect(fenced.contains("# Title\n\nLINE\n"))
        #expect(fenced.contains("# not a heading\n```"))

        // With no H1 it leads the body.
        let noH1 = RelationMeta.insertUnderH1("LINE", into: "\n## Statement")
        #expect(noH1 == "\nLINE\n\n## Statement")
    }

    // MARK: Render request

    static let fixture: [String: String] = [
        "Reductions/a-to-b.md": """
            ---
            type: reduction
            status: draft
            title: "A ⇒ B"
            aliases: []
            id: red-a-to-b
            kind: implication
            hypotheses: [a]
            conclusion: b
            class: fully-black-box
            model: rom
            source:
              - "[[KEY - Paper Title|KEY]]"
            security-loss: "$O(q)$ loss"
            ---

            # A ⇒ B

            ## Statement

            Uses [$k$-Lin](b-page#sec) and [gone](missing-page).
            """,
        "Primitives/b-page.md": """
            ---
            type: primitive
            status: draft
            title: B
            aliases: []
            ---

            # B

            ## Sec
            """,
        "Glossary/reduction-classes.md": """
            ---
            type: glossary
            status: draft
            title: Reduction classes
            aliases: []
            ---

            # Reduction classes

            ### Fully black-box
            """,
        "Glossary/random-oracle-model.md": """
            ---
            type: glossary
            status: draft
            title: Random oracle model
            aliases: []
            ---

            # Random oracle model
            """,
        "References/KEY - Paper Title.md": """
            ---
            type: reference
            status: draft
            title: KEY
            aliases: []
            ---

            # Paper Title
            """,
    ]

    static func makeIndex() throws -> (WikiIndex, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-relation-meta-\(UUID().uuidString)")
        for (path, contents) in fixture {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (WikiIndex.build(contentRoot: root), root)
    }

    @Test("a render request carries the line under the H1, with its links resolved")
    func renderRequest() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(index.pages["Reductions/a-to-b.md"])

        var renderer = PageRenderer(index: index)
        renderer.relations = Self.manifest
        renderer.relationLabels = Self.labels
        let request = renderer.request(for: page)

        let classLink = "[[reduction-classes#fully-black-box|Fully-black-box reduction]]"
        let modelLink = "[[random-oracle-model|random oracle model]]"
        let source = "[[KEY - Paper Title|KEY]]"
        let line = [classLink, modelLink, source, "security loss: $O(q)$ loss"]
            .joined(separator: RelationMeta.separator) + " " + RelationMeta.marker
        #expect(request.markdown.contains("# A ⇒ B\n\n" + line + "\n"))

        let classHref = request.links[classLink]?.href
        let modelHref = request.links[modelLink]?.href
        let sourceHref = request.links[source]?.href
        #expect(classHref == CCwikiURL.page(
            path: "Glossary/reduction-classes.md", anchor: "fully-black-box"))
        #expect(modelHref == CCwikiURL.page(path: "Glossary/random-oracle-model.md"))
        #expect(sourceHref == CCwikiURL.page(path: "References/KEY - Paper Title.md"))

        // The body's markdown links are in the same map, keyed by destination.
        let markdownHref = request.links["b-page#sec"]?.href
        let markdownKind = request.links["b-page#sec"]?.kind
        #expect(markdownHref == CCwikiURL.page(path: "Primitives/b-page.md", anchor: "sec"))
        #expect(markdownKind == "page")
        #expect(request.links["missing-page"] == nil)
        #expect(request.notices.map(\.text) == ["1 link on this page has no target."])
    }

    @Test("a page that is not a reduction or barrier is sent as written")
    func otherPagesUntouched() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(index.pages["Primitives/b-page.md"])

        var renderer = PageRenderer(index: index)
        renderer.relations = Self.manifest
        let request = renderer.request(for: page)
        #expect(request.markdown == page.body)
    }
}
