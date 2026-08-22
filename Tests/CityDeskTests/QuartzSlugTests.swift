import Testing
@testable import CityDesk

/// A port of `quartz/util/path.test.ts` from the wiki repo, assertion for
/// assertion, plus the `sluggify` and `splitAnchor` vectors that upstream only
/// covers indirectly.
///
/// This suite is the contract: if CityDesk's slug rules drift from Quartz's,
/// the app shows links the website does not have (or hides links it does), and
/// that is invisible in normal use until someone clicks one.
struct QuartzSlugTests {

    // MARK: sluggify — the file-path slugifier

    @Test("sluggify preserves case and strips almost nothing")
    func sluggify() {
        let cases: [(String, String)] = [
            ("note with spaces", "note-with-spaces"),
            ("what about r&d?", "what-about-r-and-d"),
            ("special chars #3", "special-chars-3"),
            ("50% off", "50-percent-off"),
            // Real reference filenames — the punctuation must survive verbatim.
            ("AKS83 - An 0(n log n) sorting network",
             "AKS83---An-0(n-log-n)-sorting-network"),
            ("AMYY25 - Evasive LWE Attacks, Variants & Obfustopia",
             "AMYY25---Evasive-LWE-Attacks,-Variants--and--Obfustopia"),
            ("GG98 - On the possibility of basing Cryptography on the assumption that P != NP",
             "GG98---On-the-possibility-of-basing-Cryptography-on-the-assumption-that-P-!=-NP"),
            ("Zal97 - Grover's quantum searching algorithm is optimal",
             "Zal97---Grover's-quantum-searching-algorithm-is-optimal"),
            ("Ω/Ünïcode Page", "Ω/Ünïcode-Page"),
            ("trailing/", "trailing"),
        ]
        for (input, expected) in cases {
            #expect(QuartzSlug.sluggify(input) == expected, "sluggify(\(input))")
        }
    }

    // MARK: slugifyFilePath

    @Test("slugifyFilePath matches path.test.ts")
    func slugifyFilePath() {
        let cases: [(String, String)] = [
            ("content/index.md", "content/index"),
            ("content/index.html", "content/index"),
            ("content/_index.md", "content/index"),
            ("/content/index.md", "content/index"),
            ("content/cool.png", "content/cool.png"),
            ("index.md", "index"),
            ("test.mp4", "test.mp4"),
            ("note with spaces.md", "note-with-spaces"),
            ("notes.with.dots.md", "notes.with.dots"),
            ("test/special chars?.md", "test/special-chars"),
            ("test/special chars #3.md", "test/special-chars-3"),
            ("cool/what about r&d?.md", "cool/what-about-r-and-d"),
        ]
        for (input, expected) in cases {
            #expect(QuartzSlug.slugifyFilePath(input) == expected, "slugifyFilePath(\(input))")
        }
    }

    @Test("file extensions are ASCII-alphanumeric and anchored to the end")
    func fileExtension() {
        #expect(QuartzSlug.fileExtension("foo.tar.gz") == ".gz")
        #expect(QuartzSlug.fileExtension("notes.with.dots.md") == ".md")
        #expect(QuartzSlug.fileExtension("foo.") == nil)
        #expect(QuartzSlug.fileExtension("P != NP") == nil)
        #expect(QuartzSlug.fileExtension("no-extension") == nil)
        #expect(QuartzSlug.fileExtension("a.PNG") == ".PNG")
    }

    // MARK: simplifySlug

    @Test("simplifySlug trims the index segment")
    func simplifySlug() {
        #expect(QuartzSlug.simplifySlug("index") == "/")
        #expect(QuartzSlug.simplifySlug("abc") == "abc")
        #expect(QuartzSlug.simplifySlug("abc/index") == "abc/")
        #expect(QuartzSlug.simplifySlug("abc/def") == "abc/def")
    }

    @Test("endsWith is segment-aware")
    func endsWith() {
        #expect(QuartzSlug.endsWith("notindex", "index") == false)
        #expect(QuartzSlug.endsWith("abc/index", "index"))
        #expect(QuartzSlug.endsWith("index", "index"))
        #expect(QuartzSlug.trimSuffix("abc/index", "index") == "abc/")
        #expect(QuartzSlug.trimSuffix("notindex", "index") == "notindex")
    }

    // MARK: transformInternalLink

