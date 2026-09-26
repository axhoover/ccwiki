import Foundation
import Testing
@testable import CCwiki

/// End-to-end `[[wikilink]]` → file resolution.
///
/// The fixture below is a miniature of the real wiki: the same directory
/// layout, the same alias conventions, and one of each hazard the corpus
/// actually contains — a two-owner alias, a case-mismatched alias, a
/// `KEY - Title.md` reference filename with punctuation, a folder link with no
/// index note, and an asset embed.
struct WikilinkResolutionTests {

    // MARK: Fixture

    /// path → file contents, written to a temp directory per test run.
    static let fixture: [String: String] = [
        "index.md": """
        ---
        type: note
        status: draft
        title: Cryptology City
        aliases: []
        ---

        # Cryptology City

        Browse [[Primitives]], [[Assumptions]] and [[References]].
        See [[pseudorandom-function|PRFs]] and [[PRF]] and [[Pseudorandom function]].
        Deep link: [[Primitives/oblivious-transfer]].
        A paper: [[AKS83 - An 0(n log n) sorting network]].
        Ampersand: [[AMYY25 - Evasive LWE Attacks, Variants & Obfustopia]].
        Case mismatch: [[Oblivious transfer|OT]].
        Missing: [[collision-resistant-hash-function|CRHF]].
        Not a link: `[[pseudorandom-function]]` in code.
        Also not a link:

        ```pseudocode
        \\State $x \\gets [[not-a-link]]$
        ```
        """,

        "Primitives/pseudorandom-function.md": """
        ---
        type: primitive
        status: draft
        aliases:
          - PRF
          - Pseudorandom function
        title: Pseudorandom function
        ---

        # Pseudorandom function

        ## Syntax

        A PRF is a pair of algorithms.

        ## Properties

        ### Security

        Games go here.

        ## Syntax

        A repeated heading, to exercise anchor deduplication.

        # Other results

        - PRPs over large domains are iPRFs — [[pseudorandom-permutation|PRP]]
        - Uses [[oblivious-transfer#Syntax]]
        - Self anchor: [[#Properties|properties]]
        """,

        "Primitives/oblivious-transfer.md": """
        ---
        type: primitive
        status: draft
        aliases:
          - OT
        title: Oblivious transfer
        ---

        # Oblivious transfer

        ## Syntax

        See [[Rab81]] and [[interactive-protocol|two-party protocol]].
        """,

        "Primitives/pseudorandom-permutation.md": """
        ---
        type: primitive
        status: stub
        aliases:
          - PRP
        title: Pseudorandom permutation
        ---

        # Pseudorandom permutation
        """,

        "Assumptions/learning-with-errors.md": """
        ---
        type: assumption
        status: draft
        aliases:
          - LWE
        title: Learning with errors
        ---

        # Learning with errors

        ## Assumption

        ## Ring LWE

        Also see [[#Ring LWE|Ring LWE (RLWE)]].
        """,

        "Assumptions/planted-clique.md": """
        ---
        type: assumption
        status: draft
        aliases:
          - planted-clique
        title: Planted clique
        ---

        # Planted clique
        """,

        "Complexity/polynomial-time.md": """
        ---
        type: complexity-class
        status: draft
        aliases:
          - P
        title: Polynomial time
        ---

        # Polynomial time
        """,

        "Complexity/sharp-p.md": """
        ---
        type: complexity-class
        status: draft
        aliases:
          - "#P"
        title: "#P"
        ---

        # Sharp P
        """,

        "Glossary/interactive-protocol.md": """
        ---
        type: glossary
        status: draft
        aliases:
          - interactive-protocol
        title: Interactive protocol
        ---

        # Interactive protocol
        """,

        "References/Rabin81 - How to Exchange Secrets with Oblivious Transfer.md": """
        ---
        type: reference
        status: draft
        title: "Rab81"
        source: https://eprint.iacr.org/2005/187
        authors: Michael O. Rabin
        venue: Harvard TR-81
        published: 1981
        aliases:
          - Rab81
        cryptobib_key: EPRINT:Rabin81
        ---

        # [Rab81] How to Exchange Secrets with Oblivious Transfer
        """,

        "References/AKS83 - An 0(n log n) sorting network.md": """
        ---
        type: reference
        status: stub
        title: "AKS83"
        source: https://doi.org/10.1145/800061.808726
        authors: Miklós Ajtai, János Komlós, Endre Szemerédi
        venue: STOC 1983
        published: 1983
        aliases:
          - AKS83
        cryptobib_key: STOC:AKS83
        ---
        """,

        "References/AMYY25 - Evasive LWE Attacks, Variants & Obfustopia.md": """
        ---
        type: reference
        status: stub
        title: "AMYY25"
        source: https://eprint.iacr.org/2025/375
        authors: A, M, Y, Y
        venue: Eurocrypt 2025
        published: 2025
        aliases:
          - AMYY25
        cryptobib_key: EPRINT:AMYY25
        ---
        """,

        "Files/Minicrypt.png": "not really a png",
        // Excluded from the site by quartz.config.ts ignorePatterns.
        "Templates/Primitive.md": """
        ---
        type: primitive
        status: stub
        aliases: []
        title: Full primitive name
        ---
        """,
        // No dot in the filename, so Quartz's `**/*.*` glob never sees it.
        "Primitives/NOTES": "invisible to the site",
    ]

