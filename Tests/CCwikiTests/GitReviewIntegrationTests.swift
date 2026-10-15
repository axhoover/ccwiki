import Foundation
import Testing
@testable import CCwiki

/// The git a review runs on, against real git in temporary repositories
/// (plans/corrections.md §6, §12.2). Nothing here touches the network: the
/// "GitHub" is a bare repository beside the clone. CI has git but no
/// identity, so `FixtureRepository.environment` supplies one, and no global
/// or system configuration can sign, hook or rename anything.
///
/// These check `GitService` itself: bytes, staging, the patch, the commit,
/// the leases. The snapshot and Approve built on them have tests of their
/// own.
struct GitReviewIntegrationTests {

    /// A clone with a bare `origin`, and a job's worktree on `fix/page` at
    /// the commit `origin/main` named. Nil when git is not installed.
    struct Scene {
        let clone: FixtureRepository
        let origin: URL
        let worktree: URL
        let base: String

        var git: GitService { clone.service }

        static let branch = "fix/page"

        static func make() async throws -> Scene? {
            guard let clone = await FixtureRepository.make() else { return nil }
            let parent = clone.root.deletingLastPathComponent()
            let name = clone.root.lastPathComponent
            let origin = parent.appending(path: name + "-origin.git")
            let worktree = parent.appending(path: name + "-worktree")

            let bare = await Subprocess.run(
                executable: clone.git,
                arguments: ["init", "-q", "--bare", "-b", "main", origin.path(percentEncoded: false)],
                environment: FixtureRepository.environment())
            try #require(bare.succeeded, "git init --bare: \(bare.output)")

            // No final newline, CRLF endings, and a file nobody changes.
            try clone.write("content/page.md", "a\nb\nc")
            try clone.write("content/crlf.md", "x\r\ny\r\n")
            try clone.write("content/other.md", "other\n")
            try #require(await clone.commit("init", date: 1_780_000_000) != nil)
            for arguments in [["remote", "add", "origin", origin.path(percentEncoded: false)],
                              ["push", "-q", "origin", "main"],
                              ["fetch", "-q", "origin"]] {
                let result = await clone.run(arguments)
                try #require(result.succeeded, "git \(arguments[0]): \(result.output)")
            }

            let base = try #require(await clone.service.resolveCommit("origin/main", in: clone.root))
            let added = await clone.service.addWorktree(
                clone: clone.root, at: worktree, branch: branch, baseRef: base) { _ in }
            try #require(added)
            return Scene(clone: clone, origin: origin, worktree: worktree, base: base)
        }

        func delete() {
            clone.delete()
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: worktree)
        }

        /// git in the worktree, as an agent or a person would run it.
        @discardableResult
        func run(_ arguments: [String], date: Int? = nil) async -> Subprocess.Result {
            await Subprocess.run(
                executable: clone.git,
                arguments: ["-C", worktree.path(percentEncoded: false)] + arguments,
                environment: FixtureRepository.environment(date: date))
        }

