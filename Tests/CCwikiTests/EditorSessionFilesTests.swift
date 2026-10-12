import Foundation
import Testing
@testable import CCwiki

/// Where an editor writes (plans/corrections.md §4.4, §7.5): into the job's
/// worktree while it is one, and never into a worktree that is gone, which
/// a write would otherwise make again as a plain folder git does not know.
struct EditorSessionFilesTests {

    @Test("a folder is a worktree only with its .git; a folder without one is not")
    func isWorktree() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "worktrees/job")
        #expect(!EditorSession.isWorktree(worktree))

        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        #expect(!EditorSession.isWorktree(worktree))

        // A linked worktree's .git is a file pointing into the clone.
        try Data("gitdir: /tmp/clone/.git/worktrees/job\n".utf8)
            .write(to: worktree.appending(path: ".git"))
        #expect(EditorSession.isWorktree(worktree))
    }

    @Test("a save into a worktree that is gone makes nothing, and says why")
    func refusesAWorktreeThatIsGone() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "worktrees/job")
        let file = worktree.appending(path: "content/Primitives/pseudorandom-function.md")

        let failure = await EditorSession.writeFile("text", to: file, in: worktree)
        #expect(failure == EditorSession.worktreeGone)
        #expect(!FileManager.default.fileExists(atPath: worktree.path(percentEncoded: false)))
    }

    @Test("a save into a worktree makes the folders it needs below the root")
    func writesBelowTheRoot() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "worktrees/job")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/clone/.git/worktrees/job\n".utf8)
            .write(to: worktree.appending(path: ".git"))

        // A file the job adds, in a folder that does not exist yet; and an
        // unsaved version kept in .ccwiki, which no snapshot stages.
        for path in ["content/References/A - B.md", ".ccwiki/pseudorandom-function.md.unsaved"] {
            let file = worktree.appending(path: path)
            let failure = await EditorSession.writeFile("Some $\\calA$ text.\n", to: file, in: worktree)
            #expect(failure == nil)
            #expect(try String(contentsOf: file, encoding: .utf8) == "Some $\\calA$ text.\n")
        }
    }

    // MARK: Helpers

    static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