    static func makeIndex() throws -> (WikiIndex, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-fixture-\(UUID().uuidString)")
        for (path, contents) in fixture {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (WikiIndex.build(contentRoot: root), root)
    }

    /// Resolve the first wikilink in `text` as if it appeared on `source`.
    private func resolve(
        _ text: String, from source: String, in index: WikiIndex
    ) throws -> WikiIndex.Target {
        let links = WikilinkParser.links(in: text)
        let link = try #require(links.first, "no wikilink parsed from \(text)")
        return index.resolve(link, from: source)
    }

    // MARK: Index shape

    @Test("the index mirrors Quartz's glob and ignore rules")
    func indexShape() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(index.pages["Templates/Primitive.md"] == nil,
                "Templates/ is in quartz.config.ts ignorePatterns")
        #expect(index.pages["Primitives/NOTES"] == nil,
                "a file with no dot is invisible to glob(**/*.*)")
        #expect(index.assets["Files/Minicrypt.png"] == "Files/Minicrypt.png")
        #expect(index.folders.contains("Primitives"))
        #expect(index.folders.contains("References"))
        #expect(index.allSlugs.contains("Primitives/pseudorandom-function"))
        #expect(index.allSlugs.contains("PRF"), "aliases become root-level slugs")
        #expect(index.allSlugs.contains("Pseudorandom-function"))
        #expect(index.allSlugs.contains("P"), "alias `#P` slugifies to `P`")
    }

    @Test("an alias claimed by two pages is reported rather than silently picked")
    func ambiguousAlias() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        // `P` is claimed by polynomial-time (alias `P`) and sharp-p (alias `#P`
        // slugifies to `P`) — exactly the collision the real corpus has.
        let owners = try #require(index.ambiguousAliases["P"])
        #expect(owners.count == 2)
        #expect(owners.contains("Complexity/polynomial-time.md"))
        #expect(owners.contains("Complexity/sharp-p.md"))
    }

    // MARK: Resolution

    @Test("a unique basename resolves through the shortest strategy")
    func uniqueBasename() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[pseudorandom-function|PRFs]]", from: "index.md", in: index)
            == .page(path: "Primitives/pseudorandom-function.md", anchor: nil))
        #expect(try resolve("[[pseudorandom-permutation|PRP]]",
                            from: "Primitives/pseudorandom-function.md", in: index)
            == .page(path: "Primitives/pseudorandom-permutation.md", anchor: nil))
    }

    @Test("aliases resolve, including from a deep source page")
    func aliases() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[PRF]]", from: "index.md", in: index)
            == .page(path: "Primitives/pseudorandom-function.md", anchor: nil))
        #expect(try resolve("[[Pseudorandom function]]", from: "index.md", in: index)
            == .page(path: "Primitives/pseudorandom-function.md", anchor: nil))
        #expect(try resolve("[[OT]]", from: "Primitives/pseudorandom-function.md", in: index)
            == .page(path: "Primitives/oblivious-transfer.md", anchor: nil))
        #expect(try resolve("[[Rab81]]", from: "Primitives/oblivious-transfer.md", in: index)
            == .page(path: "References/Rabin81 - How to Exchange Secrets with Oblivious Transfer.md",
                     anchor: nil))
    }

    @Test("two basename matches fall through to the root-absolute slug")
    func twoMatchesFallThrough() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        // `interactive-protocol` matches both the file slug
        // `Glossary/interactive-protocol` and the root alias slug
        // `interactive-protocol`, so the shortest search declines and the
        // absolute branch lands on the alias — which happens to be the same page.
        #expect(try resolve("[[interactive-protocol|two-party protocol]]",
                            from: "Primitives/oblivious-transfer.md", in: index)
            == .page(path: "Glossary/interactive-protocol.md", anchor: nil))
        #expect(try resolve("[[planted-clique|planted clique conjecture]]",
                            from: "index.md", in: index)
            == .page(path: "Assumptions/planted-clique.md", anchor: nil))
    }

    @Test("anchors are slugified with github-slugger, not the path slugifier")
    func anchors() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[learning-with-errors#Ring LWE|Ring-LWE]]",
                            from: "Assumptions/planted-clique.md", in: index)
            == .page(path: "Assumptions/learning-with-errors.md", anchor: "ring-lwe"))
        // Already-slugified anchors are idempotent.
        #expect(try resolve("[[learning-with-errors#ring-lwe|Ring LWE]]",
                            from: "Assumptions/planted-clique.md", in: index)
            == .page(path: "Assumptions/learning-with-errors.md", anchor: "ring-lwe"))
        #expect(try resolve("[[oblivious-transfer#Syntax]]",
                            from: "Primitives/pseudorandom-function.md", in: index)
            == .page(path: "Primitives/oblivious-transfer.md", anchor: "syntax"))
    }

    @Test("an empty target is a same-page anchor")
    func samePageAnchor() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[#Ring LWE|Ring LWE (RLWE)]]",
                            from: "Assumptions/learning-with-errors.md", in: index)
            == .samePage(anchor: "ring-lwe"))
        #expect(try resolve("[[#Properties|properties]]",
                            from: "Primitives/pseudorandom-function.md", in: index)
            == .samePage(anchor: "properties"))
    }

    @Test("a bare directory name resolves to a synthetic folder page")
    func folderLinks() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[Primitives]]", from: "index.md", in: index)
            == .folder(slug: "Primitives"))
        #expect(try resolve("[[References]]", from: "index.md", in: index)
            == .folder(slug: "References"))
    }

    @Test("a target containing a slash skips the shortest search")
    func explicitPath() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[Primitives/oblivious-transfer]]", from: "index.md", in: index)
            == .page(path: "Primitives/oblivious-transfer.md", anchor: nil))
    }

    @Test("reference filenames survive slugification verbatim")
    func referenceFilenames() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[AKS83 - An 0(n log n) sorting network]]",
                            from: "index.md", in: index)
            == .page(path: "References/AKS83 - An 0(n log n) sorting network.md", anchor: nil))
        // `&` expands to `-and-`, and the spaces around it become dashes too.
        #expect(try resolve("[[AMYY25 - Evasive LWE Attacks, Variants & Obfustopia]]",
                            from: "index.md", in: index)
            == .page(path: "References/AMYY25 - Evasive LWE Attacks, Variants & Obfustopia.md",
                     anchor: nil))
    }

    @Test("case is significant on the slug side")
    func caseSensitivity() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        // The alias is `Oblivious transfer`? No — the page's title is, but its
        // alias is `OT`. `[[Oblivious transfer]]` slugifies to
        // `Oblivious-transfer`, which nothing claims. The website shows this as
        // a dead link too; matching it case-insensitively would invent a link.
        let target = try resolve("[[Oblivious transfer|OT]]", from: "index.md", in: index)
        #expect(target.isResolved == false)
    }

    @Test("an unresolvable target is reported, not silently dropped")
    func unresolved() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = try resolve("[[collision-resistant-hash-function|CRHF]]",
                                 from: "index.md", in: index)
        #expect(target.isResolved == false)
    }

    @Test("an embed resolves to the asset and drops its anchor")
    func embeds() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let links = WikilinkParser.links(in: "![[Minicrypt.png]]")
        let link = try #require(links.first)
        #expect(link.isEmbed)
        #expect(index.resolve(link, from: "index.md") == .asset(path: "Files/Minicrypt.png"))
    }

    @Test("an http target is an external link, not a wiki page")
    func externalTargets() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try resolve("[[https://eprint.iacr.org/2025/375|ePrint]]",
                            from: "index.md", in: index)
            == .external(url: "https://eprint.iacr.org/2025/375"))
    }

    // MARK: Parsing

    @Test("wikilinks inside code spans and fences are not links")
    func codeIsNotLinked() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try #require(index.pages["index.md"])
        let targets = WikilinkParser.links(in: page.body).map(\.target)
        #expect(!targets.contains("not-a-link"), "a fenced pseudocode block is not linkable")
        #expect(targets.filter { $0 == "pseudorandom-function" }.count == 1,
                "the backticked copy must not be counted")
    }

    @Test("a comment hides its wikilinks, on one line or across several")
    func commentsAreNotLinked() {
        let text = """
            See [[visible]] and %%[[hidden-inline]]%% here.
            %%
            A note to self: compare with [[hidden-multiline]]
            and [[also-hidden]] before publishing.
            %%
            Then [[visible-again]].
            """
        let targets = WikilinkParser.links(in: text).map(\.target)
        #expect(targets == ["visible", "visible-again"])
    }

    @Test("every wikilink form parses")
    func parsing() throws {
        func parse(_ s: String) throws -> Wikilink {
            try #require(WikilinkParser.links(in: s).first, "no link in \(s)")
        }

        let plain = try parse("[[target]]")
        #expect(plain.target == "target" && plain.alias == nil && plain.rawAnchor == nil)

        let aliased = try parse("[[target|display text]]")
        #expect(aliased.target == "target" && aliased.alias == "display text")

        let anchored = try parse("[[target#Some Heading]]")
        #expect(anchored.target == "target" && anchored.rawAnchor == "#Some Heading")

        let both = try parse("[[target#Heading|display]]")
        #expect(both.target == "target" && both.rawAnchor == "#Heading" && both.alias == "display")

        let sameFile = try parse("[[#Heading|display]]")
        #expect(sameFile.target.isEmpty && sameFile.rawAnchor == "#Heading")

        let block = try parse("[[target#^abc123]]")
        #expect(block.isBlockRef && block.anchorText == "^abc123")

        let embed = try parse("![[Minicrypt.png]]")
        #expect(embed.isEmbed && embed.target == "Minicrypt.png")

        #expect(WikilinkParser.links(in: "[[a]] and [[b]] and [[c]]").count == 3)
    }

    // MARK: Backlinks

    @Test("backlinks are collected with the line that mentions them")
    func backlinks() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let map = index.backlinkMap()
        let incoming = try #require(map["Primitives/pseudorandom-function.md"])
        #expect(incoming.contains { $0.sourcePath == "index.md" })
        // Three links from index.md all point at the PRF page; it should appear once.
        #expect(incoming.filter { $0.sourcePath == "index.md" }.count == 1)

        let ot = try #require(map["Primitives/oblivious-transfer.md"])
        let fromPRF = try #require(ot.first { $0.sourcePath == "Primitives/pseudorandom-function.md" })
        #expect(fromPRF.context == "Uses oblivious-transfer#Syntax",
                "the list marker and the wikilink markup are stripped")
    }

    @Test("backlink context is reduced to prose")
    func backlinkContextIsPlainText() {
        let cases: [(String, String)] = [
            ("- PRFs imply iPRFs — [[HPPY25 - Plinko|HPPY25]]", "PRFs imply iPRFs — HPPY25"),
            ("- [[pseudorandom-permutation|PRP]]s are iPRFs", "PRPs are iPRFs"),
            ("The _alternating moduli assumption_ (also called _Crypto Dark Matter_[^1])",
             "The alternating moduli assumption (also called Crypto Dark Matter)"),
            ("* **Bold** and `code` and $x^2$", "Bold and code and x^2"),
            ("Unkeyed DEPIR with storage $O(N^{1+\\varepsilon})$",
             "Unkeyed DEPIR with storage O(N^{1+\\varepsilon})"),
            ("See [the site](https://cryptology.city) for more",
             "See the site for more"),
            ("An embed ![[Minicrypt.png]] inline", "An embed Minicrypt.png inline"),
        ]
        for (input, expected) in cases {
            #expect(WikiIndex.plainText(input) == expected, "plainText(\(input))")
        }
    }

    // MARK: Outline

    @Test("heading ids deduplicate the way rehype-slug does")
    func headingIds() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try #require(index.pages["Primitives/pseudorandom-function.md"])
        let ids = page.headings().map(\.id)
        #expect(ids == ["pseudorandom-function", "syntax", "properties", "security",
                        "syntax-1", "other-results"])
    }
}

