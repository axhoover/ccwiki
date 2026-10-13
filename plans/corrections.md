# Corrections, and a review step before anything reaches GitHub

**Spec, 2026-10-11; revised 2026-10-12 after three critics (Review notes,
§16); built on `claude/page-corrections`, 2026-10-12. §6.2 is DiffGuard as
built.**

This covers two requests in [roadmap.md](roadmap.md): §1, a human step
between the agent and GitHub, and §3, correcting a page from the reader. It
builds on [ingestion.md](ingestion.md), §4 in particular (`DiffGuard`), and on
the Jobs code as it stands (`Sources/CCwiki/Jobs/*`). It also reads the
wiki's own contract files: `CLAUDE.md`, `CONTRIBUTING.md`, `schema/README.md`,
`.github/prompts/paper-submission.md`, `scripts/lint.mjs`,
`.fact-check/queue.json`, `.orchestrator/` and `.review/`. Nothing was
compiled, because this machine has no Swift. Every claim about the wiki was
checked against a clone at `ab81f02`.

> `CLAUDE.md` asks for the **swiftui-pro**, **typography-designer** and
> **macos-design** skills before and after deciding on code. None is
> installed in this session, the same gap [design-system.md](design-system.md)
> records. So this spec follows `SWIFTUI-RULES.md`, which it cites by
> section, and design-system §1 for type. Each track runs whichever of the
> three skills is installed by then, before and after it writes code.

---

## 0. What the maintainer decided (2026-10-11)

1. **Three routes.** Each starts from a page or a selected passage, and each
   carries the page, the section, the source line range and the quoted text.
   - **a. Edit it yourself.** The page's Markdown opens in an editor, with a
     live preview rendered by the reader's own pipeline. Submit opens a
     correction PR to `axhoover/cryptology.city`.
   - **b. Describe it, and an agent edits.** A small, cheap agent job drafts
     the minimal edit. It has its own short prompt, and a smaller model
     where the `claude` CLI allows choosing one.
   - **c. Open an issue.** A GitHub issue, prefilled with the page, the
     section and the quoted passage. No branch, no diff.

   "Check this page", a read-only pass that hunts for errors, is **not** in
   this version.
2. **A review step for every job, paper ingestion included.** Nothing is
   pushed or opened on GitHub until the maintainer approves. The review shows:
   - the diff, rendered the way the reader renders pages;
   - the lines `DiffGuard` flagged;
   - the PR title and body, which can be edited.

   The maintainer can edit the changed files before approving. **Approve**
   commits, pushes and runs `gh pr create`. **Discard** prunes the worktree.

## 1. The answers, in one table

| Question | Answer | § |
|---|---|---|
| How does a selection map back to source lines? | markdown-it's own `token.map` is stamped on every rendered block as `data-source-lines`. A selection takes the lines of the blocks it starts and ends in. Swift maps those lines to the file, past the frontmatter and around the relation-meta line the renderer splices in, with a pure, tested `SourceLineMap`. A right-click with nothing selected names the page, not a word | §3 |
| What is the job model? | `IngestJob` becomes `Job`, with a `JobKind`: `ingestion`, `correction` (route b) or `edit` (route a). An issue is not a job. `JobState` gains `awaitingReview`, `publishing(step)` and `discarded`. Only queued and running work can be cancelled; a quit never cancels a review. Records written before this change still load | §4 |
| What survives a relaunch? | The job record, now with the base commit, the PR title and body, and what was pushed or being pushed. The worktree. A patch of the last reviewed diff in Application Support. The transcript, never truncated. Editor windows, through SwiftUI's restoration, because history loads before any window | §4.3 |
| Where does the UI live? | The **editor** is a window of its own, one per file, like a document. The **review** is in the **Jobs window**: every route, and ingestion, ends there. **Describe** and **Open an Issue** are sheets on the reader window | §6.6, §7, §8 |
| How does route a reuse the review? | An edit is a job from its first second: a worktree at the reader's commit, in `awaitingReview`. The editor writes into that worktree. Review, Approve and Discard are the same code as for an agent job | §7 |
| How are issues created and previewed? | `gh issue create --repo … --title … --body-file …`. The sheet is the preview: one Body editor holding the exact text sent, with the footer CCwiki adds shown beneath it. A GitHub permalink to the lines at the reader's commit shows as a code snippet | §8.2 |
| What does DiffGuard check? | Nineteen rules, in three severities. **Blocking**, for what the wiki forbids outright: any path outside `content/` (an allow-list), a rename or deletion, a binary, a hand-edited generated region, relation fields on an object page, math in a wikilink, a local path or a token. Approve stays disabled. **Warnings** need a confirmation. **Notes** inform. A pure function, tested rule by rule | §6.2 |
| What may the correction agent touch? | One page, named in the prompt. Tools: `Read`, `Edit`, `Write`, `Glob`, `Grep`; no `Bash` at all. Every agent job runs **sealed**: no `gh` credentials and no push credentials in its environment. That stops a confused agent, not a determined one: ingestion keeps `node`. A tripwire after each run looks for any push or PR CCwiki did not make | §5 |
| How are duplicate PRs and lost edits prevented? | Duplicates: a state machine, a lease on every push recorded before it is sent, a recovery path when the lease is refused, and a check for an open PR on the branch before creating one. Lost edits: the editors are flushed before Approve and before quit, a patch backup outside Caches, one git queue per job, and a digest that makes Approve commit only the diff that was reviewed | §4.4 |
| What does CCwiki Dev do? | It targets the **same repository** and **says so**: in the review and the issue sheet before anything is sent, and in a footer on every PR and issue body. `CCWIKI_TARGET_REPO=owner/name` points a Dev build at a fork for testing; the release ignores it | §10 |
| Which model? | `claude --model sonnet` by default for corrections, set in Settings → Jobs. Ingestion keeps the CLI's default | §5.4 |

## 2. The flow, end to end

```
 reader: a page, or a passage selected on it
   │
   ├─ Edit Page… (⌥⌘E) ───────────► worktree at the reader's commit ──► editor window
   │                                                                     (writes into the worktree)
   ├─ Describe a Correction… ──► sheet ──► worktree ──► claude (sealed, one page)
   │                                                         │
   │   Ingest a Paper… (⇧⌘N) ──────────► worktree ──► claude (sealed) ┤
   │                                                         ▼
   │                         Jobs window · Awaiting review
   │                         rendered diff · DiffGuard · PR title and body
   │                         Edit… (opens the editor) · Discard… · Open Draft PR
   │                                                         │
   │                                     commit, push, gh pr create --draft
   │
   └─ Open an Issue About This Page… ──► sheet (the exact text) ──► gh issue create
```

Three surfaces, each with one job. The **editor** is where files change. The
**Jobs window** is where work waits, and the only place it leaves for GitHub.
The **sheets** are short forms about the page you are reading.

---

## 3. From a selection to source lines

### 3.1 What the reader renders

`PageRenderer.request(for:)` sends the web view `page.body`: the file text
from `Frontmatter.bodyStart`, which is the start of the line after the closing
`---`. On a reduction or barrier page it first splices in the site's
relation-meta line, using `RelationMeta.insertUnderH1`. That splice inserts
whole lines, either `["", line, ""]` under the H1 or `[line, ""]` at the top,
and changes no other line. So the rendered Markdown differs from the file in
exactly two ways:

- a fixed number of lines is missing at the top, the frontmatter;
- a run of two or three lines is added after the H1.

### 3.2 Stamping blocks

**The Markdown half of `ccwiki.js` moves into its own file.** Track C moves
`createMarkdown`, `createPreviewMarkdown` and their helpers (`mathInline`,
`mathBlock`, `wikilink`, `headingIds`, `callouts`, `katexOptionsFor`,
`displayText`, …) unchanged into **`Resources/web/ccwiki-markdown.js`**. It
touches no DOM, wraps itself as `(function (global) {…})(typeof window !==
"undefined" ? window : this)`, and defines `global.CCwikiMarkdown = { create,
createPreview, reviewEntries }`. `index.html` loads it after
`github-slugger.umd.js` and before `ccwiki.js`, which keeps everything that
touches the document. The point is the tests: JavaScriptCore can load this
file without a web view (§12.1, `SourceStampTests`).

markdown-it 15 (vendored) gives every block token a `map`: `[firstLine,
endLine)`, 0-based, in the source string it was handed. A core rule,
`ccwiki_source_lines`, pushed after `ccwiki_callouts`, stamps it onto the
HTML:

- Every token with `map`, `block`, and `nesting !== -1` (an opening tag or a
  self-contained block) gets `data-source-lines="a-b"` through `attrSet`.
- `math_block` and the custom `table_open` renderer build their own markup,
  so each writes the attribute itself: on `div.math-display`, and on
  `div.table-scroll`.
- **`mathBlock`'s own map is fixed.** Today it sets `map = [startLine,
  nextLine]`, which leaves out the closing `$$` line. It becomes
  `blockToken.map = [startLine, state.line]`, set after `state.line`, so the
  range, the excerpt and the editor's selection all end on the `$$`.
- **Pseudocode is the exception.** `pseudocode.renderElement` copies the
  `<pre>`'s `dataset` into its own options (`renderPseudocode` already says
  so). So the fence renderer writes the range as a **non-`data-`** attribute,
  `ccwiki-lines="a-b"`. `renderPseudocode` moves it onto the
  `.pseudocode-container` box as `data-source-lines` before rendering.
- An `html_block`, such as the generated-region markers, carries its map like
  any other block. Raw HTML inside one cannot be stamped, and is the one
  thing a selection can land in without a range (§3.6).

Most paragraphs in this wiki are a single source line (`Primitives/` alone
has 231 lines longer than 200 characters), so block precision is usually
line precision. The places where it is not are wrapped list items and
pseudocode. In both, the quoted text narrows it for a human.

### 3.3 Reading the selection

```js
CCwiki.selectionSource()   // → a JSON string, or the string "null"
```

The function works on the live selection:

1. It returns `"null"` unless the selection is non-empty and inside `#page`.
2. It takes the nearest stamped ancestor of the range's start, and of its end.
   If only one end has one (a selection that starts in a notice), it uses
   that one.
3. The line range is the union of the two:
   `{start: min(a.start, b.start), end: max(a.end, b.end)}`.
4. The text is the selection as the reader shows it, with each formula
   written as `$…$` or `$$…$$`. This is the same widening and `texify` the
   ⌘C handler does, factored out into a shared `selectionText(range)`, so
   copying and quoting cannot drift apart.
5. The heading is the last `h1`–`h6` with an `id` that precedes the start
   block in document order: `{id, text, level}`.
6. It also returns `path`, and the `revision` that came with the render
   payload (§3.5).

**A right-click must not invent a selection.** On a secondary click, macOS
WebKit selects the word under the pointer *before* it dispatches
`contextmenu`. That is what makes Look Up “word” appear. Read at
`contextmenu`, nearly every right-click would report a one-word "passage". So:

- A capture-phase `mousedown` listener, for `event.button === 2 ||
  event.ctrlKey`, records the selection as it was: the `selectionSource()`
  object if the selection is non-collapsed **and** the pointer lies inside one
  of its `getClientRects()`, otherwise `null`. That runs before WebKit's
  contextual selection. It is a listener of its own: it returns at once for
  any other button, and calls no `preventDefault`. reader-comforts adds
  separate `mousedown` and `mouseup` listeners for the middle button.
- The existing `contextmenu` listener adds `selection` to the
  `contextTarget` message it already posts ahead of the menu. It is the
  recorded object when there was one. Otherwise it is the block under the
  pointer, `event.target.closest('[data-source-lines]')`, with its lines and
  heading and **`text: null`**. reader-comforts adds `link` to the same
  message, so its keys end up `type, tex, algorithm, algorithmExpanded,
  link, selection`.
- A `selection` with `text: null` is a pointer, not a passage. The menu says
  "Page" (§9), and the target is the whole page with that block's section,
  so the editor opens at the paragraph you right-clicked.

This rule cannot be tested off a Mac; §13 lists it.

Three more functions serve the editor's preview and the review:

```js
CCwiki.revealSourceLines(start, end, mark)  // scroll the first block overlapping [start,end) to centre;
                                            // with mark, outline the blocks briefly (.source-reveal, 1.2 s)
CCwiki.renderReview(payload)                // §6.3
CCwiki.scrollToReviewEntry(id)              // §6.3
```

### 3.4 `SourceLineMap` (pure Swift)

```swift
struct SourceLineMap: Sendable, Equatable {
    /// File lines before the body: the frontmatter and both of its fences.
    let bodyOffset: Int
    /// Rendered lines the renderer added (the relation-meta splice). Empty when none.
    let inserted: Range<Int>

    init(fileText: String, renderedMarkdown: String)

    enum Location: Sendable, Equatable {
        case body(LineRange)          // 1-based, in the file
        case frontmatter(LineRange)   // the selection was the generated relation-meta line
    }
    /// A 0-based, half-open rendered range → where it lives in the file.
    func location(ofRendered range: Range<Int>) -> Location?
    /// A 1-based file line → the rendered line, for the preview to follow the cursor.
    /// nil inside the frontmatter.
    func renderedLine(forFileLine line: Int) -> Int?
}
```

`bodyOffset` counts the newlines before `Frontmatter.parse(fileText).bodyStart`.
`inserted` comes from aligning the body's lines with the rendered lines: the
first index where they differ, and a length of `rendered.count -
body.count`. When the inserted run sits beside blank lines, the alignment can
start a line early or late. That cannot move any non-blank line, because the
only lines that could trade places are identical. A test pins this. A rendered
line `r` outside the run maps to file line `bodyOffset + r - (r >= inserted.upperBound ?
inserted.count : 0) + 1`. A range that falls entirely inside the run maps to
`.frontmatter(2...bodyOffset - 1)`: the line is generated from the fields
there. A range that only partly overlaps the run drops the overlap.

### 3.5 `CorrectionTarget`

```swift
struct CorrectionTarget: Codable, Sendable, Hashable {
    struct Section: Codable, Sendable, Hashable { let id: String; let title: String; let level: Int }
    enum Region: String, Codable, Sendable { case body, frontmatter, generated }

    let pagePath: String        // relative to content/
    let pageTitle: String
    let baseCommit: String      // the commit the reader rendered: the selection's revision, else lastRenderedRevision
    var section: Section?
    var lines: LineRange?       // nil: the whole page
    var region: Region
    var quote: String?          // as the reader showed it, formulas as $…$, at most quoteLimit
    var excerpt: String?        // the file's `lines`, verbatim

    var repositoryPath: String { "content/" + pagePath }
    var summary: String         // "Lines 42–44, in “Security”", "The whole page"
    static let quoteLimit = 2_000

    /// Pure; tested. `readingHeading` is the heading at the top of the viewport,
    /// used when there is no selection and no pointer.
    static func make(page: WikiPage, fileText: String, renderedMarkdown: String,
                     baseCommit: String, selection: ReaderSelection?,
                     readingHeading: Section?) -> CorrectionTarget
}
```

- **The inputs are the ones that were shown.** `fileText` is `git show
  <revision>:content/<path>` (through `GitService.blob`, §11.6), where
  `<revision>` is the selection's, else the `WebController`'s
  `lastRenderedRevision`; or the file on disk for a snapshot store. Reading
  the disk at click time could pair a file a sync has just rewritten with
  the old revision. `renderedMarkdown` is the `RenderRequest.markdown` the
  reader last sent, which `WebController` keeps as `lastRenderedMarkdown`,
  with that request's `revision` as `lastRenderedRevision`. Rebuilding it
  could differ from what was drawn.
- **The base commit is the commit the reader rendered**, not `origin/main`
  and not necessarily the clone's HEAD. The line numbers were read from that
  commit's file, so the worktree starts there. A correction's PR still
  targets `main`, and GitHub merges from the common ancestor;
  `changedUpstream` (§6.2) warns when the page has changed since.
- **The revision travels with the render.** `RenderRequest` gains `var
  revision: String?`, which is `headRevision` at render time and goes into
  the payload. `ccwiki.js` returns it with the selection. A sync can land
  between the render and the click. Once reader-comforts is in, a sync of a
  clone also leaves alone every tab whose page it did not touch
  (reader-comforts §3.6), so a tab's shown revision is often older than HEAD;
  a snapshot store's page tabs render again at the new marker. Neither is
  an error: the target is built entirely at the shown revision, never
  compared with HEAD. Only when that revision's file cannot be read, in a
  snapshot store whose marker has moved since the render (a selection made
  just before the sync), does the target fall back to the whole page at
  HEAD, with the section, and the sheet or editor says "The page changed
  since it was shown; the selection was not carried over."
- **`region = .generated`** when the lines fall between
  `<!-- BEGIN GENERATED participates-in` and `<!-- END GENERATED
  participates-in -->`. Those lines are derived from reduction pages (111
  object pages carry such a region). **`region = .frontmatter`** for the
  relation-meta line. Route b refuses both (§8.1); routes a and c say what
  the passage is.
- **A pointer, or no selection.** The target is the whole page. Its section
  is the pointer's heading, or else the heading the reader is on
  (`webController.activeHeadingID`), so the editor opens there.

```swift
/// What `ccwiki.js` reports. Decoding is pure and tested.
struct ReaderSelection: Sendable, Equatable {
    let renderedLines: Range<Int>   // 0-based, half-open, in the RenderRequest's markdown
    let text: String?               // nil: a right-click with nothing selected (a pointer)
    let heading: CorrectionTarget.Section?
    let path: String
    let revision: String?
    var isPassage: Bool { text != nil }
    init?(json: String)                    // CCwiki.selectionSource(); nil for "null" or malformed
    init?(message: [String: Any])          // contextTarget's "selection"; NSNull reads as absent
}

/// 1-based, inclusive.
struct LineRange: Codable, Sendable, Hashable {
    let first: Int
    let last: Int
    var count: Int { last - first + 1 }
    var label: String                      // "line 42", "lines 42–44"
    func overlaps(_ other: LineRange) -> Bool
}
```

### 3.6 What is not mapped

- **Folder pages and the app's own documents** (Welcome, What's New) have
  no source file. The correction commands are disabled on them.
- **A selection that touches no stamped block**: raw HTML, or a notice
  alone. It falls back to the whole page.
- **A snapshot store**, a copy fetched as a tarball because `git` was
  missing (`SnapshotService`). Routes a and b need a worktree, so they are
  refused with "This copy of the wiki is a snapshot. Sync (⌘R) to replace it
  with a git clone." (a sync with git does exactly that). Route c still
  works, using the commit in the snapshot's marker for the permalink.

---

## 4. The job model

### 4.1 Kinds and states