        func write(_ path: String, _ data: Data) throws {
            let file = worktree.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        func read(_ path: String) throws -> Data {
            try Data(contentsOf: worktree.appending(path: path))
        }

        /// The staged changes' `--name-status -z` fields.
        func nameStatus() async throws -> [String] {
            try #require(await git.stageAll(in: worktree))
            let diff = try #require(await git.stagedDiff(in: worktree, base: base))
            return GitService.fields(nulSeparated: diff.nameStatus)
        }

        /// Stages everything, as a review does, and returns the staged tree
        /// and the digest of its diff: what a person would have reviewed.
        func review(with git: GitService? = nil) async throws -> (tree: String, digest: String) {
            let git = git ?? self.git
            try #require(await git.stageAll(in: worktree))
            let diff = try #require(await git.stagedDiff(in: worktree, base: base))
            return (diff.tree, ReviewSnapshot.digest(diff.patch))
        }

        /// What is staged, reviewed and then committed as Approve commits it.
        func commitReviewed(_ message: String) async throws -> String {
            let reviewed = try await review()
            let outcome = await git.commitReviewed(
                in: worktree, base: base, branch: Self.branch, tree: reviewed.tree,
                digest: reviewed.digest, message: message)
            return try #require(outcome.commit, "\(outcome)")
        }

        /// The digest of `git diff --cached <base>` with the options the
        /// review used before the PR #11 review's fixes: what git itself,
        /// honouring replacements and `diff.ignoreSubmodules`, shows.
        func porcelainDigest() async throws -> String {
            let result = await Subprocess.runData(
                executable: clone.git,
                arguments: ["-C", worktree.path(percentEncoded: false), "diff", "--cached",
                            "--no-color", "--no-ext-diff", "--no-textconv", "-M", "--binary",
                            "--full-index", "--src-prefix=a/", "--dst-prefix=b/", base],
                environment: FixtureRepository.environment())
            try #require(result.status == 0, "git diff: \(result.stderr)")
            return ReviewSnapshot.digest(result.stdout)
        }

        /// `git rev-parse <revision>` in the worktree.
        func revParse(_ revision: String) async -> String {
            await run(["rev-parse", revision]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static let newPage = "content/References/A - B & é [draft].md"

    // MARK: Reading

    @Test("a commit resolves to its full name; a ref that names nothing does not")
    func resolving() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        #expect(scene.base.count == 40)
        #expect(await scene.git.resolveCommit(scene.base, in: scene.worktree) == scene.base)
        #expect(await scene.git.resolveCommit("no-such-branch", in: scene.clone.root) == nil)
        #expect(await scene.git.mergeBase(scene.base, "HEAD", in: scene.worktree) == scene.base)
    }

    @Test("blobs come back byte for byte: CRLF, no final newline, the index")
    func blobs() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        #expect(await git.blob("\(scene.base):content/page.md", in: scene.worktree)
            == Data("a\nb\nc".utf8))
        #expect(await git.blob("\(scene.base):content/crlf.md", in: scene.worktree)
            == Data("x\r\ny\r\n".utf8))
        #expect(await git.blob("\(scene.base):content/missing.md", in: scene.worktree) == nil)
        #expect(await git.blob("\(scene.base):content", in: scene.worktree) == nil,
                "a directory is not a blob")

        try scene.write("content/page.md", Data("a\nB\nc\n".utf8))
        #expect(await git.stageAll(in: scene.worktree))
        #expect(await git.blob(":content/page.md", in: scene.worktree) == Data("a\nB\nc\n".utf8))
    }

    // MARK: Staging and the patch

    @Test("staging leaves out .ccwiki, even when the agent committed it, and ignores upstream")
    func staging() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }

        // Upstream moves on; the review is against the base, so it does not show.
        try scene.clone.write("content/other.md", "upstream\n")
        try #require(await scene.clone.commit("upstream", date: 1_780_000_100) != nil)
        try #require(await scene.clone.run(["push", "-q", "origin", "main"]).succeeded)

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        try scene.write(Self.newPage, Data("new\n".utf8))
        try scene.write(".ccwiki/pull-request.md", Data("# [fix] Page: b\n".utf8))
        try scene.write(".ccwiki/lint.log", Data("ok\n".utf8))
        let staged = try await scene.nameStatus()
        #expect(staged == ["A", Self.newPage, "M", "content/page.md"])

        // An agent that committed its hand-over despite the deny-list.
        #expect(await scene.run(["add", "-f", ".ccwiki/pull-request.md"]).succeeded)
        #expect(await scene.run(["commit", "-q", "--no-verify", "-m", "agent"],
                                date: 1_780_000_200).succeeded)
        let afterCommit = try await scene.nameStatus()
        #expect(afterCommit == ["A", Self.newPage, "M", "content/page.md"])
    }

    @Test("the patch is stable, numstat names a binary in one field, and an untouched file gives nothing")
    func diffOutputs() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        #expect(await git.stageAll(in: scene.worktree))
        let clean = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        #expect(clean.nameStatus.isEmpty && clean.numstat.isEmpty && clean.patch.isEmpty,
                "files with and without a final newline, untouched, are not changes")

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        try scene.write("content/figure.bin", Data([0, 1, 2, 0, 255]))
        #expect(await scene.run(["mv", "content/crlf.md", "content/crlf-renamed.md"]).succeeded)
        #expect(await git.stageAll(in: scene.worktree))
        let first = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        let second = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        #expect(first.patch == second.patch)
        #expect(first.nameStatus == second.nameStatus)

        // `--no-renames`: every numstat entry is "<added>\t<removed>\t<path>".
        let numstat = GitService.fields(nulSeparated: first.numstat)
        #expect(numstat.contains("-\t-\tcontent/figure.bin"))
        let malformed = numstat.filter { $0.split(separator: "\t").count != 3 }
        #expect(malformed.isEmpty, "\(malformed)")
        let renames = GitService.fields(nulSeparated: first.nameStatus).filter { $0.hasPrefix("R") }
        #expect(!renames.isEmpty, "name-status still detects the rename")

        let patch = String(decoding: first.patch, as: UTF8.self)
        #expect(patch.contains("diff --git a/content/page.md b/content/page.md"))
        #expect(patch.contains("GIT binary patch"))
    }

    @Test("reverting returns a changed file to the base and removes an added one")
    func reverting() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        try scene.write(Self.newPage, Data("new\n".utf8))
        let before = try await scene.nameStatus()
        #expect(before.count == 4)

        #expect(await git.revertPath("content/page.md", to: scene.base, in: scene.worktree))
        #expect(await git.revertPath(Self.newPage, to: scene.base, in: scene.worktree))
        let page = try scene.read("content/page.md")
        #expect(page == Data("a\nb\nc".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: scene.worktree.appending(path: Self.newPage).path(percentEncoded: false)))
        let after = try await scene.nameStatus()
        #expect(after.isEmpty)
    }

    @Test("the patch round-trips: a worktree made again at the base takes it back exactly")
    func restoring() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        try scene.write("content/crlf.md", Data("x\r\nY\r\n".utf8))
        try scene.write(Self.newPage, Data("new\n".utf8))
        #expect(await git.stageAll(in: scene.worktree))
        let reviewed = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        let patchFile = scene.clone.root.deletingLastPathComponent()
            .appending(path: scene.clone.root.lastPathComponent + ".patch")
        defer { try? FileManager.default.removeItem(at: patchFile) }
        try reviewed.patch.write(to: patchFile)

        // Caches cleared by hand: the worktree's directory is simply gone.
        try FileManager.default.removeItem(at: scene.worktree)
        #expect(await git.addWorktree(
            clone: scene.clone.root, at: scene.worktree,
            resettingBranch: Scene.branch, to: scene.base))
        #expect(await git.applyPatch(patchFile, in: scene.worktree))

        let page = try scene.read("content/page.md")
        let crlf = try scene.read("content/crlf.md")
        let added = try scene.read(Self.newPage)
        #expect(page == Data("a\nB\nc".utf8))
        #expect(crlf == Data("x\r\nY\r\n".utf8))
        #expect(added == Data("new\n".utf8))
        let restored = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        #expect(restored.patch == reviewed.patch, "the restored index is the reviewed one")

        // An empty patch is nothing to apply, not a failure.
        let empty = patchFile.deletingPathExtension().appendingPathExtension("empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        #expect(await git.applyPatch(empty, in: scene.worktree))
    }

    @Test("a worktree moves into place with its changes, and never into a folder already there")
    func moving() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git
        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        #expect(await git.stageAll(in: scene.worktree))
        let moved = scene.worktree.deletingLastPathComponent()
            .appending(path: scene.worktree.lastPathComponent + "-moved")
        defer { try? FileManager.default.removeItem(at: moved) }

        #expect(await git.moveWorktree(clone: scene.clone.root, from: scene.worktree, to: moved))
        #expect(!FileManager.default.fileExists(atPath: scene.worktree.path(percentEncoded: false)))
        #expect(try Data(contentsOf: moved.appending(path: "content/page.md")) == Data("a\nB\nc".utf8))
        #expect(await git.blob(":content/page.md", in: moved) == Data("a\nB\nc".utf8),
                "the index moved with it")
        let listed = await git.listWorktrees(clone: scene.clone.root).map(\.path)
        #expect(listed.contains { $0.hasSuffix("/" + moved.lastPathComponent) })
        #expect(!listed.contains { $0.hasSuffix("/" + scene.worktree.lastPathComponent) })

        // git would move it inside a folder that is there; CCwiki refuses.
        try FileManager.default.createDirectory(at: scene.worktree, withIntermediateDirectories: true)
        #expect(!(await git.moveWorktree(clone: scene.clone.root, from: moved, to: scene.worktree)))
        #expect(FileManager.default.fileExists(
            atPath: moved.appending(path: "content/page.md").path(percentEncoded: false)))
    }

    // MARK: Committing and pushing

    @Test("the commit collapses whatever the agent committed into one, of exactly what was reviewed")
    func committing() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        #expect(await scene.run(["add", "-A"]).succeeded)
        #expect(await scene.run(["commit", "-q", "--no-verify", "-m", "agent"],
                                date: 1_780_000_200).succeeded)
        try scene.write(Self.newPage, Data("new\n".utf8))
        try scene.write(".ccwiki/pull-request.md", Data("# [fix] Page: b\n".utf8))
        let reviewed = try await scene.review()
        let tree = await scene.run(GitService.hooksOff + ["write-tree"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reviewed.tree == tree, "the review is of the staged tree, by name")

        let outcome = await git.commitReviewed(
            in: scene.worktree, base: scene.base, branch: Scene.branch, tree: reviewed.tree,
            digest: reviewed.digest, message: "[fix] Page: b\n\nOpened with CCwiki.")
        let commit = try #require(outcome.commit, "\(outcome)")
        #expect(await scene.revParse("\(commit)^{tree}") == tree, "the reviewed tree")
        #expect(await scene.run(["rev-list", "--parents", "-n", "1", commit]).stdout
            == "\(commit) \(scene.base)", "one commit, whose only parent is the base")
        #expect(await scene.revParse("refs/heads/\(Scene.branch)") == commit)
        #expect(await scene.revParse("HEAD") == commit, "the worktree's HEAD is the branch")
        let files = await scene.run(
            ["-c", "core.quotePath=false", "diff", "--name-only", scene.base, commit])
        #expect(files.stdout.components(separatedBy: "\n").sorted()
            == ["content/page.md", Self.newPage].sorted())
        let message = await scene.run(["log", "-1", "--format=%B", commit])
        #expect(message.stdout.trimmingCharacters(in: .newlines)
            == "[fix] Page: b\n\nOpened with CCwiki.")
        #expect(await git.reflog(of: Scene.branch, in: scene.worktree).contains(commit))
    }

    @Test("a staged tree that is not the reviewed change is never committed, and the branch stays")
    func committingSomethingElse() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        let reviewed = try await scene.review()
        // Staged after the review, as a hook or a straggling process could.
        try scene.write("extra.md", Data("unreviewed\n".utf8))
        #expect(await scene.run(GitService.hooksOff + ["add", "extra.md"]).succeeded)

        // Neither by its tree, nor by its digest when the tree would pass.
        let staged = await scene.run(GitService.hooksOff + ["write-tree"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for (tree, digest) in [(reviewed.tree, reviewed.digest), (staged, reviewed.digest)] {
            let outcome = await git.commitReviewed(
                in: scene.worktree, base: scene.base, branch: Scene.branch, tree: tree,
                digest: digest, message: "m")
            guard case .notReviewed(let why) = outcome else {
                Issue.record("committed a tree nobody reviewed: \(outcome)")
                return
            }
            #expect(why.contains("is not the reviewed change"), "\(why)")
        }
        #expect(await scene.revParse("refs/heads/\(Scene.branch)") == scene.base)
        #expect(await git.reflog(of: Scene.branch, in: scene.worktree)
            .subtracting([scene.base]).isEmpty, "nothing was ever committed to the branch")
    }

    // MARK: What git shows is what git sends (the PR #11 review)

    @Test("a replaced object hides nothing: the review is of the real tree, and a digest taken through the replacement is not the reviewed change")
    func replacedObjects() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        // An agent stages extra.md, writes that tree, and makes it stand in
        // for the base's tree in the clone's shared refs/replace/: through
        // the replacement, the base already has extra.md.
        try scene.write("extra.md", Data("unreviewed\n".utf8))
        #expect(await scene.run(["add", "extra.md"]).succeeded)
        let planted = await scene.run(["write-tree"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = await scene.run(["replace", "\(scene.base)^{tree}", planted])
        try #require(replaced.succeeded, "git replace: \(replaced.output)")
        try scene.write("content/page.md", Data("a\nB\nc".utf8))

        let staged = try await scene.nameStatus()
        #expect(staged == ["M", "content/page.md", "A", "extra.md"], "\(staged)")
        let diff = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        #expect(String(decoding: diff.patch, as: UTF8.self).contains("+unreviewed"))
        // The control: git's own diff, through the replacement, hides it.
        let hidden = await scene.run(["diff", "--cached", "--name-only", scene.base])
        #expect(hidden.stdout == "content/page.md", "\(hidden.output)")

        // The digest the review used to take, through the replacement, is
        // not the reviewed change, though the tree is the one staged.
        let through = try await scene.porcelainDigest()
        #expect(through != ReviewSnapshot.digest(diff.patch))
        let outcome = await git.commitReviewed(
            in: scene.worktree, base: scene.base, branch: Scene.branch, tree: diff.tree,
            digest: through, message: "m")
        guard case .notReviewed = outcome else {
            Issue.record("committed through a replacement: \(outcome)")
            return
        }
        #expect(await scene.revParse("refs/heads/\(Scene.branch)") == scene.base)
    }

    @Test("a submodule's new commit is in the review, by its full name, whatever diff.ignoreSubmodules and diff.submodule say")
    func submodules() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git
        for (key, value) in [("diff.ignoreSubmodules", "all"), ("diff.submodule", "log")] {
            #expect(await scene.clone.run(["config", key, value]).succeeded)
        }

        // What `git submodule update --remote` and an add leave in the
        // index: a gitlink at a commit the review must show, its directory
        // there and not populated, so `add -A` leaves it.
        let commit = String(repeating: "1", count: 40)
        let linked = await scene.run(
            ["update-index", "--add", "--cacheinfo", "160000,\(commit),vendor/cryptobib"])
        try #require(linked.succeeded, "git update-index: \(linked.output)")
        try FileManager.default.createDirectory(
            at: scene.worktree.appending(path: "vendor/cryptobib"), withIntermediateDirectories: true)
        try scene.write("content/page.md", Data("a\nB\nc".utf8))

        let staged = try await scene.nameStatus()
        #expect(staged == ["M", "content/page.md", "A", "vendor/cryptobib"], "\(staged)")
        let diff = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        #expect(String(decoding: diff.patch, as: UTF8.self).contains("+Subproject commit \(commit)"),
                "the commit's full name, never diff.submodule=log's abbreviation")
        // The control: git's own diff hides it.
        let hidden = await scene.run(["diff", "--cached", "--name-only", scene.base])
        #expect(hidden.stdout == "content/page.md", "\(hidden.output)")

        let without = try await scene.porcelainDigest()
        let outcome = await git.commitReviewed(
            in: scene.worktree, base: scene.base, branch: Scene.branch, tree: diff.tree,
            digest: without, message: "m")
        guard case .notReviewed = outcome else {
            Issue.record("committed a submodule nobody reviewed: \(outcome)")
            return
        }
        #expect(await scene.revParse("refs/heads/\(Scene.branch)") == scene.base)
    }

    @Test("a commit's header gives its tree and its parents, not the message's look-alikes")
    func commitHeader() {
        let header = GitService.commitHeader("""
            tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
            parent 1111111111111111111111111111111111111111
            parent 2222222222222222222222222222222222222222
            author A <a@ccwiki.invalid> 1780000000 +0000
            committer A <a@ccwiki.invalid> 1780000000 +0000

            tree in a subject
            parent 3333333333333333333333333333333333333333
            """)
        #expect(header.tree == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        #expect(header.parents == ["1111111111111111111111111111111111111111",
                                   "2222222222222222222222222222222222222222"])
        #expect(GitService.commitHeader("").tree == nil)
    }

    @Test("leases: the first push on absence, the next expecting it, and a stale one refused")
    func pushing() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git
        let remote = scene.origin.path(percentEncoded: false)

        #expect(await git.remoteTip(of: Scene.branch, remote: remote, in: scene.worktree) == .absent)
        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        let first = try await scene.commitReviewed("first")
        let pushed = await git.push(
            first, in: scene.worktree, to: remote, branch: Scene.branch, expecting: nil)
        #expect(pushed.succeeded, "\(pushed.output)")
        #expect(await git.remoteTip(of: Scene.branch, remote: remote, in: scene.worktree)
            == .at(first))

        try scene.write("content/page.md", Data("a\nBB\nc".utf8))
        let second = try await scene.commitReviewed("second")

        let stale = await git.push(
            second, in: scene.worktree, to: remote, branch: Scene.branch, expecting: nil)
        #expect(!stale.succeeded, "a lease on absence cannot overwrite a branch that exists")
        #expect(GitService.leaseWasRefused(stale.output), "\(stale.output)")

        let again = await git.push(
            second, in: scene.worktree, to: remote, branch: Scene.branch, expecting: first)
        #expect(again.succeeded, "\(again.output)")
        #expect(await git.remoteHeads(remote: remote, in: scene.worktree)?[Scene.branch] == second)
        #expect(await git.remoteHeads(remote: remote, in: scene.worktree)?["main"] == scene.base)
        let reflog = await git.reflog(of: Scene.branch, in: scene.worktree)
        #expect(reflog.contains(first) && reflog.contains(second))

        let nowhere = scene.origin.deletingLastPathComponent()
            .appending(path: "no-such-origin.git").path(percentEncoded: false)
        #expect(await git.remoteTip(of: Scene.branch, remote: nowhere, in: scene.worktree)
            == .unknown)
        #expect(await git.remoteHeads(remote: nowhere, in: scene.worktree) == nil)
    }

    @Test("the push arguments name the commit, never HEAD, and lease on absence, then on the commit expected")
    func pushArguments() {
        let first = GitService.pushArguments(
            remote: "origin", branch: "fix/x", commit: "c0ffee", expecting: nil)
        #expect(first.contains("--force-with-lease=refs/heads/fix/x:"))
        #expect(first.suffix(2) == ["origin", "c0ffee:refs/heads/fix/x"])
        #expect(first.contains("--no-verify"))
        #expect(first.contains("--no-follow-tags") && first.contains("--recurse-submodules=no"))
        let next = GitService.pushArguments(
            remote: "origin", branch: "fix/x", commit: "c0ffee", expecting: "abc123")
        #expect(next.contains("--force-with-lease=refs/heads/fix/x:abc123"))
        #expect(!next.contains("--force") && !next.contains("-f"))
        for arguments in [first, next] {
            #expect(!arguments.contains { $0.contains("HEAD") }, "\(arguments)")
        }
        #expect(GitService.hooksOff
            == ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        #expect(GitService.realObjects
            == ["--no-replace-objects", "-c", "core.useReplaceRefs=false"])
        let service = GitService(executable: "/usr/bin/git", environment: [:])
        #expect(service.invocation(["status"]) == GitService.realObjects + ["status"])
        #expect(service.withoutHooks.invocation(["status"])
            == GitService.realObjects + GitService.hooksOff + ["status"])
    }

    @Test("the push sends one ref and no tag, whatever push.followTags says")
    func noTagFollows() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let remote = scene.origin.path(percentEncoded: false)
        // An annotated tag on the base, which the origin does not have.
        #expect(await scene.clone.run(["tag", "-a", "-m", "a tag", "v-local", scene.base]).succeeded)
        #expect(await scene.clone.run(["config", "push.followTags", "true"]).succeeded)

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        let commit = try await scene.commitReviewed("m")
        let pushed = await scene.git.push(
            commit, in: scene.worktree, to: remote, branch: Scene.branch, expecting: nil)
        #expect(pushed.succeeded, "\(pushed.output)")
        func originRefs() async -> Set<String> {
            let listed = await scene.run(["ls-remote", remote])
            return Set(GitService.refs(fromLsRemote: listed.stdout).keys)
        }
        let refs = await originRefs()
        #expect(refs.contains("refs/heads/\(Scene.branch)"))
        #expect(!refs.contains { $0.hasPrefix("refs/tags/") }, "\(refs)")

        // The control: git's own push of the same commit takes the tag along.
        let own = await scene.run(["push", "-q", remote, "\(commit):refs/heads/control"])
        #expect(own.succeeded, "\(own.output)")
        #expect(await originRefs().contains("refs/tags/v-local"))
    }

    // MARK: Hooks

    @Test("no hook runs from staging to the push, and the push sends the reviewed tree on the base",
          arguments: HookTrap.Place.allCases)
    func hooksNeverRun(_ place: HookTrap.Place) async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let trap = try await HookTrap.install(beside: scene.clone, at: place)
        defer { trap.delete() }
        // For `.environment`, only the user's environment names the hooks:
        // the command line's -c is read after it, as after every
        // configuration file. The other places leave it alone, so
        // `.gitDirectory` is git's default lookup with nothing configured.
        let environment = place == .environment
            ? FixtureRepository.environment().merging(
                trap.environment, uniquingKeysWith: { _, named in named })
            : FixtureRepository.environment()
        let git = GitService(executable: scene.clone.git, environment: environment)
        let remote = scene.origin.path(percentEncoded: false)

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        let reviewed = try await scene.review(with: git.withoutHooks)
        let tree = await scene.run(GitService.hooksOff + ["write-tree"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reviewed.tree == tree)
        let outcome = await git.commitReviewed(
            in: scene.worktree, base: scene.base, branch: Scene.branch, tree: reviewed.tree,
            digest: reviewed.digest, message: "[fix] Page: B")
        let commit = try #require(outcome.commit, "\(outcome)")
        let pushed = await git.push(
            commit, in: scene.worktree, to: remote, branch: Scene.branch, expecting: nil)
        #expect(pushed.succeeded, "\(pushed.output)")

        #expect(trap.ran().isEmpty, "hooks ran: \(trap.ran())")
        #expect(await git.remoteTip(of: Scene.branch, remote: remote, in: scene.worktree)
            == .at(commit))
        #expect(await scene.revParse("\(commit)^{tree}") == tree, "the reviewed tree")
        #expect(await scene.run(["rev-list", "--parents", "-n", "1", commit]).stdout
            == "\(commit) \(scene.base)")
        #expect(await git.blob("\(commit):extra.md", in: scene.worktree) == nil)

        // The control: the same hooks, and the monitor, are live for git's
        // own commands, in the same environment, and the sequence Approve
        // used to run is the one the review found.
        let worktree = scene.worktree.path(percentEncoded: false)
        for arguments in [["reset", "-q", "--soft", scene.base],
                          ["commit", "-q", "--no-verify", "-m", "control"]] {
            let result = await Subprocess.run(
                executable: scene.clone.git, arguments: ["-C", worktree] + arguments,
                environment: environment)
            #expect(result.succeeded, "git \(arguments[0]): \(result.output)")
        }
        let ran = trap.ran()
        #expect(ran.contains("post-commit") && ran.contains("reference-transaction")
            && ran.contains(HookTrap.fsmonitor), "\(ran)")
        #expect(await git.blob("HEAD:extra.md", in: scene.worktree) != nil,
                "--no-verify still runs post-commit, which amended HEAD")
    }

    @Test("what is pushed is the commit that was checked, whatever moves HEAD after")
    func headMovesAfterTheCheck() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git
        let remote = scene.origin.path(percentEncoded: false)

        try scene.write("content/page.md", Data("a\nB\nc".utf8))
        let checked = try await scene.commitReviewed("checked")
        try scene.write("content/page.md", Data("a\nunreviewed\nc".utf8))
        #expect(await scene.run(["commit", "-q", "--no-verify", "-a", "-m", "moved"],
                                date: 1_780_000_300).succeeded)
        let head = await scene.revParse("HEAD")
        #expect(head != checked && head.count == checked.count)

        let pushed = await git.push(
            checked, in: scene.worktree, to: remote, branch: Scene.branch, expecting: nil)
        #expect(pushed.succeeded, "\(pushed.output)")
        #expect(await git.remoteTip(of: Scene.branch, remote: remote, in: scene.worktree)
            == .at(checked))
    }

    // MARK: Branches, identity, upstream

    @Test("a branch is renamed in its worktree and deleted from the clone, never the remote")
    func branches() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }
        let git = scene.git

        #expect(await git.renameBranch(Scene.branch, to: "fix/page-2", in: scene.worktree))
        let head = await scene.run(["rev-parse", "--abbrev-ref", "HEAD"])
        #expect(head.stdout == "fix/page-2")

        #expect(await git.removeWorktree(clone: scene.clone.root, at: scene.worktree, force: true))
        #expect(await git.deleteBranch("fix/page-2", in: scene.clone.root))
        #expect(await git.resolveCommit("refs/heads/fix/page-2", in: scene.clone.root) == nil)
    }

    @Test("the identity is the environment's, or the configuration's; without either, none")
    func identity() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }

        let fromEnvironment = try #require(await scene.git.identity(in: scene.worktree))
        #expect(fromEnvironment.name == "CCwiki Tests")
        #expect(fromEnvironment.email == "tests@ccwiki.invalid")

        let anonymous = GitService(
            executable: scene.clone.git,
            environment: FixtureRepository.environment().filter { !$0.key.hasPrefix("GIT_AUTHOR_") })
        #expect(await anonymous.identity(in: scene.worktree) == nil)

        #expect(await scene.run(["config", "user.name", "Configured"]).succeeded)
        #expect(await scene.run(["config", "user.email", "configured@ccwiki.invalid"]).succeeded)
        let configured = try #require(await anonymous.identity(in: scene.worktree))
        #expect(configured.name == "Configured")
        #expect(configured.email == "configured@ccwiki.invalid")
    }

    @Test("only the given paths that changed upstream since the base are named")
    func upstream() async throws {
        guard let scene = try await Scene.make() else { return }
        defer { scene.delete() }

        try scene.clone.write("content/other.md", "upstream\n")
        try #require(await scene.clone.commit("upstream", date: 1_780_000_100) != nil)
        try #require(await scene.clone.run(["push", "-q", "origin", "main"]).succeeded)
        try #require(await scene.clone.run(["fetch", "-q", "origin"]).succeeded)

        let changed = await scene.git.changedPaths(
            in: scene.clone.root, from: scene.base, to: "origin/main",
            limitedTo: ["content/other.md", "content/page.md"])
        #expect(changed == ["content/other.md"])
        #expect(await scene.git.changedPaths(
            in: scene.clone.root, from: scene.base, to: "origin/main", limitedTo: []).isEmpty)
    }

}

