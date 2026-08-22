# Architecture

## 1. The layers

Five directories under `Sources/CCwiki/`, in dependency order. Nothing lower
imports anything higher.

| Layer | Isolation | Owns |
|---|---|---|
| `Wiki/` | none — pure value types | Slugs, wikilinks, frontmatter, macros, the page index. Fully unit-tested; see [wiki-model.md](wiki-model.md). |
| `Search/` | `actor SearchIndex` | The derived FTS5 index and the fuzzy matcher. See [search.md](search.md). |
| `Jobs/` | none — async free functions | Subprocess streaming, tool discovery, every `git` call. |
| `Reader/` | `@MainActor` | The one `WKWebView`, its scheme handler, and the request that drives it. See [render-pipeline.md](render-pipeline.md). |
| `App/` + `UI/` | `@MainActor` | `AppModel` and the SwiftUI views. |

## 2. One model, one web view

`AppModel` is a single `@Observable @MainActor` class. The expensive work —
walking the clone, parsing ~300 files, rebuilding the search index — happens off
the main actor and lands as one assignment, so the UI never sees a half-built
library.

`WebController` owns the app's only `WKWebView` and outlives the SwiftUI struct
that shows it. `WebPane.makeNSView` returns the existing instance and
`updateNSView` is deliberately empty: rendering is driven by
`controller.render(_:)`, not by view updates, because SwiftUI calls
`updateNSView` on every parent recomposition and doing work there would reset the
scroll position on every keystroke elsewhere in the window.

## 3. From `git pull` to a rendered page

```
AppModel.sync()                       single-flight; ⌘R twice does not clone twice
  └─ GitService.sync(clone:remote:)   clone, or fetch + merge --ff-only
       └─ Subprocess.lines(...)       AsyncStream<ProcessLine>, \r-aware
            └─ appendSyncLine         progress lines REPLACE, they do not stack

AppModel.loadLibrary()
  ├─ Task.detached: WikiIndex.build(contentRoot:)      glob, parse, slug, alias
  │                 index.backlinkMap()                one sweep, 673 links
  ├─ MacroTable.load(cloneRoot:)                       122 macros out of macros.ts
  ├─ GitService.modifiedDates(in:)                     ONE git log, not one per file
  └─ Task.detached: SearchIndex.rebuild(pages:)        full FTS5 rebuild

AppModel.open(.page(path:anchor:))
  ├─ reveal()                         select in the sidebar, expand its folder
  └─ PageRenderer.request(for:)        resolve every wikilink on the page → hrefs
       └─ WebController.render(_:)     evaluateJavaScript("CCwiki.render({…})")

ccwiki.js
  ├─ markdown-it with math/wikilink/heading/callout rules
  ├─ katex.renderToString per math token
  ├─ pseudocode.renderElement per pre.pseudocode, then .game-group grouping
  └─ postMessage {type:"rendered", toc:[…]}  → the inspector's outline

a click
  └─ postMessage {type:"navigate", href:"ccwiki://wiki/page/…"}
       └─ AppModel.navigate(to:)      → back to open()
```

**Cold start reads before it fetches.** `RootView.task` calls `loadLibrary()`
first and only calls `sync()` if there is nothing on disk, so a launch with no
network opens instantly on the last pull.

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
