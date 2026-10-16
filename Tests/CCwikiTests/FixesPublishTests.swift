import Foundation
import Testing
@testable import CCwiki

/// The review and Approve against what git can stage besides text pages: a
/// submodule's commit, a symbolic link, a worktree's `.git` or `commondir`
/// rewritten, and a warning a sync brings after the review
/// (plans/corrections.md §5.1, §6.1, §6.2, §6.5). Against real git in
/// temporary repositories; nothing touches the network.
@MainActor
@Suite struct FixesPublishTests {

    /// A clone whose base records `vendor/sub`, a submodule at the first of
    /// its two commits, and a job's worktree with the submodule checked out
    /// there, as an ingestion's runner leaves it. Nil when git is not
    /// installed.
    struct SubmoduleScene {
        let library: FixtureRepository
        let clone: FixtureRepository
        let worktree: URL
        let base: String
        /// The submodule's commit at the base, and the one after it.
        let recorded: String
        let later: String

        var git: GitService { clone.service }

        static let path = "vendor/sub"

        static func make() async throws -> SubmoduleScene? {
            guard let library = await FixtureRepository.make() else { return nil }
            try library.write("bib.txt", "one\n")
            let recorded = try #require(await library.commit("one", date: 1_780_000_000))
            try library.write("bib.txt", "two\n")
            let later = try #require(await library.commit("two", date: 1_780_000_100))

            guard let clone = await FixtureRepository.make() else {
                library.delete()
                return nil
            }
            try clone.write("content/page.md", "a\nb\nc")
            try #require(await clone.commit("page", date: 1_780_000_150) != nil)
            // A submodule cloned from a local path needs the file transport
            // allowed (git 2.38.1 and later).
            let added = await clone.run([
                "-c", "protocol.file.allow=always", "submodule", "add",
                library.root.path(percentEncoded: false), path,
            ])
            try #require(added.succeeded, "git submodule add: \(added.output)")
            let pinned = await clone.run(["-C", path, "checkout", "-q", recorded])
            try #require(pinned.succeeded, "git checkout: \(pinned.output)")
            let base = try #require(await clone.commit("init", date: 1_780_000_200))

            let worktree = clone.root.deletingLastPathComponent()
                .appending(path: clone.root.lastPathComponent + "-worktree")
            let made = await clone.service.addWorktree(
                clone: clone.root, at: worktree, branch: "ingest/x", baseRef: base) { _ in }
            try #require(made)
            let scene = SubmoduleScene(
                library: library, clone: clone, worktree: worktree, base: base,
                recorded: recorded, later: later)
            let updated = await scene.run([
                "-c", "protocol.file.allow=always", "submodule", "update", "--init",
            ])
            try #require(updated.succeeded, "git submodule update: \(updated.output)")
            return scene
        }

        func delete() {
            library.delete()
            clone.delete()
            try? FileManager.default.removeItem(at: worktree)
        }

        /// git in the worktree, as an agent or a person would run it.
        @discardableResult
        func run(_ arguments: [String]) async -> Subprocess.Result {
            await Subprocess.run(
                executable: clone.git,
                arguments: ["-C", worktree.path(percentEncoded: false)] + arguments,
                environment: FixtureRepository.environment())
        }

        /// The submodule at its later commit, as `git submodule update
        /// --remote` leaves it.
        func moveSubmodule() async throws {
            let moved = await run(["-C", Self.path, "checkout", "-q", later])
            try #require(moved.succeeded, "git checkout: \(moved.output)")
        }