/// The snapshot a review is built on, taken through the job center against
/// real git (plans/corrections.md §6.1, §12.2, steps 1–6). Upstream moves
/// on after the job starts; the agent's or the editor's scratch in
/// `.ccwiki/` is never part of it.
@MainActor
struct ReviewSnapshotIntegrationTests {

    static let newPage = "content/References/A - B & é [draft].md"

    /// An edit job; then `origin/main` advances, the page is edited, a page
    /// is added, and the hand-over and a lint log are written.
    static func editedScene() async throws -> (JobScene, Job)? {
        guard let scene = try await JobScene.make() else { return nil }
        let job = try await scene.beginEdit()

        try scene.clone.write("content/other.md", "upstream\n")
        try #require(await scene.clone.commit("upstream", date: 1_780_000_100) != nil)
        try #require(await scene.clone.run(["push", "-q", "origin", "main"]).succeeded)
        try #require(await scene.clone.run(["fetch", "-q", "origin"]).succeeded)

        try scene.write("content/page.md", "a\nB\nc", in: job)
        try scene.write(newPage, "new\n", in: job)
        try scene.write(".ccwiki/pull-request.md", "# [fix] Page: B\n\nWhy.\n", in: job)
        try scene.write(".ccwiki/lint.log", "ok\n", in: job)
        return (scene, job)
    }