/// The sidebar's shape. References are 68% of the wiki's pages, so leaving them
/// out of the tree is the difference between a navigable structure and a wall
/// of citation keys.
struct PageTreeTests {

    @Test("references are left out of the tree, everything else stays")
    func excludesReferences() throws {
        let (index, root) = try WikilinkResolutionTests.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let full = PageTreeNode.build(pages: index.allPages)
        let sidebar = PageTreeNode.build(pages: index.allPages, excluding: [.reference])

        #expect(full.contains { $0.name == "References" })
        #expect(!sidebar.contains { $0.name == "References" },
                "the tree should have no References folder at all")

        // Everything else survives, root pages included.
        for folder in ["Primitives", "Assumptions", "Complexity", "Glossary"] {
            #expect(sidebar.contains { $0.name == folder }, "lost \(folder)")
        }
        #expect(sidebar.contains { $0.page?.path == "index.md" })

        let referenceCount = index.allPages.count { $0.kind == .reference }
        #expect(referenceCount > 0, "the fixture should have references to exclude")
        #expect(sidebar.reduce(0) { $0 + $1.pageCount }
            == full.reduce(0) { $0 + $1.pageCount } - referenceCount)
    }

    @Test("a reference has no ancestor to reveal, a primitive does")
    func ancestors() {
        #expect(PageTreeNode.ancestors(of: "Primitives/pseudorandom-function.md") == ["Primitives"])
        #expect(PageTreeNode.ancestors(of: "index.md") == [])

        // Nothing to expand for a page the tree does not contain — otherwise
        // the expansion set fills with folder names that match no row.
        #expect(PageTreeNode.ancestors(
            of: "References/AKS83 - An 0(n log n) sorting network.md",
            excluding: [.reference]) == [])
        #expect(PageTreeNode.ancestors(
            of: "Primitives/pseudorandom-function.md", excluding: [.reference]) == ["Primitives"])
    }

    @Test("folders sort before root pages, and pages sort by title")
    func ordering() throws {
        let (index, root) = try WikilinkResolutionTests.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let tree = PageTreeNode.build(pages: index.allPages, excluding: [.reference])
        let folderCount = tree.prefix { $0.isFolder }.count
        #expect(tree.dropFirst(folderCount).allSatisfy { !$0.isFolder },
                "a root page appeared above a folder")

        let folderNames = tree.prefix(folderCount).map(\.name)
        #expect(folderNames == folderNames.sorted())

        if let primitives = tree.first(where: { $0.name == "Primitives" }) {
            let titles = primitives.children.map(\.name)
            #expect(titles == titles.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            })
        }
    }
}