```swift
enum JobKind: Codable, Sendable, Equatable {
    case ingestion(IngestSubmission)
    case correction(CorrectionRequest)   // route b: described, drafted by an agent
    case edit(CorrectionTarget)          // route a: edited by hand

    enum Tag: String, Codable, Sendable { case ingestion, correction, edit }
    enum Family: Sendable { case ingestion, correction }   // DiffGuard's thresholds; edit is .correction
    var tag: Tag
    var family: Family
    var target: CorrectionTarget?        // nil for ingestion
    var slug: String                     // "eprint-2025-375", "pseudorandom-function"
    var branchPrefix: String             // "ingest/", "fix/"
    var symbolName: String               // doc.badge.plus, text.bubble, square.and.pencil
    var noun: String                     // "ingestion", "correction", "edit": dialog text
}

struct CorrectionRequest: Codable, Sendable, Equatable {
    let target: CorrectionTarget
    let description: String              // what the reader says is wrong
    let model: String                    // the --model alias used; "" for the CLI's default
}
```

An issue is **not** a job. Its sheet is its review and its result (§8.2),
so it needs no row, no record and no restoration.

```
                 ┌──────────── ingestion, correction ─────────────┐
 queued → preparing(step) → running ──► awaitingReview ◄── edit starts here
                │               │            │    ▲  │
                │               │            │    │  └──► discarded       (Discard…)
                │               │            ▼    │ changed since review, refused, failed,
                │               │      publishing(step)  or interrupted by a quit:
                │               │            │           nothing is lost, back to review
                ▼               ▼            ▼
        failed · cancelled · aborted      opened(url)
          (worktree kept; Review Anyway when it holds changes)
```

```swift
enum JobState: Equatable, Sendable, Codable {
    case queued
    case preparing(String)
    case running
    case awaitingReview
    case publishing(String)
    case opened(url: URL)
    case aborted(reason: String)
    case failed(String)
    case cancelled
    case discarded

    var isTerminal: Bool     // opened, aborted, failed, cancelled, discarded
    var isActive: Bool       // preparing, running, publishing: a process is running
    var isCancellable: Bool  // queued, preparing, running
    var label: String        // "Awaiting review", "Discarded"; the rest as today
    var symbolName: String   // awaitingReview: "rectangle.and.text.magnifyingglass"; discarded: "trash"
}
```

The case names and labels that exist today stay exactly as they are. Old
records were written with synthesized `Codable`, which keys on them.

- **Cancelling acts only on work that has not reached review.**
  `Job.cancel()` does nothing unless `isCancellable`. Discard is the only way
  out of review. Cancel and Cancel Job appear only for queued, preparing and
  running jobs.
- **`publishing` is interrupted, never cancelled.**
  `Job.interruptPublishing()` cancels the task, which stops the push or `gh`
  call, and returns the job to `awaitingReview` with the log line "Publishing
  was interrupted. Opening the pull request again checks GitHub first, so it
  cannot be opened twice."
- **`awaitingReview` is not active.** No process runs, so quitting does not
  ask about it, and it survives a relaunch.
- **One term.** The label is "Awaiting review". An `edit` job awaiting
  review whose snapshot is empty is labelled "Editing", sits under Jobs rather
  than Awaiting Review, and is not counted in `reviewCount`. "Ready for
  review" is GitHub's word for a PR that is no longer a draft, and the app
  already uses it that way.

### 4.2 `Job` and `JobRecord`

`Jobs/IngestJob.swift` becomes `Jobs/Job.swift`. The surface the other
tracks compile against:

```swift
@Observable @MainActor
final class Job: Identifiable {
    let id: String                       // "<yyyyMMdd-HHmmss-SSS>-<kind>-<slug>"; ingestion keeps "<stamp>-<slug>"
    let kind: JobKind
    let createdAt: Date
    let worktree: URL
    let scratch: URL                     // <caches>/scratch/<id>/: the agent's GH_CONFIG_DIR; removed with the worktree
    let logFile: URL
    let recordFile: URL
    let patchFile: URL                   // logs/<id>.patch: the last reviewed diff (§4.4)
    private(set) var branch: String
    private(set) var state: JobState
    private(set) var log: [JobLogEntry]
    private(set) var outcome: ClaudeOutcome?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var preflight: [PreflightFinding]
    private(set) var baseCommit: String?
    private(set) var review: ReviewSnapshot?
    private(set) var findings: [DiffFinding]
    private(set) var pushingCommit: String?  // persisted before each push is sent
    private(set) var pushedCommit: String?   // persisted once the push is confirmed
    private(set) var notice: JobNotice?      // the last publish result, or the tripwire (§5.5)
    private(set) var needsRestore: Bool      // restored without its worktree; Restore applies patchFile
    /// Edited in the review. Persisted at most once a second, and before Approve.
    var pullRequest: PullRequestDraft
    @ObservationIgnored var task: Task<Void, Never>?

    init(kind: JobKind, paths: AppPaths, createdAt: Date = Date())
    init(restoring record: JobRecord, paths: AppPaths, worktreeExists: Bool, patchExists: Bool)

    var record: JobRecord
    var title: String                    // the paper, or the page title
    var detail: String                   // "Lines 42–44, in “Security”", or the source URL
    var statusLabel: String              // state.label, adjusted per kind (§4.1)
    var canEdit: Bool                    // state == .awaitingReview && !needsRestore
    var canRunAgain: Bool                // ingestion or correction, ended failed, cancelled or aborted
    var submission: IngestSubmission?    // for the code that already reads it

    // Runners and JobCenter only:
    func setBranch(_ branch: String)
    func setState(_ state: JobState)
    func setPreflight(_ findings: [PreflightFinding])
    func setOutcome(_ outcome: ClaudeOutcome)
    func setBaseCommit(_ sha: String)
    func setReview(_ snapshot: ReviewSnapshot, findings: [DiffFinding])
    func setPushingCommit(_ sha: String?)
    func setPushedCommit(_ sha: String?)
    func setNotice(_ notice: JobNotice?)
    func setNeedsRestore(_ flag: Bool)
    func append(_ entry: JobLogEntry)    // also written to logFile, as a system line
    func append(_ entries: [JobLogEntry])
    func appendRaw(_ line: String)
    /// A restored job: logFile through ClaudeStreamParser, off the main actor,
    /// to rebuild `log` and `outcome`. Once, when the job is first shown.
    func replayTranscript() async
    func cancel()                        // only when state.isCancellable
    func interruptPublishing()           // publishing → awaitingReview (§4.1)
}

struct JobNotice: Codable, Sendable, Equatable {
    enum Tone: String, Codable, Sendable { case warning, failure }   // orange, red
    let tone: Tone
    let text: String
}

struct JobRecord: Codable, Sendable {
    let id: String
    let kind: JobKind
    let branch: String
    let state: JobState
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let baseCommit: String?
    let pullRequest: PullRequestDraft?
    let pushingCommit: String?
    let pushedCommit: String?
    let notice: JobNotice?
}
extension JobRecord {
    /// In an extension, so the memberwise init `Job.record` uses survives.
    /// A record written before 0.3 has `submission` and no `kind`: it decodes
    /// as .ingestion(submission), with createdAt = submission.submittedAt.
    private enum LegacyKeys: String, CodingKey { case submission }
    init(from decoder: Decoder) throws
}
```

- **`LogWriter` appends.** Today it calls `createFile(atPath:contents:nil)`,
  which truncates, and writes from offset 0. The first `appendRaw` after a
  relaunch, a Review Anyway or a publish would wipe the agent's transcript.
  It now creates the file only if it is missing, then `seekToEnd()`.
- `TranscriptBuffer` moves with the class and takes a `Job`. The slug
  cleaning that `IngestSubmission.slug` does moves into
  `BranchName.slug(_:)` in `Job.swift`, and every kind uses it.
  `SubmissionSourceTests` guard that the behaviour is unchanged.

### 4.3 What survives a relaunch

**History loads before any window.** `JobCenter.init` reads the records
synchronously: a few small JSON files, no tools needed. `AppModel` is the
app's `@State`, made before SwiftUI restores a window, so a restored editor
finds its job. `RootView`'s `.task` no longer calls `loadJobHistory()`; once
reader-comforts is in, that call is step 2 of `AppModel.launchIfNeeded()`,
and the integrator deletes it there (§17).

| At quit | At the next launch |
|---|---|
| `queued`, `preparing`, `running` | A normal quit has cancelled them (`cancelled`). After a crash: `failed("Interrupted — CCwiki quit while this job was running.")`, as today. Review Anyway is offered if the worktree holds changes |
| `awaitingReview`, worktree present | `awaitingReview`. The transcript is replayed when the job is first shown. The snapshot is recomputed then, and for every review still without one once git is found (`JobCenter.refreshMissingReviews`): a window macOS restores asks before the tools are known |
| `awaitingReview`, worktree gone, patch present | `awaitingReview` with `needsRestore`. The review shows "The worktree is gone. CCwiki kept your changes." with a Restore button (§4.4) |
| `awaitingReview`, both gone | `failed("The worktree and the saved changes are both gone.")` |
| `publishing` | A normal quit has already returned it to `awaitingReview` (§4.1). After a crash, the same, with the same log line |
| any terminal state | as it was |

- **Editor windows** come back through `WindowGroup(for: EditorTarget.self)`
  restoration. A window whose job is gone, or not `canEdit` and not
  publishing, closes itself (SWIFTUI-RULES §6.5).
- **The PR title and body** are in the record; **text typed into an
  editor** is in the worktree (§7.5).
- `refreshOrphanedWorktrees` treats as known every job that owns its
  worktree (`JobCenter.ownsWorktree`): every non-terminal job, as it already
  did, and every failed, aborted or cancelled one that Review Anyway may still
  take to review, a job a quit cancelled included. Because a quit no longer
  cancels a review, a worktree awaiting review is never offered for pruning
  under Left Behind, and neither is one Review Anyway offers. It becomes a
  stray only once Clear Finished drops its job, which looks for strays again.
  Review Anyway looks again too, and `pruneOrphan` refuses a path whose last
  component is a job that owns it, whatever a list drawn earlier shows.
- **Reset Clone** (Settings → Storage) is refused while any job is not
  terminal: "Publish or discard the 2 jobs in Jobs first." Their worktrees
  live in the clone's `.git`.

### 4.4 Duplicates and lost edits

| Risk | Guard |
|---|---|
| Open Draft PR pressed twice | `approve` acts only from `awaitingReview`. The button is disabled while `publishing` |
| A crash, a quit or a lost reply between the push and the PR | `pushingCommit` is persisted before the push. `publishing` comes back as review. A refused lease asks GitHub where the branch is and recovers (§6.5 step 3). Before creating a PR, publishing looks for an **open PR whose head is the job's branch** (`gh pr list --head`); if one exists, it updates it (`gh pr edit`) instead of opening another |
| Pushing again after edits | `--force-with-lease=refs/heads/<branch>:<pushedCommit>`. The first push leases on absence (`…:`), so it cannot overwrite a branch someone else made |
| The branch name already on GitHub, unfetched | The lease refuses; `git ls-remote` shows a tip CCwiki never made; the job takes the next free name and says so (§6.5 step 3) |
| Two corrections of one page | Edit Page… on a page whose `edit` job can still be edited opens that job's editor, at the new lines, with no alert. Any other job on the page asks first (§7.1). DiffGuard's `changedUpstream` catches the rest at Approve |
| The agent pushing or opening a PR itself | The seal makes it unlikely, not impossible (§5.1). The tripwire looks afterwards (§5.5) |
| An issue sent twice | Open Issue is disabled while `gh` runs. A retry first searches for the sheet's hidden marker (§8.2) |
| Text lost when an editor or the app closes | Autosave, 0.5 s after typing stops and on close. `approve`, `revert`, `refreshReview` and `restoreWorktree` first await `JobCenter.flushEdits`, which saves every open editor of the job. A quit with unsaved text returns `.terminateLater` until `flushAllEditors()` finishes. An editor writes only while its job is `awaitingReview`. An editor whose text did not reach the disk (a conflict nobody settled, or a failed write) disables Open Draft PR, and `approve` asks `unsettledEdits` again after its own flush and refuses: publishing would send the file without that text and close the editor |
| Two git commands in one worktree at once | One serial queue per job (§6.1). Two `git add -A` runs would collide on `index.lock` |
| CCwiki changing a file under an open editor (Revert File, Restore) | `JobCenter.onFilesChanged` reloads the editor: silently if nothing is unsaved, otherwise with the choice "CCwiki reverted this file in Jobs." Use Reverted File, or Keep My Version |
| The worktree deleted (Caches cleared by hand; the maintainer has done this before, update-integrity.md) | Every snapshot also writes `git diff --cached --binary <base>`, byte for byte, to `logs/<id>.patch` in Application Support. Restore runs `git worktree prune`, `git worktree add -B <branch> <path> <base>`, then `git apply --index`. An empty patch applies as nothing; a missing one is said to be missing, and git is not asked |
| Approving a diff that changed after it was shown | The snapshot carries a SHA-256 of the staged patch. Approve snapshots again and compares the two. If they differ, it shows the new diff and sends nothing |
| The file edited outside CCwiki while the editor is open | Before each save, the editor compares the file on disk with what it last wrote. If they differ, it asks: Keep My Version, or Use the File on Disk |
| Discard by mistake | A confirmation dialog. The patch file stays in `logs/` until Clear Finished, and the transcript stays as it does today |

---

## 5. Agent jobs stop before GitHub

### 5.1 The seal

Today the ingestion agent pushes and opens the PR itself, with `Bash(git:*)`
and `Bash(gh:*)` allowed. Under the new rule, a prompt that says "do not
push" is not enough. PROBLEMS.md makes the point twice: a warning is not a
fix. So every agent run, ingestion and correction, gets four layers:

1. **The allow-list leaves out `gh` and every git command that writes.** The
   ingestion agent no longer commits, so its `Bash(git:*)` becomes the
   subcommands it reads with: `Bash(git status:*)`, `Bash(git diff:*)`,
   `Bash(git log:*)`, `Bash(git show:*)`, `Bash(git ls-files:*)`,
   `Bash(git grep:*)`, `Bash(git rev-parse:*)` and `Bash(git submodule
   update:*)`. Corrections get no `Bash` at all (§5.4).
2. **A deny-list, which wins over any allow:**
   `--disallowedTools "Bash(git push:*),Bash(git commit:*),Bash(git remote:*),Bash(git config:*),Bash(gh:*)"`.