    @Test("transformInternalLink matches path.test.ts")
    func transformInternalLink() {
        let cases: [(String, String)] = [
            ("", "."),
            (".", "."),
            ("./", "./"),
            ("./index", "./"),
            ("./index#abc", "./#abc"),
            ("./index.html", "./"),
            ("./index.md", "./"),
            ("./index.css", "./index.css"),
            ("content", "./content"),
            ("content/test.md", "./content/test"),
            ("content/test.pdf", "./content/test.pdf"),
            ("./content/test.md", "./content/test"),
            ("../content/test.md", "../content/test"),
            ("tags/", "./tags/"),
            ("/tags/", "./tags/"),
            ("content/with spaces", "./content/with-spaces"),
            ("content/with spaces/index", "./content/with-spaces/"),
            ("content/with spaces#and Anchor!", "./content/with-spaces#and-anchor"),
        ]
        for (input, expected) in cases {
            #expect(QuartzSlug.transformInternalLink(input) == expected,
                    "transformInternalLink(\(input))")
        }
    }

    // MARK: pathToRoot / joinSegments / resolveRelative

    @Test("pathToRoot matches path.test.ts")
    func pathToRoot() {
        #expect(QuartzSlug.pathToRoot("index") == ".")
        #expect(QuartzSlug.pathToRoot("abc") == ".")
        #expect(QuartzSlug.pathToRoot("abc/def") == "..")
        #expect(QuartzSlug.pathToRoot("abc/def/ghi") == "../..")
        #expect(QuartzSlug.pathToRoot("abc/def/index") == "../..")
    }

    @Test("joinSegments matches path.test.ts")
    func joinSegments() {
        #expect(QuartzSlug.joinSegments("a", "b") == "a/b")
        #expect(QuartzSlug.joinSegments("a/", "b") == "a/b")
        #expect(QuartzSlug.joinSegments("a", "b/") == "a/b/")
        #expect(QuartzSlug.joinSegments("a/", "b/") == "a/b/")

        #expect(QuartzSlug.joinSegments("/a", "b") == "/a/b")
        #expect(QuartzSlug.joinSegments("/a/", "b") == "/a/b")
        #expect(QuartzSlug.joinSegments("/a", "b/") == "/a/b/")
        #expect(QuartzSlug.joinSegments("/a/", "b/") == "/a/b/")

        #expect(QuartzSlug.joinSegments("/a/", "b", "/") == "/a/b/")

        // Protocol specifiers survive because stripSlashes only takes one
        // leading slash off.
        #expect(QuartzSlug.joinSegments("https://example.com", "a") == "https://example.com/a")
        #expect(QuartzSlug.joinSegments("https://example.com/", "a") == "https://example.com/a")
        #expect(QuartzSlug.joinSegments("https://example.com", "a/") == "https://example.com/a/")
        #expect(QuartzSlug.joinSegments("https://example.com/", "a/") == "https://example.com/a/")
    }

    @Test("resolveRelative matches path.test.ts")
    func resolveRelative() {
        #expect(QuartzSlug.resolveRelative("index", "index") == "./")
        #expect(QuartzSlug.resolveRelative("index", "abc") == "./abc")
        #expect(QuartzSlug.resolveRelative("index", "abc/def") == "./abc/def")
        #expect(QuartzSlug.resolveRelative("index", "abc/def/ghi") == "./abc/def/ghi")

        #expect(QuartzSlug.resolveRelative("abc/def", "index") == "../")
        #expect(QuartzSlug.resolveRelative("abc/def", "abc") == "../abc")
        #expect(QuartzSlug.resolveRelative("abc/def", "abc/def") == "../abc/def")
        #expect(QuartzSlug.resolveRelative("abc/def", "ghi/jkl") == "../ghi/jkl")

        #expect(QuartzSlug.resolveRelative("abc/index", "index") == "../")
        #expect(QuartzSlug.resolveRelative("abc/def/index", "index") == "../../")
        #expect(QuartzSlug.resolveRelative("index", "abc/index") == "./abc/")
        #expect(QuartzSlug.resolveRelative("abc/def", "abc/index") == "../abc/")

        #expect(QuartzSlug.resolveRelative("abc/def", "") == "../")
        #expect(QuartzSlug.resolveRelative("abc/def", "ghi") == "../ghi")
        #expect(QuartzSlug.resolveRelative("abc/def", "ghi/") == "../ghi/")
    }

    // MARK: splitAnchor

    @Test("splitAnchor reproduces JS split(sep, 2) and the PDF carve-out")
    func splitAnchor() {
        func check(_ input: String, _ path: String, _ anchor: String) {
            let result = QuartzSlug.splitAnchor(input)
            #expect(result.path == path && result.anchor == anchor,
                    "splitAnchor(\(input)) == \(result)")
        }
        check("a#B", "a", "#b")
        check("a", "a", "")
        check("a#", "a", "#")
        // JS `split("#", 2)` splits fully and *then* truncates, so `#y` is lost.
        check("a#x#y", "a", "#x")
        check("foo##Sub", "foo", "#")
        check("#Ring LWE", "", "#ring-lwe")
        // PDF fragments are page directives, not headings — left verbatim.
        check("a.pdf#page=3", "a.pdf", "#page=3")
    }

    // MARK: transformLink — the three strategies

    private static let allSlugs = [
        "a/b/c", "a/b/d", "a/b/index", "e/f", "e/g/h", "index", "a/test.png",
    ]

    private func link(_ src: String, _ target: String, _ strategy: QuartzSlug.Strategy) -> String {
        QuartzSlug.transformLink(
            src: src, target: target, strategy: strategy, allSlugs: Self.allSlugs)
    }

    @Test("absolute strategy")
    func absoluteStrategy() {
        #expect(link("a/b/c", "a/b/d", .absolute) == "../../a/b/d")
        #expect(link("a/b/c", "a/b/index", .absolute) == "../../a/b/")
        #expect(link("a/b/c", "e/f", .absolute) == "../../e/f")
        #expect(link("a/b/c", "e/g/h", .absolute) == "../../e/g/h")
        #expect(link("a/b/c", "index", .absolute) == "../../")
        #expect(link("a/b/c", "index.png", .absolute) == "../../index.png")
        #expect(link("a/b/c", "index#abc", .absolute) == "../../#abc")
        #expect(link("a/b/c", "tag/test", .absolute) == "../../tag/test")
        #expect(link("a/b/c", "a/b/c#test", .absolute) == "../../a/b/c#test")
        #expect(link("a/b/c", "a/test.png", .absolute) == "../../a/test.png")

        #expect(link("a/b/index", "a/b/d", .absolute) == "../../a/b/d")
        #expect(link("a/b/index", "a/b", .absolute) == "../../a/b")
        #expect(link("a/b/index", "index", .absolute) == "../../")

        #expect(link("index", "index", .absolute) == "./")
        #expect(link("index", "a/b/c", .absolute) == "./a/b/c")
        #expect(link("index", "a/b/index", .absolute) == "./a/b/")
    }

    @Test("shortest strategy — what cryptology.city is configured for")
    func shortestStrategy() {
        #expect(link("a/b/c", "d", .shortest) == "../../a/b/d")
        #expect(link("a/b/c", "h", .shortest) == "../../e/g/h")
        #expect(link("a/b/c", "a/b/index", .shortest) == "../../a/b/")
        #expect(link("a/b/c", "a/b/index.png", .shortest) == "../../a/b/index.png")
        #expect(link("a/b/c", "a/b/index#abc", .shortest) == "../../a/b/#abc")
        #expect(link("a/b/c", "index", .shortest) == "../../")
        #expect(link("a/b/c", "index.png", .shortest) == "../../index.png")
        #expect(link("a/b/c", "test.png", .shortest) == "../../a/test.png")
        #expect(link("a/b/c", "index#abc", .shortest) == "../../#abc")

        #expect(link("a/b/index", "d", .shortest) == "../../a/b/d")
        #expect(link("a/b/index", "h", .shortest) == "../../e/g/h")
        #expect(link("a/b/index", "a/b/index", .shortest) == "../../a/b/")
        #expect(link("a/b/index", "index", .shortest) == "../../")

        #expect(link("index", "d", .shortest) == "./a/b/d")
        #expect(link("index", "h", .shortest) == "./e/g/h")
        #expect(link("index", "a/b/index", .shortest) == "./a/b/")
        #expect(link("index", "index", .shortest) == "./")
    }

    @Test("relative strategy")
    func relativeStrategy() {
        #expect(link("a/b/c", "d", .relative) == "./d")
        #expect(link("a/b/c", "index", .relative) == "./")
        #expect(link("a/b/c", "../../../index", .relative) == "../../../")
        #expect(link("a/b/c", "../../../index.png", .relative) == "../../../index.png")
        #expect(link("a/b/c", "../../../index#abc", .relative) == "../../../#abc")
        #expect(link("a/b/c", "../../../", .relative) == "../../../")
        #expect(link("a/b/c", "../../../a/test.png", .relative) == "../../../a/test.png")
        #expect(link("a/b/c", "../../../e/g/h", .relative) == "../../../e/g/h")
        #expect(link("a/b/c", "../../../e/g/h#abc", .relative) == "../../../e/g/h#abc")

        #expect(link("a/b/index", "../../index", .relative) == "../../")
        #expect(link("a/b/index", "../../", .relative) == "../../")
        #expect(link("a/b/index", "../../e/g/h", .relative) == "../../e/g/h")
        #expect(link("a/b/index", "c", .relative) == "./c")

        #expect(link("index", "e/g/h", .relative) == "./e/g/h")
        #expect(link("index", "a/b/index", .relative) == "./a/b/")
    }

    @Test("two basename matches silently fall back to absolute-from-root")
    func ambiguousBasenameFallsBack() {
        // `c` is unique, so shortest fires; add a second and it must not.
        let ambiguous = Self.allSlugs + ["z/c"]
        #expect(QuartzSlug.transformLink(
            src: "a/b/d", target: "c", strategy: .shortest, allSlugs: Self.allSlugs)
            == "../../a/b/c")
        #expect(QuartzSlug.transformLink(
            src: "a/b/d", target: "c", strategy: .shortest, allSlugs: ambiguous)
            == "../../c")
    }
}

