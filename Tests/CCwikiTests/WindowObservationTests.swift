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

    // MARK: The editor preview's overlay

    /// The preview as `AppModel.previewRequest(path:text:in:)` built it at
    /// 21df5d7, on every pause in typing, with the model's state passed in:
    /// what a kept overlay must render the same as.
    private static func legacyRequest(
        _ page: WikiPage, index: WikiIndex, review: ReviewSnapshot?
    ) -> RenderRequest {
        let added = review.map(ReviewPayload.addedPages(in:)) ?? []
        var renderer = PageRenderer(index: index.overlaying(added), hiddenPaths: [])
        renderer.relations = .empty
        renderer.relationLabels = .empty
        renderer.buildsPreviews = false
        let rendered = renderer.request(for: page)
        return RenderRequest(
            path: rendered.path, title: rendered.title, markdown: rendered.markdown,
            html: nil,
            links: ReviewPayload.markingNew(
                rendered.links, newPages: ReviewPayload.newPagePaths(added, in: index)),
            anchor: nil, notices: rendered.notices)
    }

    /// Everything a preview request carries, as `==` can compare it:
    /// `RenderRequest` is not `Equatable`, and its JSON has no fixed key
    /// order.
    private static func facts(_ request: RenderRequest) -> [String] {
        let links = request.links.sorted { $0.key < $1.key }.map {
            "link \($0.key) → \($0.value.href) \($0.value.kind) "
                + "\($0.value.external) \($0.value.isImage)"
        }
        let notices = request.notices.map { "notice \($0.level): \($0.text)" }
        return [request.path, request.title, request.markdown] + links + notices
    }

    private static func facts(_ overlay: PreviewOverlay, _ page: WikiPage) -> [String] {
        facts(overlay.request(for: page, hiddenPaths: [], relations: .empty, labels: .empty))
    }

    /// PRF as the ingestion leaves it: citing the reference page the same
    /// change adds.
    private static func editedPRF() throws -> WikiPage {
        let file = try #require(ReviewPayloadTests.ingestion().files.first)
        let text = try #require(file.newText)
        return WikiPage(path: "Primitives/pseudorandom-function.md", text: text)
    }

    @Test("the preview's overlay is kept while the library and the added pages are the same")
    func overlayKept() throws {
        let index = ReviewPayloadTests.readerIndex()
        let review = ReviewPayloadTests.ingestion()
        let kept = PreviewOverlay(index: index, generation: 1, review: review)
        #expect(kept.index.pages.count == index.pages.count + 1)

        // Handed another index under the same generation, it gives the kept
        // overlay back, nothing assembled: the generation stands for the
        // index, and AppModel bumps it with every library it puts up.
        let other = WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"), files: [], pages: [:])
        let reused = PreviewOverlay.reusing(kept, index: other, generation: 1, review: review)
        #expect(reused.index.pages.count == kept.index.pages.count)
        #expect(reused.newPages == kept.newPages)

        // A pause in typing renders through it what the old path rendered.
        let page = try Self.editedPRF()
        #expect(Self.facts(reused, page)
            == Self.facts(Self.legacyRequest(page, index: index, review: review)))
        let citation = reused.request(for: page, hiddenPaths: [], relations: .empty, labels: .empty)
            .links[ReviewPayloadTests.ggmLink]
        #expect(citation?.kind == "new")
    }

    /// What happens after every pause in typing: the editor saves, and a
    /// second later the review is taken again, with a new tree and the
    /// edited page's new text.
    @Test("a review taken again after a save of the edited page keeps the preview's overlay")
    func overlayKeptAcrossSaves() throws {
        let index = ReviewPayloadTests.readerIndex()
        let review = ReviewPayloadTests.ingestion()
        let kept = PreviewOverlay(index: index, generation: 1, review: review)

        // PRF saved with a line more; the reference page as it was. Handed
        // an empty index, the kept overlay comes back, nothing assembled.
        let prf = try #require(review.files.first)
        let reference = try #require(review.files.last)
        let saved = try #require(prf.newText)
        let typed = saved + "\nMore.\n"
        let retaken = ReviewSnapshot(
            baseCommit: review.baseCommit, tree: "9f1c2e7",
            files: [ReviewPayloadTests.file(old: prf.oldText, new: typed, hunks: prf.hunks), reference],
            digest: "4567")
        #expect(retaken != review)
        let other = WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"), files: [], pages: [:])
        let reused = PreviewOverlay.reusing(kept, index: other, generation: 1, review: retaken)
        #expect(reused.index.pages.count == index.pages.count + 1)
        #expect(reused.newPages == kept.newPages)

        // The text as typed renders through it as the old path rendered it
        // against the review taken again.
        let page = WikiPage(path: "Primitives/pseudorandom-function.md", text: typed)
        #expect(Self.facts(reused, page)
            == Self.facts(Self.legacyRequest(page, index: index, review: retaken)))
    }

    @Test("other added pages, or a new library, build the preview's overlay again")
    func overlayRebuilt() throws {
        let index = ReviewPayloadTests.readerIndex()
        let review = ReviewPayloadTests.ingestion()
        let page = try Self.editedPRF()
        let kept = PreviewOverlay(index: index, generation: 1, review: review)
        let before = Self.facts(kept, page)

        // The review taken again no longer adds the reference page: the
        // citation has no target, as the old path says.
        let edited = ReviewPayloadTests.snapshot(try #require(review.files.first))
        let refreshed = PreviewOverlay.reusing(kept, index: index, generation: 1, review: edited)
        #expect(refreshed.newPages.isEmpty)
        #expect(Self.facts(refreshed, page) != before)
        #expect(Self.facts(refreshed, page)
            == Self.facts(Self.legacyRequest(page, index: index, review: edited)))

        // The reference page saved again: the overlay reads it anew.
        let reference = try #require(review.files.last)
        let revised = ReviewPayloadTests.file(
            ReviewPayloadTests.ggmPath, status: .added, old: nil,
            new: FixtureClone.page(
                type: "reference", title: "GGM86",
                body: "# How to construct random functions\n\nThe tree construction, revised.\n"),
            hunks: reference.hunks)
        let rewritten = ReviewPayloadTests.snapshot(try #require(review.files.first), revised)
        let reread = PreviewOverlay.reusing(kept, index: index, generation: 1, review: rewritten)
        let ggm = try #require(ReviewPayload.contentPath(ReviewPayloadTests.ggmPath))
        #expect(reread.index.pages[ggm]?.body.contains("revised") == true)
        #expect(Self.facts(reread, page)
            == Self.facts(Self.legacyRequest(page, index: index, review: rewritten)))

        // A sync brought the page into the library: a page now, not new.
        let synced = index.overlaying(ReviewPayload.addedPages(in: review))
        let loaded = PreviewOverlay.reusing(kept, index: synced, generation: 2, review: review)
        #expect(loaded.newPages.isEmpty)
        #expect(Self.facts(loaded, page) != before)
        #expect(Self.facts(loaded, page)
            == Self.facts(Self.legacyRequest(page, index: synced, review: review)))
        let citation = loaded.request(for: page, hiddenPaths: [], relations: .empty, labels: .empty)
            .links[ReviewPayloadTests.ggmLink]
        #expect(citation?.kind == "page")

        // The job gone: the reader's index alone.
        let alone = PreviewOverlay.reusing(kept, index: index, generation: 1, review: nil)
        #expect(alone.index.pages.count == index.pages.count)
        #expect(Self.facts(alone, page)
            == Self.facts(Self.legacyRequest(page, index: index, review: nil)))
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
