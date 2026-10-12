import Foundation
@testable import CCwiki

/// A wiki clone in a temporary directory, in the shape a library load reads:
/// `content/`, `.reductions/relations.json` and `macros.ts`. The incremental
/// indexing suites edit it file by file and load it again
/// (plans/reader-comforts.md §5). Paths are relative to the clone's root.
struct FixtureClone {
    let root: URL

    init(_ files: [String: String] = FixtureClone.standard) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "content"), withIntermediateDirectories: true)
        for (path, text) in files { try write(path, text) }
    }

    var content: URL { root.appending(path: "content") }

    func url(_ path: String) -> URL { root.appending(path: path) }

    func write(_ path: String, _ text: String) throws {
        try write(path, data: Data(text.utf8))
    }

    func write(_ path: String, data: Data) throws {
        let file = url(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url(path))
    }

    /// Removes the whole clone.
    func delete() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Pages

    static func page(
        type: String, title: String, aliases: [String] = [], status: String = "draft",
        extra: String = "", body: String
    ) -> String {
        var text = "---\ntype: \(type)\nstatus: \(status)\ntitle: \(title)\n"
        text += aliases.isEmpty
            ? "aliases: []\n"
            : "aliases:\n" + aliases.map { "  - \($0)\n" }.joined()
        return text + extra + "---\n\n" + body
    }

    static let prf = "content/Primitives/pseudorandom-function.md"
    static let owf = "content/Primitives/one-way-function.md"
    static let lwe = "content/Assumptions/learning-with-errors.md"
    static let ggm = "content/References/GGM86 - How to construct random functions.md"
    static let diagram = "content/Files/diagram.png"
    static let manifestPath = ".reductions/relations.json"

    /// Content-relative, as `ContentFingerprints` and `WikiIndex` key them.
    static func relative(_ path: String) -> String {
        String(path.dropFirst("content/".count))
    }

    /// The manifest: three objects, the first titled `prfTitle`; OWF's page
    /// off the listings when `unlistingOWF`. With `withVariant`, a fourth: a
    /// variant for PRF's Syntax section, written the way manifests from
    /// before the final form write one, its title only its id, so its label
    /// is read from the heading on PRF's page.
    static func manifest(
        prfTitle: String = "Pseudorandom function", unlistingOWF: Bool = false,
        withVariant: Bool = false
    ) -> String {
        var variant = ""
        if withVariant {
            variant = """
                ,
                  {"id": "prf-syntax", "kind": "variant", "of": "prf", "title": "prf-syntax",
                   "anchor": "syntax", "type": "primitive",
                   "page": "content/Primitives/pseudorandom-function.md",
                   "slug": "pseudorandom-function"}
                """
        }
        return """
            {"version": 1, "classes": {}, "classSentinels": [], "propositions": {},
             "objects": [
              {"id": "prf", "kind": "object", "type": "primitive",
               "page": "content/Primitives/pseudorandom-function.md",
               "slug": "pseudorandom-function", "title": "\(prfTitle)", "aliases": ["PRF"]},
              {"id": "owf", "kind": "object", "type": "primitive",
               "page": "content/Primitives/one-way-function.md",
               "slug": "one-way-function", "title": "One-way function", "aliases": ["OWF"],
               "unlisted": \(unlistingOWF)},
              {"id": "lwe", "kind": "object", "type": "assumption",
               "page": "content/Assumptions/learning-with-errors.md",
               "slug": "learning-with-errors", "title": "Learning with errors", "aliases": ["LWE"]}\(variant)
             ],
             "reductions": [], "barriers": []}
            """
    }

    static let macros = """
        export const customMacros: Record<string, string> = {
          "\\\\calA": "\\\\mathcal{A}",
        };
        """

    /// A miniature of the wiki: pages that link to each other by name, by
    /// alias and to an asset, a reference, and the files a load must not
    /// list (a template, a hidden file, a file with no extension).
    static let standard: [String: String] = [
        "content/index.md": page(
            type: "note", title: "Cryptology City",
            body: "# Cryptology City\n\nBrowse [[Primitives]]. See [[pseudorandom-function|PRFs]].\n"),
        prf: page(
            type: "primitive", title: "Pseudorandom function", aliases: ["PRF"],
            body: """
                # Pseudorandom function

                Built from a [[one-way-function]] by \
                [[GGM86 - How to construct random functions|GGM86]].

                ## Syntax

                A keyed family of functions that looks random.

                """),
        owf: page(
            type: "primitive", title: "One-way function", aliases: ["OWF"],
            body: "# One-way function\n\nEasy to compute and hard to invert.\n"),
        lwe: page(
            type: "assumption", title: "Learning with errors", aliases: ["LWE"],
            body: "# Learning with errors\n\nNoisy linear equations imply a [[PRF]].\n\n"
                + "![[diagram.png]]\n"),
        ggm: page(
            type: "reference", title: "GGM86",
            extra: "authors: Oded Goldreich, Shafi Goldwasser, Silvio Micali\n"
                + "published: 1986-01-01\n",
            body: "# How to construct random functions\n\nThe tree construction of a "
                + "pseudorandom function from a pseudorandom generator.\n"),
        diagram: "not really a PNG",
        "content/Templates/primitive.md": page(
            type: "primitive", title: "Template", body: "# Template\n"),
        "content/Primitives/.draft.md": page(
            type: "primitive", title: "Hidden", body: "# Hidden\n"),
        "content/Primitives/README": "No extension, so not part of the site.\n",
        manifestPath: manifest(),
        "macros.ts": macros,
    ]
}

