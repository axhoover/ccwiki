# Architecture

## 1. The layers

The directories under `Sources/CCwiki/`, in dependency order. Nothing lower
imports anything higher.

| Layer | Isolation | Owns |
|---|---|---|
| `Wiki/` | none — pure value types | Slugs, wikilinks, frontmatter, macros, the page index, the relationship manifest, and the content fingerprints that say what a pull changed. Fully unit-tested; see [wiki-model.md](wiki-model.md) and [relations.md](relations.md). |
| `Search/` | `actor SearchIndex` | The derived FTS5 index and the fuzzy matcher. See [search.md](search.md). |
| `Jobs/` | none — async free functions | Subprocess streaming, tool discovery, every `git` call. |
| `Papers/` | none — value types and an async fetcher | Finding a reference's PDF from its own links, fetching it once, and keeping it in `library/papers/`, outside the clone. Above `Jobs/`, whose `IngestSubmission.Source` reads the links. See [reader-comforts.md](reader-comforts.md) §2. |
| `Reader/` | `@MainActor` | A `WKWebView` per reader window, its scheme handler, the request that drives it, and what a click means (`LinkDisposition`). See [render-pipeline.md](render-pipeline.md). |
| `App/` + `UI/` | `@MainActor` | `AppModel`, a `ReaderSession` per reader window, `PaperLibrary`, and the SwiftUI views. |

## 2. One library, one session per window

`AppModel` is a single `@Observable @MainActor` class, and it is app-wide: the
wiki, the search index, jobs, sync, updates, settings and the papers. The
expensive work — walking the clone, parsing ~880 files, decoding
`relations.json`, syncing the search index — happens off the main actor and
lands as one assignment, so the UI never sees a half-built library.

Each reader window or tab has a `ReaderSession`, also `@Observable
@MainActor`: its location, history, web view, sidebar selection, inspector and
sheets. `ReaderWindowView` claims the session from `AppModel`'s registry once
AppKit says which window it is in, puts it in the environment, and lets it go
on the window's `willCloseNotification`. Three rules hold the split together
([reader-comforts.md](reader-comforts.md) §1.2):

- A view inside a reader window reads its own window's session, from
  `@Environment(ReaderSession.self)`, never "the active one".
- A window that is not a reader (the explorer, Jobs, a paper, Settings) never
  reads a session. It opens pages through `AppModel`'s small API for the
  active reader, the one key most recently (`open`, `revealInReader`).
- `AppModel` never renders. After a load it hands each session the
  `LibraryUpdate`, and the session renders its page again only if the update
  changed something that page shows.

Each session's `WebController` owns its window's `WKWebView` and outlives the
SwiftUI struct that shows it. `WebPane.makeNSView` returns the existing instance
and `updateNSView` is deliberately empty: rendering is driven by
`controller.render(_:)`, not by view updates, because SwiftUI calls
`updateNSView` on every parent recomposition and doing work there would reset the
scroll position on every keystroke elsewhere in the window. Every reader's web
view shares one non-persistent data store (`WebController.sharedDataStore`), so
there is one network process however many tabs are open.

## 3. From `git pull` to a rendered page

```
AppModel.sync()                       single-flight; ⌘R twice does not clone twice
  ├─ GitService.sync(clone:remote:)   clone, or fetch + merge --ff-only
  │    └─ Subprocess.lines(...)       AsyncStream<ProcessLine>, \r-aware
  │         └─ appendSyncLine         progress lines REPLACE, they do not stack
  └─ LibraryRefresh.needsReload       "already up to date" at the loaded revision: no load

AppModel.loadLibrary(reason:)         serialized: one load at a time
  ├─ Task.detached: LoadedLibrary.build, or .update(previous) after a pull
  │    ├─ ContentScan.read            each file read once: its fingerprint and its page
  │    ├─ WikiIndex.assemble          slug, alias, the resolution tables
  │    ├─ manifest, labels, backlinkMap(), TextGrep, Derivation, LinkPreviews
  │    └─ LibraryChanges.between      the fingerprint difference from the last load
  ├─ LibraryRefresh.revisionFacts     meanwhile: HEAD, its date, modified dates
  │                                   (cached, range merge)
  ├─ apply(library)                   one main-actor assignment, with the dates
  ├─ async let SearchIndex.sync(…)    started, not awaited: only the rows whose
  │                                   fingerprint changed
  ├─ currentRevision again            loadedRevision, only if the commit did not move
  ├─ sessionsDidLoad(update)          each ReaderSession.libraryDidLoad: renders again
  │                                   if requiresRerender; ⌘O's list if one is up; ⇧⌘F
  ├─ await the sync → searchDidSync() ⌘S's and ⇧⌘R's open queries again
  └─ job housekeeping                 when LibraryRefresh.runsJobHousekeeping(reason)

ReaderSession.open(.page(path:anchor:))         the window's own session
  ├─ reveal()                         select in its sidebar, expand its folder
  └─ PageRenderer.request(for:)        resolve every wikilink on the page → hrefs
       └─ WebController.render(_:)     evaluateJavaScript("CCwiki.render({…})")

ccwiki.js
  ├─ markdown-it with math/wikilink/heading/callout rules
  ├─ katex.renderToString per math token
  ├─ pseudocode.renderElement per pre.pseudocode, then .game-group grouping
  └─ postMessage {type:"rendered", toc:[…]}  → the inspector's outline

a click
  └─ postMessage {type:"navigate", href:"ccwiki://wiki/page/…", command, shift, …}
       └─ ReaderSession.navigate(to:disposition:)
            ├─ here                   → back to open()
            └─ a tab or a window      → openInReader → a new ReaderSession
```

