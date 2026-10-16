import Foundation
import Testing
@testable import CCwiki

/// Copy a proof (plans/relations-followups.md §3): the order a paper argues
/// in, the names it uses, the keys its bibliography has, and the honesty
/// contract of relations-explorer.md §1 carried into the copy. Pure: a small
/// manifest with a curation, and a temporary wiki holding the reference
/// pages its `source` entries link to.
///
/// ```
/// crhf ⇒ owf ⇒ prg ⇒ prf ⇒ ske;  kem ∧ ske ⇒ pke;  gapsvp ⇒ lwe ⇒ pke (quantum, then standard)
/// prp ⇒ invertible-prf (weakened) ⇒ prf;  cpir ⇒ ot ⇒ mpc (Kil88 needs malicious OT; DMO00 gives it)
/// isis ⇔ sis (quantum; its reverse needs SIS with a prime modulus);  ssddh ⇒ ke (SSDDH refuted)
/// a ∧ b ∧ c ⇒ d ⇒ ke (both cite KR03, whose entry's key is KemReg03)
/// ```
struct ProofExportTests {

    static let revision = "ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157"

    // MARK: Fixture

    static let hill99 = "[[HILL99 - A Pseudorandom Generator from Any One-Way Function|HILL99]]"
    static let ggm86 = "[[GGM86 - How to construct random functions|GGM86]]"
    static let cs03 = "[[CS03 - Design and Analysis of Practical Public-Key Encryption Schemes|CS03]]"
    static let dmo00 = "[[DMO00 - Single Database Private Information Retrieval Implies Oblivious Transfer|DMO00]]"
    static let kil88 = "[[Kil88 - Founding cryptography on oblivious transfer|Kil88]]"
    static let gmw87 = "[[GMW87 - How to play ANY mental game|GMW87]]"
    static let reg05 = "[[Reg05 - On lattices and learning with errors|Reg05]]"
    static let jdf11 = "[[JDF11 - Towards quantum-resistant cryptosystems from supersingular elliptic curve isogenies|JDF11]]"
    static let kr03 = "[[KR03 - 3-Local Hamiltonian is QMA-complete|KR03]]"
    static let dam87 = "[[Dam87 - Collision free hash functions|Dam87]]"

    static let gmw87Entry = """
        @inproceedings{GMW87,
          author    = {Oded Goldreich and Silvio Micali and Avi Wigderson},
          title     = {How to Play {ANY} Mental Game},
          year      = {1987}
        }
        """

    static let kr03Entry = """
        @Article{KemReg03,
          author  = {Julia Kempe and Oded Regev},
          title   = {3-Local {H}amiltonian is {QMA}-complete},
          journal = {Quantum Information \\& Computation},
          year    = {2003}
        }
        """

    /// A reference page as the wiki writes one: the key as its title, and a
    /// CryptoBib key, an inline entry, or neither.
    static func referencePage(_ key: String, cryptobib: String? = nil, bibtex: String? = nil) -> String {
        var lines = ["---", "type: reference", "status: draft", "title: \(key)"]
        if let cryptobib { lines.append("cryptobib_key: \(cryptobib)") }
        if let bibtex {
            lines.append("bibtex: |")
            lines += bibtex.components(separatedBy: "\n").map { "  " + $0 }
        }
        lines += ["---", "", "# [\(key)] A paper", ""]
        return lines.joined(separator: "\n")
    }

    static let referencePages: [String: String] = [
        "References/HILL99 - A Pseudorandom Generator from Any One-Way Function.md":
            referencePage("HILL99", cryptobib: "HILL99"),
        "References/GGM86 - How to construct random functions.md":
            referencePage("GGM86", cryptobib: "GolGolMic86"),
        "References/CS03 - Design and Analysis of Practical Public-Key Encryption Schemes.md":
            referencePage("CS03", cryptobib: "CraSho03"),
        "References/DMO00 - Single Database Private Information Retrieval Implies Oblivious Transfer.md":
            referencePage("DMO00", cryptobib: "EC:DiCMalOst00"),
        "References/Kil88 - Founding cryptography on oblivious transfer.md":
            referencePage("Kil88", cryptobib: "STOC:Kilian88"),
        "References/GMW87 - How to play ANY mental game.md":
            referencePage("GMW87", bibtex: gmw87Entry),
        "References/Reg05 - On lattices and learning with errors.md":
            referencePage("Reg05", cryptobib: "STOC:Regev05"),
        "References/JDF11 - Towards quantum-resistant cryptosystems from supersingular elliptic curve isogenies.md":
            referencePage("JDF11", cryptobib: "PQCRYPTO:JaoDeF11"),
        "References/CD22 - An efficient key recovery attack on SIDH.md":
            referencePage("CD22", cryptobib: "EC:CasDec23"),
        "References/KR03 - 3-Local Hamiltonian is QMA-complete.md":
            referencePage("KR03", bibtex: kr03Entry),
        "References/Dam87 - Collision free hash functions.md":
            referencePage("Dam87"),
    ]