3. **The environment**, built by `AgentInvocation.sealed`:
   - `GH_CONFIG_DIR` → an empty directory under the job's scratch,
     `<caches>/scratch/<id>/gh`, outside the worktree, so `gh` sees no
     logged-in host and nothing it writes can be staged;
   - `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` and `SSH_AUTH_SOCK`
     are removed;
   - `GIT_CONFIG_COUNT=3`, with:
     - `remote.origin.pushurl=ccwiki-review-first://blocked`;
     - `credential.helper=` (empty), which clears the helper list;
     - `credential.https://github.com.helper=` (empty), which clears the
       clone's `gh auth git-credential`;
   - `GIT_SSH_COMMAND`, `GIT_ASKPASS` and `SSH_ASKPASS` → `/usr/bin/false`;
   - `GIT_TERMINAL_PROMPT=0`, which is already set.

   Requires git ≥ 2.31 (Apple's is 2.39). Fetching public submodules over
   HTTPS still works, and the runner does that before the agent starts
   anyway.
4. **Nothing of the user's own Claude configuration.** `claude -p` would
   otherwise load the allow rules and hooks in `~/.claude/settings.json`,
   and every MCP server the user has added, and `--allowedTools` only adds
   to those rules. A user allow rule such as `Bash(git:*)`, or a GitHub MCP
   server whose tools are pre-approved and which carries its own token,
   would reach past the other three layers: the deny-list covers only
   `Bash(...)`, and the environment does not reach a server's token. So both
   agents run with `--strict-mcp-config` and no `--mcp-config`, which loads
   no MCP server, and `--setting-sources project`, which loads only the
   settings checked into the wiki itself, if it has any: rules reviewed in
   its own repository. Both flags are to be confirmed on the first live job
   (§13).

**What the seal is, and is not.** It stops a confused agent and an accident:
a plain `git push` or `gh pr create` fails, and the integration test proves
that against real git. It does not stop a determined one. `git -c
credential.helper=… push` does not match the deny rule's prefix, and git
reads `-c` after the environment's entries. Ingestion keeps `node`, `npm` and
`npx`, which can run anything with any environment, and `gh` may find a token
in the keychain without its config directory. Ingestion reads untrusted
papers. So the tripwire (§5.5) is the backstop, and the review is the gate:
whatever the agent did, nothing it **left in the worktree** reaches GitHub
without approval. §13 records this.

CCwiki's own commands (the snapshot, the commit, the push, `gh pr create`)
run with `tools.childEnvironment()` as today, unsealed.

### 5.2 The handover file

The agent no longer commits. It leaves its changes in the working tree, and
writes the PR text to **`.ccwiki/pull-request.md`** in the worktree:

- the first line is `# <title>`;
- the rest is the body.

`.ccwiki/` is also where an agent writes any scratch output, such as a lint
log. Every `git add` CCwiki runs excludes it (`':(exclude).ccwiki'`), so
nothing in it can reach a PR. CCwiki reads the handover into
`job.pullRequest`. If the file is missing or has no title, the job proposes a
title and body of its own (§6.4).

### 5.3 Ingestion, changed

- **The base is a commit, not a ref.** Before `git worktree add`, the runner
  resolves `git rev-parse --verify origin/<default>^{commit}`, passes that SHA
  as `baseRef`, and calls `job.setBaseCommit` before the agent starts. Left
  as `origin/main`, a sync during review would move the base: the snapshot
  would show upstream commits reversed, and Approve's `reset --soft` would
  commit their reversal.
- **`prompts/ingest.md` Step 6** becomes "Stop and hand over". The agent does
  not commit, push or open a PR. It writes the PR text, using the body
  template in `.github/prompts/paper-submission.md`, to the handover file,
  then prints `READY FOR REVIEW` as its last line.
- **Scratch output** goes under `.ccwiki/`. The line "Redirect inside the
  worktree" becomes "Redirect into `.ccwiki/`, which CCwiki never commits".
- **The precedence sentence changes.** Today it reads "Where it and this
  prompt disagree, it wins — without exception." The wiki's contract was
  written for a GitHub Action, and its Step 5 says `gh pr create --draft`.
  Left as it is, the agent is told to open the PR by the document it is told
  to obey. The new sentence: **the contract decides what the change is; this
  envelope decides how it leaves the machine.** Committing, branching,
  pushing and opening the PR belong to CCwiki.
- **Pre-flight is unchanged.** `gh` authentication and push rights are
  still checked before the agent starts, and again at Approve. A credential
  needed at the end is checked at the beginning (PROBLEMS.md).
- **`IngestJobRunner`'s ending.**
  - With an `ABORTED:` block, the job is `aborted`, as today.
  - Otherwise CCwiki runs the tripwire (§5.5), reads the handover, takes a
    snapshot, and goes to `awaitingReview`. If the snapshot is empty, the
    job is `failed("The agent finished without changing anything.")`.
  - `confirmedPullRequest` moves to `Publisher`. The tripwire keeps a
    variant of it.
- `make shots PLAN='ingest:<url>'` now waits for `awaitingReview` or a
  terminal state.

### 5.4 The correction agent

```
claude -p "<prompts/correct.md, composed>"
  --output-format stream-json --verbose
  --model sonnet                       # CCwikiSettings.correctionModel; omitted when ""
  --permission-mode acceptEdits
  --allowedTools Read,Edit,Write,Glob,Grep
  --disallowedTools Bash(git push:*),Bash(git commit:*),Bash(git remote:*),Bash(git config:*),Bash(gh:*)
  --max-turns 20                       # CCWIKI_CORRECTION_MAX_TURNS overrides
```

- **No `Bash`, no web, no `npm`, no `node`.** The agent needs no git: CCwiki
  computes the diff itself. And `git diff`, `log` and `show` all accept
  `--output=<file>`, which writes anywhere the user can. A correction that
  needs the cited paper read again is beyond a cheap job. The prompt tells
  the agent to abort and say what a human should check.
- **The base** is `target.baseCommit`, resolved with `rev-parse --verify
  <sha>^{commit}` and recorded before the agent starts, as for ingestion.
- **No submodules, no `npm ci`.** The worktree comes up in a second or two.
- **Allowed files.** The prompt names one page. `acceptEdits` allows `Edit`
  and `Write` on any file in the worktree, so the one-page rule is enforced
  at review: DiffGuard warns on any other page and blocks anything outside
  `content/`. Path-scoped rules (`Edit(./content/<path>)`) would enforce it
  up front; §13 says when.
- **Never on a generated passage.** Route b is refused for a target whose
  region is `generated` or `frontmatter` (§8.1), each with its own text. A
  "Participates in" section is rebuilt from the reduction pages; the
  relation line under a reduction or barrier page's title is drawn from that
  page's own frontmatter. Fixing either means changing frontmatter and
  regenerating `relations.json`, and this agent cannot run the generator.

`prompts/correct.md` follows `ingest.md`'s rule: **house style is not
compiled in.** It points the agent at the worktree's own `CLAUDE.md`
("Writing Style", "Content Conventions", "Citations"), at `macros.ts` before
it touches math, and at `schema/README.md` on a reduction or barrier page.
In full, as `prompts/correct.md` has it, less its title and the comment
that explains the placeholders:

`````markdown
You are correcting one page of the cryptology.city wiki, in a git worktree
that belongs to you alone: `{{WORKTREE}}`.

Page: `{{PAGE_PATH}}`{{#PAGE_URL}} ({{PAGE_URL}}){{/PAGE_URL}}, {{LINES}}{{SECTION}}.

{{#QUOTE}}
The reader quoted, as rendered:

> {{QUOTE}}

{{/QUOTE}}
{{#EXCERPT}}
The source of those lines:

{{FENCE}}
{{EXCERPT}}
{{FENCE}}

{{/EXCERPT}}
What the reader says is wrong:

> {{REQUEST}}

1. Read `CLAUDE.md` § Writing Style, § Content Conventions and § Citations,
   and `macros.ts` if you will touch math. They are the rules; this prompt
   restates none of them. On a page under `content/Reductions/` or
   `content/Barriers/`, read `schema/README.md` too.
2. Read the page. Decide whether the reader is right. If the page is right,
   or the fix needs a source you cannot check from the repository, abort.
3. Make the smallest edit that does what was asked, in `{{PAGE_PATH}}` only.
   Never edit between `<!-- BEGIN GENERATED participates-in` and
   `<!-- END GENERATED participates-in -->`. Never rename a file. Never add
   relation fields to an object page.
4. Do not commit, push, or open anything. CCwiki shows your edit to a
   maintainer, who approves it. Write nothing except the page and the file
   in step 5.
5. Write `.ccwiki/pull-request.md`: the first line
   `# [fix] {{PAGE_TITLE}}: <what changed>`, then two or three sentences
   saying what you changed and why. No recap, no adjectives, and no local
   paths: it is published as written.

To abort, change nothing and print a block that starts `ABORTED:` with the
reason and what a human would need to check. An abort is a good outcome.
`````

The placeholders are filled by `PromptComposer.composeCorrection`. As with
ingestion, everything up to the end of the leading HTML comment, the title
included, is cut before anything is filled in. `{{#NAME}}…{{/NAME}}` keeps
what it wraps only when NAME has a value: a whole-page target has no quote
and no excerpt, so the prompt shows neither, and `{{LINES}}` reads "the
whole page". `{{PAGE_URL}}` is the page on cryptology.city with the section
as its anchor. `{{FENCE}}` is a run of backticks one longer than the longest
run inside the excerpt, and never shorter than three, so a pseudocode fence
in the excerpt cannot close it early. The quote and the request continue the
template's `> ` on every line after the first. Filling is one pass, so a
value holding `{{`, as LaTeX does, arrives as it was.

### 5.5 Outcomes, and the tripwire

| Agent result | State | Worktree |
|---|---|---|
| Changes, no abort | `awaitingReview` | kept |
| `ABORTED:` | `aborted(reason)`, orange, as today | kept |
| No changes, no abort | `failed("The agent finished without changing anything.")` | pruned |
| Error, or out of turns | `failed`, with Review Anyway if the worktree holds changes | kept |
| Cancelled | `cancelled` | kept |
| The tripwire finds a PR | `opened(url)`, with an orange notice | kept, for inspection |

**The tripwire.** Before the agent starts, the runner records `git ls-remote
--heads <PublishTarget.pushURL>`. After it exits, unless cancelled, it checks
two things:

1. **Branches.** `git ls-remote --heads` again. A head that is new or moved,
   and is not the branch of another CCwiki job, was pushed while the agent
   ran. The job's own branch gives the notice "The agent pushed fix/… itself,
   bypassing review." Any other gives "<branch> was pushed to GitHub while
   the agent ran, and CCwiki did not push it." The job still goes to review.
2. **Pull requests.** `gh pr list --repo R --author @me --state open --json
   url,createdAt,headRefName`, keeping PRs created at or after `startedAt −
   60 s` whose head is not another CCwiki job's branch. A hit makes the job
   `opened(url)`, with the orange notice "The agent opened this pull request
   itself, bypassing review." if its head is the job's branch, or "A pull
   request was opened while the agent ran, and CCwiki did not open it." if
   not.

If GitHub cannot be reached, the log says the tripwire did not run. The
contract's own branch name, `paper-submission/<KEY>-<slug>`, is covered by
check 1, which watches every head.

---

## 6. Review

### 6.1 The snapshot

`ReviewSnapshotter.snapshot(worktree:base:patchFile:)` runs in the worktree:

```
git add -A -- . ':(exclude).ccwiki'
git diff --cached -M --name-status -z <base>     → GitNameStatus.parse
git diff --cached --numstat -z <base>            → binary paths ("-\t-\t")
git diff --cached --binary <base>                → the digest (SHA-256), and logs/<id>.patch
git show <base>:<old path>                       → each changed file's old text
git show :<path>                                 → each changed file's new text, from the index
```

- **Bytes, not lines.** `Subprocess.run` goes through `LineSplitter`, which
  splits on `\r` as well as `\n`, decodes lossily and drops the final
  newline. Every `git show`, `-z` and `--binary` call therefore uses
  `Subprocess.runData` (§11.6), and texts are decoded only after. Otherwise
  every file would gain a spurious end-of-file hunk, and the patch backup
  would not apply.
- **The new text comes from the index**, so the snapshot shows exactly what
  was staged and digested, not what was on disk a moment later.
- `-z` is not optional: reference filenames carry spaces, `&` and non-ASCII
  titles, which git otherwise quotes.
- If the agent committed despite the deny-list, `git diff --cached <base>`
  still shows everything since the base, and Approve collapses it (§6.5).
- **The base is required.** Snapshot, Revert File, Restore and Approve
  refuse when `baseCommit` is nil.

**One queue per job.** `JobCenter` runs all git work for a job through one
serial chain, a stored `Task` per job id. A refresh asked for while one runs
coalesces into a single follow-up. Approve, Revert File, Restore and Discard
wait for whatever is in flight. `ReviewSnapshot.assemble` and `LineDiff` run
in `Task.detached`, because `relations.json` is 11,432 lines; only the result
is assigned on the main actor.

The snapshot is taken only for a job in `awaitingReview`, or as it enters
it:

- when an agent finishes, and at Review Anyway;
- when a job is first shown;
- 1 s after the editor saves, with saves coalesced;
- after Revert File and Restore;
- at Approve.

### 6.2 DiffGuard

`DiffGuard.check(_:context:)` is pure. It takes the snapshot and a
`Context`:

- the job's kind, from which the family follows;
- the pages `human_verified` in `.fact-check/queue.json` at the base
  (`FactCheckQueue`);
- the paths changed on `origin/<default>` since the base;
- the correction's target;
- the local paths that must not appear in text (`PrivateText`).

It returns findings sorted blocking first, then by path and line, and keeps
one per rule, path and line. Rules about lines look only at the lines the
change added, so a page that already broke a rule at the base does not block
a fix elsewhere on it. The rules that read a page's text (the region rules,
`relationFieldOnObjectPage`, `wikilinkMath`, `proseRelationBullet`,
`statusComplete` and `rawHTML`) read only `.md` files under `content/`.

**Rules that copy the wiki's lint** name its rule id, and their messages end
with it, as "(lint: `wikilink-math`)". There are three: `generated-region` and
`generated-region-edited`, `object-relation-field`, and `wikilink-math`. They
are copied because routes a and b never run the lint: there is no `node` in
those worktrees. Each test cites the `lint.mjs` lines it follows. The lint's
`edge-unresolved-id` is not copied (§14).

**Blocking.** Open Draft PR stays disabled, and each finding on a path
offers Revert File.

| Rule | Kind | Fires when | Message |
|---|---|---|---|
| `outsideContent` | all | any path, or a rename's old path, other than a `.md` file under `content/` (excluding `content/Templates/`, in any case) or `.reductions/relations.json`. This is an **allow-list**: `scripts/`, `CLAUDE.md`, `.claude/`, `tsconfig.tsbuildinfo` and a stray `lint.log` at the root are all caught | "CCwiki opens pull requests that change `content/` only. Revert `scripts/lint.mjs`, or make this change outside CCwiki." |
| `renamedOrDeleted` | all | a rename to or from a path under `content/`, a deletion under `content/`, or the deletion of `.reductions/relations.json` | Rename: "Filenames under `content/` are live URLs. Revert the rename." Deletion: "Filenames under `content/` are live URLs. Restore the file." `relations.json`: "`relations.json` is generated, and the site reads it. Restore the file." |
| `binaryFile` | all | a binary file, or any `.pdf`, that the change adds, changes or renames. This includes a page or `relations.json` that git calls binary, or whose text could not be read as UTF-8 (`ReviewSnapshot.assemble` treats a side it could not read as binary) | "PDFs and other binary files never enter the wiki." For a page or `relations.json`: "CCwiki could not read this file as UTF-8 text, so it checked nothing in it. Revert it, or save it as UTF-8." |
| `generatedRegionEdited` | all | on a page, the BEGIN and END marker counts differ, unless the base had the same counts; or a region the change added or altered fails its checksum, `sha256(trimmed contents)[0..<12]`; or a region is gone, markers and all, while `relations.json` was not regenerated in the same diff | Edited: "The “Participates in” section on lines 153–171 was edited by hand. It is rebuilt from the reduction pages; correct those instead. (lint: `generated-region-edited`)" Unbalanced markers: "The “Participates in” markers are unbalanced (2 BEGIN, 1 END). They are written by the script; restore them, and correct the reduction pages instead. (lint: `generated-region`)" A removed region: "The “Participates in” section was removed by hand. It is rebuilt from the reduction pages; restore it, and correct those instead." |
| `relationFieldOnObjectPage` | all | an object page gains `implies`, `implied-by`, `implied_by`, `reductions`, `barriers`, `separations`, `from`, `to`, `between`, `hypotheses` or `conclusion` in its frontmatter (lint.mjs `FORBIDDEN_ON_OBJECTS`), one finding per key. An object page has `type:` `primitive`, `assumption`, `complexity-class`, `glossary`, `folklore` or `note`; without a `type:`, it is any page not directly under `References/`, `Reductions/` or `Barriers/` | "Relation fields such as `implies` are not allowed on object pages. A relation is a page in `content/Reductions/`. (lint: `object-relation-field`)" |
| `wikilinkMath` | all | an added line, outside generated regions, backtick code fences and inline code, with an unescaped `$` inside `[[…]]` | "Math in a wikilink breaks the link on the site. Write `[text $x$](slug)` instead. (lint: `wikilink-math`)" |
| `privateText` | all | an added line of any text file matched by `PrivateText` (§6.4) | "This line contains a local path or a token: `/Users/…/Library/…`." A path is shown whole, a token by its first eight characters and "…". |

**Warnings.** These need a human's judgement. Open Draft PR asks first
(§6.6).

| Rule | Kind | Fires when | Message |
|---|---|---|---|
| `newObjectPage` | all | a new `.md` file under `Primitives/`, `Assumptions/`, `Complexity/`, `Glossary/` or `Folklore/` | "This creates an object page. The wiki asks for a human decision on new objects." |
| `otherPages` | correction, edit | a changed `.md` file under `content/` other than the target, by its new or old path | "This also changes `X.md`, which is not the page you started from." |
| `largeEdit` | correction, edit | more than 20 changed lines in all, in Markdown files (`relations.json` does not count), counting hand lines only: not blank, and outside generated regions, except a region removed by hand. A hunk counts the larger of its removed and added sides. The finding is on the file that changed most | "This changes 46 lines. A correction is usually a line or two." |
| `ingestionScope` | ingestion | more than one new page outside `References/`, `Reductions/` and `Barriers/`; or hand changes to more than one existing page; or more than 5 hand-changed lines on one (ingestion.md §4). Lines are counted as for `largeEdit`. Page counts up to nine are spelled out | New pages: "This adds two pages outside `References/`, `Reductions/` and `Barriers/`. An ingestion normally adds a reference and its reductions." Existing pages: "This changes three existing pages. An ingestion normally adds pages and touches at most one." Lines on one page: "This changes 7 lines of `x.md` by hand. An ingestion normally changes at most five lines of an existing page." |
| `proseRelationBullet` | all | an added list item with two or more wikilinks, outside code fences and generated regions, in a section headed `Other results`, `Known relationships` or `Known results`, at any level and in any case, or in a subsection of one | "This adds a relationship as a prose bullet. Relationships are reduction pages." |
| `derivedFilesStale` | all | without a regenerated `.reductions/relations.json` (changed, not deleted), the diff changes a reduction or barrier page's frontmatter; an object page's `id`, `title`, `aliases`, `variants`, `unlisted` or `type`; or a heading a `variants` anchor names, reworded, gained or lost. One finding per page | "The “Participates in” sections and `relations.json` are now out of date, and the wiki's checks fail until they are regenerated. In this job's worktree (Open in Terminal), run `npm ci` and `node scripts/generate-relations.mjs`, then review again. Or run them on the branch after the pull request is open." |
| `relationsJSONByHand` | correction | `.reductions/relations.json` changed | "`relations.json` changed. The correction agent cannot run the generator, so unless you ran it in this worktree, revert this file." |
| `humanVerified` | all | a changed page whose queue entry at the base is `human_verified`. There are none today: 59 are `bot_flagged`, 30 `unreviewed` | "A human verified this page. The wiki asks that a change to a claim here also marks its queue entry stale; CCwiki does not edit that file." |
| `statusComplete` | all | `status:` becomes `complete` | "`status: complete` is a human judgement, and the lint then requires the full section contract." |
| `changedUpstream` | all | a changed path, or a rename's old path, also changed on `origin/<default>` since the base | "This page changed on main after the job started. The pull request may conflict." For a path that is not a `.md` file: "This file changed on main after the job started. The pull request may conflict." |
| `rawHTML` | all | an added body line with an HTML tag or `<!--`, outside code fences, display math, inline code, `$…$` spans, backslash escapes and the generated markers. An autolink such as `<https://…>` is not a tag. The wiki's 222 `<!--` are all generated markers | "This adds raw HTML, which the Rendered view may hide. Check it in Source." |

**Notes.**

| Rule | Kind | Fires when | Message |
|---|---|---|---|
| `regionRegenerated` | all | a region the change added or altered, whose checksum matches; or a region is gone while `relations.json` changed in the same diff and was not deleted, since the generator drops the region from a page left with no relation | "Regenerated by the script, not edited by hand." A removed region: "Removed by the script, not by hand: `relations.json` was regenerated too." |

So following `derivedFilesStale`'s advice in an edit or ingestion worktree
gives notes, never a block. `derivedFilesStale` is a warning, not an
automatic fix: running the generator needs `npm ci` (it requires
`gray-matter` and `js-yaml`), which costs minutes and the network for what
is usually a one-line fix. §15 records the choice.

### 6.3 Showing the diff

The changes pane has two modes, switched by a segmented control bound to
`model.reviewShowsSource`: **Rendered** (the default) and **Source**. A job
with a `rawHTML` finding opens in Source.

**Rendered** is the page as the reader draws it. It shows changed blocks and
nothing else, in a second `WebController` (`AppModel.reviewWeb`) running the
same shell, the same markdown-it instance and the same macros. **JavaScript
owns the blocks**, as it owns all parsing (the `ccwiki.js` header):

- Swift sends each file's old and new **body** text, the line hunks in body
  coordinates, the frontmatter lines and the flags (`ReviewPayload`, Track D).
- `CCwikiMarkdown.reviewEntries(md, file)` (Track C, DOM-free) parses both
  texts with markdown-it and takes the top-level blocks from `token.map`.
  A run of non-blank lines in none of them (a footnote's definition, which
  markdown-it moves to the end, or a link reference definition, which it
  draws as nothing) is a block too, shown as its source with the note
  "Shown as source", so a change to one is never read as blank lines.
  For each hunk:
  - the old blocks it overlaps become `removed` entries;
  - the new blocks it overlaps become `added` entries;
  - one unchanged block either side becomes `context`;
  - every other run of unchanged blocks becomes one `gap` ("12 unchanged
    blocks");
  - a hunk that overlaps no block on either side (blank lines only) becomes
    one `gap` reading "Only blank lines changed here. See Source."
- **Whitespace-only pairs.** A removed and added pair that is identical once
  whitespace is collapsed gets the note "Whitespace only".
- **Frontmatter** is YAML, not Markdown. It is shown as source lines, with
  one line of context, in a monospaced box at the top of the file.
- **Files that are not Markdown** (`relations.json`) are one line: the path,
  `+n −m`, and "Shown in Source".
- **New and deleted files** are all `added`, or all `removed`.
- **Flags** attach to the entries whose lines they overlap.
- **The endpoints.** The header of a reduction or barrier page lists its
  hypotheses and conclusion as links to their pages, through
  `RelationLabels.destination`. This is the cheap half of roadmap §1's second
  wish; the full half is in §14.
- **Links** are resolved over the old and new texts together, against the
  reader's index **overlaid with the pages the snapshot adds**
  (`WikiIndex.overlaying`). A link to a page the change adds, such as an
  ingestion's new reference page, gets the kind `new`: styled as a link, with
  the tooltip "Added by this change", and not clickable. Without the overlay,
  every ingestion's key citation would show as a red broken link. The
  editor's preview of a new file uses the same overlay.

The payload `CCwiki.renderReview` takes:

```json
{
  "macros": { "\\calA": "\\mathcal{A}" },
  "files": [{
    "id": "f0",
    "path": "content/Primitives/pseudorandom-function.md",
    "title": "Pseudorandom function",
    "status": "modified",
    "summary": "1 line changed",
    "isMarkdown": true,
    "header": "markdown for the endpoints line, or \"\"",
    "frontmatter": [{ "kind": "context", "text": "status: draft" }],
    "old": "body markdown before",
    "new": "body markdown after",
    "bodyLine": { "old": 14, "new": 14 },
    "hunks": [{ "old": [41, 42], "new": [41, 42] }],
    "flags": [{ "lines": [41, 42], "severity": "warning", "text": "Math in a wikilink…" }],
    "links": { "[[raw]]": { "href": "…", "kind": "page", "external": false, "isImage": false } }
  }]
}
```

Hunks and flag lines are 0-based, half-open, in the body; `bodyLine` is the
1-based file line of body line 0, for labels. `renderReview` writes one
`<section class="review-file">` per file into `#page`, and each entry as a
`div.review-entry.<kind>` with the `data-entry-id` that `scrollToReviewEntry`
looks for. Pseudocode is grouped and rendered as on a page. It posts
`rendered` with an empty table of contents. `app.css` gains, in light and
dark (design-system §2):

- `added`: a 3 px green rule on the leading edge, a faint green tint, and
  the label **After** in the leading gutter;
- `removed`: the red equivalent, at 75% opacity, never struck through,
  because struck-through math is unreadable, labelled **Before**;
- the labels are small capitals in the tertiary colour, from CSS `::before`,
  so added and removed differ by more than colour. The entries also carry
  `role="insertion"` and `role="deletion"`, with `aria-label` "Added" and
  "Removed", for VoiceOver;
- `gap`: one line of small capitals in the tertiary colour;
- `.review-flag`: a caption above its entry, with the severity's glyph;
- `a.new`: the link colour, dotted underline, default cursor.

`WebController` keeps the last review JSON in `pendingReviewJSON` and sends it
when the shell posts `ready`, so the first review shown is never blank, and
the owner's `onReady` renders again after a WebContent crash. Link clicks
follow the explorer's rule: with no reader window open (`mainWindowCount ==
0`), the view opens one, then the page.

**Source** is a SwiftUI list (`SourceDiffView`) of each file's hunks, in
`Theme.Fonts.log`:

- old and new line numbers in the gutter;
- `−` and `+` rows tinted red and green at 10% opacity, and marked by the
  sign itself;
- within a changed pair, `WordDiff` emphasises the changed tokens by weight,
  not colour alone, so a one-letter fix is findable;
- a file of more than 400 changed lines (`relations.json`) is collapsed
  behind Show.

### 6.4 The PR title and body

```swift
struct PullRequestDraft: Codable, Sendable, Equatable {
    var title: String
    var body: String
    struct Provenance: Sendable, Equatable {
        let appVersion: String
        let isDevBuild: Bool
        let route: String   // "edited by hand", "drafted by claude (sonnet)", "ingested by claude"
    }
    /// `.ccwiki/pull-request.md`: first line `# <title>`, the rest the body. nil without a title.
    static func parse(handover: String) -> PullRequestDraft?
    /// What CCwiki proposes, merged with the agent's handover when there is one.
    static func make(for kind: JobKind, handover: PullRequestDraft?, siteURL: URL?) -> PullRequestDraft
    /// The line after a rule, then the hidden marker. Shared with issues (§8.2).
    static func footer(_ provenance: Provenance, marker: String) -> String
    /// The body as sent: the edited body, then the footer with "ccwiki-job: <id>".
    func bodyForGitHub(jobID: String, provenance: Provenance) -> String
}

enum PrivateText {
    /// Each local path or token in `text`, as found. Pure.
    /// Paths: the home directory, and the worktree, library and Application Support roots.
    /// Tokens: gh[pousr]_[A-Za-z0-9]{36,} and github_pat_[A-Za-z0-9_]{22,}.
    static func findings(in text: String, privatePaths: [String]) -> [String]
}
```

- **Edit.**
  - Title: `[fix] <page title>: <section title>`.
  - Body: an empty first paragraph for the why. Then `**Page:** [<title>](<site
    URL>#<section>), \`<path>\`, lines 42–44 (“Security”)`.
- **Correction.**
  - Title: the agent's, or the edit's form.
  - Body: the agent's body, then `**Requested in CCwiki:**` and the reader's
    description as a quote, then the page line.
- **Ingestion.** The agent's handover verbatim, which follows
  `paper-submission.md`'s template. Without one: `[paper] <source>`, with the
  source's canonical URL and the submitter's notes. **Never** `localPDF`:
  `IngestSubmission.metadataJSON()` carries the PDF's absolute path, and it
  would put the user's home directory into a public PR.
- **Nothing private leaves.** `PrivateText` runs over the title and body as
  they are typed (a red line under the Body field) and again at Approve, over
  every added line (`privateText`, §6.2), and over an issue's text (§8.2).
  The agent's prompt contains the worktree's path, so its handover can too.

The footer is the same for all three, one line after a rule:

```
---
Opened with CCwiki 0.3.0 (CCwiki Dev, a development build) · edited by hand
<!-- ccwiki-job: 20261011-142210-118-edit-pseudorandom-function -->
```

The commit message is the title, a blank line, and `Opened with CCwiki
<version> (job <id>).`. The commit is authored by the user's own git
identity.

### 6.5 Approve, Discard, Revert File, Review Anyway

**Approve** is `JobCenter.approve(job)`. It awaits `flushEdits(job)`, then the
job's git queue, sets `publishing("Checking…")` (which makes every editor of
the job read-only), clears `notice`, and calls
`Publisher.publish(job, reviewed:provenance:)`. Each step sets
`publishing(step)` and is also written to the job's log file.

1. **"Checking…"**
   - Take a snapshot. If its digest differs from the reviewed one, return
     `.changedSinceReview`.
   - Run DiffGuard. A blocking finding returns `.refused`. So does a
     `PrivateText` hit in the title or body.
   - `git config user.name` / `user.email` in the worktree: if either is
     missing, return `.refused("Set your git name and email first: git config
     --global user.name …")`.
   - `GitHubAccess` (§7.1) must be `.ready`, for `PublishTarget.repository`.
     Offline, it returns `.refused("Offline. Nothing was sent; open the pull
     request when you are connected.")`.
2. **"Committing…"**
   - `git reset --soft <base>`, which collapses anything the agent committed;
   - `git commit --no-verify -m …`. A hook that rewrites files would change
     what was reviewed.
3. **"Pushing fix/pseudorandom-function…"**
   - persist `pushingCommit` = the new commit;
   - `git push <PublishTarget.pushURL> HEAD:refs/heads/<branch>
     --force-with-lease=refs/heads/<branch>:<pushedCommit or empty>`;
   - on success, persist `pushedCommit`.
   - **If the lease is refused**, ask GitHub: `git ls-remote <pushURL>
     refs/heads/<branch>`, then `Publisher.leaseRecovery` decides:
     - the branch is absent: retry, leasing on absence;
     - the tip is `pushingCommit`, `pushedCommit`, or any commit in the local
       branch's reflog (every Approve's commit is there): it is ours. Adopt it
       as `pushedCommit` and retry once;
     - the tip is unknown and this job has never confirmed a push: someone
       else's branch. Take the next name free both locally and on GitHub,
       `git branch -m`, log "fix/x was taken on GitHub; using fix/x-2", and
       retry once;
     - otherwise refuse: "fix/x on GitHub has commits CCwiki did not push.
       CCwiki will not overwrite them; check the branch on GitHub."
4. **"Opening the pull request…"**
   - `gh pr list --repo R --head <branch> --state open --json url,createdAt`.
   - If one exists: `gh pr edit <url> --title … --body-file …`.
   - Otherwise: `gh pr create --repo R --draft --base <default> --head
     <branch> --title … --body-file …`.
   - Confirm with `gh pr list`, using today's
     `pullRequest(createdAfter:in:)` with `job.createdAt − 60 s`.
5. Prune the worktree and the scratch directory. Delete the local branch,
   never the remote one. The job is `opened(url)`.

`CCWIKI_PUBLISH_DRY_RUN=1` stops after step 2, logs the push and `gh`
commands it would have run, and returns
`.refused("Dry run: committed locally, nothing pushed.")`.

```swift
enum ApproveResult: Sendable, Equatable {
    case opened(URL)
    case changedSinceReview   // nothing sent; the review now shows the new diff
    case refused(String)      // nothing sent
    case failed(String)       // a step failed; the message says what was already sent
}
```

**Every outcome other than `opened` returns the job to `awaitingReview`**,
and sets `notice`: `refused` and `changedSinceReview` in orange, `failed` in
red. `changedSinceReview` reads "The files changed since you reviewed them.
Check the new diff, then open the pull request." Publishing never leaves a
job terminal and its work stranded.

**Discard…** first asks GitHub, when the job has pushed or tried to: `gh pr
list --repo R --head <branch> --state open`. Then it confirms, per kind:

- correction: "Discard this correction?" — "Its worktree and changes are
  deleted. The transcript is kept.";
- edit: "Discard this edit?" — "Your changes are deleted.";
- ingestion: "Discard this ingestion?" — "Its worktree and changes are
  deleted. The transcript is kept.";
- if pushed, it adds "The branch fix/… is already on GitHub; CCwiki leaves it
  there.", and if a PR is open, "An open pull request exists: <url>. CCwiki
  leaves it open."

Destructive button: Discard. Then, through the job's queue:
`git worktree remove --force`, the scratch directory removed, `git branch -D
<branch>` (local only), and the record moves to `discarded`. Editor windows
for the job close themselves.

**Revert File…** confirms first ("Revert pseudorandom-function.md to the
version the job started from?"), then returns one file to the base: `git
checkout <base> -- <path>`, or `git rm --cached` and a delete for a new file.
It calls `onFilesChanged`, then takes a snapshot. The editor's toolbar has the
same command under the same name.

**Review Anyway**, on a failed or aborted agent job whose worktree has
changes, takes a snapshot and moves the job to `awaitingReview`. A record
from before 0.3 has no base: it is computed once as `git merge-base HEAD
origin/<default>` and recorded.

### 6.6 The review in the Jobs window

The Jobs window keeps its two columns: the queue on the left, a job on the
right ([design-system.md](design-system.md) §4a).

- **The queue** gains a section **Awaiting Review** above **Jobs**. Each row
  has its kind's glyph. Its subtitle is the page or paper, then the status.
  Its context menu adds Edit…, Discard…, and Reveal Patch in Finder. Cancel
  Job appears only for queued, preparing and running jobs; Run Again only
  where `canRunAgain`.
- **The queue column's toolbar** holds Clear Finished and **Ingest a Paper**
  (renamed from New Job), as Mail puts New Message over its list.
- **The detail column's toolbar**, for a job with a review: a segmented
  **Changes | Transcript** (Changes is selected when a job enters review),
  then **Edit…** (a pull-down when several files changed), **Discard…**,
  and, last, **Open Draft PR** (`.borderedProminent`, no shortcut, §9).
- **The header of a job under review** is the state row and the banner. The
  metadata (branch, page or source) moves into the banner's second line, and
  the pre-flight findings move to the Transcript tab.
- **The banner**, in the accent colour:
  - nothing pushed by CCwiki: "Awaiting your review. CCwiki has pushed
    nothing." It says what CCwiki did, not what is on GitHub: an agent that
    pushed for itself is the tripwire's notice beneath, which the banner
    must not contradict;
  - `pushedCommit` set: "Awaiting your review. The branch fix/… is on GitHub;
    no pull request is open yet.";
  - publishing: the step;
  - no worktree: "The worktree is gone. CCwiki kept your changes." with
    **Restore**;
  - opened by the tripwire: orange, with the tripwire's notice.

  Under it, the job's `notice`, orange or red, and the GitHub line when
  `GitHubAccess` is not `.ready` (§7.1).
- **The Changes pane** is a `VSplitView`:
  - **Top:** the findings strip, one row per finding, each with its glyph:
    `xmark.octagon.fill` (red) for blocking, `exclamationmark.triangle.fill`
    (orange) for warnings, `info.circle` (secondary) for notes. Blocking rows
    on a path offer Revert File; `derivedFilesStale` offers Open in Terminal.
    Clicking a row scrolls the diff to it. With no findings, one secondary
    line: "DiffGuard flagged nothing." Below it, the diff, Rendered or Source.
  - **Bottom:** the pull request (minimum 150 pt):
    - a Title field;
    - a Body editor in `Theme.Fonts.code`, with a red line under it when
      `PrivateText` matches;
    - a footer line that names where it goes: "Opens a draft pull request on
      axhoover/cryptology.city", followed by "· from CCwiki Dev" in a Dev
      build.
- **Open Draft PR** is disabled with a blocking finding, a `PrivateText` hit,
  `GitHubAccess` not `.ready`, or an editor of the job holding text the disk
  does not, a conflict nobody settled or a write that failed ("page.md could
  not be saved. Settle it in its window first."); its help says why.
  `JobCenter.approve` asks the last again once it has saved the editors
  (`unsettledEdits`), since that save may be the one that fails, and refuses
  with the same words. With warnings, or in a Dev build, it confirms: "Open
  a draft pull request with 2 flagged changes?" (or "Open a draft pull
  request on axhoover/cryptology.city?"),
  with "on axhoover/cryptology.city · from CCwiki Dev" as the informative
  text in a Dev build, and the buttons **Open Draft PR** (default) and
  **Cancel**.
- **An edit job with no changes yet** shows `ContentUnavailableView("No
  Changes Yet", systemImage: "square.and.pencil")` with "Edit the page in
  its window; changes appear here as you save." and the action Open Editor.
- **The window** defaults to 1100 × 760 and its minimum rises from 860 × 520
  to 860 × 640 (`Theme.jobsDefaultWidth/Height`, `Theme.jobsMinWidth/Height`),
  so the PR form never covers the diff.
- **The status bar** of each reader window gains a quiet button, "2 awaiting
  review", beside the running-jobs count. It opens the Jobs window
  (`model.requestJobsWindow(selecting:)`).
- **The Dock badge.** An ingestion now stops after twenty minutes and waits,
  usually while the maintainer is in another app. `JobCenter` sets
  `NSApp.dockTile.badgeLabel` to `reviewCount` whenever it changes, and to
  nil at zero, as Mail does. It observes `reviewCount` with
  `withObservationTracking`, re-registering after each change.

---

## 7. Editing (route a, and Edit… from a review)

### 7.1 Starting

**Edit Page…** (⌥⌘E), or **Edit This Passage…** / **Edit This Page…** from
the context menu, does four things:

1. **It checks the blockers**, which are local only: git is present, and the
   wiki is a git clone (`paths.wikiStore == .git`). A snapshot store gets
   "This copy of the wiki is a snapshot. Sync (⌘R) to replace it with a git
   clone." If any is missing, an alert lists it, with Open Settings….
   Editing needs no network, and the reader is built to work offline.
2. **It builds the `CorrectionTarget`** (§3.5).
3. **It looks for a job on the page** (`jobCenter.jobs(touching:)`: a job
   whose target is the page, or whose last snapshot changes it).
   - An `edit` job that `canEdit`: open its editor, with the cursor at the
     new target's lines. No alert.
   - Any other job: an alert, "This page already has a job in Jobs.", whose
     informative text names its kind, status and detail ("A correction,
     running: Lines 42–44, in “Security”."), with **Show Job** (default),
     **Start Another** and **Cancel**.
4. **It calls `jobCenter.beginEdit(target)`**, which creates `fix/<slug>`,
   runs `git worktree add` at `target.baseCommit`, records the base, and puts
   the job in `awaitingReview`. Then it opens the editor window (§7.2).

**GitHub is asked in the background.** `JobCenter.refreshGitHubAccess()` runs
`gh auth status` and the push-rights query for `PublishTarget.repository`
while the editor opens, and caches the answer as `gitHubAccess`. The editor
and the review show its banner when it is not `.ready`:

| `GitHubAccess` | Banner |
|---|---|
| `.offline` (a timeout, or a network failure) | "Offline. You can edit now; opening the pull request needs a connection." |
| `.ghMissing` | "gh is not installed, so this cannot become a pull request yet. Install it with Homebrew (brew install gh), then check again." No issue is offered: opening one needs gh too (§8.2) |
| `.notSignedIn` | "gh is not signed in. Run gh auth login in Terminal, then check again." |
| `.cannotPush` | "The signed-in account cannot push to axhoover/cryptology.city, so this cannot become a pull request. Open an issue instead." with **Open an Issue…** |

Each banner sits beside **Check Again**. Approve asks again (§6.5).

**Not before the tools are found.** At launch, gh is found a moment after
git, in the background, and a window macOS restores asks at once. An answer
computed before gh is found says it is missing, and would be kept. So the
editor and the review ask only once `AppModel.isDiscoveringTools` is false,
and ask then if nobody has; and when discovery finishes,
`JobCenter.toolsDidChange()` waits for any ask in flight and asks again if an
answer was kept, so one asked meanwhile from elsewhere (a correction begun
from the reader) is replaced.

If the target's region is `generated`, the editor opens with a banner: "This
passage is generated from the reduction pages. Correct the reduction page it
links to; edits here are refused at review."

### 7.2 The window

- **The scene.** `WindowGroup("Edit Page", id: CCwikiApp.editorWindowID,
  for: EditorTarget.self)`. The default size is 1200 × 820, and each pane is
  at least 320 pt wide.
- **The identity.** `EditorTarget` is `{jobID, path}`. Asking again for a
  file that is already open brings its window forward, and
  `EditorSession.reveal(_:)` moves the cursor to the new lines.
- **Opening it.** Views that have `@Environment(\.openWindow)` (JobsView,
  ReviewView, EditorWindow) call `model.showEditor(_:at:using:)`, which
  reveals and then calls `openWindow(id:value:)` directly. AppKit and async
  callers (the context menu, the menu bar's Edit Page…) use
  `model.requestEditor(_:at:)`: a reader window's `RootView` observes the
  request count and calls `takeEditorRequest()`, which clears the request, so
  a second reader window finds nil and nothing opens twice.
- **The title and subtitle.** The title is the file name,
  "pseudorandom-function.md", as a document window's is; the reader window
  already uses the page title. The subtitle is "Pseudorandom function ·
  Lines 42–44, in “Security”", or the path for a file the agent added.
- **The context strip.** Under the toolbar, on `.bar`, a strip shows the
  carried quote: two lines, `Theme.Fonts.log`, secondary. It has a **Show**
  button that reselects the lines, and a close button.
- **The panes.** An `HSplitView`:
  - **left:** `SourceTextView`, the whole file, frontmatter included;
  - **right:** the preview, `WebPane` over the session's own
    `WebController`.
- **The toolbar.** **Show/Hide Preview**, **Revert File…** in the overflow,
  then **Review Changes** (⌘↩, from the Jobs menu, §9). Review Changes
  saves, takes a snapshot, and opens the Jobs window on the job.
- **Saving is automatic**, so there is no Save command. ⌘S stays Search the
  Wiki, which is disabled in an editor window; the status line's "Saved" is
  the feedback.
- **The status line,** in `Theme.Fonts.meta`, reads: "Saved to the job's
  worktree" or "Saving…", then "Line 42, Column 7", then "CCwiki Dev" in a
  Dev build.

### 7.3 The source view

`SourceTextView` is an `NSViewRepresentable` around `NSTextView`. SwiftUI's
`TextEditor` cannot select a range programmatically before macOS 15, and the
deployment target is 14.

- **The text** is set in `NSFont.monospacedSystemFont(ofSize:
  NSFont.systemFontSize)`, and wraps to the pane.
- **Everything that would corrupt Markdown or LaTeX is off:** smart quotes,
  smart dashes, text replacement, automatic spelling correction, link
  detection, and data detectors. Continuous spell-checking is off by default
  too, because a page full of `\calA` would be red throughout. The user can
  turn it on from the context menu.
- **Undo, and the find bar** (`usesFindBar`). Find goes through ⌘F: the
  window publishes its own `focusedSceneValue(\.findAction, …)`, which calls
  `performTextFinderAction`. The reader's Find menu items therefore work
  here too.
- **On open, and on `reveal`,** the view selects the lines and scrolls them
  to the centre. `TextLines` does the line ↔ UTF-16 conversion, and it is
  pure and tested.
- **When the job is not editable** (`publishing`, or any state other than
  `awaitingReview`), the view is read-only, and the strip says why.

### 7.4 The preview

The preview renders `model.previewRequest(path:text:)`. That is
`PageRenderer.request(for: WikiPage(path:text:))` against the reader's index,
overlaid with the job's added pages (§6.3), with:

- the macros;
- the manifest and the labels, so the relation-meta line appears;
- `buildsPreviews = false`, because hover cards are noise while editing.

It renders 300 ms after typing stops, with `preservesScroll`, after
`invalidate()` (`render` skips a path it already shows). When the cursor
moves, the preview calls `revealSourceLines`, through
`SourceLineMap.renderedLine(forFileLine:)`, coalesced to one call per 150 ms.
So the preview follows the line you are on. Links in the preview open in the
reader, by the explorer's rule (§6.3).

### 7.5 Saving and closing

`EditorSession` owns the text, the original (`git show <base>:<path>`, as
bytes), the preview controller and two debouncers:

- **save**, 0.5 s after the last keystroke. It writes atomically, after the
  external-change check (§4.4), and only while the job is `awaitingReview`;
- **refresh**, 1 s after a save, which runs `jobCenter.refreshReview`.

**When CCwiki changes the file** (Revert File, Restore), `reloadFromDisk()`
reloads silently if nothing is unsaved. Otherwise it asks: "CCwiki reverted
this file in Jobs." with **Use Reverted File** and **Keep My Version**.

**Closing an editor** saves. If the job is an `edit` job whose snapshot is
empty, closing discards it, with no dialog: an untouched edit leaves nothing
behind. Otherwise the job stays in Jobs, awaiting review. A window whose job
is opened, discarded or gone closes itself.

**Quitting** with unsaved text: `applicationShouldTerminate` returns
`.terminateLater`, awaits `model.flushAllEditors()`, then replies. SwiftUI
does not reliably run `onDisappear` during termination, so this is the only
dependable save.

---

## 8. The two sheets

Both are sheets on the reader window, 560 pt wide, in IngestSheet's shape.
After reader-comforts that is the session's own window, through
`ReaderSession.correctionSheet` (§17). The one exception is **Open an
Issue…** on the editor's or the review's GitHub banner (§7.1). It opens the
issue sheet on that window, from the view's own `@State`, because a sheet on
another window would appear behind the one that was clicked. The sheets'
shape:

- a title in `.title2.weight(.semibold)`, then one secondary line in
  `Theme.Fonts.meta`;
- the fields;
- blockers, listed as IngestSheet lists them;
- Cancel (Esc) and a prominent default button (⌘↩).

Both show an inline note, with **Show Job**, when a job already exists on the
page (§7.1).

### 8.1 Describe a Correction (route b)

- **The secondary line:** "An agent drafts the smallest edit that does what
  you ask. Nothing reaches GitHub until you approve it in Jobs."
- **A context card:** the page title, the summary, and the quote in
  `Theme.Fonts.log`, at most four lines, with a `.help` that holds all of it.
- **The field:** "What is wrong, and what should it say?", focused when the
  sheet opens.
- **Below the field:** "Uses Claude Sonnet." (or "Uses the claude CLI's
  default model.") "Change it in Settings > Jobs." (with `>`, as the app's
  other strings name a settings pane).
- **The blockers:** git, claude, and a git clone (§7.1). GitHub is asked in
  the background, as for an edit.
- **A generated passage** shows, in place of the field, a note with **Open
  an Issue…** as the default button. The note is
  `CorrectionBlockers.generated` or `.frontmatterLine`, the blocker
  `CorrectionBlockers.list` gives route b, and the failure a correction run
  again later meets (`CorrectionJobRunner`):
  - a "Participates in" passage (`generated`): "This passage is generated
    from the reduction pages. Open an issue, or edit the reduction page it
    links to.";
  - the relation line under a reduction or barrier page's title
    (`frontmatter`), whose links go to classes, models and references, never
    to a reduction page: "This line is built from this page's own
    frontmatter, which an agent cannot change here. Open an issue, or edit
    those fields yourself with Edit Page."
- **Start Job** calls `jobCenter.startCorrection(CorrectionRequest(target:
  description: model:))` and opens the Jobs window on the new job, as
  ingestion does.

### 8.2 Open an Issue About This Page (route c)

- **The secondary line:** "For when something is wrong and you are not sure
  what it should say. No branch, no pull request."
- **The fields:**
  - **Title,** proposed as `<page title>: <section title>`, or the page
    title alone when there is no section or it has the page's title;
  - **Body,** one editor in `Theme.Fonts.code`, prefilled by
    `IssueComposer`: the page line, the permalink and the quote, then an
    empty paragraph where the cursor lands. It holds exactly the text sent.
  - Under it, one secondary line showing what CCwiki adds: "CCwiki adds:
    Opened with CCwiki 0.3.0 (CCwiki Dev, a development build) · reported
    from the reader". That is the footer's visible line, as
    `PullRequestDraft.footer` writes it; the release leaves out the
    parenthesis. The hidden marker is not shown.

  The body is not rendered: the reader's renderer is not GitHub's, which
  turns a permalink into a code snippet and renders math its own way.
- **The footer:** "Opens an issue on axhoover/cryptology.city as @login",
  followed by "· from CCwiki Dev" in a Dev build. The login comes from
  `model.githubLogin()` (`gh api user --jq .login`), cached for the session.
- **The blockers:** gh is installed. When `GitHubAccess` is `.offline` or
  `.notSignedIn`, Open Issue is disabled with that reason, and the text is
  kept.
- **Open Issue** runs `model.openIssue(draft)`: `gh issue create --repo R
  --title T --body-file F`, where `F` is a temporary file holding the body
  plus `PullRequestDraft.footer(_:marker:)` with `ccwiki-issue: <uuid>`, one
  UUID per sheet. `gh` prints the URL, and the sheet changes to "Issue #123
  opened." with Open in Browser and Done.
- **A retry** after a failure first runs `gh issue list --repo R --author @me
  --state all --limit 50 --json url,body` and looks for the marker in the
  bodies itself: GitHub's search lags a new issue and may not read inside
  the HTML comment that holds the marker. If the issue exists, gh's reply was lost; the sheet shows it
  instead of opening another. If gh cannot answer, nothing is sent.
- **Deadlines.** `gh issue create` and the retry's `gh issue list` each get
  `Publisher.ghDeadline` (90 s), and `githubLogin` gets
  `GitHubAuth.deadline`, so a stalled network cannot hold the sheet, whose
  Cancel is disabled while gh runs. A create that does not answer in time
  fails with "gh did not answer in time. The issue may have been opened;
  Open Issue checks GitHub for it before sending again."
- **On failure** the sheet stays open, with the text and gh's error.
- **`CCWIKI_PUBLISH_DRY_RUN=1`** stops before `gh issue create` and shows the
  command it would have run.
- Nothing is recorded locally; the issue on GitHub is the record.

`IssueComposer` (pure) proposes the body:

````markdown
**Page:** [Pseudorandom function](https://cryptology.city/Primitives/pseudorandom-function#security), `content/Primitives/pseudorandom-function.md`, lines 42–44 (“Security”)

https://github.com/axhoover/cryptology.city/blob/<base commit>/content/Primitives/pseudorandom-function.md?plain=1#L42-L44

```text
<the quote>
```

````

- **The quote is in a `text` fence**, not a blockquote: GitHub renders
  `$…$` in a blockquote with its own math, and the wiki's macros would show
  as errors. The fence is one backtick longer than any run in the quote.
- **The permalink** sits on a line of its own, and points at the base
  commit with `?plain=1` and a line anchor. GitHub embeds a link like that as
  a code snippet when the issue is in the same repository.
- **The path** is percent-encoded segment by segment, because reference
  filenames have spaces and `&`.
- **Labels.** None are passed. The wiki defines none, and `--label` fails
  on a missing one. §15 records the choice.

---

## 9. Entry points and shortcuts

| Where | Item | Shortcut |
|---|---|---|
| Wiki menu, a group after Copy Wikilink | Edit Page… | ⌥⌘E |
| | Describe a Correction… | — |
| | Open an Issue About This Page… | — |
| Reader context menu, a group of its own after the page group | Edit This Passage… / Edit This Page… | — |
| | Describe a Correction… | — |
| | Open an Issue About This Passage… / About This Page… | — |
| Reader toolbar, before the inspector toggle | a pull-down, `square.and.pencil`, `.accessibilityLabel("Correct This Page")`, help "Edit this page, describe a correction, or open an issue", with the three items | — |
| Reader status bar | "2 awaiting review", which opens Jobs | — |
| Jobs menu | Review Changes (in an editor window) | ⌘↩ |
| Jobs menu | Open Draft PR (in the Jobs window) | — |

- **⌥⌘E is free.** ⌘E is the system's Use Selection for Find, ⇧⌘E opens the
  Relations Explorer, and ⌥⇧⌘E is Explore From This Page. It is free
  against the rest of the batch too: reader-comforts adds ⌘N, ⌘T and ⌥⌘P,
  and relations-followups ⌥⌘C and ⌥⇧⌘C (reader-comforts §10 has the table).
- **Where the Wiki menu's group goes.** After the page group, which ends
  with reader-comforts' Show Paper (⌥⌘P), behind a divider, and before
  Reveal Page in Finder. The Jobs menu's two items follow Show Jobs, behind
  a divider.
- **⌘↩ has two meanings, never in one window.** Review Changes is a menu
  item enabled only in an editor window. Elsewhere ⌘↩ is a sheet's own
  default button: IngestSheet's Start Job, this spec's two sheets, and
  reader-comforts' palettes. §12.3 checks that the disabled menu item does
  not take it from a sheet.
- **The context menu group** sits behind a separator after Explore From This
  Page…, so the page actions stay one group and these three another.
- **Open Draft PR has no shortcut.** Review Changes brings the Jobs window
  forward on the job; if ⌘↩ also meant Open Draft PR there, two presses from
  the editor would publish. Both Jobs-menu items are driven by focused values
  (`\.reviewChangesAction`, `\.openDraftPRAction`) and are disabled
  elsewhere.
- **The menu bar items keep a fixed title.** When one is invoked, it carries
  whatever is selected, through `selectionSource()`.
- **The context menu titles say Passage or Page,** from `isPassage` (§3.3).
- **Wording.** Help → Report an Issue… stays as it is, for bugs in CCwiki
  itself. The wiki items always say "About This Page" or "About This
  Passage", so the two cannot be confused.
- **When the items are disabled:** when no wiki page is showing (a folder,
  Welcome, What's New, or nothing). Blockers are explained by the sheet or
  the alert, not by a disabled item.
- design-system.md §4 gains the rows ⌥⌘E (Edit Page) and ⌘↩ (Review
  Changes).

---

## 10. CCwiki Dev, and where things go

**Decision: Dev targets the same repository, `axhoover/cryptology.city`, and
says so at every step.**

```swift
struct PublishTarget: Sendable, Equatable {
    let repository: String     // "axhoover/cryptology.city"
    let pushURL: String        // "origin" for the clone's own remote, else "https://github.com/<repo>.git"
    let isDevBuild: Bool
    let isOverridden: Bool     // CCWIKI_TARGET_REPO took effect
    static func resolve(channel: BuildIdentity.Channel, environment: [String: String]) -> PublishTarget
}
```

Everything that names a repository takes `PublishTarget.repository`, not
`AppPaths.repositorySlug`: push rights, the tripwire, `gh pr` and `gh issue`,
the confirmations, and permalinks.

- **Before anything is sent:**
  - the review's PR footer line reads "Opens a draft pull request on
    axhoover/cryptology.city · from CCwiki Dev";
  - the issue sheet's footer says the same;
  - the Approve confirmation, which a Dev build always shows, repeats it.
- **In what is sent:** the footer on every PR and issue body names the
  version and "CCwiki Dev, a development build" (§6.4).
- **For testing the publish path end to end:**
  `CCWIKI_TARGET_REPO=owner/name` points a Dev build at a fork. The fork
  becomes the push URL and the `gh --repo`. The UI then says "on
  owner/name". The release ignores the variable, so a stray environment
  cannot redirect it. An invalid value (not `owner/name`) is ignored, with a
  warning in the status bar. A fork has issues off by default, and a
  permalink works only if the fork contains the base commit.
- **For testing everything but the push:** `CCWIKI_PUBLISH_DRY_RUN=1`, in
  either channel, for PRs and issues.

**Why the same repository.**

- **The corrections are real.** The maintainer is the only person with push
  access, and builds CCwiki with Dev builds. A correction made while
  dogfooding is a real correction, and sending it elsewhere would mean doing
  it twice.
- **A sandbox drifts.** A sandbox repository goes stale against the wiki.
  Its lint and its `generate-relations --check` would test a different
  wiki.
- **Nothing is sent unattended.** After this change, nothing is sent
  without an approval that names the repository. That was not true before: a
  Dev build's ingestion agent pushed on its own.
- **The footer marks provenance.** A reviewer can weigh a PR from a
  development build accordingly. The hidden marker ties the PR back to the
  job's transcript.

---

## 11. Parallel tracks: who owns which file

Phase 0 lands first and holds every seam. After it, four tracks run in
parallel, and **no two edit the same file**.

### 11.1 Phase 0: the seams

One PR. It compiles, keeps every existing test green, and changes nothing a
reader sees except three disabled menu items, an empty toolbar menu, and the
corrected texts below.

| File | Change |
|---|---|
| `Jobs/IngestJob.swift` → `Jobs/Job.swift` | The rename. `JobState` (top level, the three new cases, `isCancellable`), `JobKind` with `Tag`, `JobNotice`, `JobRecord` with its legacy decoding in an extension, `BranchName.slug`, and the new fields and setters of §4.2. **`cancel()` acts only when `isCancellable`, and `interruptPublishing()` is real** (§4.1). **`LogWriter` appends** (§4.2). Other new members have trivial bodies |
| `Jobs/IngestJobRunner.swift`, `Jobs/PromptComposer.swift`, `Jobs/IngestSubmission.swift` | Compile against `Job` (`job.submission!`, `BranchName.slug`). No behaviour change |
| `Jobs/GitService.swift`, `Jobs/Preflight.swift` | The two symbols other tracks call, as stubs: `GitService.blob(_:in:)` (returns nil; Track C reads the shown file with it), and `GitHubAccess` with `GitHubAuth.signedIn(tools:)` (Tracks C and D show it). Track B fills both |
| `App/AppPaths.swift` | `scratch(forJob:)` (`<caches>/scratch/<id>`) and `patch(forJob:)` (`logs/<id>.patch`) |
| `App/JobCenter.swift` (new) | The job section of `AppModel`, moved: `jobs`, `orphanedWorktrees`, `submitIngestion`, `loadJobHistory` (now private, **called from `init`**), `clearFinishedJobs`, `runAgain`, `start`, `refreshOrphanedWorktrees`, `pruneOrphan`. **`cancelActiveJobs` changes**: `cancel()` for queued, preparing and running jobs; `interruptPublishing()` for publishing ones; then `Subprocess.terminateAll()`. `ApproveResult` and `JobError` live here. Plus the §11.6 surface, with stub bodies (`.failure(JobError("Not built yet."))`) |
| `App/AppModel.swift` | `let jobCenter`, its `environment` closure, and forwarders, so existing views compile (`jobs`, `activeJobCount`, `submitIngestion`, …), including `orphanedWorktrees`, `refreshOrphanedWorktrees()` and `pruneOrphan(_:)`, which reader-comforts' library load also calls (§17). `let webRoot: URL`, set once in `init` from `paths.stagedWebRoot()`, declared exactly as reader-comforts' Phase 0 declares it. The stored properties of §11.6. `init` wires `webController.onCorrect`, `webController.correctionAvailable`, `jobCenter.flushEdits` and `jobCenter.onFilesChanged`. `warn(_:)` and `gitService` become internal. `requestEditor(_:at:)`, `takeEditorRequest()`, `requestJobsWindow(selecting:)`. `renderCurrent` sets `revision`. `resetClone` refuses while any job is not terminal. `mayStopJobs` and `relaunchToUpdate` get the alert texts below |
| `App/CCwikiApp.swift` | The editor `WindowGroup(for:)`. The Wiki-menu group (§9), disabled through `model?.canCorrectCurrentPage`. The two Jobs-menu items and their focused-value keys. `editorWindowID = "ccwiki.editor"`. The Jobs `defaultSize` from `Theme`. **`AppDelegate`**: the quit alert counts agents and publishing jobs apart (texts below); with unsaved editor text, `.terminateLater` while `flushAllEditors()` runs |
| `Corrections/CorrectionTarget.swift` (new) | `LineRange`, `CorrectionTarget` (`make` returns a whole-page target), `ReaderSelection` (both inits return nil), `CorrectionRequest`, `IssueDraft`, `CorrectionRoute`, `CorrectionSheetRequest`, `EditorTarget`, `CorrectionBlockers` (returns `[]`) |
| `Corrections/SourceLineMap.swift`, `Corrections/IssueComposer.swift` (new) | The declarations. `location` returns nil |
| `Jobs/ReviewSnapshot.swift`, `Jobs/LineDiff.swift`, `Jobs/GitNameStatus.swift`, `Jobs/DiffGuard.swift`, `Jobs/FactCheckQueue.swift`, `Jobs/PullRequestDraft.swift`, `Jobs/PublishTarget.swift`, `Jobs/PrivateText.swift` (new) | The declarations of §11.6, with trivial bodies |
| `App/AppModel+Corrections.swift`, `App/AppModel+Editor.swift`, `App/EditorSession.swift` (new) | The declarations of §11.6, with stub bodies |
| `UI/EditorWindow.swift`, `UI/CorrectionSheet.swift`, `UI/IssueSheet.swift`, `UI/ReviewView.swift` (new) | Placeholders: a `ContentUnavailableView` each |
| `Reader/WebController.swift` | `selectionSource()` returns nil. `renderReview(json:)`, `revealSourceLines(_:mark:)` and `scrollToReviewEntry(_:)` evaluate `window.CCwiki.<fn> && …` with the **completion-handler** `evaluateJavaScript`, because the async overload traps when JavaScript returns undefined. `onCorrect`, `correctionAvailable`, and `lastRenderedMarkdown` and `lastRenderedRevision`, both set in `render(_:)` |
| `Reader/RenderRequest.swift` | `var revision: String?`, in `jsonPayload()` |
| `UI/RootView.swift` | The toolbar pull-down, `.sheet(item: $model.correctionSheet)` switching to the two sheets, `.onChange(of: model.editorWindowRequestCount)` → `takeEditorRequest()` → `openWindow(id:value:)`, the status bar's "N awaiting review". The `.task` no longer calls `loadJobHistory()`. The drop overlay's text |
| `UI/JobsView.swift`, `UI/JobDetailView.swift` | `IngestJob` → `Job`, `job.submission.displayName` → `job.title`, the optional `submission` unwrapped, the tint and banner switches given the new states, Cancel and Cancel Job only when `isCancellable`, Run Again only when `canRunAgain`, `jobsWindowSelection` honoured, `Theme.jobsMinWidth/Height`. The empty states' texts and "Ingest a Paper" |
| `UI/IngestSheet.swift` | Its secondary line (below) |
| `App/Settings.swift`, `UI/SettingsView.swift` | `correctionModel` (default `"sonnet"`). The **Ingestion** tab is renamed **Jobs** (`hammer`), with a section **Corrections** holding a picker labelled **Model**: Sonnet, Haiku, Opus, The CLI's default. The footers' texts (below) |
| `App/Theme.swift` | `editorDefaultWidth` 1200, `editorDefaultHeight` 820, `editorPaneMinWidth` 320, `jobsDefaultWidth` 1100, `jobsDefaultHeight` 760, `jobsMinWidth` 860, `jobsMinHeight` 640, `reviewFormMinHeight` 150, `sheetWidth` 560, and `Fonts.code = .system(.body, design: .monospaced)` |
| `App/ScreenshotRunner.swift` | Steps `edit:<path>`, `review:<path>`, `source`, `describe:<path>`, `issue:<path>` (§12.3). The first two call `jobCenter.beginEdit` directly, past the blockers; `source` sets `model.reviewShowsSource`. `waitForJob` also stops at `awaitingReview` |
| `Tests/CCwikiTests/IngestionTests.swift` | Compile against `Job` |
| `Tests/CCwikiTests/JobRecordTests.swift` (new) | §12.1's Phase 0 cases |
| `PLAN.md` | The index entry for this file |

**The texts Phase 0 corrects.** After §5, no agent opens a PR on its own, and
four existing strings say it does; the Jobs window and Settings now cover more
than papers.

| Where | New text |
|---|---|
| IngestSheet, secondary line | "CCwiki runs an agent in a throwaway git worktree. Nothing reaches GitHub until you approve it in Jobs; then CCwiki opens a **draft** pull request, and never merges one." |
| RootView, drop overlay | "CCwiki will run an agent in a worktree and show you its changes before opening a draft PR." |
| Quit, relaunch and hand-over alerts, for agents | "The agent will be stopped. Its worktree and transcript are kept." |
| The same alerts, for a publishing job | Message: "Quit while a pull request is being opened?" Informative: "Quitting stops it. The job returns to review, and CCwiki checks GitHub before opening the pull request again." |
| JobsView, empty states | "Papers you ingest and corrections you start appear here." The "New Job" button becomes "Ingest a Paper" |
| Settings → Jobs, footers | "Ingestion and corrections need these; opening an issue needs only gh. Reading needs none of them." and "Jobs need an account that can push a branch to the wiki." |

The integrator updates PLAN.md §3's "Never merge a PR" row, which cites
`prompts/ingest.md` Step 6, to point at `Publisher`.

### 11.2 Track A: the review model (pure)

- **Owns:**
  - `Jobs/ReviewSnapshot.swift` (with `ReviewSnapshot.assemble`);
  - `Jobs/LineDiff.swift`, which builds hunks on `CollectionDifference`,
    merging adjacent ones;
  - `Jobs/GitNameStatus.swift`;
  - `Jobs/DiffGuard.swift`;
  - `Jobs/FactCheckQueue.swift`;
  - `Jobs/PullRequestDraft.swift` (with `footer`);
  - `Jobs/PublishTarget.swift`;
  - `Jobs/PrivateText.swift`;
  - tests: `LineDiffTests`, `GitNameStatusTests`, `DiffGuardTests`,
    `FactCheckQueueTests`, `PullRequestDraftTests`, `PublishTargetTests`,
    `PrivateTextTests`;
  - `Tests/CCwikiTests/Fixtures/review/` (new).
- **Edits nothing else.** It needs no process, no view and no `AppModel`.
- **Consumes:** `Frontmatter`, `WikiPage.atxHeading`, `BuildIdentity`, and
  CryptoKit.

### 11.3 Track B: the pipeline

- **Owns:**
  - `Jobs/Job.swift` and `App/JobCenter.swift`, with real bodies: the
    per-job git queue, `flushEdits` and `onFilesChanged` calls,
    `gitHubAccess`, the Dock badge, transcript replay;
  - `Jobs/IngestJobRunner.swift`;
  - new: `Jobs/CorrectionJobRunner.swift`, `Jobs/Publisher.swift`,
    `Jobs/ReviewSnapshotter.swift`, `Jobs/AgentInvocation.swift`,
    `Jobs/Tripwire.swift`;
  - `Jobs/GitService.swift`, which gains the additions in §11.6, after
    `updateSubmodules(in:onLine:)` and before the private helpers
    (reader-comforts adds its date methods beside `modifiedDates(in:)`);
  - `Jobs/Subprocess.swift`, which gains `runData`;
  - `Jobs/PromptComposer.swift`, which gains `template(named:)` and
    `composeCorrection`;
  - `Jobs/Preflight.swift`, which gains `GitHubAccess` and
    `GitHubAuth.signedIn()`;
  - `prompts/ingest.md` (Step 6, scratch, the precedence sentence), and
    `prompts/correct.md` (new);
  - `plans/ingestion.md`: §7 "what CCwiki never does" and §9, the review
    and the seal;
  - tests: `IngestionTests.swift` (the prompt and allow-list tests change,
    §12.1), `AgentInvocationTests`, `PublisherTests`, `JobCenterTests`,
    `GitHubAccessTests`, `GitReviewIntegrationTests`, `JobRecordTests`.
- **Consumes:** Track A's types, and `CorrectionTarget`.

### 11.4 Track C: the reader side

- **Owns:**
  - `Corrections/CorrectionTarget.swift` (`make`, `ReaderSelection`'s
    decoding, `LineRange`, `CorrectionBlockers`);
  - `Corrections/SourceLineMap.swift`;
  - `Corrections/IssueComposer.swift`;
  - `App/AppModel+Corrections.swift`, with `openIssue` and `githubLogin`;
  - `Reader/WebController.swift`: the real `selectionSource()`,
    `pendingReviewJSON`, the context-menu group, and `ReaderContextTarget`
    gaining `selection`, a defaulted init parameter that goes last, after
    reader-comforts' `link` (§17);
  - `Resources/web/ccwiki-markdown.js` (new, §3.2), with `reviewEntries`;
  - `Resources/web/ccwiki.js`: the right-click rule, `selectionSource`,
    `revealSourceLines`, `renderReview`, `scrollToReviewEntry`,
    `selectionText` factored out of the copy handler, and links of kind
    `new`;
  - `Resources/web/index.html` (the new script tag) and
    `Resources/web/app.css` (the review and reveal styles, light and dark);
  - `UI/CorrectionSheet.swift` and `UI/IssueSheet.swift`;
  - `plans/render-pipeline.md`: a section on source lines, and the load
    order;
  - tests: `SourceLineMapTests`, `CorrectionTargetTests`,
    `ReaderSelectionTests`, `IssueComposerTests`, `SourceStampTests`,
    `ReviewEntriesTests`, and `ReaderContextMenuTests` (extended).
- **Consumes:** `JobCenter.startCorrection`, `jobs(touching:)` and
  `gitHubAccess`, `PublishTarget`, and `PullRequestDraft.footer`.
- **Publishes:** the JS functions of §3.3, implemented to §6.3's payload
  exactly.

### 11.5 Track D: the review and the editor

- **Owns:**
  - new: `Jobs/ReviewPayload.swift`, `Jobs/WordDiff.swift`,
    `UI/TextLines.swift`;
  - `App/EditorSession.swift` and `App/AppModel+Editor.swift`;
  - `Wiki/WikiIndex.swift`: `overlaying(_:)`, built on
    `assemble(contentRoot:files:pages:)`, the second half of `build`, which
    reader-comforts' D6 also needs (§11.6, §17);
  - `UI/EditorWindow.swift` and `UI/SourceTextView.swift` (new);
  - `UI/ReviewView.swift` and `UI/SourceDiffView.swift` (new);
  - `UI/JobsView.swift` and `UI/JobDetailView.swift`;
  - `plans/design-system.md` §4 (the two shortcuts) and §4a;
  - tests: `ReviewPayloadTests`, `WordDiffTests`, `TextLinesTests`.
- **Consumes:**
  - from Track B: `JobCenter.refreshReview`, `approve`, `discard`,
    `revert`, `reviewAnyway`, `restoreWorktree` and `gitHubAccess`;
  - from Track A: `ReviewSnapshot`, `DiffFinding`, `PullRequestDraft` and
    `PrivateText`;
  - from Track C: `WebController.renderReview`, `revealSourceLines` and
    `scrollToReviewEntry`, and `SourceLineMap`.

### 11.6 The interfaces, exactly

The types in §3.4, §3.5, §4.1, §4.2, §6.4, §6.5 and §10 are part of this
list, and are not repeated. Bodies are elided.

```swift
// MARK: Corrections/CorrectionTarget.swift — Phase 0 declares; Track C fills
enum CorrectionRoute: String, Sendable, CaseIterable { case edit, describe, issue }
struct IssueDraft: Sendable, Equatable {
    let target: CorrectionTarget
    let marker: String        // a UUID, one per sheet: "ccwiki-issue: <marker>"
    var title: String
    var body: String          // exactly as typed; the footer is added when sending
}
struct CorrectionSheetRequest: Identifiable, Sendable {
    enum Kind: Sendable { case describe, issue }
    let id: UUID
    let kind: Kind
    let target: CorrectionTarget
}
struct EditorTarget: Codable, Hashable, Sendable {
    let jobID: String
    let path: String          // repository-relative
}
enum CorrectionBlockers {
    /// Pure. Local conditions only; GitHub is GitHubAccess's.
    static func list(route: CorrectionRoute, region: CorrectionTarget.Region,
                     gitPresent: Bool, claudePresent: Bool, ghPresent: Bool,
                     store: AppPaths.WikiStore) -> [String]
}

// MARK: Corrections/IssueComposer.swift — Phase 0 declares; Track C fills
enum IssueComposer {
    static func proposedTitle(for target: CorrectionTarget) -> String
    static func body(for target: CorrectionTarget, siteURL: URL?, repository: String) -> String
    static func permalink(repository: String, commit: String, path: String, lines: LineRange?) -> URL
    static func fence(for text: String) -> String   // backticks, one more than the longest run, at least 3
}

// MARK: App/AppModel+Corrections.swift — Track C
extension AppModel {
    var canCorrectCurrentPage: Bool { get }
    func correctionBlockers(_ route: CorrectionRoute, target: CorrectionTarget) -> [String]
    /// Reads the selection, builds the target, then opens the editor or a sheet.
    func beginCorrection(_ route: CorrectionRoute) async
    /// From the context menu, where the selection is already in hand.
    func beginCorrection(_ route: CorrectionRoute, selection: ReaderSelection?)
    func githubLogin() async -> String?
    func openIssue(_ draft: IssueDraft) async -> Result<URL, JobError>
}
// After reader-comforts (§17), the first and the two beginCorrection move,
// unchanged in signature, to App/ReaderSession+Corrections.swift:
//   extension ReaderSession { canCorrectCurrentPage; beginCorrection(_:);
//                             beginCorrection(_:selection:) }
// They read the session's own webController and currentPage, and
// model.jobCenter. correctionBlockers, githubLogin and openIssue stay here.

// MARK: Reader/WebController.swift — Phase 0 stubs; Track C fills
extension WebController {
    func selectionSource() async -> ReaderSelection?
    func renderReview(json: String)                  // held in pendingReviewJSON until "ready"
    func revealSourceLines(_ range: Range<Int>, mark: Bool)
    func scrollToReviewEntry(_ id: String)
}
// stored, Phase 0:
//   var onCorrect: ((CorrectionRoute, ReaderSelection?) -> Void)?
//   var correctionAvailable: (() -> Bool)?
//   private(set) var lastRenderedMarkdown: String?
//   private(set) var lastRenderedRevision: String?   // that request's `revision` (§3.5)
// stored, Track C:
//   @ObservationIgnored private var pendingReviewJSON: String?
// Functions whose JavaScript returns undefined use the completion-handler
// evaluateJavaScript; selectionSource keeps returning the string "null".

// MARK: App/AppModel.swift — Phase 0
// let jobCenter: JobCenter
// var correctionSheet: CorrectionSheetRequest?
// private(set) var editorWindowRequestCount = 0
// @ObservationIgnored private var editorWindowRequest: EditorTarget?
// func requestEditor(_ target: EditorTarget, at lines: LineRange?)   // AppKit and async callers
// func takeEditorRequest() -> EditorTarget?                          // clears it
// private(set) var jobsWindowSelection: String?
// func requestJobsWindow(selecting jobID: String? = nil)
// var reviewShowsSource = false
// @ObservationIgnored var editorSessions: [EditorTarget: EditorSession] = [:]
// @ObservationIgnored private(set) lazy var reviewWeb = WebController(paths: paths, webRoot: webRoot)
//     after reader-comforts: WebController(paths: paths, webRoot: webRoot, pageZoom: pageZoom)
// let webRoot: URL                              // the staged root, made once in init;
//                                               // reader-comforts declares the same, one is kept
//
// After reader-comforts (§17), these three are per window and move to
// ReaderSession; everything else in this list stays on AppModel:
//   var correctionSheet: CorrectionSheetRequest?     a stored property of ReaderSession
//   webController.onCorrect, .correctionAvailable    wired in ReaderSession.init
//   request.revision = model.headRevision            set in ReaderSession.renderCurrent
// var correctionModel: String                    // CCwikiSettings.correctionModel, persisted
// func warn(_ message: String)                   // was private
// var gitService: GitService? { get }            // was private

// MARK: App/JobCenter.swift — Phase 0 moves and stubs; Track B fills
@MainActor @Observable
final class JobCenter {
    struct Environment: Sendable {
        let tools: ToolLocator
        let git: GitService?
        let index: WikiIndex?
        let relations: RelationsManifest
        let labels: RelationLabels
        let appVersion: String
        let correctionModel: String
        let target: PublishTarget
        let privatePaths: [String]
    }
    private(set) var jobs: [Job]
    private(set) var orphanedWorktrees: [String]
    private(set) var gitHubAccess: GitHubAccess?      // nil until asked
    /// Read fresh at each call (SWIFTUI-RULES §3.5).
    @ObservationIgnored var environment: @MainActor () -> Environment
    /// Saves every open editor of the job. Set by AppModel.init.
    @ObservationIgnored var flushEdits: (@MainActor (Job) async -> Void)?
    /// Why an editor of the job holds text the disk does not (a conflict,
    /// or a failed write); nil when none does. Approve asks it after
    /// flushEdits (§4.4). Set by AppModel.init.
    @ObservationIgnored var unsettledEdits: (@MainActor (Job) -> String?)?
    /// CCwiki changed these repository-relative paths in the job's worktree.
    @ObservationIgnored var onFilesChanged: (@MainActor (Job, [String]) -> Void)?
    /// Loads the job history synchronously.
    init(paths: AppPaths, environment: @escaping @MainActor () -> Environment)

    var activeJobCount: Int { get }       // preparing, running, publishing
    var publishingCount: Int { get }
    var reviewCount: Int { get }          // awaitingReview, less untouched edits; the Dock badge
    var hasFinishedJobs: Bool { get }
    func job(id: String) -> Job?
    /// Non-terminal jobs whose target is this page, or whose last snapshot
    /// changes it (content-relative), newest first.
    func jobs(touching pagePath: String) -> [Job]
    func refreshGitHubAccess() async
    /// Once git is found: a snapshot for every review that has none.
    func refreshMissingReviews() async
    /// Once every tool is found: refreshMissingReviews, then GitHub asked
    /// again if an answer was kept from before gh was found (§4.3, §7.1).
    func toolsDidChange() async
    /// A transcript line from outside the runners, which alone change a
    /// job (§4.2): an editor saying where its unsaved text went.
    func log(_ entry: JobLogEntry, in job: Job)

    @discardableResult func submitIngestion(source: IngestSubmission.Source?, pdf: URL?, notes: String) -> Job
    @discardableResult func startCorrection(_ request: CorrectionRequest) -> Job
    func beginEdit(_ target: CorrectionTarget) async -> Result<Job, JobError>
    func runAgain(_ job: Job)

    func refreshReview(_ job: Job) async
    func revert(_ path: String, in job: Job) async
    func reviewAnyway(_ job: Job) async
    func restoreWorktree(_ job: Job) async -> Bool
    func approve(_ job: Job) async -> ApproveResult
    /// The open PR on the job's branch, if any: for Discard's dialog.
    func openPullRequest(for job: Job) async -> URL?
    func discard(_ job: Job) async
    /// Closing an untouched edit's last editor.
    func discardIfUntouched(_ job: Job) async

    func clearFinishedJobs()
    func cancelActiveJobs()
    func refreshOrphanedWorktrees() async
    /// Never the worktree of a job that owns it.
    func pruneOrphan(_ path: String)
    /// Not finished, or Review Anyway may still take it to review (§4.3).
    nonisolated static func ownsWorktree(_ state: JobState) -> Bool
}
struct JobError: Error, Sendable, Equatable { let message: String; init(_ message: String) }

// MARK: Jobs/ReviewSnapshot.swift, LineDiff.swift, GitNameStatus.swift — Track A
struct ReviewSnapshot: Sendable, Equatable {
    let baseCommit: String
    let files: [ChangedFile]
    let digest: String                    // hex SHA-256 of `git diff --cached --binary <base>`
    var isEmpty: Bool { files.isEmpty }
    /// Pure and Sendable, so it runs in Task.detached.
    static func assemble(base: String, entries: [GitNameStatus.Entry], binary: Set<String>,
                         patch: Data, oldTexts: [String: String], newTexts: [String: String])
        -> ReviewSnapshot
}
struct ChangedFile: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable { case added, modified, deleted, renamed }
    let path: String
    let oldPath: String?
    let status: Status
    let isBinary: Bool
    let oldText: String?
    let newText: String?
    let hunks: [LineHunk]
    var id: String { path }
    var addedLines: Int { get }
    var removedLines: Int { get }
    var isMarkdown: Bool { get }
}
struct LineHunk: Sendable, Equatable { let old: Range<Int>; let new: Range<Int> }   // 0-based file lines
enum LineDiff { static func hunks(old: String, new: String) -> [LineHunk] }
enum GitNameStatus {
    struct Entry: Sendable, Equatable { let status: ChangedFile.Status; let path: String; let oldPath: String? }
    static func parse(nameStatusZ: Data) -> [Entry]
    static func binaryPaths(numstatZ: Data) -> Set<String>
}

// MARK: Jobs/DiffGuard.swift, FactCheckQueue.swift — Track A
struct DiffFinding: Sendable, Equatable, Identifiable {
    enum Severity: Int, Sendable, Comparable {
        case note, warning, blocking
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    enum Rule: String, Sendable, CaseIterable {
        case outsideContent, renamedOrDeleted, binaryFile, generatedRegionEdited,
             relationFieldOnObjectPage, wikilinkMath, privateText,
             newObjectPage, otherPages, largeEdit, ingestionScope, proseRelationBullet,
             derivedFilesStale, relationsJSONByHand, humanVerified, statusComplete,
             changedUpstream, rawHTML, regionRegenerated
    }
    let rule: Rule
    let severity: Severity
    let path: String
    let lines: LineRange?                 // in the new text; the old text for a deletion
    let message: String                   // shown as is
    var id: String { get }                // "\(rule):\(path):\(lines?.first ?? 0)"
}
enum DiffGuard {
    struct Context: Sendable {
        var kind: JobKind.Tag
        var family: JobKind.Family { get }
        var humanVerifiedPaths: Set<String>
        var changedUpstream: Set<String>
        var target: CorrectionTarget?
        var privatePaths: [String]
    }
    static func check(_ snapshot: ReviewSnapshot, context: Context) -> [DiffFinding]
    static func regionChecksum(_ inner: String) -> String    // sha256(trimmed)[0..<12], as lint.mjs
    /// The allow-list: `.md` under content/ but not content/Templates/, and .reductions/relations.json.
    static func isPublishable(_ path: String) -> Bool
}
enum FactCheckQueue { static func humanVerifiedPaths(json: Data) -> Set<String> }   // [] on any error

// MARK: Jobs — Track B
extension Subprocess {
    /// Run to completion with stdout as bytes, untouched by LineSplitter.
    static func runData(executable: String, arguments: [String], currentDirectory: URL? = nil,
                        environment: [String: String]) async
        -> (status: Int32, stdout: Data, stderr: String)
}
enum GitHubAccess: Sendable, Equatable {
    case ready, offline, ghMissing, notSignedIn, cannotPush(repository: String)
    var banner: String? { get }           // §7.1; nil for .ready
    /// Pure. `signedIn` and `canPush` are nil when gh could not be asked.
    static func classify(ghPresent: Bool, signedIn: Bool?, canPush: Bool?, repository: String) -> GitHubAccess
}
extension GitHubAuth {
    /// `gh auth status`: nil on a timeout, unlike isAuthenticated's false.
    static func signedIn(tools: ToolLocator) async -> Bool?
}
struct AgentInvocation: Sendable, Equatable {
    var arguments: [String]
    var environment: [String: String]
    static func ingestion(prompt: String, maxTurns: String,
                          base: [String: String], scratch: URL) -> AgentInvocation
    static func correction(prompt: String, model: String, maxTurns: String,
                           base: [String: String], scratch: URL) -> AgentInvocation
    static func sealed(_ environment: [String: String], scratch: URL) -> [String: String]
    static let ingestionTools: [String]   // today's list, Bash(git:*) narrowed (§5.1), Bash(gh:*) removed
    static let correctionTools: [String]  // Read, Edit, Write, Glob, Grep
    static let denied: [String]
}
@MainActor struct Tripwire {
    let git: GitService
    let tools: ToolLocator
    let target: PublishTarget
    func headsBefore() async -> [String: String]?
    /// §5.5. `otherBranches` are other CCwiki jobs' branches.
    func check(_ job: Job, headsBefore: [String: String]?, otherBranches: Set<String>) async
        -> (pullRequest: URL?, notice: JobNotice?)
}
@MainActor struct ReviewSnapshotter {
    let git: GitService
    func snapshot(worktree: URL, base: String, patchFile: URL) async -> ReviewSnapshot?
}
@MainActor struct Publisher {
    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    let target: PublishTarget
    func publish(_ job: Job, reviewed digest: String,
                 provenance: PullRequestDraft.Provenance) async -> ApproveResult
    enum LeaseRecovery: Sendable, Equatable { case retry(expecting: String?), rename, refuse }
    nonisolated static func leaseRecovery(remoteTip: String?, pushing: String?, pushed: String?,
                                          reflog: Set<String>) -> LeaseRecovery
    nonisolated static func pushArguments(remote: String, branch: String, expecting: String?) -> [String]
    nonisolated static func createArguments(target: PublishTarget, base: String, branch: String,
                                            title: String, bodyFile: String) -> [String]
    nonisolated static func commitMessage(title: String, version: String, jobID: String) -> String
}
@MainActor struct CorrectionJobRunner {
    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    let model: String
    func run(_ job: Job) async
}
enum RemoteTip: Sendable, Equatable { case absent, at(String), unknown }
extension GitService {
    func resolveCommit(_ ref: String, in directory: URL) async -> String?       // rev-parse --verify <ref>^{commit}
    func mergeBase(_ a: String, _ b: String, in directory: URL) async -> String?
    func stageAll(in worktree: URL) async -> Bool                               // excludes .ccwiki
    func stagedDiff(in worktree: URL, base: String) async
        -> (nameStatus: Data, numstat: Data, patch: Data)?
    /// `git show <spec>`, bytes exact: "<base>:<path>", or ":<path>" for the index.
    func blob(_ spec: String, in directory: URL) async -> Data?
    func revertPath(_ path: String, to base: String, in worktree: URL) async -> Bool
    func commitStaged(in worktree: URL, base: String, message: String) async -> String?  // the new sha
    func push(in worktree: URL, to remote: String, branch: String, expecting: String?) async
        -> Subprocess.Result
    func remoteTip(of branch: String, remote: String, in directory: URL) async -> RemoteTip
    func remoteHeads(remote: String, in directory: URL) async -> [String: String]?
    func reflog(of branch: String, in directory: URL) async -> Set<String>
    func renameBranch(to name: String, in worktree: URL) async -> Bool
    func identity(in worktree: URL) async -> (name: String, email: String)?
    func changedPaths(in clone: URL, from base: String, to ref: String, limitedTo paths: [String]) async
        -> Set<String>
    /// `git worktree prune`, then `git worktree add -B <branch> <path> <base>`.
    func addWorktree(clone: URL, at path: URL, resettingBranch branch: String, to base: String) async -> Bool
    func applyPatch(_ patch: URL, in worktree: URL) async -> Bool                // apply --index
    func deleteBranch(_ name: String, in clone: URL) async -> Bool              // local only
}
extension PromptComposer {
    static func template(named name: String) -> String?
    @MainActor static func composeCorrection(_ request: CorrectionRequest, job: Job,
                                             siteURL: URL?) throws -> String
}

// MARK: Track D
enum ReviewPayload {
    /// §6.3's JSON. Pure.
    static func json(snapshot: ReviewSnapshot, findings: [DiffFinding],
                     title: (String) -> String?, header: (ChangedFile) -> String,
                     links: (ChangedFile) -> [String: RenderRequest.ResolvedLink],
                     macros: [String: String]) -> String
}
extension WikiIndex {
    /// This index with `pages` added or replaced: for links to pages a change adds.
    /// `assemble` over this index's markdown and asset paths plus the added ones.
    func overlaying(_ pages: [WikiPage]) -> WikiIndex
    /// The second half of `build`, which becomes `contentFiles`, a load per
    /// `.md` file, then this. Shared, signature and all, with reader-comforts'
    /// D6 (its §4.6): whichever lands first defines it.
    static func assemble(contentRoot: URL, files: [String],
                         pages: [String: WikiPage]) -> WikiIndex
}
enum WordDiff {
    struct Segment: Sendable, Equatable { enum Kind: Sendable { case same, removed, added }; let kind: Kind; let text: String }
    /// Tokens are runs of non-space; `$…$` spans are one token.
    static func segments(old: String, new: String) -> [Segment]
}
enum TextLines {
    static func utf16Range(of lines: LineRange, in text: String) -> NSRange?
    static func line(atUTF16Offset offset: Int, in text: String) -> Int        // 1-based
}
@MainActor @Observable final class EditorSession {
    let target: EditorTarget
    var text: String
    private(set) var original: String?
    private(set) var saveState: SaveState
    private(set) var cursorLine: Int
    private(set) var pendingReveal: LineRange?   // consumed by SourceTextView
    var hasUnsavedText: Bool { get }
    @ObservationIgnored private(set) lazy var preview: WebController
    init(target: EditorTarget, model: AppModel)
    func load() async
    func textDidChange()
    func cursorDidMove(toLine line: Int)
    func reveal(_ lines: LineRange?)
    func saveNow() async          // writes only while the job is awaitingReview
    func reloadFromDisk() async   // after CCwiki changed the file
    func revertFile() async
    func close() async
    enum SaveState: Sendable, Equatable {
        case saved, saving
        case conflict(diskText: String, revertedByCCwiki: Bool)
    }
}
extension AppModel {
    func editorSession(for target: EditorTarget) -> EditorSession
    func closeEditorSession(_ target: EditorTarget)
    func showEditor(_ target: EditorTarget, at lines: LineRange?, using openWindow: OpenWindowAction)
    var hasUnsavedEdits: Bool { get }
    func flushEdits(for job: Job) async
    func flushAllEditors() async
    func filesChanged(in job: Job, paths: [String])
    func previewRequest(path: String, text: String) -> RenderRequest
    func reviewPayload(for job: Job) -> String?
}
```

`ReviewView` and `EditorWindow` set their `WebController`'s `onNavigate` and
`onReady` themselves, because the open-a-reader rule (§6.3) needs a view's
`openWindow`.

### 11.7 Merge order and gates

1. **Phase 0** first.
2. **Tracks A, B, C and D in parallel.** Every symbol another track uses is
   in Phase 0's stubs, so each compiles on its own.
   - A has no dependency.
   - B's integration test needs A's `assemble` and `GitNameStatus`. Until A
     lands, B runs it against Phase 0's stubs with the test marked
     `.disabled("needs Track A")`.
   - D builds its views against Phase 0's `JobCenter` stubs, and against
     fixture snapshots, as `RelationsTests` does.
3. **Merge order: A, then B, then C and D in either order.** C's
   `reviewEntries` and D's payload meet only in the JSON of §6.3, which
   `ReviewEntriesTests` and `ReviewPayloadTests` both pin.
4. The integrator writes the `PROGRESS.md` entry, the `CHANGELOG.md` notes and
   the PLAN.md §3 row. Tracks do not edit those, because parallel edits to
   their heads conflict every time.
5. **Across the batch, this feature merges to `main` last**, after
   relations-followups and reader-comforts. Before its PR leaves draft, the
   integrator rebases `claude/page-corrections` onto `main` and works
   through §17. That is one more CI round, and `make shots` on a Mac.

**The gates.** The tracks have no Mac and no Swift. Each track's gate is a
green CI `make check` on its draft PR. `make shots` is the maintainer's step,
on a Mac, before merge; CI does not run it. Every PR is a draft. **No one
merges to `main`.**

---

## 12. Tests and the visual gate

### 12.1 Unit tests (swift-testing)

**`JobRecordTests`** (Phase 0, then B)
- The 0.2 record, verbatim JSON, decodes as ingestion. Each kind
  round-trips. The memberwise init still exists.
- After `cancelActiveJobs()`, a job in `awaitingReview` and one in
  `publishing` both read `awaitingReview`, in memory and in the record.
- `cancel()` on `awaitingReview` changes nothing.
- A fresh `JobCenter` has its records right after `init`, with no view.
- `appendRaw` after a restore keeps the earlier lines of the log file.
- Restoration follows §4.3, row by row, with temp directories.

**`SourceLineMapTests`** (C)
- A 13-line frontmatter: rendered line 0 is file line 14.
- A reduction page with the splice: the lines after it shift by 3; a range
  inside the run maps to `.frontmatter`; a range that partly overlaps the
  run keeps only its body part.
- A splice beside blank lines: no non-blank line moves.
- A page without frontmatter. A BOM.
- `renderedLine(forFileLine:)` inverts `location`; inside the frontmatter it
  is nil.

**`SourceStampTests`** (C, JavaScriptCore)
- A `JSContext` loads the vendored `markdown-it.umd.min.js`,
  `markdown-it-footnote`, `markdown-it-mark` and `github-slugger.umd.js`, a
  stub `katex` whose `renderToString` returns its input, and
  `ccwiki-markdown.js`, read through `#filePath`.
- Fixtures: a list, a `$$` block, a pseudocode fence, a table, a callout, a
  generated region, and a reduction page with the relation-meta splice. For
  each stamped block, `SourceLineMap` maps its `data-source-lines` (or
  `ccwiki-lines`) to the file lines that hold it. The `$$` block's range ends
  on the closing `$$`.

**`ReviewEntriesTests`** (C, JavaScriptCore)
- `reviewEntries` on a one-word change gives one removed and one added
  entry, a context entry either side, and gaps.
- Every entry carries a `kind`. A whitespace-only pair is noted. A new file
  is all added. A blank-lines-only hunk gives the "See Source" gap.

**`ReaderSelectionTests`** (C)
- `"null"`, malformed JSON, an empty or negative range, and an NSNull
  heading are all nil or absent.
- A full message round-trips; `text: null` decodes as a pointer.

**`CorrectionTargetTests`** (C)
- The excerpt equals the file's lines; a display block's excerpt ends with
  `$$`.
- The section comes from the selection's heading. A pointer gives the whole
  page with the pointer's section. Without either, the reading heading.
- The quote is capped at 2,000 characters.
- A generated region is `.generated`; the relation-meta line `.frontmatter`.
- A selection made at a revision older than HEAD builds the target at that
  revision: its base, excerpt and lines are the old commit's. A snapshot
  store whose marker moved since the render falls back to the whole page.
- `CorrectionBlockers`: `.describe` lists the reason for both regions; a
  snapshot store gives the Sync message for `.edit` and `.describe` and
  nothing for `.issue`; nothing GitHub-related is ever listed.

**`IssueComposerTests`** (C)
- The permalink encodes ` ` and `&`, and carries `?plain=1#L42-L44`, or
  `#L42` for one line.
- The quote is in a `text` fence one backtick longer than any run in it.
- The body ends with an empty paragraph.

**`ReaderContextMenuTests`** (C, extended)
- With a passage, the items say "Passage"; with a pointer or nothing,
  "Page".
- The group follows a separator. There are no items on a folder.

**`LineDiffTests`** (A)
- Identical texts give no hunks, with and without a final newline.
- One changed line; an insertion at the end; a deletion.
- Two distant changes give two hunks; adjacent ones merge.

**`GitNameStatusTests`** (A)
- `-z` parsing, with `R100` renames.
- Paths with spaces, `&` and non-ASCII.
- Binary detection from `--numstat -z`.

**`DiffGuardTests`** (A)
- One test per rule, firing and not firing. The copied lint rules cite the
  `lint.mjs` lines they follow.
- `outsideContent`: `scripts/lint.mjs`, `CLAUDE.md`, a root `lint.log`,
  `content/Templates/X.md` and `.claude/skills/city-style/SKILL.md` all
  block; `content/References/A - B.md` and `.reductions/relations.json` do
  not.
- The checksum is checked against a real region from
  `Primitives/pseudorandom-function.md` (`865206d47c53`), copied into
  `Fixtures/review/`. A regenerated region is a note, a hand edit blocking,
  unbalanced markers blocking.
- An edit job with a regenerated `relations.json` and matching checksums has
  no blocking finding; the same for a correction gives
  `relationsJSONByHand`, a warning.
- `rawHTML` fires on a hidden `<span style="display:none">` and on a
  comment; not on the generated markers, nor on `$a <b$`.
- A deletion's `renamedOrDeleted` message says "Restore the file."
- Findings are sorted, blocking first. The family switches `largeEdit` and
  `otherPages` for `ingestionScope`.

**`PrivateTextTests`** (A)
- The home directory, a worktree path and both token shapes are found; a
  `~/` in prose and a 20-character `ghp_` are not.

**`FactCheckQueueTests`** (A)
- `human_verified` paths are read. Malformed input gives `[]`. The live
  format (`version`, `pages`) is accepted.

**`PullRequestDraftTests`** (A)
- The handover is parsed. Without a `#` title it is nil.
- The proposal for each kind. The ingestion fallback never contains the
  PDF's path.
- The footer carries the version and the marker, and "CCwiki Dev" only in
  Dev.

**`PublishTargetTests`** (A)
- The release ignores `CCWIKI_TARGET_REPO`.
- Dev honours a valid `owner/name` and ignores an invalid one.
- The push URL's form.

**`AgentInvocationTests`** (B)
- Corrections: `--model sonnet`, or no `--model` for `""`; `--max-turns 20`;
  **no `Bash` entry at all**, and no `WebFetch` or `WebSearch`;
  `--disallowedTools` holds `Bash(git push:*)` and `Bash(gh:*)`.
- Ingestion: no `Bash(gh:*)`, and **no unscoped `Bash(git:*)`**: every git
  entry is one of §5.1's read-only subcommands.
- The sealed environment: `GH_CONFIG_DIR` points under the scratch
  directory, outside the worktree; the three token variables and
  `SSH_AUTH_SOCK` are gone; `GIT_CONFIG_COUNT` and its keys and values;
  `GIT_SSH_COMMAND` and the two askpass variables.

**`PromptCompositionTests`** (B, changed)
- `ingest.md` contains `.ccwiki/pull-request.md`, and no longer the
  instruction to run `gh pr create`.
- `correct.md`: every placeholder is filled; the page path, lines, quote,
  excerpt and request are all present; it defers to `CLAUDE.md`.
- The old `allowedTools` test now expects `Bash(gh:*)` to be **absent**.

**`PublisherTests`** (B)
- The lease is `--force-with-lease=refs/heads/x:` before the first push,
  and `:<sha>` after.
- `leaseRecovery`: absent → retry on absence; the tip equal to
  `pushingCommit`, to `pushedCommit`, or in the reflog → retry expecting it;
  unknown with no confirmed push → rename; unknown after a confirmed push →
  refuse.
- The create arguments include `--draft`, `--repo`, `--head`, `--base` and
  `--body-file`, and never `--ready`, `merge` or `--auto`.
- The commit message.

**`JobCenterTests`** (B)
- With a fake `flushEdits` that records calls, `approve`, `revert` and
  `refreshReview` flush before any git work.
- `reviewCount` leaves out an untouched edit.
- `jobs(touching:)` finds a job by its target and by its snapshot.

**`GitHubAccessTests`** (B)
- `classify` for each case; `signedIn: nil` is `.offline`, never
  `.notSignedIn`.

**`ReviewPayloadTests`** (D)
- The payload has exactly §6.3's keys.
- A change only to the frontmatter gives frontmatter lines and no hunks.
- Hunks and flags are converted to body lines with each side's own
  frontmatter length.
- A wikilink to a page added in the same diff resolves, with the kind `new`,
  and is not broken. Links are resolved over the old and new texts.

**`WordDiffTests`** and **`TextLinesTests`** (D)
- `$…$` spans stay one token.
- UTF-16 offsets are right with emoji and combining marks.

### 12.2 Integration tests, with real git

`GitReviewIntegrationTests` (B) runs only when `ToolLocator.locate(.git)`
finds git. The macOS CI runner has it but has no git identity, so the test
sets `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and
`GIT_COMMITTER_EMAIL` in its environment. It needs no network:

1. Make a temporary repository containing a page with a generated region,
   a file without a final newline, plus a bare repository as `origin`.
2. Resolve `origin/main` to a SHA and add a worktree there. Then advance
   `origin/main` by a commit.
3. Edit a line, add a file, and write `.ccwiki/pull-request.md` and
   `.ccwiki/lint.log`.
4. `snapshot` reports exactly the two files, excludes `.ccwiki/`, ignores
   the upstream commit, and has a stable digest. An untouched file, with or
   without a final newline, gives no hunk.
5. Two overlapping `refreshReview` calls give one snapshot and no failure.
6. Revert both files: the snapshot is empty.
7. The patch round-trips: remove the worktree, `addWorktree(…
   resettingBranch:to:)` and `applyPatch` restore a byte-identical tree,
   and `refreshOrphanedWorktrees` never lists the job's worktree.
8. `commitStaged` collapses an agent commit, and the committed tree contains
   only the job's change.
9. The first push with the absence lease succeeds, a second push after an
   edit with `expecting:` succeeds, and a push with a stale lease is refused.
   With `pushedCommit` dropped and `pushingCommit` set, Approve recovers and
   pushes. With the branch taken in `origin` by another commit, it renames.
10. The sealed environment makes a plain `git push origin` fail.

`gh` is not exercised. Its argument builders are covered above.

### 12.3 The visual gate

New `make shots` steps, all added in Phase 0. Each is captured also in
`dark`. The maintainer runs them on a Mac before merging a track that
changes UI.

| Step | Shows |
|---|---|
| `edit:Primitives/pseudorandom-function.md` | the editor at the section in view, the preview following |
| `review:Primitives/pseudorandom-function.md` | a scripted one-word edit (` (shots)` appended to the first paragraph), reviewed in Jobs, Rendered mode |
| `review:Primitives/pseudorandom-function.md`, then `source` | the same, Source mode. `source` is a step of its own, like `dark`, because the plan separates steps with commas |
| `describe:Primitives/pseudorandom-function.md` | the Describe sheet over the reader |
| `issue:Primitives/pseudorandom-function.md` | the Issue sheet with the composed text |

Teardown discards the scripted job, so no shots run leaves a worktree behind.

**Check by hand, because no test can:**

- a right-click on a paragraph with nothing selected shows the menu titled
  "Page"; with a selection, "Passage"; a right-click outside a selection,
  "Page" (§3.3);
- added and removed entries are told apart without colour, by their Before
  and After labels, and VoiceOver reads them as removed and added;
- a removed formula stays legible;
- the PR form never covers the diff at the window's minimum size;
- the editor's preview tracks the cursor;
- the context strip's quote truncates without reflowing;
- the Dev footer line is visible before Open Draft PR, not after;
- a restored editor window reappears after a relaunch, and one restored with
  no reader window loads its file (it runs `launchIfNeeded`, §17);
- ⌘↩ in the Describe sheet, the Issue sheet, IngestSheet and a palette
  presses that sheet's button, not the disabled Review Changes item. If the
  menu item takes it, Review Changes loses its shortcut.

---

## 13. Risks

- **None of this has run on a Mac.**
  - `NSTextView` inside an `NSViewRepresentable`, and `HSplitView` and
    `VSplitView` hosted in `WindowGroup(for:)`, are the constraint-engine
    territory of SWIFTUI-RULES §1. No view here is inserted with a
    transition. Panes hide by width.
  - Window restoration with a value is unverified.
  - Three `WKWebView`s at once (reader, review, one per editor) cost a
    content process each.
  - The right-click rule (§3.3) depends on WebKit dispatching `mousedown`
    before its contextual selection. It is the first thing to check by hand.
  - JavaScriptCore loading the vendored UMD bundles is unverified;
    `SourceStampTests` fails loudly if it cannot.
- **The seal is not a sandbox** (§5.1). Ingestion reads untrusted papers and
  keeps `node`. The tripwire reports a push or a PR CCwiki did not make; it
  cannot undo one.
- **CLI flags.** `--disallowedTools`, the `Bash(git push:*)` prefix rule,
  `--model sonnet`, `--strict-mcp-config` and `--setting-sources project`
  are from the CLI's documented surface, not from a run. Confirm each
  against `claude --help` on the first live job, an ingestion and a
  correction both, and watch that job. If a flag is refused, the job fails
  visibly at start, and the environment seal still holds.
  `--setting-sources project` also leaves out an `env` block or an
  `apiKeyHelper` in the user's own `~/.claude/settings.json`: a maintainer
  who reaches Claude that way (a provider or a key set there) finds the
  first job failing to sign in, and must set it where the app's
  environment, or the CLI's own login, provides it.
  **Path-scoped rules** (`Edit(./content/<path>)`,
  `Write(./.ccwiki/pull-request.md)`, with `--permission-mode default`) would
  enforce the one-page rule before the fact. Adopt them once that first run
  shows the CLI accepts path rules in `--allowedTools`, paths with spaces
  included; until then the rule is enforced at review.
- **git's config environment.** `GIT_CONFIG_COUNT` needs git ≥ 2.31. Apple's
  is 2.39. An older Homebrew git would ignore it, and only the deny-list
  would stand. The integration test fails loudly on such a runner.
- **Tracked build output.** `tsconfig.tsbuildinfo` is tracked in the wiki
  though `.gitignore` names it. If an ingestion's build step touches it,
  `outsideContent` blocks the job until Revert File. That is correct, and
  may be a nuisance; if it happens often, the snapshot could revert that one
  file itself.
- **The block mapping.** It is block-precise, not character-precise. A
  wrapped list item or a pseudocode line maps to its whole block. Footnote
  definitions and raw HTML may have no map. Those fall back to the
  nearest stamped ancestor, or to the whole page.
- **The Rendered mode can mislead.** For a change to whitespace or to
  invisible markup, the before and after look the same. The "Whitespace
  only" note and `rawHTML` (which opens Source) cover the known cases, and
  the Source mode is always one click away.
- **`derivedFilesStale`.** It leaves CI red on any PR that changes relation
  frontmatter, until someone runs the generator. `paper-submission.md` says
  the wiki's PR checks are currently disabled, which makes the warning matter
  more, not less.
- **A race the digest does not close.** A change to the worktree from outside
  CCwiki between the last render and the click makes Approve refuse with
  "The files changed since you reviewed them", which is safe, though mildly
  surprising.
- **The ingestion prompt's new precedence sentence.** It overrides
  `paper-submission.md` on one topic. If the wiki rewrites its Step 5, the
  sentence must still read correctly. PromptCompositionTests pins the
  handover path, not the wiki's wording.

## 14. Deliberately not in this version

- **"Check this page"**, the read-only pass that hunts for errors. The
  maintainer left it out. When it comes, it should read `.fact-check/` and
  `.orchestrator/prompts/skeptical-checker.md` first, as roadmap §3 says.
- **Fork-based PRs** for readers without push access. Corrections need write
  access, as ingestion does. Issues work for any signed-in account.
- **Regenerating derived files** (`npm ci` plus `generate-relations.mjs`)
  inside CCwiki. A warning instead (§6.2).
- **Copying more of the lint.** `edge-unresolved-id` needs the manifest and
  the ids a diff declares; ingestion runs the real lint, and an edit rarely
  touches `hypotheses`. Each copied rule is a rule that can drift.
- **The endpoint pages' definitions shown beside a proposed relation**
  (roadmap §1.2, in full). The review links each endpoint; reading its
  `## Syntax` there would mean a second pane of rendered excerpts.
- **Rebasing a job onto a newer `main`.** `changedUpstream` warns, and
  GitHub shows the conflict.
- **Deleting a pushed branch, or closing a PR, on Discard.** CCwiki never
  deletes anything on GitHub.
- **Filing findings into the wiki's `.review/inbox/`** instead of an issue.
  The review pipeline accepts files there from the maintainer, so it would
  fit, but it is a change to the repository and so a PR. The maintainer
  chose issues.
- **Labels, assignees and issue templates.** The wiki defines none.
- **Notifications** when a job awaits review. The Dock badge and the status
  bar's count are the affordances.
- **Line numbers in the editor's gutter.** The status line gives line and
  column.

## 15. The maintainer's questions, as settled and built

1. **The default model for corrections.** *Settled: Sonnet.* Haiku is
   cheaper, but a mangled macro in a security definition costs more than the
   difference. All four choices are in Settings → Jobs: Sonnet, Haiku, Opus,
   and the CLI's default.
2. **Should the correction agent have `WebFetch`, to check a cited paper?**
   *Settled: no, not in this version.* It turns a job of seconds and
   cents into minutes and dollars. The prompt tells the agent to abort and
   say what to check.
3. **The title prefix.** *Settled: `[fix]`*, mirroring the wiki's
   `[paper]`, in the title and the commit subject.
4. **Draft or ready for review?** *Settled: draft.* You have approved
   it, but "never ready-for-review" is a non-negotiable in PLAN.md §3, and CI
   runs on drafts.
5. **Where CCwiki Dev publishes.** *Settled: the same repository, said
   at every step (§10).* The alternative is a standing sandbox repository.
   `CCWIKI_TARGET_REPO=owner/name` points a Dev build at a fork for
   testing.
6. **Should CCwiki regenerate derived files?** *Settled: not yet.* Warn,
   and build it if the warning fires often.
7. **A `reader-report` label on the wiki.** *Settled: none for now.*
   CCwiki passes no `--label` (§8.2). The wiki defines no such label, and
   `--label` fails on a missing one.
8. **⌥⌘E for Edit Page.** *Settled: yes.* It is the only free chord near
   ⇧⌘E that reads as Edit.

## 16. Review notes (2026-10-12)

Three critics (architecture, macOS UX, safety and honesty) reviewed the first
draft. Every finding was checked against the code and the wiki. Most were
right and are folded in above; the largest were that a quit cancelled every
review (`cancelActiveJobs` and `Job.cancel()` act on any non-terminal job),
that `Subprocess.run` mangles `git show` output, that `LogWriter` truncates,
that history loaded after restored windows, that the seal was described as
stronger than it is, and that DiffGuard's protected paths were a deny-list.
What was adapted or rejected, and why:

- **`generatedFileByHand`, blocking for `.correction` only.** Adapted. A
  maintainer who follows `derivedFilesStale`'s advice in a correction's
  worktree would still be blocked. It is now `relationsJSONByHand`, a warning
  for corrections; edit and ingestion get the `regionRegenerated` note.
- **A `make shots` step that right-clicks.** Rejected. A context menu is
  modal and `ScreenshotRunner` has no proven way to drive one in a
  `WKWebView`. It is the first item under Check by hand instead.
- **An "Edit <reduction page>…" button on a generated passage.** Rejected.
  It would need the selection's links carried through `ReaderSelection`; the
  link is one click away in the reader, and the sheet says to follow it.
- **⌘↩ for Open Draft PR** (one critic) against no shortcut (another). No
  shortcut: Review Changes brings Jobs forward, so two presses from the
  editor would publish.
- **Who owns `IngestSheet.swift`.** Phase 0, with the other corrected texts,
  not Track B, which otherwise owns no view.
- **Tripwire breadth.** Adopted both `ls-remote` over all heads and `gh pr
  list --author @me`, but other CCwiki jobs' branches are excluded and the
  wording says what CCwiki knows ("CCwiki did not push it"), because the
  maintainer may push from Terminal in the same twenty minutes.
- **Copied lint rules "with fixtures from lint.mjs's own cases".**
  `lint.mjs` has no unit cases for them. Three rules stay, named by lint id
  and citing the lines they follow; `unresolvedEndpoint` is deferred (§14)
  and the marker count joined `generatedRegionEdited`.
- **`hasLoadedHistory` for restored editors.** Not needed: history now loads
  in `JobCenter.init`, before any window exists.
- **An issue recorded as a job.** Dropped, as recommended: the sheet is its
  review and its result, and a job would need a detail view nobody designed.
  The duplicate check uses a per-sheet marker instead of a job id.
- **A line in the sync log for each issue.** Not adopted: the sync log is
  cleared at every sync, so it is no record. The issue on GitHub is.

## 17. Seams with the rest of the batch

Two other specs are built beside this one, from the same base:
[relations-followups.md](relations-followups.md) and
[reader-comforts.md](reader-comforts.md). **They merge to `main` in that
order, and this one last** (reader-comforts §10 gives the reasons, and the
menus and shortcuts after all three).

- relations-followups shares only `CCwikiApp.swift` (an Edit-menu group
  and a `@FocusedValue`, beside this spec's Jobs items) and design-system
  §4's table. Both are additive.
- reader-comforts moves everything about the page being read from
  `AppModel` into a per-window `ReaderSession`. It adds window scenes and a
  once-per-process launch, and changes `WebController`'s initialiser and
  link callback.

The tracks build against today's code, as §11 says. When the integrator
rebases `claude/page-corrections` onto `main`, it makes the changes below.

**Per window** (reader-comforts §1.2: per-page state belongs in
`ReaderSession`):

- `ReaderSession.swift` gains `var correctionSheet: CorrectionSheetRequest?`.
  Its `init` wires its own `webController.onCorrect` and
  `.correctionAvailable`, beside `siteURLProvider` and `exploreHere`. Its
  `renderCurrent` sets `request.revision`.
- `canCorrectCurrentPage` and both `beginCorrection`s move to
  `App/ReaderSession+Corrections.swift` (§11.6). `RootView` binds
  `.sheet(item: $session.correctionSheet)`, and its toolbar pull-down calls
  the session. The Wiki menu's group reads `@FocusedValue(\.readerSession)`.
- The editor request stays on `AppModel`. Each reader window's `RootView`
  observes `editorWindowRequestCount`, beside the Jobs and Settings hooks;
  the first to call `takeEditorRequest()` opens the editor, and the others
  find nil.
- "N awaiting review" in the status bar reads `model.jobCenter.reviewCount`
  and is the same in every window, like the job count.
- reader-comforts' A3 grep gate is run again. `ReviewView` and
  `EditorWindow` are added to its exceptions, since they are not readers.
  `CorrectionSheet` and `IssueSheet` read the session.

**The revision.** A sync no longer re-renders tabs it did not touch, so the
target is built at the shown revision (§3.5), never compared with HEAD.

**Windows** (reader-comforts §1.3, §1.7, §1.8):

- The editor scene comes after the reader's `WindowGroup`, which stays the
  first scene. It gets `.handlesExternalEvents(matching: [])`, so a
  `ccwiki://` link never opens an editor. Its `WindowReader` sets
  `tabbingIdentifier = "ccwiki.editor"`, so editors tab with editors, never
  with readers.
- The editor's and the Jobs scene's content set `appDelegate.model = model`
  on appear and run `.task { await model.launchIfNeeded() }`. Without them,
  an editor or a review restored with no reader window has no git, and a
  quit with unsaved text or a publishing job does not ask.
- `launchIfNeeded()` loses its `loadJobHistory()` step (§4.3).
- `reviewWeb` and each `EditorSession.preview` are made with
  `WebController(paths:webRoot:pageZoom:)`, from `model.webRoot` and
  `model.pageZoom`, so they share `sharedDataStore`. Phase 0's `webRoot` is
  reader-comforts' declaration, and one copy is dropped. `ReviewView` and
  `EditorWindow` follow `model.pageZoom` with `.onChange`.
- Their `onNavigate` takes a `LinkDisposition`. `.onSite` opens the page on
  cryptology.city. Anything else follows the explorer's rule:
  `model.navigate(to:)`, which renders in the active reader without bringing
  it forward, and with `mainWindowCount == 0` first `openWindow(id:
  CCwikiApp.mainWindowID, value: ReaderWindow())`. So their link menus
  offer no new tab or window, only Open Link on cryptology.city
  (`WebController.opensLinksInTabs` is a reader's alone).

**Jobs:**

- The library load's job housekeeping (reader-comforts §3.2) calls the
  forwarders Phase 0 keeps: `refreshOrphanedWorktrees()` and
  `orphanedWorktrees`.
- The queue's **Ingest a Paper** and the empty state's action both call
  `model.requestIngestSheet(in: nil)`.
- `ScreenshotRunner` is `run(model:session:openWindow:)`. The `describe:`
  and `issue:` steps set the session's `correctionSheet`. `edit:` and
  `review:` keep the model's request calls. shots.sh's
  `-ApplePersistenceIgnoreState YES` also keeps restored editors out of a
  capture.

**The web view, shared with reader-comforts Track B.** `ReaderContextTarget`
ends with `link` and then `selection`. The `contextTarget` message and the
`mousedown` listeners are as §3.3 says. The reader's context menu ends with
this spec's group, after the page group (reader-comforts §10).
reader-comforts edits only `ccwiki.js`'s event handlers, which stay in that
file when §3.2 moves the Markdown half out. Both specs add test functions
to `ReaderContextMenuTests`.

**Shared code.** `WikiIndex.assemble(contentRoot:files:pages:)` is defined
once (§11.6). If reader-comforts built D6, Track D's copy is deleted. The
new `GitService` methods sit apart from reader-comforts' (§11.3).

**Words and versions.** "Correction" here is a change a reader proposes to
a wiki page. The explorer's section for the curation's effects, which
relations-followups first called "Corrections CCwiki applied", is
"Adjustments" (decided 2026-10-12), so the word means one thing in the app.
This spec says "0.3" for the release that ships it; nothing in the code
depends on the number.
