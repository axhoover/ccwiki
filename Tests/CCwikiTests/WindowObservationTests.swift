import Foundation
import Observation
import Testing
@testable import CCwiki

/// What the explorer, editor and Jobs windows tell their views, and what
/// they work out again (plans/efficiency.md §2.9).
@MainActor
struct WindowObservationTests {

    // MARK: The editor's save state

    /// A keystroke after the first of a burst leaves the editor saving.
    /// Its readers, the editor's chrome and Jobs' Open Draft PR gate, are
    /// told nothing until the save lands.
    @Test("a keystroke that keeps the editor saving does not notify saveState's readers")
    func keystrokeKeepsSaving() async throws {
        let paths = try JobRecordTests.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.support) }
        let id = "editor"
        try JobRecordTests.write(
            JobRecordTests.record(id, kind: .edit(JobRecordTests.target), state: .awaitingReview),
            in: paths)
        // A worktree is a folder with a `.git` (`EditorSession.isWorktree`).
        // The file is not Markdown, so the editor makes no preview web view.
        let worktree = paths.worktree(forJob: id)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /nonexistent\n".utf8).write(to: worktree.appending(path: ".git"))
        try Data("Some text.\n".utf8).write(to: worktree.appending(path: "notes.txt"))

        // A model that has not looked for git yet, so loading reads the
        // worktree alone. The save the keystrokes schedule finds no session
        // when it wakes: the model lets it go at the end.
        let model = AppModel(paths: paths)
        let target = EditorTarget(jobID: id, path: "notes.txt")
        let session = model.editorSession(for: target)
        await session.load()
        try #require(session.isLoaded)
        #expect(session.saveState == .saved)

        session.text += "a"
        session.textDidChange()
        #expect(session.saveState == .saving)

        let notified = WindowObservationFlag()
        withObservationTracking {
            _ = session.saveState
        } onChange: {
            notified.mark()
        }
        session.text += "b"
        session.textDidChange()
        #expect(session.saveState == .saving)
        #expect(!notified.value, "an unchanged save state was assigned again")

        // Typed back to the text on disk: a change, and it is told.
        let changed = WindowObservationFlag()
        withObservationTracking {
            _ = session.saveState
        } onChange: {
            changed.mark()
        }
        session.text = "Some text.\n"
        session.textDidChange()
        #expect(session.saveState == .saved)
        #expect(changed.value)

        model.closeEditorSession(target)
    }

    /// Whether this toolchain's `@Observable` tells observers about an
    /// assignment of an equal value. Printed, not asserted: where it does,
    /// the test above fails without the guard in `EditorSession`; where it
    /// does not, that guard is insurance for toolchains that do.
    @Test("an equal assignment to an @Observable property: notified or not, printed")
    func equalAssignment() {
        let probe = SaveStateProbe()
        let notified = WindowObservationFlag()
        withObservationTracking {
            _ = probe.state
        } onChange: {
            notified.mark()
        }
        probe.state = .saving
        let notifies = notified.value
        let behaviour = notifies ? "notifies" : "does not notify"
        let guardIs = notifies
            ? "removed work: its test fails without it"
            : "insurance: its test passes without it"
        print("window observation: @Observable \(behaviour) observers of an equal assignment "
            + "on this toolchain; the editor's save-state guard is \(guardIs)")
    }
}

/// One property, of the editor's own type, to ask the toolchain with.
@MainActor
@Observable
final class SaveStateProbe {
    var state: EditorSession.SaveState = .saving
}

/// Set from `withObservationTracking`'s `onChange`, which is `@Sendable`.
///
/// `@unchecked Sendable` with a lock, as `ProgressLog` is: `onChange` runs
/// on whichever thread made the change.
private final class WindowObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        storage = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