    @Test("the saved patch holds the two changes, not .ccwiki/ and not upstream's")
    func patch() async throws {
        guard let (scene, job) = try await Self.editedScene() else { return }
        defer { scene.delete() }

        await scene.center.refreshReview(job)
        let patch = scene.patch(of: job)
        #expect(patch.contains("diff --git a/content/page.md b/content/page.md"))
        // git quotes the new page's name, for its é, so its content is looked for.
        #expect(patch.contains("new file mode") && patch.contains("+new"))
        #expect(!patch.contains(".ccwiki"))
        #expect(!patch.contains("content/other.md"), "upstream's commit is not the job's")
        #expect(!patch.contains("content/region.md"))

        // Nothing changed, nothing new: the same bytes again.
        let first = try Data(contentsOf: job.patchFile)
        await scene.center.refreshReview(job)
        #expect(try Data(contentsOf: job.patchFile) == first)
    }

    @Test("reverting both files leaves nothing to review")
    func revertBoth() async throws {
        guard let (scene, job) = try await Self.editedScene() else { return }
        defer { scene.delete() }

        await scene.center.refreshReview(job)
        await scene.center.revert("content/page.md", in: job)
        await scene.center.revert(Self.newPage, in: job)
        #expect(try Data(contentsOf: job.patchFile).isEmpty)
        #expect(try scene.read("content/page.md", in: job) == JobScene.page)
        #expect(!FileManager.default.fileExists(
            atPath: job.worktree.appending(path: Self.newPage).path(percentEncoded: false)))
        #expect(job.review?.isEmpty == true)
        #expect(FileManager.default.fileExists(
            atPath: job.worktree.appending(path: ".ccwiki/lint.log").path(percentEncoded: false)),
            "the scratch stays on disk")
    }

    @Test("the snapshot reports exactly the two files, with a stable digest")
    func snapshot() async throws {
        guard let (scene, job) = try await Self.editedScene() else { return }
        defer { scene.delete() }

        await scene.center.refreshReview(job)
        let review = try #require(job.review)
        #expect(review.baseCommit == scene.base)
        #expect(review.files.map(\.path) == [Self.newPage, "content/page.md"])
        let page = try #require(review.files.first { $0.path == "content/page.md" })
        #expect(page.status == .modified)
        #expect(page.oldText == JobScene.page && page.newText == "a\nB\nc")
        #expect(page.hunks == [LineHunk(old: 1..<2, new: 1..<2)],
                "no end-of-file hunk for a file without a final newline")
        let added = try #require(review.files.first { $0.path == Self.newPage })
        #expect(added.status == .added && added.oldText == nil && added.newText == "new\n")
        #expect(review.digest.count == 64)

        await scene.center.refreshReview(job)
        #expect(job.review?.digest == review.digest)
    }

    @Test("an agent's commit shows in the review, collapsed onto the base")
    func agentCommit() async throws {
        guard let (scene, job) = try await Self.editedScene() else { return }
        defer { scene.delete() }
        let agent = await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false), "add", "-A", "--",
                        "content"],
            environment: FixtureRepository.environment())
        try #require(agent.succeeded)
        let commit = await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false), "commit", "-q",
                        "--no-verify", "-m", "agent"],
            environment: FixtureRepository.environment(date: 1_780_000_200))
        try #require(commit.succeeded)

        await scene.center.refreshReview(job)
        #expect(job.review?.files.map(\.path) == [Self.newPage, "content/page.md"])
    }
}