/// A git repository in a temporary directory, for the tests that check
/// what CCwiki asks git. Every command runs with no global or system
/// configuration and a fixed identity, since CI has no identity and a
/// maintainer's own configuration may sign or hook (§5). Nil when git is
/// not installed, and the test then has nothing to check.
struct FixtureRepository {
    let root: URL
    let git: String

    /// A new, empty repository on `main`, at `root` or in a fresh temporary
    /// directory.
    static func make(at place: URL? = nil) async -> FixtureRepository? {
        guard let git = ToolLocator.locate(.git, override: nil) else { return nil }
        let directory = place ?? FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-repository-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }
        let repository = FixtureRepository(root: directory, git: git)
        guard await repository.run(["init", "-q", "-b", "main"]).succeeded else {
            repository.delete()
            return nil
        }
        return repository
    }

    static func environment(date: Int? = nil) -> [String: String] {
        // The process's own, for PATH, TMPDIR and DEVELOPER_DIR, without any
        // GIT_ variable that could point git somewhere else.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge([
            "HOME": FileManager.default.temporaryDirectory.path(percentEncoded: false),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "CCwiki Tests",
            "GIT_AUTHOR_EMAIL": "tests@ccwiki.invalid",
            "GIT_COMMITTER_NAME": "CCwiki Tests",
            "GIT_COMMITTER_EMAIL": "tests@ccwiki.invalid",
            "GIT_TERMINAL_PROMPT": "0",
        ]) { _, fixed in fixed }
        if let date {
            environment["GIT_AUTHOR_DATE"] = "\(date) +0000"
            environment["GIT_COMMITTER_DATE"] = "\(date) +0000"
        }
        return environment
    }

    /// The service the app would use on this repository.
    var service: GitService {
        GitService(executable: git, environment: Self.environment())
    }

    @discardableResult
    func run(_ arguments: [String], date: Int? = nil) async -> Subprocess.Result {
        await Subprocess.run(
            executable: git, arguments: ["-C", root.path(percentEncoded: false)] + arguments,
            environment: Self.environment(date: date))
    }

    func write(_ path: String, _ text: String) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: path))
    }

    /// Stages everything and commits it at `date`, seconds since 1970;
    /// returns the commit.
    func commit(_ message: String, date: Int) async -> String? {
        guard await run(["add", "-A"]).succeeded,
              await run(["commit", "-q", "--no-verify", "-m", message], date: date).succeeded
        else { return nil }
        return await head()
    }

    func head() async -> String? {
        let result = await run(["rev-parse", "HEAD"])
        return result.succeeded ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func delete() {
        try? FileManager.default.removeItem(at: root)
    }
}