**The page does not wait for the search index**
([efficiency.md](efficiency.md), U1). Nothing a render reads is in it, so
the sessions render once git has said whether the commit moved, while the
index is still being written; a search typed meanwhile waits on the actor.
`loadLibrary` still returns only after the sync and the housekeeping.
Before U1 the page waited for both ([reader-comforts.md](reader-comforts.md)
§3.2).

**Cold start reads before it fetches.** `AppModel.launchIfNeeded()`, which
every reader window and paper window calls and which runs once per process,
calls `loadLibrary(reason: .launch)` first and only then syncs, so a launch
with no network opens instantly on the last pull. A load whose search index
already matches writes nothing, and a launch sync that finds the wiki
already up to date loads nothing again ([reader-comforts.md](reader-comforts.md)
§3).

## 4. Where resolution happens, and why

**Swift resolves; JavaScript renders.**

Link resolution has ~150 test vectors behind it and must match Quartz exactly,
so it stays in Swift. Markdown, KaTeX and pseudocode.js only exist in
JavaScript, so rendering stays there. The bridge is `RenderRequest.links`: a map
from the raw `[[…]]` text to a resolved href. Both sides parse wikilinks with
the same regex, so the keys line up by construction.

Notably the markdown is **not** rewritten before it crosses. Splicing
`[text](url)` into the source would mean editing a string that also contains
`$…$` and fenced TeX, which is exactly where escaping bugs live.

## 5. Two clones' worth of safety, from one clone

The reader's checkout at `…/CCwiki/repo` is pull-only: `--ff-only`, and a
non-fast-forward is reported as "something else wrote here" rather than merged.

Ingestion jobs get a **git worktree** at `…/CCwiki/worktrees/<job-id>` on a
fresh branch off `origin/<default>`. A worktree has its own working directory
and shares only the object database, so a job can check out, edit, commit and
push without the reader's files changing under the user's cursor — and several
jobs can run at once. See [ingestion.md](ingestion.md).

## 6. Subprocess plumbing

Everything the app shells out to is long-running and has to show its work, so it
all goes through `Subprocess.lines`, which returns an `AsyncStream<ProcessLine>`.
Three details that are easy to get wrong and are commented in the source:

- **Split on `\r` as well as `\n`.** `git --progress` terminates each update
  with `\r`; a splitter that only knows `\n` buffers an entire clone into one
  multi-megabyte "line" and the UI shows nothing until it finishes.
- **Wait for both pipes to hit EOF before reporting the exit status**, via a
  `DispatchGroup`, or the tail of the output is lost.
- **Clear `readabilityHandler` on EOF**, or the dispatch queue spins.

Cancelling the consuming task sends `SIGTERM` to the child's whole process
group and escalates to `SIGKILL` after three seconds. Foundation already gives
the child its own group, so `kill(-pid, …)` reaches `git`'s helpers and
`claude`'s node subprocesses with no risk of signalling CCwiki.

`ToolLocator` exists because a Finder-launched app inherits launchd's `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin`) — enough for `/usr/bin/git` and nothing else.
It probes the inherited `PATH`, then the usual Homebrew and `~/.local/bin`
locations, then asks a login shell as a last resort with a three-second
deadline.

## 6a. From a dropped PDF to a draft PR

```
IngestSheet / a drop on the reader
  └─ AppModel.stagePDF(from:)          copy into library/, OUTSIDE the clone
  └─ AppModel.submitIngestion(...)     → IngestJob, jobs window opens
       └─ IngestJobRunner.run(job)
            ├─ Preflight.run(...)      tooling, gh auth, push creds, duplicate page
            ├─ git worktree add        …/worktrees/<id> on ingest/<slug>
            ├─ git submodule update    cryptobib, for citation-key lookup
            ├─ PromptComposer.compose  fills prompts/ingest.md placeholders only
            ├─ claude -p … --output-format stream-json
            │    └─ ClaudeStreamParser → JobLogEntry per step → the jobs panel
            └─ outcome: opened(url) | aborted(reason) | failed | cancelled
                 └─ worktree pruned ONLY on success
```

The runner is `@MainActor` and `await`s throughout, so the job's observable
state and its transcript are mutated from one place with no locking. The work
itself is in child processes, which is where the time goes.

## 7. Concurrency notes

- `AppModel` and everything in `UI/` are `@MainActor`.
- `WikiIndex`, `WikiPage`, `MacroTable`, `RenderRequest` and `SearchHit` are
  `Sendable` value types, so a whole library snapshot crosses actor boundaries
  by copy.
- `SearchIndex` is an `actor` because the system SQLite is built
  `SQLITE_THREADSAFE=2`, where one connection may not be used from two threads
  at once. The actor *is* the serialization, so the connection opens `NOMUTEX`
  and pays no lock.
- `LineSplitter` is the one `@unchecked Sendable` in the codebase — fifteen
  lines with an `NSLock`, because the readability handler runs on a private
  dispatch queue.
- `WKNavigationDelegate`'s decision handler must be spelled
  `@escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void`. The
  obvious shorter spelling compiles with only a "nearly matches optional
  requirement" *warning* and is then never called, which silently disables every
  link interception in the app.