    static func makeIndex() throws -> (WikiIndex, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-proof-export-\(UUID().uuidString)")
        for (path, contents) in referencePages {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (WikiIndex.build(contentRoot: root), root)
    }

    /// `ExplorerFixture.reduction`, with the wiki's slug and its own `source`
    /// list of wikilinks.
    static func reduction(_ id: String, _ hypotheses: [String], _ conclusion: String,
                          title: String, slug: String, source: [String],
                          reductionClass: String = "fully-black-box", model: String = "standard",
                          kind: String = "implication") -> [String: Any] {
        var made = ExplorerFixture.reduction(id, hypotheses, conclusion, title: title, source: "",
                                             reductionClass: reductionClass, model: model, kind: kind)
        made["source"] = source
        made["slug"] = slug
        return made
    }

    static func manifest() throws -> RelationsManifest {
        typealias F = ExplorerFixture
        let objects: [[String: Any]] = [
            F.object("hash-function", title: "Hash function", aliases: ["CRH", "Hash function"]),
            F.object("owf", title: "Preimage resistance (one-wayness)", of: "hash-function",
                     anchor: "preimage-resistance-one-wayness"),
            F.object("crhf", title: "Collision resistance", of: "hash-function",
                     anchor: "collision-resistance"),
            F.object("prg", title: "Pseudorandom generator", aliases: ["PRG"]),
            F.object("prf", title: "Pseudorandom function", aliases: ["PRF"]),
            F.object("invertible-prf", title: "Invertible PRFs", of: "prf", anchor: "invertible-prfs"),
            F.object("prp", title: "Pseudorandom permutation", aliases: ["PRP"]),
            F.object("ske", title: "Symmetric key encryption", aliases: ["SKE", "SE"]),
            F.object("cpa-security", title: "CPA Security", of: "ske"),
            F.object("ind-dollar-cpa", title: "IND$-CPA Security", of: "ske"),
            F.object("kem", title: "Key encapsulation mechanism", aliases: ["KEM"]),
            F.object("pke", title: "Public key encryption", aliases: ["PKE"]),
            F.object("pke-cpa-security", title: "CPA Security", of: "pke", anchor: "cpa-security"),
            F.object("ot", title: "Oblivious transfer", aliases: ["OT"]),
            F.object("mpc", title: "Secure multi-party computation", aliases: ["MPC"]),
            F.object("honest-majority", title: "Honest majority ($t < n/2$)", of: "mpc"),
            F.object("cpir", title: "Private information retrieval", aliases: ["cPIR"]),
            F.object("sis", title: "Short integer solution", type: "assumption", aliases: ["SIS"]),
            F.object("isis", title: "ISIS (Inhomogeneous SIS)", type: "assumption", of: "sis"),
            F.object("gapsvp", title: "Gap shortest vector problem", type: "assumption",
                     aliases: ["GapSVP"]),
            F.object("lwe", title: "Learning with errors", type: "assumption", aliases: ["LWE"]),
            F.object("lpn", title: "Learning parity with noise", type: "assumption", aliases: ["LPN"]),
            F.object("lpn-low-noise", title: "Low-noise LPN", type: "assumption", of: "lpn"),
            F.object("rsa", title: "RSA assumption", type: "assumption", aliases: ["RSA"]),
            F.object("phi-hiding", title: "Φ-Hiding", type: "assumption", of: "rsa"),
            F.object("sidh", title: "Supersingular isogeny Diffie-Hellman", type: "assumption",
                     aliases: ["SIDH"]),
            F.object("ssddh", title: "Decisional variant (SSDDH)", type: "assumption", of: "sidh",
                     anchor: "decisional-variant-ssddh"),
            F.object("ke", title: "Key exchange", aliases: ["KE"]),
            F.object("a", title: "Alpha"),
            F.object("b", title: "Beta"),
            F.object("c", title: "Gamma"),
            F.object("d", title: "Delta"),
        ]
        let reductions: [[String: Any]] = [
            reduction("red-crhf-to-owf", ["crhf"], "owf", title: "CRHF ⇒ OWF", slug: "crhf-to-owf",
                      source: [dam87]),
            reduction("red-owf-to-prg-hill99", ["owf"], "prg", title: "OWF ⇒ PRG",
                      slug: "owf-to-prg-hill99", source: [hill99]),
            reduction("red-prg-to-prf-ggm86", ["prg"], "prf", title: "PRG ⇒ PRF (GGM)",
                      slug: "prg-to-prf-ggm86", source: [ggm86]),
            reduction("red-prf-to-ske", ["prf"], "ske", title: "PRF ⇒ CPA-secure SKE",
                      slug: "prf-to-ske", source: ["folklore"]),
            reduction("red-kem-and-ske-to-pke", ["kem", "ske"], "pke", title: "KEM + SKE ⇒ PKE",
                      slug: "kem-and-ske-to-pke", source: [cs03]),
            reduction("red-prp-to-invertible-prf", ["prp"], "invertible-prf", title: "PRP ⇒ iPRF",
                      slug: "prp-to-invertible-prf", source: ["folklore"]),
            reduction("red-invertible-prf-to-prf", ["invertible-prf"], "prf", title: "iPRF ⇒ PRF",
                      slug: "invertible-prf-to-prf", source: ["folklore"]),
            reduction("red-cpir-to-ot-dmo00", ["cpir"], "ot", title: "cPIR ⇒ OT",
                      slug: "cpir-to-ot-dmo00", source: [dmo00], reductionClass: "unstated"),
            reduction("red-ot-to-mpc-kil88", ["ot"], "mpc", title: "OT ⇒ MPC",
                      slug: "ot-to-mpc-kil88", source: [kil88, gmw87]),
            reduction("red-isis-to-sis", ["isis"], "sis", title: "ISIS ⇔ SIS", slug: "isis-to-sis",
                      source: ["folklore"], model: "quantum", kind: "equivalence"),
            reduction("red-gapsvp-to-lwe-reg05", ["gapsvp"], "lwe", title: "GapSVP ⇒ LWE",
                      slug: "gapsvp-to-lwe-reg05", source: [reg05], model: "quantum"),
            reduction("red-lwe-to-pke-reg05", ["lwe"], "pke", title: "LWE ⇒ PKE",
                      slug: "lwe-to-pke-reg05", source: [reg05]),
            reduction("red-sidh-to-ke-jdf11", ["ssddh"], "ke", title: "SSDDH ⇒ KE",
                      slug: "sidh-to-ke-jdf11", source: [jdf11], reductionClass: "unstated"),
            reduction("red-abc-to-d", ["a", "b", "c"], "d", title: "A + B + C ⇒ D", slug: "abc-to-d",
                      source: [kr03]),
            reduction("red-d-to-ke", ["d"], "ke", title: "D ⇒ KE", slug: "d-to-ke", source: [kr03]),
        ]
        return try ExplorerFixture.manifest(objects: objects, reductions: reductions)
    }

    static let curation = DerivationCuration(
        refuted: [
            DerivationCuration.Refutation(
                objectID: "ssddh", source: "CD22",
                text: "SSDDH is the decisional variant of SIDH, which CD22 breaks.", evidence: ""),
        ],
        requires: [
            DerivationCuration.Requirement(
                relationID: "red-ot-to-mpc-kil88", isReverse: false, hypothesis: "ot",
                notion: "OT secure against malicious parties", metBy: ["red-cpir-to-ot-dmo00"]),
            DerivationCuration.Requirement(
                relationID: "red-isis-to-sis", isReverse: true, hypothesis: "sis",
                notion: "SIS with a prime modulus q", metBy: [],
                notionMarkdown: "SIS with a prime modulus $q$"),
        ],
        weakens: [
            DerivationCuration.Weakening(
                relationID: "red-prp-to-invertible-prf",
                notion: "an invertible PRF for the forward-oracle game only",
                acceptedBy: ["red-invertible-prf-to-prf"]),
        ])

    static func derivation() throws -> Derivation {
        Derivation(manifest: try manifest(), curation: curation)
    }

    static func result(_ query: ExplorerQuery, over derivation: Derivation) -> ExplorerResult {
        ExplorerResult.compute(query, derivation: derivation,
                               labels: ExplorerFixture.labels(derivation.manifest))
    }

    /// The answer's proof, as Edit → Copy Proof As copies it with nothing
    /// selected.
    static func copy(_ from: [String], _ to: String, over derivation: Derivation) -> ProofCopy? {
        result(ExplorerQuery(from: from, to: to), over: derivation)
            .proofCopy(selection: [], showingStronger: false)
    }

    static func context(_ derivation: Derivation, index: WikiIndex?,
                        macros: MacroTable = .empty) -> ProofWriterContext {
        ProofWriterContext(
            manifest: derivation.manifest, labels: ExplorerFixture.labels(derivation.manifest),
            citations: ProofCitations(index: index), macros: macros, revision: revision)
    }

    // MARK: The shape

    @Test("steps come in dependency order, each after the steps that give its hypotheses")
    func dependencyOrder() throws {
        let derivation = try Self.derivation()
        let copy = try #require(Self.copy(["owf", "kem"], "pke", over: derivation))
        let export = copy.export
        #expect(export.steps.map(\.relationID) == [
            "red-owf-to-prg-hill99", "red-prg-to-prf-ggm86", "red-prf-to-ske", "red-kem-and-ske-to-pke",
        ])
        #expect(export.steps.last?.hypotheses == ["kem", "ske"])
        #expect(export.start == ["owf", "kem"])
        #expect(export.target == "pke")
        #expect(export.relationCount == 4)
        #expect(export.depth == 4)
        #expect(export.chainClass == .fullyBlackBox)
        #expect(export.unstatedSteps == 0)
        #expect(export.models.isEmpty)
        #expect(export.refutations.isEmpty)
        #expect(!export.isRecordedResult)
    }

    @Test("a shared sub-proof is one step, and givens and references give none")
    func sharedSubproof() throws {
        typealias F = ExplorerFixture
        let derivation = try F.derivation(
            objects: [
                F.object("s", title: "Start"), F.object("t", title: "Shared"),
                F.object("u", title: "Left"), F.object("v", title: "Right"),
                F.object("x", title: "Target"),
            ],
            reductions: [
                F.reduction("red-s-to-t", ["s"], "t", title: "S ⇒ T", source: "folklore"),
                F.reduction("red-t-to-u", ["t"], "u", title: "T ⇒ U", source: "folklore"),
                F.reduction("red-t-to-v", ["t"], "v", title: "T ⇒ V", source: "folklore"),
                F.reduction("red-u-and-v-to-x", ["u", "v"], "x", title: "U + V ⇒ X",
                            source: "folklore"),
            ])
        let closure = derivation.closure(from: ["s"], options: .standard)
        let proof = try #require(closure.proof(of: "x"))
        // x, u, t, s (given), v, t (shown above).
        #expect(proof.rows.count == 6)
        #expect(proof.rows.filter { $0.isReference }.count == 1)
        let export = ProofExport(proof: proof, start: ["s"], target: "x", depth: 3,
                                 chainClass: .fullyBlackBox, unstatedSteps: 0, refutations: [],
                                 manifest: derivation.manifest)
        #expect(export.steps.map(\.relationID) == [
            "red-s-to-t", "red-t-to-u", "red-t-to-v", "red-u-and-v-to-x",
        ])
        #expect(export.relationCount == 4)
    }

    @Test("a conjunction is one item, never split into its hypotheses")
    func conjunctionWhole() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Self.context(derivation, index: index)
        let copy = try #require(Self.copy(["a", "b", "c"], "d", over: derivation))

        let latex = ProofLaTeX.write(copy.export, context: context)
        let items = latex.components(separatedBy: "\n").filter { $0.hasPrefix(#"  \item"#) }
        #expect(items.count == 1)
        #expect(items.first?.components(separatedBy: #"$\wedge$"#).count == 3)
        #expect(items.first == #"  \item Alpha $\wedge$ Beta $\wedge$ Gamma $\Rightarrow$ Delta "#
            + #"by~\cite{KemReg03}. % red-abc-to-d (A + B + C ⇒ D): fully black-box"#)

        let markdown = ProofMarkdown.write(copy.export, context: context)
        let lines = markdown.components(separatedBy: "\n").filter { $0.hasPrefix("1. ") }
        #expect(lines.count == 1)
        #expect(lines.first?.components(separatedBy: " ∧ ").count == 3)
    }

    // MARK: LaTeX and Markdown, exactly

    @Test("LaTeX: the provenance in comments, then one cited item per step")
    func latexExact() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try #require(Self.copy(["owf", "kem"], "pke", over: derivation))
        let latex = ProofLaTeX.write(copy.export, context: Self.context(derivation, index: index))
        let expected = [
            #"% OWF ∧ KEM ⇒* PKE: derived by CCwiki from 4 recorded reductions (cryptology.city relations.json at ab81f02ff4a0)."#,
            #"% Each step is a result the wiki records. The chain is CCwiki's composition: the wiki does not state it."#,
            #"% Fully black-box: every step is."#,
            "% \(ProofLaTeX.macrosUnavailable)",
            #"% In CryptoBib (crypto.bib): HILL99, GolGolMic86, CraSho03."#,
            #"\begin{enumerate}"#,
            #"  \item OWF $\Rightarrow$ PRG by~\cite{HILL99}. % red-owf-to-prg-hill99 (OWF ⇒ PRG): fully black-box"#,
            #"  \item PRG $\Rightarrow$ PRF by~\cite{GolGolMic86}. % red-prg-to-prf-ggm86 (PRG ⇒ PRF (GGM)): fully black-box"#,
            #"  \item PRF $\Rightarrow$ SKE (folklore). % red-prf-to-ske (PRF ⇒ CPA-secure SKE): fully black-box"#,
            #"  \item KEM $\wedge$ SKE $\Rightarrow$ PKE by~\cite{CraSho03}. % red-kem-and-ske-to-pke (KEM + SKE ⇒ PKE): fully black-box"#,
            #"\end{enumerate}"#,
        ].joined(separator: "\n")
        #expect(latex == expected)
    }

    @Test("LaTeX: a precondition a producer met is cited, and an inline entry is announced")
    func latexEstablished() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try #require(Self.copy(["cpir"], "mpc", over: derivation))
        let latex = ProofLaTeX.write(copy.export, context: Self.context(derivation, index: index))
        let expected = [
            #"% cPIR ⇒* MPC: derived by CCwiki from 2 recorded reductions (cryptology.city relations.json at ab81f02ff4a0)."#,
            #"% Each step is a result the wiki records. The chain is CCwiki's composition: the wiki does not state it."#,
            #"% Class unstated: 1 step does not state its."#,
            "% \(ProofLaTeX.macrosUnavailable)",
            #"% In CryptoBib (crypto.bib): EC:DiCMalOst00, STOC:Kilian88."#,
            #"% Not in CryptoBib; Copy BibTeX of Cited Works gives their entries: GMW87."#,
            #"\begin{enumerate}"#,
            #"  \item cPIR $\Rightarrow$ OT by~\cite{EC:DiCMalOst00}. % red-cpir-to-ot-dmo00 (cPIR ⇒ OT): unstated"#,
            #"  \item OT $\Rightarrow$ MPC by~\cite{STOC:Kilian88,GMW87}, for OT secure against malicious parties, which~\cite{EC:DiCMalOst00} establishes. % red-ot-to-mpc-kil88 (OT ⇒ MPC): fully black-box"#,
            #"\end{enumerate}"#,
        ].joined(separator: "\n")
        #expect(latex == expected)
        let established = try #require(copy.export.steps.last?.established.first)
        #expect(established.producer == "red-cpir-to-ot-dmo00")
        #expect(established.requirement.hypothesis == "ot")
    }

    @Test("Markdown: the provenance in an HTML comment, then a numbered list linking every page")
    func markdownExact() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try #require(Self.copy(["owf", "kem"], "pke", over: derivation))
        let markdown = ProofMarkdown.write(copy.export, context: Self.context(derivation, index: index))
        let expected = [
            "<!-- OWF ∧ KEM ⇒* PKE: derived by CCwiki from 4 recorded reductions (cryptology.city "
                + "relations.json at ab81f02ff4a0). Each step is a result the wiki records. The chain "
                + "is CCwiki's composition: the wiki does not state it. Fully black-box: every step is. -->",
            "1. [[hash-function#preimage-resistance-one-wayness|OWF]] ⇒ [[prg|PRG]] by "
                + "[[owf-to-prg-hill99|OWF ⇒ PRG]] — \(Self.hill99).",
            "2. [[prg|PRG]] ⇒ [[prf|PRF]] by [[prg-to-prf-ggm86|PRG ⇒ PRF (GGM)]] — \(Self.ggm86).",
            "3. [[prf|PRF]] ⇒ [[ske|SKE]] by [[prf-to-ske|PRF ⇒ CPA-secure SKE]] — folklore.",
            "4. [[kem|KEM]] ∧ [[ske|SKE]] ⇒ [[pke|PKE]] by [[kem-and-ske-to-pke|KEM + SKE ⇒ PKE]] "
                + "— \(Self.cs03).",
        ].joined(separator: "\n")
        #expect(markdown == expected)
    }

    @Test("Markdown: a variant links its host's section, and a name with $ is a markdown link")
    func markdownLinks() throws {
        let derivation = try Self.derivation()
        let context = Self.context(derivation, index: nil)
        #expect(ProofMarkdown.objectLink("owf", context: context)
            == "[[hash-function#preimage-resistance-one-wayness|OWF]]")
        #expect(ProofMarkdown.objectLink("ind-dollar-cpa", context: context)
            == #"[SKE IND\$-CPA Security](<ske#ind-dollar-cpa>)"#)
        #expect(ProofMarkdown.objectLink("honest-majority", context: context)
            == "[MPC Honest majority ($t < n/2$)](<mpc#honest-majority>)")
        #expect(ProofMarkdown.objectLink("phi-hiding", context: context) == "[[rsa#phi-hiding|RSA Φ-Hiding]]")
    }

    // MARK: BibTeX and keys

    @Test("BibTeX holds only the inline entries, verbatim, once each, and is nil without one")
    func bibtex() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Self.context(derivation, index: index)

        // All in CryptoBib, and all folklore: nothing to copy.
        let cryptobib = try #require(Self.copy(["owf", "kem"], "pke", over: derivation))
        let folklore = try #require(Self.copy(["prf"], "ske", over: derivation))
        #expect(ProofBibTeX.write(cryptobib.export, context: context) == nil)
        #expect(ProofBibTeX.write(folklore.export, context: context) == nil)
        #expect(!context.hasInlineEntries(cryptobib.export))
        #expect(!context.hasInlineEntries(folklore.export))

        let mpc = try #require(Self.copy(["cpir"], "mpc", over: derivation))
        #expect(context.hasInlineEntries(mpc.export))
        let expected = "% Works cited by the proof of cPIR ⇒* MPC that are not in CryptoBib, from "
            + "cryptology.city's reference pages. The others: EC:DiCMalOst00, STOC:Kilian88.\n\n"
            + Self.gmw87Entry
        #expect(ProofBibTeX.write(mpc.export, context: context) == expected)

        // Two steps citing KR03: its entry once, under its own key.
        let twice = try #require(Self.copy(["a", "b", "c"], "ke", over: derivation))
        #expect(twice.export.steps.count == 2)
        let kr03 = "% Works cited by the proof of Alpha ∧ Beta ∧ Gamma ⇒* KE that are not in "
            + "CryptoBib, from cryptology.city's reference pages.\n\n" + Self.kr03Entry
        #expect(ProofBibTeX.write(twice.export, context: context) == kr03)
    }

    @Test("\\cite keys: CryptoBib's, else the inline entry's, else the wiki's, said beside the step")
    func citeKeys() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Self.context(derivation, index: index)

        func items(_ from: [String], _ to: String, _ context: ProofWriterContext) throws -> [String] {
            let copy = try #require(Self.copy(from, to, over: derivation))
            return ProofLaTeX.write(copy.export, context: context)
                .components(separatedBy: "\n").filter { $0.hasPrefix(#"  \item"#) }
        }

        // A reference page with neither key: the wiki's key, flagged.
        let dam87 = try items(["crhf"], "owf", context)
        #expect(dam87 == [
            #"  \item CRHF $\Rightarrow$ OWF by~\cite{Dam87}. % red-crhf-to-owf (CRHF ⇒ OWF): fully "#
                + "black-box; Dam87 has no BibTeX key on its reference page",
        ])
        // KR03's entry is KemReg03, so that is the key a paper resolves.
        let conjunction = try items(["a", "b", "c"], "d", context)
        #expect(conjunction.first?.contains(#"by~\cite{KemReg03}."#) == true)
        // Folklore cites nothing.
        let folklore = try items(["prf"], "ske", context)
        #expect(folklore.first?.contains(#"\cite"#) == false)
        #expect(folklore.first?.contains("(folklore).") == true)

        // With no wiki loaded, every key is the wiki's, each flagged once.
        let bare = Self.context(derivation, index: nil)
        let ggm = try items(["prg"], "prf", bare)
        #expect(ggm == [
            #"  \item PRG $\Rightarrow$ PRF by~\cite{GGM86}. % red-prg-to-prf-ggm86 (PRG ⇒ PRF (GGM)): "#
                + "fully black-box; GGM86 has no BibTeX key on its reference page",
        ])
    }

    @Test("citations resolve to reference pages; a refutation's key finds its page by file name")
    func citations() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let citations = ProofCitations(index: index)

        let found = citations.citations([Self.kil88, "folklore", " "], from: "Reductions/x.md")
        #expect(found.map(\.key) == ["Kil88", "folklore"])
        #expect(found.first?.referencePath == "References/Kil88 - Founding cryptography on oblivious transfer.md")
        #expect(found.first?.texKey == "STOC:Kilian88")
        #expect(found.last?.isFolklore == true)
        #expect(found.last?.texKey == nil)

        let cd22 = citations.citation(forKey: "CD22")
        #expect(cd22.entry == "[[CD22 - An efficient key recovery attack on SIDH|CD22]]")
        #expect(cd22.texKey == "EC:CasDec23")
        let unknown = citations.citation(forKey: "XYZ99")
        #expect(unknown.entry == "XYZ99")
        #expect(unknown.referencePath == nil)
        #expect(unknown.usesWikiKey)

        #expect(ProofCitations.entryKey(Self.kr03Entry) == "KemReg03")
        #expect(ProofCitations.entryKey("@misc{ key with space, }") == nil)
        #expect(ProofCitations.entryKey("no entry here") == nil)
    }

    // MARK: Honesty

    @Test("only the header says ⇒*, a chain is derived by CCwiki, and one step is the wiki's")
    func honesty() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Self.context(derivation, index: index)

        let chain = try #require(Self.copy(["owf", "kem"], "pke", over: derivation))
        let chainLines = ProofLaTeX.write(chain.export, context: context).components(separatedBy: "\n")
        #expect(chainLines.first?.contains("derived by CCwiki from 4 recorded reductions") == true)
        #expect(chainLines.first?.contains("⇒*") == true)
        for line in chainLines where !line.hasPrefix("%") {
            #expect(!line.contains("⇒*"), "\(line)")
            #expect(!line.contains(#"\Rightarrow^*"#), "\(line)")
        }

        let recorded = try #require(Self.copy(["ssddh"], "ke", over: derivation))
        #expect(recorded.export.isRecordedResult)
        let latex = ProofLaTeX.write(recorded.export, context: context)
        let markdown = ProofMarkdown.write(recorded.export, context: context)
        for text in [latex, markdown] {
            #expect(!text.contains("⇒*"))
            #expect(!text.contains("derived"))
            #expect(text.contains("recorded in the wiki"))
        }
    }

    @Test("a refuted start is said in visible text, outside every comment")
    func refutedStart() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Self.context(derivation, index: index)
        let copy = try #require(Self.copy(["ssddh"], "ke", over: derivation))
        #expect(copy.export.refutations.map(\.objectID) == ["ssddh"])

        let latex = ProofLaTeX.write(copy.export, context: context)
        #expect(latex == [
            #"% SSDDH ⇒ KE: recorded in the wiki (cryptology.city relations.json at ab81f02ff4a0)."#,
            "% \(ProofLaTeX.macrosUnavailable)",
            #"% In CryptoBib (crypto.bib): EC:CasDec23, PQCRYPTO:JaoDeF11."#,
            #"SSDDH is known to be false~\cite{EC:CasDec23}, so this implication is vacuous."#,
            #"\begin{enumerate}"#,
            #"  \item SSDDH $\Rightarrow$ KE by~\cite{PQCRYPTO:JaoDeF11}. % red-sidh-to-ke-jdf11 (SSDDH ⇒ KE): unstated"#,
            #"\end{enumerate}"#,
        ].joined(separator: "\n"))

        let markdown = ProofMarkdown.write(copy.export, context: context)
        #expect(markdown == [
            "<!-- SSDDH ⇒ KE: recorded in the wiki (cryptology.city relations.json at ab81f02ff4a0). -->",
            "[[sidh#decisional-variant-ssddh|SSDDH]] is known to be false "
                + "([[CD22 - An efficient key recovery attack on SIDH|CD22]]), so this implication is vacuous.",
            "",
            "1. [[sidh#decisional-variant-ssddh|SSDDH]] ⇒ [[ke|KE]] by [[sidh-to-ke-jdf11|SSDDH ⇒ KE]] "
                + "— \(Self.jdf11).",
        ].joined(separator: "\n"))
        // The comment closes before the sentence, so the site shows it.
        let lines = markdown.components(separatedBy: "\n")
        #expect(lines.first?.hasSuffix("-->") == true)
        #expect(lines[1].contains("<!--") == false)
    }

    // MARK: Show It

    /// QR ⇒ COM recorded in the quantum setting with no class, beside a
    /// fully black-box, standard-model chain through factoring.
    private static func strongerDerivation() throws -> Derivation {
        typealias F = ExplorerFixture
        return try F.derivation(
            objects: [
                F.object("qr", title: "Quadratic residuosity", type: "assumption", aliases: ["QR"]),
                F.object("fac", title: "Factoring", type: "assumption", aliases: ["FAC"]),
                F.object("com", title: "Commitment scheme", aliases: ["COM"]),
            ],
            reductions: [
                F.reduction("red-qr-to-com", ["qr"], "com", title: "QR ⇒ COM", source: "folklore",
                            reductionClass: "unstated", model: "quantum"),
                F.reduction("red-qr-to-fac", ["qr"], "fac", title: "QR ⇒ FAC", source: "folklore"),
                F.reduction("red-fac-to-com", ["fac"], "com", title: "FAC ⇒ COM", source: "folklore"),
            ])
    }

    @Test("a copy made with Show It states the stronger proof's own N, depth, class and models")
    func strongerCopy() throws {
        let derivation = try Self.strongerDerivation()
        let result = Self.result(ExplorerQuery(from: ["qr"], to: "com"), over: derivation)
        let context = Self.context(derivation, index: nil)

        let shortest = try #require(result.proofCopy(selection: [], showingStronger: false))
        let stronger = try #require(result.proofCopy(selection: [], showingStronger: true))
        #expect(stronger == result.stronger?.copy)

        #expect(shortest.export.depth == 1)
        #expect(shortest.export.relationCount == 1)
        #expect(shortest.export.chainClass == .unstated)
        #expect(shortest.export.models == ["quantum"])
        guard case .derived(let answer) = derivation.answer(from: ["qr"], to: "com", options: .standard)
        else {
            Issue.record("expected a derivation")
            return
        }
        #expect(shortest.export.models == answer.fact.models.sorted(by: Derivation.precedes))

        #expect(stronger.export.depth == 2)
        #expect(stronger.export.relationCount == 2)
        #expect(stronger.export.chainClass == .fullyBlackBox)
        #expect(stronger.export.models.isEmpty)

        let shortestLines = ProofLaTeX.write(shortest.export, context: context).components(separatedBy: "\n")
        #expect(shortestLines.first == #"% QR ⇒ COM: recorded in the wiki (cryptology.city relations.json at ab81f02ff4a0)."#)
        #expect(shortestLines.contains { $0.contains("(folklore), in the quantum setting.") })

        let strongerLines = ProofLaTeX.write(stronger.export, context: context).components(separatedBy: "\n")
        #expect(Array(strongerLines.prefix(3)) == [
            #"% QR ⇒* COM: derived by CCwiki from 2 recorded reductions (cryptology.city relations.json at ab81f02ff4a0)."#,
            "% " + DerivationWording.derivedFooter,
            #"% Fully black-box: every step is."#,
        ])
    }

    // MARK: Qualifiers

    @Test("a quantum step, a reverse step, an assumed and a met precondition, and a weakened step say so")
    func qualifiers() throws {
        let derivation = try Self.derivation()
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Self.context(derivation, index: index)

        func lines(_ from: [String], _ to: String) throws -> [String] {
            let copy = try #require(Self.copy(from, to, over: derivation))
            return ProofLaTeX.write(copy.export, context: context).components(separatedBy: "\n")
        }

        // The model, in the item and in the header's class line.
        let quantum = try lines(["gapsvp"], "pke")
        #expect(quantum.contains(#"% Fully black-box: every step is. Uses the quantum setting."#))
        #expect(quantum.contains(#"  \item GapSVP $\Rightarrow$ LWE by~\cite{STOC:Regev05}, in the quantum "#
            + "setting. % red-gapsvp-to-lwe-reg05 (GapSVP ⇒ LWE): fully black-box"))
        #expect(quantum.contains(#"% In CryptoBib (crypto.bib): STOC:Regev05."#))

        // Model, direction, then the assumed notion, which keeps its math.
        let reverse = try lines(["sis"], "isis")
        #expect(reverse.contains(#"  \item SIS $\Rightarrow$ ISIS (folklore), in the quantum setting, "#
            + #"used right to left, assuming SIS with a prime modulus $q$. % red-isis-to-sis (ISIS ⇔ SIS): unstated"#))

        // A given hypothesis: the notion is assumed of it.
        let assumed = try lines(["ot"], "mpc")
        #expect(assumed.contains(#"  \item OT $\Rightarrow$ MPC by~\cite{STOC:Kilian88,GMW87}, assuming OT "#
            + "secure against malicious parties. % red-ot-to-mpc-kil88 (OT ⇒ MPC): fully black-box"))

        // A weakened conclusion, accepted by the next step.
        let weakened = try lines(["prp"], "prf")
        #expect(weakened.filter { $0.hasPrefix(#"  \item"#) } == [
            #"  \item PRP $\Rightarrow$ Invertible PRFs (folklore), giving only an invertible PRF for "#
                + "the forward-oracle game only. % red-prp-to-invertible-prf (PRP ⇒ iPRF): fully black-box",
            #"  \item Invertible PRFs $\Rightarrow$ PRF (folklore). % red-invertible-prf-to-prf (iPRF ⇒ PRF): "#
                + "fully black-box",
        ])

        // Markdown: the same qualifiers, in the same order, after the citation.
        let copy = try #require(Self.copy(["sis"], "isis", over: derivation))
        let markdown = ProofMarkdown.write(copy.export, context: context).components(separatedBy: "\n")
        #expect(markdown.last == "1. [[sis|SIS]] ⇒ [[sis#isis|ISIS]] by [[isis-to-sis|ISIS ⇔ SIS]] — "
            + "folklore, in the quantum setting, used right to left, assuming SIS with a prime modulus $q$.")
        let established = try #require(Self.copy(["cpir"], "mpc", over: derivation))
        let markdownMPC = ProofMarkdown.write(established.export, context: context)
        #expect(markdownMPC.hasSuffix("2. [[ot|OT]] ⇒ [[mpc|MPC]] by [[ot-to-mpc-kil88|OT ⇒ MPC]] — "
            + "\(Self.kil88), \(Self.gmw87), for OT secure against malicious parties, which "
            + "\(Self.dmo00) establishes."))
    }

    // MARK: Names

    @Test("names: a page object's alias, a hyphenless id in capitals, a variant by its host")
    func names() throws {
        let manifest = try Self.manifest()
        let labels = ExplorerFixture.labels(manifest)
        func name(_ id: String) -> String { ProofNames.name(id, manifest: manifest, labels: labels) }

        #expect(name("hash-function") == "CRH")
        #expect(name("cpir") == "cPIR")
        #expect(name("owf") == "OWF")
        #expect(name("crhf") == "CRHF")
        #expect(name("ssddh") == "SSDDH")
        // Two sections titled "CPA Security", told apart by their hosts.
        #expect(name("cpa-security") == "SKE CPA Security")
        #expect(name("pke-cpa-security") == "PKE CPA Security")
        // A title that names its host is kept, plural and all.
        #expect(name("invertible-prf") == "Invertible PRFs")
        #expect(name("lpn-low-noise") == "Low-noise LPN")
        // SKE's alias "SE" is not a word of "Security".
        #expect(name("ind-dollar-cpa") == "SKE IND$-CPA Security")
        #expect(name("honest-majority") == "MPC Honest majority ($t < n/2$)")
        #expect(name("phi-hiding") == "RSA Φ-Hiding")
        // No alias: the label.
        #expect(name("a") == "Alpha")
        #expect(name("not-in-the-wiki") == labels.label("not-in-the-wiki"))

        #expect(ProofNames.namesWholeWord("PRF", in: "Invertible PRFs"))
        #expect(ProofNames.namesWholeWord("Functions", in: "Function secret sharing"))
        #expect(!ProofNames.namesWholeWord("SE", in: "CPA Security"))
        #expect(!ProofNames.namesWholeWord("OT", in: "Notable problems"))
    }

    @Test("on the wiki, no two objects share a copy name")
    func corpusNamesAreUnique() throws {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty else { return }
        let manifest = RelationsManifest.load(cloneRoot: URL(fileURLWithPath: path))
        guard manifest.diagnostic == nil, !manifest.objectsByID.isEmpty else { return }
        let labels = RelationLabels(manifest: manifest, index: nil)
        var owners: [String: [String]] = [:]
        for id in manifest.objectsByID.keys {
            owners[ProofNames.name(id, manifest: manifest, labels: labels), default: []].append(id)
        }
        let shared = owners.filter { $0.value.count > 1 }
        #expect(shared.isEmpty, "objects sharing a copy name: \(shared)")
    }

    // MARK: Escaping

    @Test("TeX: math kept and expanded, specials escaped, symbols and Greek put in math")
    func texEscaping() {
        func tex(_ text: String) -> String { TeXText.escape(text, macros: .empty) }
        #expect(tex("IND$-CPA Security") == #"IND\$-CPA Security"#)
        #expect(tex("$k$-Linear assumption") == "$k$-Linear assumption")
        #expect(tex("Honest majority ($t < n/2$)") == "Honest majority ($t < n/2$)")
        #expect(tex(#"Pseudorandom generator in $\mathrm{NC}^1$"#)
            == #"Pseudorandom generator in $\mathrm{NC}^1$"#)
        #expect(tex("RSA Φ-Hiding") == #"RSA $\Phi$-Hiding"#)
        #expect(tex("LPN with error rate l^(-delta) and λ")
            == #"LPN with error rate l\^{}(-delta) and $\lambda$"#)
        #expect(tex("Hash function § Preimage resistance (one-wayness)")
            == #"Hash function \S{} Preimage resistance (one-wayness)"#)
        #expect(tex(#"50% & #1_x {y} ~z \ w"#)
            == ##"50\% \& \#1\_x \{y\} \textasciitilde{}z \textbackslash{} w"##)
        #expect(tex("A ⇒* B ⇔ C ∧ D ⇒ E")
            == #"A $\Rightarrow^*$ B $\Leftrightarrow$ C $\wedge$ D $\Rightarrow$ E"#)
        #expect(tex("a – b — c… <x> |y|") == #"a -- b --- c\ldots{} \textless{}x\textgreater{} \textbar{}y\textbar{}"#)
        #expect(tex("x ≤ y ∈ ℤ") == #"x $\le$ y $\in$ $\mathbb{Z}$"#)
        #expect(tex("Håstad’s “lemma”") == "Håstad’s “lemma”")

        let macros = MacroTable(macros: [#"\ZZ"#: #"\mathbb{Z}"#], diagnostic: nil)
        #expect(TeXText.escape(#"DLOG hard in $\ZZ_p^*$ (p prime)"#, macros: macros)
            == #"DLOG hard in $\mathbb{Z}_p^*$ (p prime)"#)
    }

    @Test("Markdown: the site's escaping outside math, plus emphasis")
    func markdownEscaping() {
        #expect(MarkdownText.escape("IND$-CPA Security") == #"IND\$-CPA Security"#)
        #expect(MarkdownText.escape("$k$-Linear assumption") == "$k$-Linear assumption")
        #expect(MarkdownText.escape("Honest majority ($t < n/2$)") == "Honest majority ($t < n/2$)")
        #expect(MarkdownText.escape(#"Pseudorandom generator in $\mathrm{NC}^1$"#)
            == #"Pseudorandom generator in $\mathrm{NC}^1$"#)
        #expect(MarkdownText.escape("RSA Φ-Hiding") == "RSA Φ-Hiding")
        #expect(MarkdownText.escape("LPN with error rate l^(-delta) and λ")
            == "LPN with error rate l^(-delta) and λ")
        #expect(MarkdownText.escape("Hash function § Preimage resistance (one-wayness)")
            == "Hash function § Preimage resistance (one-wayness)")
        #expect(MarkdownText.escape("DLOG hard in Z_p^*") == #"DLOG hard in Z\_p^\*"#)
        #expect(MarkdownText.escape("$a_1 * b$ and *c*") == #"$a_1 * b$ and \*c\*"#)
        // Without `*` or `_`, exactly the site's escaping.
        for text in ["a [b] $c$ `d$` e$ \\[f", "IND$-CPA", "$$x$$ and $y"] {
            #expect(MarkdownText.escape(text) == RelationMeta.escapeOutsideMath(text), "\(text)")
        }
    }

    @Test("macros expand as whole control words, to a fixed point")
    func macroExpansion() {
        let table = MacroTable(macros: [#"\st"#: #"\mathsf{st}"#], diagnostic: nil)
        #expect(table.expanded(#"$\st + \stA + \st_1$"#) == #"$\mathsf{st} + \stA + \mathsf{st}_1$"#)
        // `\Z` writes `\A`, which a later pass writes out.
        let chained = MacroTable(macros: [#"\Z"#: #"\A"#, #"\A"#: "q"], diagnostic: nil)
        #expect(chained.expanded(#"$\Z$"#) == "$q$")
        #expect(MacroTable.empty.expanded(#"$\st$"#) == #"$\st$"#)
        // A body with a dollar is inserted as it is.
        let dollar = MacroTable(macros: [#"\cash"#: #"\$"#], diagnostic: nil)
        #expect(dollar.expanded(#"$\cash 5$"#) == #"$\$ 5$"#)
    }

    @Test("the copy names a class as the explorer's rows do")
    func classNames() throws {
        let derivation = try Self.derivation()
        let context = Self.context(derivation, index: nil)
        let writer = ExplorerWriter(derivation: derivation, labels: ExplorerFixture.labels(derivation.manifest))
        for name in ["fully-black-box", "relativizing", "free", "unstated", "", "made-up"] {
            #expect(context.className(name) == writer.className(name), "\(name)")
        }
        for id in ["red-owf-to-prg-hill99", "red-isis-to-sis", "missing"] {
            #expect(context.reductionTitle(id) == writer.reductionTitle(id), "\(id)")
        }
    }

    // MARK: Which proof Edit → Copy Proof As copies

    @Test("the selection rule: the selected rows' one proof, else the answer's, else nothing")
    func selectionRule() throws {
        let derivation = try Self.derivation()
        let answer = Self.result(ExplorerQuery(from: ["owf", "kem"], to: "pke"), over: derivation)
        let proof = try #require(answer.sections.first { $0.id == "proof" })
        let root = try #require(proof.rows.first)
        let rootCopy = try #require(root.proof)
        let deeper = try #require(answer.allRows.last)

        // One selected proof row, and two rows of the same proof.
        #expect(answer.proofCopy(selection: [root.id], showingStronger: false) == rootCopy)
        #expect(answer.proofCopy(selection: [root.id, deeper.id], showingStronger: false) == rootCopy)
        // Nothing selected: the answer's.
        #expect(answer.proofCopy(selection: [], showingStronger: false) == rootCopy)

        // A forward list: each row its own proof, and no proof of its own.
        let forward = Self.result(ExplorerQuery(from: ["owf"]), over: derivation)
        let first = try #require(forward.sections.first?.rows.first)
        let second = try #require(forward.sections.dropFirst().first?.rows.first)
        let firstCopy = try #require(first.proof)
        #expect(first.proof != second.proof)
        #expect(forward.proofCopy(selection: [first.id], showingStronger: false) == firstCopy)
        #expect(forward.proofCopy(selection: [first.id, second.id], showingStronger: false) == nil)
        #expect(forward.proofCopy(selection: [], showingStronger: false) == nil)

        // Rows of two different proofs fall back to the answer's.
        var mixed = answer
        mixed.sections.append(ExplorerSection(id: "other", rows: [first]))
        #expect(mixed.proofCopy(selection: [root.id, first.id], showingStronger: false) == rootCopy)

        // Show It: the stronger proof's, selected or not.
        let stronger = Self.result(ExplorerQuery(from: ["qr"], to: "com"),
                                   over: try Self.strongerDerivation())
        let strongerCopy = try #require(stronger.stronger?.copy)
        #expect(stronger.proofCopy(selection: [], showingStronger: true) == strongerCopy)
        let strongerRow = try #require(stronger.rows(showingStronger: true).last)
        #expect(stronger.proofCopy(selection: [strongerRow.id], showingStronger: true) == strongerCopy)
        #expect(stronger.proofCopy(selection: [], showingStronger: false) != strongerCopy)
    }
}
