import Testing
@testable import CCwiki

/// Local paths and tokens that must never reach GitHub (plans/corrections.md
/// §6.4, §12.1).
struct PrivateTextTests {

    static let home = "/Users/alice"
    static let worktrees = "/Users/alice/Library/Caches/CCwiki/worktrees"
    static let library = "/Users/alice/Library/Application Support/CCwiki/library"
    static let support = "/Users/alice/Library/Application Support/CCwiki"
    /// As `AppModel` passes them: the roots, then the home folder.
    static let privatePaths = [worktrees, library, support, home]

    static func findings(_ text: String) -> [String] {
        PrivateText.findings(in: text, privatePaths: privatePaths)
    }

    @Test("the home directory is found")
    func homeDirectory() {
        #expect(Self.findings("The notes are in /Users/alice/notes.txt.") == ["/Users/alice"])
        // In any case: the Mac's disk ignores it.
        #expect(Self.findings("see /users/ALICE/notes") == ["/users/ALICE"])
    }

    @Test("a worktree path is found as the worktree root, not the home inside it")
    func worktreePath() {
        let text = "Edited /Users/alice/Library/Caches/CCwiki/worktrees/"
            + "20261011-142210-118-edit-pseudorandom-function/content/Primitives/x.md by hand."
        #expect(Self.findings(text) == [Self.worktrees])
    }

    @Test("a percent-encoded path, as a file URL carries it, is found")
    func percentEncoded() {
        let text = "file:///Users/alice/Library/Application%20Support/CCwiki/library/paper.pdf"
        #expect(Self.findings(text) == ["/Users/alice/Library/Application%20Support/CCwiki/library"])
    }

    @Test("both token shapes are found, each gh prefix")
    func tokens() {
        let classic = "ghp_" + String(repeating: "a1B2", count: 9)
        let fineGrained = "github_pat_11ABCDEFG0123456789_abcdefghijklmnop"
        #expect(Self.findings("token \(classic) here") == [classic])
        #expect(Self.findings("GH_TOKEN=\(fineGrained)") == [fineGrained])
        for prefix in ["gho_", "ghu_", "ghs_", "ghr_"] {
            let token = prefix + String(repeating: "Z9", count: 18)
            #expect(Self.findings(token) == [token])
        }
    }

    @Test("a `~/` in prose and a 20-character ghp_ are not found")
    func notFound() {
        #expect(Self.findings("Keep it in ~/Library or ~/Desktop.").isEmpty)
        #expect(Self.findings("ghp_" + String(repeating: "x", count: 20)).isEmpty)
        #expect(Self.findings("github_pat_short").isEmpty)
    }

    @Test("a longer name is not the path: /Users/alicebob is someone else")
    func boundary() {
        #expect(Self.findings("/Users/alicebob/notes").isEmpty)
        #expect(Self.findings("/Users/alice-old/notes").isEmpty)
        #expect(Self.findings("(/Users/alice)") == ["/Users/alice"])
    }

    @Test("each finding once, in the order it appears")
    func order() {
        let classic = "ghp_" + String(repeating: "q", count: 40)
        let text = "\(classic) /Users/alice/a /Users/alice/b \(Self.worktrees)/x"
        #expect(Self.findings(text) == [classic, Self.home, Self.worktrees])
    }

    @Test("a path too short to mean anything is ignored")
    func shortPaths() {
        #expect(PrivateText.findings(in: "/a/b and /", privatePaths: ["/", "", "  "]).isEmpty)
        #expect(PrivateText.findings(in: "", privatePaths: Self.privatePaths).isEmpty)
    }
}