/// `github-slugger@2.0.0`, which assigns heading anchors. A *different*
/// algorithm from the path slugifier above — lowercasing, and it deletes
/// nearly all punctuation.
struct GithubSluggerTests {

    @Test("slug matches github-slugger 2.0.0")
    func slug() {
        let cases: [(String, String)] = [
            ("Hello, World!", "hello-world"),
            ("Foo & Bar", "foo--bar"),
            ("C++", "c"),
            ("a.b", "ab"),
            ("Über Café", "über-café"),
            ("日本語 テスト", "日本語-テスト"),
            ("What about r&d?", "what-about-rd"),
            ("Section 1: Overview", "section-1-overview"),
            ("  spaced  out  ", "--spaced--out--"),
            ("naïve—dash", "naïvedash"),
            ("x^2 + y_2", "x2--y_2"),
            ("emoji 🎉 here", "emoji--here"),
            (#"$O(n\log n)$"#, "onlog-n"),
            ("Zero-Knowledge Proofs (ZKP)", "zero-knowledge-proofs-zkp"),
            ("A/B testing", "ab-testing"),
            ("Don't Panic", "dont-panic"),
            ("ELI5: what?", "eli5-what"),
            ("Ω-notation", "ω-notation"),
            // Real headings from the corpus.
            ("Ring LWE", "ring-lwe"),
            ("Sparse Learning Parity with Noise", "sparse-learning-parity-with-noise"),
            ("Secret-Key PIR (SK-PIR)", "secret-key-pir-sk-pir"),
            ("Symmetric private information retrieval (Single-server)",
             "symmetric-private-information-retrieval-single-server"),
        ]
        for (input, expected) in cases {
            #expect(GithubSlugger.slug(input) == expected, "slug(\(input))")
        }
    }

    @Test("the deduplicating instance numbers repeats from -1")
    func deduplication() {
        var slugger = GithubSlugger()
        #expect(slugger.slug("Syntax") == "syntax")
        #expect(slugger.slug("Syntax") == "syntax-1")
        #expect(slugger.slug("Syntax") == "syntax-2")
        #expect(slugger.slug("Security") == "security")
        slugger.reset()
        #expect(slugger.slug("Syntax") == "syntax")
    }

    @Test("×/÷ are symbols, not letters, so they are deleted")
    func mathSymbolsAreDeleted() {
        #expect(GithubSlugger.slug("a×b") == "ab")
        #expect(GithubSlugger.slug("a÷b") == "ab")
        #expect(GithubSlugger.slug("ªµº") == "ªµº")
    }
}