        func submoduleHead() async -> String {
            await run(["-C", Self.path, "rev-parse", "HEAD"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The staged changes' `--name-status -z` fields.
        func nameStatus() async throws -> [String] {
            try #require(await git.stageAll(in: worktree))
            let diff = try #require(await git.stagedDiff(in: worktree, base: base))
            return GitService.fields(nulSeparated: diff.nameStatus)
        }

        var patchFile: URL {
            clone.root.deletingLastPathComponent()
                .appending(path: clone.root.lastPathComponent + ".patch")
        }
    }

    static let context = DiffGuard.Context(
        kind: .edit, humanVerifiedPaths: [], changedUpstream: [], target: nil, privatePaths: [])

    // MARK: Revert File on a submodule

    @Test("Revert File puts a moved submodule back, and the next snapshot stages nothing")
    func revertSubmodule() async throws {
        guard let scene = try await SubmoduleScene.make() else { return }
        defer { scene.delete() }
        let git = scene.git
        try await scene.moveSubmodule()
        #expect(try await scene.nameStatus() == ["M", SubmoduleScene.path])

        #expect(await git.revertPath(SubmoduleScene.path, to: scene.base, in: scene.worktree))
        #expect(await scene.submoduleHead() == scene.recorded)
        #expect(try await scene.nameStatus().isEmpty, "git add -A does not stage it again")
        let bib = scene.worktree.appending(path: "\(SubmoduleScene.path)/bib.txt")
        #expect(try String(contentsOf: bib, encoding: .utf8) == "one\n",
                "its checkout is kept, at the base's commit")
    }

    @Test("a submodule whose checkout cannot go back is reported, not called reverted")
    func revertSubmoduleRefused() async throws {
        guard let scene = try await SubmoduleScene.make() else { return }
        defer { scene.delete() }
        try await scene.moveSubmodule()
        // A change of its own in the submodule, which its checkout would overwrite.
        let bib = scene.worktree.appending(path: "\(SubmoduleScene.path)/bib.txt")
        try Data("local\n".utf8).write(to: bib)
        #expect(try await scene.nameStatus() == ["M", SubmoduleScene.path])

        #expect(!(await scene.git.revertPath(SubmoduleScene.path, to: scene.base, in: scene.worktree)))
        #expect(try String(contentsOf: bib, encoding: .utf8) == "local\n", "nothing was deleted")
    }

    // MARK: A submodule the configuration hides

    @Test("a moved submodule is in every staged diff, whatever the configuration hides")
    func ignoredSubmodule() async throws {
        guard let scene = try await SubmoduleScene.make() else { return }
        defer { scene.delete() }
        defer { try? FileManager.default.removeItem(at: scene.patchFile) }
        let git = scene.git
        for (key, value) in [("diff.ignoreSubmodules", "all"), ("diff.submodule", "log")] {
            let set = await scene.clone.run(["config", key, value])
            try #require(set.succeeded, "git config: \(set.output)")
        }
        try await scene.moveSubmodule()

        #expect(await git.stageAll(in: scene.worktree))
        let diff = try #require(await git.stagedDiff(in: scene.worktree, base: scene.base))
        #expect(GitService.fields(nulSeparated: diff.nameStatus) == ["M", SubmoduleScene.path])
        #expect(GitService.fields(nulSeparated: diff.numstat)
            .contains { $0.hasSuffix("\t" + SubmoduleScene.path) })
        let patch = String(decoding: diff.patch, as: UTF8.self)
        #expect(patch.contains("+Subproject commit \(scene.later)"),
                "written short, as a patch that applies again: \(patch)")
        let modes = try #require(await git.stagedModes(
            in: scene.worktree, base: scene.base, tree: diff.tree))
        #expect(GitNameStatus.irregularPaths(rawZ: modes) == [SubmoduleScene.path])

        let snapshot = try #require(await ReviewSnapshotter(git: git).snapshot(
            worktree: scene.worktree, base: scene.base, patchFile: scene.patchFile))
        let file = try #require(snapshot.files.first(where: { $0.path == SubmoduleScene.path }))
        #expect(file.isBinary)
        let blocking = DiffGuard.check(snapshot, context: Self.context)
            .filter { $0.severity == .blocking }.map(\.rule)
        #expect(blocking.contains(.outsideContent))
    }

    // MARK: Symbolic links

    @Test("--raw -z: a link and a submodule are irregular; a file, an executable and a deletion are not")
    func irregularModes() {
        let raw = [
            ":100644 100644 7898192 422c2b7 M", "content/a.md",
            ":000000 120000 0000000 91bf449 A", "content/References/A - B & é.md",
            ":100644 120000 7898192 91bf449 T", "content/other.md",
            ":160000 160000 9a9a9a3 2d2427a M", "vendor/cryptobib",
            ":100644 100755 7898192 7898192 M", "scripts/run.sh",
            ":120000 000000 91bf449 0000000 D", "content/gone.md",
            ":100644 120000 7898192 91bf449 R100", "content/old.md", "content/new.md",
        ].map { $0 + "\0" }.joined()
        #expect(GitNameStatus.irregularPaths(rawZ: Data(raw.utf8)) == [
            "content/References/A - B & é.md", "content/other.md", "vendor/cryptobib",
            "content/new.md",
        ])
        #expect(GitNameStatus.irregularPaths(rawZ: Data()).isEmpty)
    }

    @Test("a symbolic link under content/ is taken as binary, so DiffGuard blocks it")
    func symbolicLink() async throws {
        guard let scene = try await GitReviewIntegrationTests.Scene.make() else { return }
        defer { scene.delete() }
        let patchFile = scene.clone.root.deletingLastPathComponent()
            .appending(path: scene.clone.root.lastPathComponent + ".patch")
        defer { try? FileManager.default.removeItem(at: patchFile) }
        let manager = FileManager.default

        // A new page that is a link out of the repository, and a page
        // replaced by a link: a type change.
        let added = scene.worktree.appending(path: "content/References/X.md")
        try manager.createDirectory(
            at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            atPath: added.path(percentEncoded: false), withDestinationPath: "../../../../etc/passwd")
        let replaced = scene.worktree.appending(path: "content/other.md")
        try manager.removeItem(at: replaced)
        try manager.createSymbolicLink(
            atPath: replaced.path(percentEncoded: false), withDestinationPath: "page.md")

        let snapshot = try #require(await ReviewSnapshotter(git: scene.git).snapshot(
            worktree: scene.worktree, base: scene.base, patchFile: patchFile))
        let links = ["content/References/X.md", "content/other.md"]
        for path in links {
            let file = try #require(snapshot.files.first(where: { $0.path == path }), "\(path)")
            #expect(file.isBinary && file.newText == nil, "\(path)")
        }
        let blocked = DiffGuard.check(snapshot, context: Self.context)
            .filter { $0.rule == .binaryFile && $0.severity == .blocking }.map(\.path)
        #expect(Set(blocked) == Set(links))
    }

    // MARK: The worktree's .git

    @Test("a worktree's .git must still lead into the clone, however git wrote it")
    func worktreeLink() async throws {
        guard let scene = try await GitReviewIntegrationTests.Scene.make() else { return }
        defer { scene.delete() }
        let manager = FileManager.default
        let clone = scene.clone.root
        let file = scene.worktree.appending(path: ".git")
        #expect(GitService.isWorktree(scene.worktree, of: clone))
        #expect(!GitService.isWorktree(scene.worktree, of: scene.origin), "another repository's")

        // Relative, as `worktree.useRelativePaths` writes it.
        let written = try String(contentsOf: file, encoding: .utf8)
        let admin = written.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "/").last ?? ""
        try Data("gitdir: ../\(clone.lastPathComponent)/.git/worktrees/\(admin)\n".utf8)
            .write(to: file)
        #expect(GitService.isWorktree(scene.worktree, of: clone))

        // Another job's worktree of the same clone: its admin folder is in
        // the clone, but names that worktree back, not this one.
        let other = clone.deletingLastPathComponent()
            .appending(path: clone.lastPathComponent + "-other-worktree")
        defer { try? manager.removeItem(at: other) }
        let addedOther = await scene.git.addWorktree(
            clone: clone, at: other, branch: "fix/other", baseRef: scene.base) { _ in }
        try #require(addedOther)
        #expect(GitService.isWorktree(other, of: clone))
        try Data(contentsOf: other.appending(path: ".git")).write(to: file)
        #expect(!GitService.isWorktree(scene.worktree, of: clone), "another job's admin folder")

        // A repository the agent made, even one shaped like a clone's.
        let fake = scene.worktree.appending(path: ".ccwiki/repo/.git/worktrees/x")
        try manager.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("gitdir: \(fake.path(percentEncoded: false))\n".utf8).write(to: file)
        #expect(!GitService.isWorktree(scene.worktree, of: clone))

        // A link to the file git wrote, and a folder, are not what git writes.
        let elsewhere = scene.worktree.appending(path: ".ccwiki/gitfile")
        try Data(written.utf8).write(to: elsewhere)
        try manager.removeItem(at: file)
        try manager.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        #expect(!GitService.isWorktree(scene.worktree, of: clone))
        try manager.removeItem(at: file)
        try manager.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(!GitService.isWorktree(scene.worktree, of: clone))
    }

    @Test("a worktree's commondir must lead to the clone's own repository, read as git reads it")
    func worktreeCommondir() async throws {
        guard let scene = try await GitReviewIntegrationTests.Scene.make() else { return }
        defer { scene.delete() }
        let manager = FileManager.default
        let clone = scene.clone.root
        let admin = try Self.adminPath(of: scene.worktree)
        let commondir = admin + "/commondir"
        #expect(GitService.isWorktree(scene.worktree, of: clone), "as git wrote it")

        // `../..` from the folder, as git writes it; with the CR git also
        // takes off; and the clone's own repository named outright.
        let own = clone.appending(path: ".git").path(percentEncoded: false)
        for text in ["../..\n", "../..\r\n", own + "\n"] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: commondir))
            #expect(GitService.isWorktree(scene.worktree, of: clone), "\(text.debugDescription)")
        }

        // Another repository on this machine, named outright or from the
        // folder. The .git and the gitdir still lead to and from the clone,
        // and git there reads the other repository's configuration.
        let other = try await Self.otherRepository(
            cloning: scene.clone,
            at: clone.deletingLastPathComponent().appending(path: clone.lastPathComponent + "-other"))
        defer { other.delete() }
        for text in [other.root.appending(path: ".git").path(percentEncoded: false),
                     "../../../../\(other.root.lastPathComponent)/.git"] {
            try Data((text + "\n").utf8).write(to: URL(fileURLWithPath: commondir))
            #expect(!GitService.isWorktree(scene.worktree, of: clone), "\(text)")
            #expect(await Self.setting(in: scene.worktree, git: scene.clone.git) == Self.otherSetting,
                    "git in the worktree reads \(text)")
        }

        // A link, even to a file that says `../..`: git follows it, and an
        // agent could rewrite what it leads to.
        let held = scene.worktree.appending(path: ".ccwiki/commondir")
        try manager.createDirectory(
            at: held.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: held)
        try manager.removeItem(atPath: commondir)
        try manager.createSymbolicLink(
            atPath: commondir, withDestinationPath: held.path(percentEncoded: false))
        #expect(!GitService.isWorktree(scene.worktree, of: clone), "a link")

        // No commondir at all: git takes the folder itself for the
        // repository, with a configuration of its own.
        try manager.removeItem(atPath: commondir)
        let objects = admin + "/objects", refs = admin + "/refs", config = admin + "/config"
        for folder in [objects, refs] {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try Data("[review]\n\tsentinel = \(Self.otherSetting)\n".utf8)
            .write(to: URL(fileURLWithPath: config))
        #expect(await Self.setting(in: scene.worktree, git: scene.clone.git) == Self.otherSetting)
        #expect(!GitService.isWorktree(scene.worktree, of: clone), "none")
        for item in [objects, refs, config] { try manager.removeItem(atPath: item) }
        try Data("../..\n".utf8).write(to: URL(fileURLWithPath: commondir))
        #expect(GitService.isWorktree(scene.worktree, of: clone))

        // The gitdir is a file too, not a link to one.
        let gitdir = admin + "/gitdir"
        let back = try Data(contentsOf: URL(fileURLWithPath: gitdir))
        let copy = scene.worktree.appending(path: ".ccwiki/gitdir")
        try back.write(to: copy)
        try manager.removeItem(atPath: gitdir)
        try manager.createSymbolicLink(
            atPath: gitdir, withDestinationPath: copy.path(percentEncoded: false))
        #expect(!GitService.isWorktree(scene.worktree, of: clone), "a link for gitdir")
        try manager.removeItem(atPath: gitdir)
        try back.write(to: URL(fileURLWithPath: gitdir))
        #expect(GitService.isWorktree(scene.worktree, of: clone))

        // To git, a space at the end of the .git's line is part of the path:
        // the folder of that name is the one whose commondir counts.
        let file = scene.worktree.appending(path: ".git")
        let written = try Data(contentsOf: file)
        let spaced = admin + " "
        try manager.copyItem(atPath: admin, toPath: spaced)
        defer { try? manager.removeItem(atPath: spaced) }
        try Data((other.root.appending(path: ".git").path(percentEncoded: false) + "\n").utf8)
            .write(to: URL(fileURLWithPath: spaced + "/commondir"))
        try Data("gitdir: \(spaced)\n".utf8).write(to: file)
        #expect(await Self.setting(in: scene.worktree, git: scene.clone.git) == Self.otherSetting)
        #expect(!GitService.isWorktree(scene.worktree, of: clone), "the folder with the space")
        try written.write(to: file)
        #expect(GitService.isWorktree(scene.worktree, of: clone))
    }

    @Test("a worktree git moved, or one moved by hand and repaired, still leads to the clone")
    func worktreeMovedAndRepaired() async throws {
        guard let scene = try await GitReviewIntegrationTests.Scene.make() else { return }
        defer { scene.delete() }
        let manager = FileManager.default
        let clone = scene.clone.root
        let parent = clone.deletingLastPathComponent()
        let moved = parent.appending(path: clone.lastPathComponent + "-moved")
        let root = parent.appending(path: clone.lastPathComponent + "-root")
        defer {
            try? manager.removeItem(at: moved)
            try? manager.removeItem(at: root)
        }

        try #require(await scene.git.moveWorktree(clone: clone, from: scene.worktree, to: moved))
        #expect(GitService.isWorktree(moved, of: clone), "git worktree move")

        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let byHand = root.appending(path: "worktree")
        try manager.moveItem(at: moved, to: byHand)
        #expect(!GitService.isWorktree(byHand, of: clone), "its gitdir still names where it was")
        await scene.git.repairWorktrees(clone: clone, worktreeRoot: root)
        #expect(GitService.isWorktree(byHand, of: clone), "git worktree repair")

        // Neither touched commondir.
        let admin = try Self.adminPath(of: byHand)
        let commondir = try String(contentsOfFile: admin + "/commondir", encoding: .utf8)
        #expect(commondir.trimmingCharacters(in: .newlines) == "../..")
    }

    @Test("no review is taken through a .git pointed at another repository")
    func redirectedWorktree() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        let snapshotter = ReviewSnapshotter(git: scene.git)
        let before = await snapshotter.review(of: job, clone: scene.paths.clone, privatePaths: [])
        #expect(before?.snapshot.isEmpty == false)
        let reviewed = try #require(before?.snapshot)

        // A copy of the clone, with the base in it, in the agent's own folder.
        let fake = job.worktree.appending(path: ".ccwiki/repo")
        try FileManager.default.createDirectory(
            at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copied = await scene.clone.run([
            "clone", "-q", "--no-checkout", scene.clone.root.path(percentEncoded: false),
            fake.path(percentEncoded: false),
        ])
        try #require(copied.succeeded, "git clone: \(copied.output)")
        let gitdir = fake.appending(path: ".git").path(percentEncoded: false)
        try Data("gitdir: \(gitdir)\n".utf8).write(to: job.worktree.appending(path: ".git"))

        #expect(!GitService.isWorktree(job.worktree, of: scene.paths.clone))
        let after = await snapshotter.review(of: job, clone: scene.paths.clone, privatePaths: [])
        #expect(after?.snapshot == nil)
        // Said as the reason, not as git failing.
        await scene.center.refreshReview(job)
        #expect(job.log.last?.text == GitService.redirectedWorktree)
        #expect(await PublisherTests.publisher(scene).check(job, reviewed: reviewed)
            == .failed(GitService.redirectedWorktree + " Nothing was sent."))
    }

    @Test("no snapshot, staging or publishing git runs where commondir leads to another repository")
    func redirectedCommondir() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        await scene.center.refreshReview(job)
        try #require(job.review?.isEmpty == false)

        // The worktree's .git and its folder's gitdir stay as git wrote them.
        // Only commondir names another repository, whose configuration git
        // there now reads.
        let other = try await Self.otherRepository(
            cloning: scene.clone, at: scene.root.appending(path: "other"))
        let admin = try Self.adminPath(of: job.worktree)
        try Data((other.root.appending(path: ".git").path(percentEncoded: false) + "\n").utf8)
            .write(to: URL(fileURLWithPath: admin + "/commondir"))
        #expect(await Self.setting(in: job.worktree, git: scene.clone.git) == Self.otherSetting)
        #expect(!GitService.isWorktree(job.worktree, of: scene.paths.clone))

        // A change since, which any git add there would write into one
        // repository or the other.
        try scene.write("content/page.md", "a\nB\nC", in: job)
        let blob = try await Self.blob(
            of: job.worktree.appending(path: "content/page.md"), in: scene.clone)

        await scene.center.refreshReview(job)
        #expect(job.log.last?.text == GitService.redirectedWorktree)
        let result = await scene.center.approve(job)
        #expect(result == .failed(GitService.redirectedWorktree + " Nothing was sent."), "\(result)")
        #expect(job.state == .awaitingReview)
        #expect(await scene.originTip(job.branch) == .absent, "nothing was pushed")
        for repository in [scene.clone, other] {
            let staged = await repository.run(["cat-file", "-e", blob]).succeeded
            #expect(!staged, "git add ran: \(repository.root.lastPathComponent) has the new page")
        }
    }

    // MARK: Another repository

    /// What a worktree's `.git` names: the folder in `<clone>/.git/worktrees/`
    /// git keeps its index, HEAD, gitdir and commondir in.
    static func adminPath(of worktree: URL) throws -> String {
        let text = try String(contentsOf: worktree.appending(path: ".git"), encoding: .utf8)
        let named = String(text.trimmingCharacters(in: .newlines).dropFirst("gitdir: ".count))
        return named.hasPrefix("/")
            ? named : worktree.appending(path: named).path(percentEncoded: false)
    }

    /// A local clone of `source` at `place`, with a setting of its own in
    /// its configuration: another repository on this machine.
    static func otherRepository(cloning source: FixtureRepository, at place: URL) async throws
        -> FixtureRepository {
        let cloned = await source.run([
            "clone", "-q", "--no-checkout", source.root.path(percentEncoded: false),
            place.path(percentEncoded: false),
        ])
        try #require(cloned.succeeded, "git clone: \(cloned.output)")
        let other = FixtureRepository(root: place, git: source.git)
        let configured = await other.run(["config", "review.sentinel", otherSetting])
        try #require(configured.succeeded, "git config: \(configured.output)")
        return other
    }

    static let otherSetting = "other-repository"

    /// `review.sentinel` as git run in `worktree` reads it: `otherSetting`
    /// once the worktree leads to the other repository. Run only to show
    /// the test's redirection is real; CCwiki runs no git there.
    static func setting(in worktree: URL, git: String) async -> String? {
        let result = await Subprocess.run(
            executable: git,
            arguments: [
                "-C", worktree.path(percentEncoded: false), "config", "--get", "review.sentinel",
            ],
            environment: FixtureRepository.environment())
        return result.succeeded ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// The blob git would make of `file`, asked of `repository` and written
    /// nowhere.
    static func blob(of file: URL, in repository: FixtureRepository) async throws -> String {
        let hashed = await repository.run([
            "hash-object", "--no-filters", file.path(percentEncoded: false),
        ])
        let blob = hashed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(hashed.succeeded && !blob.isEmpty, "git hash-object: \(hashed.output)")
        return blob
    }

    // MARK: A warning that appears at Approve

    @Test("a warning that first appears at Approve refuses, and the next Approve has seen it")
    func newWarningAtApprove() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        await scene.center.refreshReview(job)
        let reviewed = try #require(job.review)
        #expect(!job.findings.contains { $0.rule == .changedUpstream })

        // A sync brings a commit that changed the same page; nothing takes
        // the review again.
        try scene.clone.write("content/page.md", "a\nb\nc\nd")
        try #require(await scene.clone.commit("upstream", date: 1_780_000_300) != nil)
        for arguments in [["push", "-q", "origin", "main"], ["fetch", "-q", "origin"]] {
            let result = await scene.clone.run(arguments)
            try #require(result.succeeded, "git \(arguments[0]): \(result.output)")
        }

        let publisher = PublisherTests.publisher(scene)
        let first = await publisher.check(job, reviewed: reviewed)
        let upstream = try #require(job.findings.first(where: { $0.rule == .changedUpstream }),
                                    "the review shows the new warning")
        #expect(upstream.severity == .warning)
        #expect(first == .refused(Publisher.newWarning(upstream)))
        #expect(job.review?.digest == reviewed.digest, "the diff itself did not change")

        // On screen now: the next Open Draft PR asks about it, and the
        // check goes on past it.
        let second = await publisher.check(job, reviewed: reviewed)
        #expect(second != .refused(Publisher.newWarning(upstream)))
        #expect(second != .changedSinceReview)

        // What was on screen at the click counts, not a review taken since.
        #expect(await publisher.check(job, reviewed: reviewed, findings: [])
            == .refused(Publisher.newWarning(upstream)))
    }

    @Test("Approve publishes the review its click saw: a warning a refresh showed since refuses")
    func approveTakesTheClicksReview() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        await scene.center.refreshReview(job)

        // The click, whose question counted these findings.
        let shown = JobCenter.ShownReview(of: job)
        try #require(shown.digest != nil)
        #expect(!shown.findings.contains { $0.rule == .changedUpstream })

        // While the question is up, a sync brings a commit that changed the
        // same page, and a refresh shows the warning on the same diff.
        try scene.clone.write("content/page.md", "a\nb\nc\nd")
        try #require(await scene.clone.commit("upstream", date: 1_780_000_300) != nil)
        for arguments in [["push", "-q", "origin", "main"], ["fetch", "-q", "origin"]] {
            let result = await scene.clone.run(arguments)
            try #require(result.succeeded, "git \(arguments[0]): \(result.output)")
        }
        await scene.center.refreshReview(job)
        let upstream = try #require(job.findings.first(where: { $0.rule == .changedUpstream }),
                                    "the review shows the new warning")
        #expect(job.review?.digest == shown.digest, "the diff itself did not change")

        // Confirming that question approves what it asked about, which
        // lacks the warning, so nothing is sent.
        let result = await scene.center.approve(job, shown: shown)
        #expect(result == .refused(Publisher.newWarning(upstream)), "\(result)")
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(tone: .warning, text: Publisher.newWarning(upstream)))
        #expect(await scene.originTip(job.branch) == .absent, "nothing was pushed")
    }
}