/// Executable hooks where a clone's git finds them, each leaving a marker
/// when git runs it: what a maintainer's own hooks, or ones an agent
/// planted, could do between a review and its push (§6.5). The
/// `post-commit` one also amends HEAD to add `extra.md`, which nobody
/// reviewed, as in the PR #11 review. The clone's configuration also names
/// a file-system monitor (`core.fsmonitor`), the hook githooks(5) calls
/// `fsmonitor-watchman`, which leaves the marker `fsmonitor`.
struct HookTrap {
    let hooks: URL
    let markers: URL

    /// Where the hooks go, and what names them.
    enum Place: String, Sendable, CaseIterable {
        /// The clone's own `.git/hooks`, git's default, which nothing
        /// configures.
        case gitDirectory
        /// A directory beside the clone, which the clone's configuration
        /// names as `core.hooksPath`.
        case configuredPath
        /// A directory beside the clone, which only the environment names,
        /// through `GIT_CONFIG_COUNT` (`environment`).
        case environment
    }

    static let names = [
        "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "post-rewrite",
        "post-index-change", "post-checkout", "reference-transaction", "pre-push",
    ]

    /// The marker the file-system monitor leaves.
    static let fsmonitor = "fsmonitor"

    /// Every hook, for `repository` and so for its worktrees too, at
    /// `place`, and the monitor in the repository's configuration.
    static func install(beside repository: FixtureRepository, at place: Place = .configuredPath)
        async throws -> HookTrap {
        let parent = repository.root.deletingLastPathComponent()
        let name = repository.root.lastPathComponent
        let trap = HookTrap(
            hooks: place == .gitDirectory
                ? repository.root.appending(path: ".git/hooks")
                : parent.appending(path: name + "-hooks"),
            markers: parent.appending(path: name + "-hook-markers"))
        let manager = FileManager.default
        try manager.createDirectory(at: trap.hooks, withIntermediateDirectories: true)
        try manager.createDirectory(at: trap.markers, withIntermediateDirectories: true)
        let markers = trap.markers.path(percentEncoded: false)
        for hook in names + ["fsmonitor-watchman"] {
            let marker = hook == "fsmonitor-watchman" ? fsmonitor : hook
            var script = "#!/bin/sh\ntouch '\(markers)/\(marker)'\n"
            if hook == "post-commit" {
                script += "printf 'unreviewed\\n' > extra.md\n"
                    + "git add extra.md\n"
                    + "git -c core.hooksPath=/dev/null -c commit.gpgsign=false "
                    + "commit --amend --no-edit --no-verify --quiet\n"
            }
            if hook == "fsmonitor-watchman" {
                // A monitor that cannot answer: git scans the files itself.
                script += "exit 1\n"
            }
            let file = trap.hooks.appending(path: hook)
            try Data(script.utf8).write(to: file)
            try manager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        var settings = [("core.fsmonitor", trap.hooks.appending(path: "fsmonitor-watchman"))]
        if place == .configuredPath { settings.append(("core.hooksPath", trap.hooks)) }
        for (key, value) in settings {
            let configured = await repository.run(["config", key, value.path(percentEncoded: false)])
            try #require(configured.succeeded, "git config: \(configured.output)")
        }
        return trap
    }

    /// `GIT_CONFIG_COUNT` and its pair, naming the hooks as `core.hooksPath`:
    /// the user's environment, read after every configuration file and
    /// before the command line's `-c`.
    var environment: [String: String] {
        [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": hooks.path(percentEncoded: false),
        ]
    }

    /// The hooks git has run, by name.
    func ran() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: markers.path(percentEncoded: false))) ?? []).sorted()
    }

    func delete() {
        try? FileManager.default.removeItem(at: hooks)
        try? FileManager.default.removeItem(at: markers)
    }
}

/// `Subprocess.runData`: stdout exactly as the child wrote it (§6.1).
struct SubprocessDataTests {

    static let environment = ProcessInfo.processInfo.environment

    @Test("stdout keeps carriage returns, NULs and the final newline")
    func bytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-rundata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("one\r\ntwo\rthree\u{0}four\n\n".utf8)
        try bytes.write(to: directory.appending(path: "file"))

        let cat = await Subprocess.runData(
            executable: "/bin/cat", arguments: ["file"], currentDirectory: directory,
            environment: Self.environment)
        #expect(cat.status == 0)
        #expect(cat.stdout == bytes)
        #expect(cat.stderr.isEmpty)
    }

    @Test("the status and stderr arrive apart from stdout")
    func failure() async {
        let result = await Subprocess.runData(
            executable: "/bin/sh", arguments: ["-c", "printf out; echo ' oops ' >&2; exit 3"],
            environment: Self.environment)
        #expect(result.status == 3)
        #expect(result.stdout == Data("out".utf8))
        #expect(result.stderr == "oops")

        let missing = await Subprocess.runData(
            executable: "/nonexistent/tool", arguments: [], environment: Self.environment)
        #expect(missing.status == 127)
        #expect(missing.stdout.isEmpty)
    }
}
