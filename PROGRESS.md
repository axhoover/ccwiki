# Progress

Running log. Append an entry per meaningful change: what you did, what you
learned, what surprised you (`SWIFTUI-RULES.md` §10.1). Newest at the top.

---

## 2026-09-27 — A review pass over the branch, and what it caught

With about three thousand lines on the branch that had only ever been
compiled and unit-tested, a review of the whole diff against `main` was the
next gate. It found ten things; all are fixed and CI is green. The three
that would have bitten a real user:

- **A merged PR could be mistaken for the job's own.** `gh pr view <branch>`
  resolves a merged PR for a reused branch name, so a job that aborted would
  have been marked "opened" with a stale URL and had its worktree pruned.
  Confirmation now asks for *open* PRs on the branch created after the job
  started, with a test for the filter.
- **Reset Clone under a running job.** A worktree's metadata lives in the
  clone's `.git`; deleting the clone breaks every git step the job has left.
  Refused, and the button disabled, while a job is active.
- **The relaunch could strand the user.** It launched the new instance and
  then quit unconditionally: a launch failure left no app (with the old one
  already in the Trash), and answering "Don't Quit" to the running-jobs
  question left two instances on one clone and one search index. The jobs
  question now comes first, and the quit only after the launch succeeded.

The one worth a rule: **an in-place bundle swap changes what the running
app reads from disk.** A WebContent restart after an update would have
loaded the new release's `ccwiki.js` against the old Swift. The render
pipeline is now served from a per-build copy in Caches made at launch, so
the pair stays matched until the relaunch. (`prompts/ingest.md` is still
read from the bundle at job start; a job started after an update composes
the new prompt. Noted, not fixed.)

The rest: a false success when an install was already in flight; a manual
check erasing the "installed, relaunch" note; a pid-registry race for
short-lived children; `dist` and `package` unsafe under `make -j`; and the
same download and request code in four places, now one `GitHubHTTP`.

## 2026-09-27 — Reading needs nothing installed

The audit's first finding, closed for real: a Mac without Apple's Command
Line Tools has no working `git`, and the reader used to fail at the first
sync with a git-flavoured error. `SnapshotService` now fetches the wiki
without git: one request to GitHub's branch API for the head commit, the
tarball of *that* commit from codeload (so the marker and the content cannot
disagree), unpacked with the `tar` in every Mac's base system, moved into
place atomically, with a `.ccwiki-snapshot` marker naming the commit. The
layout is a clone's, so `WikiIndex`, `MacroTable` and `RelationsManifest`
read it unchanged, and the status bar dates the wiki from the marker.

**The decision that kept it small:** the snapshot reports the same
`SyncOutcome` cases as `GitService.sync`, so `AppModel.sync` only chooses
which service to call. When git turns up later, the ordinary clone path
replaces the snapshot — it lands beside it and is moved in only on success,
so a failed clone never costs a working copy. The one dead end is a clone
with no git left to update it, which says so and points at Reset Clone.

**What changed for the reader:** the Command Line Tools state is gone from
the empty view; Settings > Tools still offers the installer, for jobs. The
`requiredForReading` notion left `ToolLocator` with it.

**Also in this batch:** PDF as an alternate document type and `ccwiki://` as
a URL scheme, both through `onOpenURL`; ⌘-click opens the page on the site
(the app has one reader window, so that is what "open elsewhere" means);
the broken-link banner behind a Reading preference, off by default; and
three long-tail fixes from the audit (§1.10, §1.12, §2.5).

**Not verified here:** the snapshot's download and unpack need a network and
a Mac. The marker, the branch-API parsing, the unpacked-root rule and the
outage classification have tests.

## 2026-09-27 — The app updates itself, and no Developer ID is involved

**The question that changed the plan.** The distribution plan said a
Developer ID was the price of admission. Asked whether it really was, the
honest answer turned out to be: only for a frictionless *first*
double-click. Gatekeeper assesses only files carrying the quarantine
attribute, which browsers add and an app's own `URLSession` download does
not (CCwiki does not opt in to `LSFileQuarantineEnabled`). A bundle the app
fetches and unpacks itself is ad-hoc signed and unquarantined, and launches
exactly like the one `make install` put there. So the first install costs
one trip to Privacy & Security, and every update after it costs nothing.
The maintainer chose that trade.

**What stands in for Apple's signature** is an Ed25519 signature over the
release zip, made with a key only the maintainer holds and checked against
the public half built into the app (`ReleaseKey.swift`). CryptoKit does it
with no dependency. TLS to github.com protects the transport; the signature
protects against a compromised GitHub account, which a `.sha256` beside the
zip never did. `make release-keys` makes the pair once and embeds the public
key; it refuses to run twice, because replacing the key orphans every
installed copy.

**The installer's order is the safety argument.** Download both files to a
temporary directory; verify before unpacking; unpack with `ditto`; check the
bundle identifier, the version the release promised, and `codesign
--verify --deep --strict`; only then move the running bundle aside, the new
one in, and the old one to the Trash, undoing the first move if the second
fails. Relaunch is a separate, user-initiated step
(`NSWorkspace.OpenConfiguration.createsNewApplicationInstance`, then
terminate). It never installs while a job is running.

**Two release paths share one artifact.** `make package` (ad-hoc, universal,
Ed25519-signed) and `make dist` (Developer ID, notarized, and now also
Ed25519-signed) both produce `CCwiki-<v>-macos.zip` plus `.sha256` and
`.sig`; `make github-release` uploads all three, and refuses without the
`.sig`, since the app installs nothing without it. `release.yml` runs the
package path on a tag push with the key as a repository secret.

**Not verified here:** the download, unpack and swap need a real release
and a real Mac. The signature check, the `.sig` format, bundle inspection
and asset selection have unit tests. The first real release is the test of
the rest, and the plan says to do it from the laptop once before trusting
the workflow.

**What surprised me.** `ReleaseInfo` needed to become partly mutable
(`var archiveURL: URL? = nil`) to keep its memberwise initializer usable
with and without assets; a `let` with a default is excluded from it.

## 2026-09-26 — Block A and most of Block B, verified by a new CI workflow

The audit's fixes, in five batches on `claude/amazing-curie-swfkbd`. The
table in [plans/audit-2026-09.md](plans/audit-2026-09.md) §6 says which item
each batch closed; what follows is what was learned doing it.

**The review machine had no Swift toolchain, so CI became the compiler.**
`.github/workflows/ci.yml` runs `make check` on a `macos-15` runner in about
half a minute, and every batch was pushed, read back from the runner's log,
and fixed before the next. Three things it caught that reading did not:

- swift-testing's `#expect` evaluates a call inside a closure over an
  *immutable* copy, so `#expect(history.visit(x))` on a mutating method does
  not compile. Hoist the call into a `let` first.
- `NSLock.lock()` is unavailable from an async context. `withLock` is the
  form Swift 6 accepts there.
- An off-by-one in a bounded-history test: the first visit records nothing.
- `swift build --arch arm64 --arch x86_64` fails with "duplicate output
  file" on the runner's toolchain. One build per architecture and
  `lipo -create` is what `build.sh` does now, and CI assembles the universal
  `.app` on every push and uploads it as a 14-day artifact.

**The visual gate has not run.** Every UI change here — the sync log sheet,
the Command Line Tools state, the blockers list in the ingest sheet, the
Updates section, the trimmed context menu — compiles and is reasoned about,
and none has been looked at. `make shots` on a Mac is the next step before
trusting any of them.

**Decisions worth recording.**

- **Macros travel with every render** rather than being re-injected as a user
  script. The JS compares a canonical key of the table and rebuilds
  markdown-it only when it differs, so the cost in the common case is a sort
  of 122 keys. This removed the "must be known before the web view is built"
  constraint entirely.
- **The git stub is detected with `xcode-select -p`, never with `git
  --version`.** On a Mac without the Command Line Tools the latter pops the
  system installer, and a check that runs at every launch would pop it at
  every launch.
- **Tool discovery is two phases.** `git` is one `stat` and is all the reader
  needs, so the launch task awaits it and goes on; the ingestion tools, which
  may each cost a login shell, are found afterwards. A generation counter
  keeps a re-discovery started from Settings from being overwritten by a
  slower one that started earlier.
- **`NavigationHistory` is its own type** so the rule that was wrong — asking
  for the current page without an anchor is not a visit — has a test that
  needs no web view. The sidebar observer was left as it was; the model
  simply no longer treats its re-selection as a move.
- **The update check is tier 1 and nothing more.** One request, a numeric
  comparison, a link. It is inert until a release exists, and a `0.0.0`
  build never asks. The decision not to build Sparkle is in
  [plans/distribution.md](plans/distribution.md) §3 with its cost.
- **Job records are written on every state change**, not at the end, so a
  crash mid-run comes back as "Interrupted" rather than vanishing. The
  transcript file is pointed at, not re-parsed; that half is still open.
- **Indented code blocks are still not inert for the wikilink parser**,
  deliberately: a nested list item is indented four spaces too, and hiding
  its links would be worse than the bug.

**What surprised me.**

- `AppKit`'s default `WKWebView` context menu carries Back, Forward and
  Reload, and Reload blanked the reader for good. Overriding
  `willOpenMenu(_:with:)` on a subclass and dropping the items by their
  `WKMenuItemIdentifier…` identifiers is the whole fix; the crash-recovery
  path (`webViewWebContentProcessDidTerminate` plus an `onReady` re-render)
  makes a stray Reload survivable anyway.
- Quartz strips `%% comments %%` over the whole source before anything else
  reads it, fences included. The per-line masking here was subtly different
  in two ways; the fix was to use its regex on the whole text and delete the
  per-line logic rather than reconcile them.

## 2026-09-26 — Audit for a public download; the distribution plan

No app code changed. Two plans and one Makefile fix.

**The question was "what would we work on next to turn this into something
people download".** Answered by reading every source file against that
scenario rather than against the developer who has been using it. The result
is [plans/audit-2026-09.md](plans/audit-2026-09.md): eight things that break
a stranger's first launch, a correctness tail, reader usability gaps, the
performance items that scale with the corpus, and an ordered list of PR-sized
work. [plans/distribution.md](plans/distribution.md) covers signing,
notarization, a release workflow, and three tiers of update mechanism.

**The three findings that matter most**, because they hit the exact path a
non-developer takes (launch → auto-clone → read):

- **Reading requires git, and a fresh Mac's `/usr/bin/git` is Apple's
  install-the-developer-tools stub.** It passes `isExecutableFile`, so the
  app raises no warning and the clone fails with "exit 1, see the sync log",
  and the sync log is shown nowhere. The short fix is to detect the stub and
  offer `xcode-select --install`; the real one is to fetch a tarball of
  `main` with `/usr/bin/tar`, which is base-OS, so the reader needs no
  developer tools at all.
- **First launch renders every page with broken macros and never says so.**
  `macros.ts` is read before the clone exists and baked into a
  `documentStart` script that is never rebuilt. After the clone, the model
  has 122 macros and drops its warning; the web view still has none.
- **The Makefile's release identity was the template author's.** `make dist`
  would have failed at `sign` on its first run. Fixed on this branch:
  `CERT_NAME` derives from `DEVELOPER_NAME` and the notary profile is
  `ccwiki-notary`. The entitlements also carry two hardened-runtime
  exceptions justified by "we spawn git and claude", which is not what those
  entitlements govern; the plan says to drop them and verify on a notarized
  build.

**On updates.** The worry was a complicated pipeline. The recommendation is
the opposite: a daily call to the GitHub releases API with an "update
available" line in About, and a Homebrew cask so `brew upgrade` does the
rest. Sparkle is written up with its real cost here (a framework in a
hand-assembled bundle, inside-out signing, an appcast) and deferred until
there is evidence people stay on old versions.

**What surprised me.**

- Following any `[[page#heading]]` link across pages corrupts back/forward:
  the sidebar's selection observer re-opens the page without the anchor,
  which counts as a new location, so the anchored entry is pushed twice and
  Forward is wiped. Thirteen corpus links and every Relations-pane variant
  take that path. No history test exists.
- Launch does up to nine seconds of main-thread busy-waiting on a Mac
  without `gh`, `claude` and `node`, which is every non-developer's Mac,
  plus a blocking `gh auth status` network call before the first frame.
- `"unable to access"` in the offline detector matches every HTTP error git
  reports, so a 403 or a certificate problem shows the calm wifi-slash.
- The review machine had no Swift toolchain, so every line reference was
  read, not run. `make check` and `make shots` on a Mac are the next step
  before any of the fixes land.

## 2026-08-24 — The wiki's relationships become data, and the ingestion prompt stops undoing them

The wiki migrated its relationship claims out of prose and into first-class
reduction and barrier pages, plus a generated manifest at
`.reductions/relations.json`. CCwiki now consumes it. Depth in
[plans/relations.md](plans/relations.md).

**The most urgent thing was not the manifest.** Surveying for existing
relationship derivation turned up almost none — `WikiIndex.backlinkMap()` and
nothing else; no prose scraping, no hardcoded lists — but it did turn up
`prompts/ingest.md` Step 4, which *instructed the agent to append prose
relationship bullets to `# Other results`*. That is precisely the form the
migration removed, and upstream had already deleted the same instruction from
their own prompt, saying: "Left alone, every accepted submission would have
undone that migration a bullet at a time." Every ingestion job CCwiki launched
would now open a PR that fails `npm run lint`. Fixed first, before any manifest
work, by deferring to `.github/prompts/paper-submission.md` instead of
restating it — which is what the file's own design rule said to do all along,
and the rule it had quietly broken.

Two false claims went with it: the prompt asserted that CCwiki "enforces on the
diff" mechanical limits that `DiffGuard` would enforce, and `DiffGuard` has
never been built. `plans/ingestion.md` §4 still specified it in terms of bullet
formatting, so that spec was rewritten too.

**Reading the manifest from the clone, not over HTTP.** The wiki serves it at a
static URL, but `GitService.sync` already does a full clone, so the file is on
disk at the *same commit as the pages it describes*. That makes version skew
impossible rather than merely unlikely, keeps reading offline, and means there
is no refetch policy to get wrong. Same contract `MacroTable` has with
`macros.ts`.

**One row is one hyperedge.** 42 of the 343 reductions have more than one
hypothesis, and `hypotheses` is a conjunction. The guard is structural rather
than careful: no query in `RelationsManifest` returns a `(from, to)` pair, so
nothing downstream can flatten what it never receives. A corpus test asserts row
counts track edges rather than endpoint pairs.

**The class order is the part that is silently wrong if you get it backwards.**
`implies` points narrower → broader, and a barrier against class B bites a
reduction of class C iff `C implies* B`. The regression test uses a live pair —
`red-oihf-to-ot-bh26` is `free`, `bar-oihf-to-ot-bh26` is `fully-black-box`,
same hyperedge — where the correct answer is *no conflict*. Inverted, that pair
reports a contradiction. Worth knowing: **five hyperedges are shared by a
reduction and a barrier and zero conflicts fire today**, so the conflict
indicator is implemented and tested but appears nowhere. That is the honest
state.

**`make shots` earned its keep again.** The first Relations pane was
model-correct and unreadable: every row led with the object named in the section
header above it, spending two of three lines restating context and truncating
the conclusion. Rows now lead with the end of the edge you are *not* on, with
any other hypothesis named underneath as "also needs …" — the conjunction in
words. A second pass fixed section headers that folded the object name in
front of the role, so "Bounded-Error Probabilistic Polynomial-Time is contained
in" truncated to leave "contained in" and "contains" indistinguishable. Neither
bug was visible to a unit test.

**Surprises worth recording.**

- **Every one of the 131 variants has `title` equal to its own `id`.** So the
  manifest cannot name them, and the label has to come from the host page's
  heading text — which works because `WikiPage.headings()` already computes
  Quartz-identical ids.
- **The migration rewrote the host pages' prose**, pointing `# Other results`
  bullets at reduction pages rather than at endpoint pages. Page URLs did not
  change, but the backlink graph changed shape underneath: corpus links went
  from 673 to 3,277, and a primitive's Backlinks pane is now largely reduction
  slugs. That is the pane getting *worse* exactly where Relations makes it
  better — which is the argument for the new tab, not against backlinks.
- **The wiki now generates a `## Participates in` block into the markdown
  itself.** The reader renders it for free, which is why Relations is an
  inspector tab rather than an inline section: the tab carries what the
  generated block does not — kind, class, model, status, source.
- One dangling reference upstream (`bar-oihf-to-ot-bh26` names a reduction
  *slug* where an id belongs) and four propositions with empty titles. Both
  degrade rather than throw.
- `https://cryptology.city/docs/relations-json` — the manifest's own `schema`
  URL — **404s**. Only the GitHub source resolves.

**The clone gained 380 pages**, so browse had to absorb them: `Reductions/`
collapses to one row beside References (a reduction is not somewhere you browse
*to*), `Barriers/` stays an ordinary folder at 37, and `PageKind` learned both
directories — it had a dead `.reduction` case with no directory and a
`.separation` case the wiki never used.

101 tests, all green against the real corpus.

---

## 2026-08-22 — Folder listings grow up; the ingestion path stops fighting itself

**Folder pages** now carry sticky alphabetical dividers and a **Hide stubs**
checkbox, mirrored in Settings and applied to the sidebar as well. The numbers
argue for it: 19 of 38 Primitives are stubs, against 4 of 200 References — so
"hide stubs" is the difference between a page of things to read and a page of
things to write, and it is a toggle rather than a default because both are
legitimate. The listing says how many it is hiding.

**The ingestion path's space problem is fixed at the cause.** A second real job
threw three confusing symptoms — `sync-cryptobib` failing, `npm ci` "not
installed", and a denied `ln` — and every one traced to the same thing: the
worktree lived under `~/Library/Application Support`, whose space arrives as
`%20` in the wiki's own `scripts/*.mjs`, which read `import.meta.url.pathname`
without decoding it. The agent worked around it with a symlink into `/tmp`,
which then needed `ln`, which is not in the allow-list.

**The earlier fix — a warning in the prompt — was wrong, and I said so in
PROBLEMS.md.** A warning does not fix a broken path; it moves the cost onto the
agent, and it cost two jobs. Worktrees now live in
`~/Library/Caches/CCwiki/worktrees`: no space, and exactly the right semantics
for something created per job and pruned on success. Everything durable stays in
Application Support. `GitService.repairWorktrees` runs `git worktree repair` on
load, because a worktree records its own absolute path.

Verified directly: `readdirSync` on an un-decoded `import.meta.url.pathname` —
the precise call that failed — now succeeds in the new location.

**Two guardrails were also mis-modelled.** Claude Code refuses output redirection
outside the working directory and refuses compound commands where any part is
unapproved, both regardless of `--allowedTools`. That is why an allow-listed
`npm ci` never ran: it was `npm ci > /tmp/log 2>&1`. The prompt now says both
plainly, and points at the `Read` tool for PDFs instead of `pdftotext`.

## 2026-08-22 — Renamed to CCwiki; the sidebar stops treating references as peers

**Renamed** from the CityDesk working title. Target, bundle id, type names, the
`ccwiki://` scheme, the `CCWIKI_*` environment variables, and the Application
Support directory — which would have orphaned a 35 MB clone and the transcripts
of jobs that already ran, so `AppPaths` moves the old directory to the new name
on first launch.

**The icon** is now the wiki's own logo reduced to what survives being an app
icon: the purple, the concentric rings, the skyline, and CC in the middle. Two
words of wordmark are unreadable at 32 pt, so it collapses to the initials and
everything else steps back. The skyline keeps two towers and two spires, because
an even row of blocks reads as a barcode; below 32 pt it is dropped entirely.

**References left the sidebar tree.** 200 of 293 pages — 68% — are references,
so the tree was two-thirds citation store, and following a citation expanded
`References/` and scrolled the concept structure off screen. The tree is now the
93 concept pages (all five folders visible at once), references are one row that
opens the folder page in the reading pane, and a **"Cited by"** section appears
above the tree while you read a reference. Reasoning and the rejected
alternatives are in [plans/design-system.md](plans/design-system.md) §3a.

The measurement that settled it: the sidebar was least useful exactly when you
most needed it, because arriving at a reference is *always* by link, and the one
question you have on arriving is what brought you here.

## 2026-08-22 — M3: polish

The parts that only matter when something goes wrong. 68 unit tests.

**Backlinks and status badges** shipped in M1, so M3 was error states, an icon,
and the Settings window the pre-flight messages had been telling people to open
without one existing.

**Every failure now has a designed resting state**, documented in
[plans/design-system.md](plans/design-system.md) §4b. The one worth calling out:
**being offline is not a fault.** The reader works entirely from the clone, so
it gets a `wifi.slash` in tertiary grey and "reading from the last pull", not a
warning triangle. `GitService` tells an outage from a real problem by matching
git's own vocabulary — "could not resolve host", "failed to connect" — because
git reports every one of them as exit 128.

**A worktree left behind by a crash** is now found at launch, not just after the
next job finishes. Verified by making one by hand and relaunching: the app found
it, warned, and offered to prune.

**Settings** (⌘,) is deliberately small: tool paths with **Locate…**, GitHub
auth and push-credential state, the storage locations, and the vendor manifest.
Every row says what CCwiki currently believes, so the window doubles as the
answer to "why isn't this working".

**The icon** is a lowercase λ on the website's purple, standing among three
blocks. λ is the wiki's own `\secpar` — precise to this audience, unlike
anything else in a Dock, and still legible at 16 pt where the blocks are dropped
as grit.

**What surprised us.**

- **`showSettingsWindow:` does nothing for a SwiftUI `Settings` scene.** It is
  the macOS 13 selector and it silently no-ops, so the harness kept capturing
  the reader. `SWIFTUI-RULES.md` §6.4 already said the macOS 14 idiom is
  `@Environment(\.openSettings)` — which only a *view* can call, so the model
  asks with a counter and `RootView` performs it, the same shape as the jobs
  window.
- **`NSApp.keyWindow` is not the frontmost window.** A freshly opened Settings
  scene is in front without being key, so the capture fell through to the
  reader. `NSApp.orderedWindows` is front-to-back and is the right question.
- **macOS revoked the Screen Recording grant partway through.** It re-prompts
  periodically. The harness already falls back to its own capture, which renders
  everything except `NSVisualEffectView` backdrops — enough to verify a Form,
  not enough to verify a sidebar.

## 2026-08-22 — M2: ingestion

Drop a PDF on the reader, or paste an ePrint/arXiv/DOI/ECCC link (⇧⌘N), and
CCwiki runs `claude` in a throwaway git worktree, streams the transcript into
a jobs window (⇧⌘J), and ends at a **draft** PR. 61 unit tests.

**The design decision everything follows from.** The wiki already has an
ingestion contract — `.github/prompts/paper-submission.md`, 238 lines, with five
merged `[paper]` commits behind it. So `prompts/ingest.md` is an *envelope*: it
states the job, points the agent at that contract **read from the live
worktree**, and adds only what the server-side pipeline cannot run — `npm ci`,
the full lint, `npx quartz build`, `npm run sync-cryptobib`, and the diff
ceiling. `PromptComposer` fills placeholders and nothing else. If it ever grows
a paraphrase of the wiki's rules, delete it: the app would be teaching agents a
snapshot that goes stale the day the wiki's own prompt changes.

**Driving the CLI.** `--output-format stream-json` is what makes the jobs panel
a log rather than a wall of text: every event is a structured step, so the
transcript renders `Bash  npm run lint` with its result indented beneath, and
the terminal `result` event carries the turn count, the cost, and any
`permission_denials`. `--permission-mode acceptEdits` plus a **scoped**
allow-list, never `bypassPermissions` — edits inside a throwaway worktree are
safe to auto-accept, shell commands are not.

**Four terminal states, and they are not all failures.** `opened(url)` prunes
the worktree; `aborted(reason)` keeps it and is shown in orange with "that is a
good outcome", because the prompt asks the agent to decline rather than guess
and punishing that visually would teach the wrong lesson; `failed` and
`cancelled` keep the worktree and offer "Reveal in Terminal".

**The first real run, end to end.** ePrint 2026/1769 → **draft PR
[#36](https://github.com/axhoover/cryptology.city/pull/36)**: one new reference
page and two bullets on `content/Primitives/secret-sharing.md`, +31/−0. The
agent ran the full lint (294 pages, 0 errors), `npx quartz build` (clean) and
`sync-cryptobib`, then pushed and opened the PR as a draft. 59 turns, 11m 15s,
$5.46. The worktree pruned itself; the reader's clone stayed on `main`, clean.

**What surprised us.**

- **`gh auth login` does not imply `git push` works.** `gh auth status` was
  healthy and `git ls-remote` succeeded, but the account's `git_protocol` is
  `ssh`, so no HTTPS credential helper existed and the push would have failed at
  the very end of a twenty-minute job. CCwiki now configures one on its **own
  clone** (`--local`, never the user's global config) and pre-flight refuses to
  start a job that could not push. The rule: anything a job needs at the end
  gets checked at the beginning.
- **The turn budget has to match the workflow.** `--max-turns 60`, copied in
  spirit from the wiki's workflow (which uses 40), was badly wrong: the first
  real run spent 54 turns before writing a single file, because our prompt adds
  four local validation steps that workflow does not have. Raised to 200; the
  real bound on a runaway is the Cancel button and the live cost readout.
- **The allow-list matches on a command's first word.** Seven of the run's
  denials were `cd X && git …` or `ln` — all harmless, all refused, all
  costing turns. The child already starts in the worktree, so the fix was to
  say so in the prompt rather than to widen the list toward uselessness.
- **A dry-run mode paid for itself immediately.**
  `CCWIKI_INGEST_DRY_RUN=1` runs every mechanical step — worktree,
  submodules, pre-flight, composition — and stops before the agent, writing the
  composed prompt into the transcript. It caught the credential gap and the
  prompt substitution bugs for free.

## 2026-08-22 — M1: the reader

CCwiki reads the wiki offline. `make check` (47 tests) and `make shots` both
pass; screenshots are in `build/shots/`.

**Recon first.** Seven parallel agents read the wiki repo and the platform
before any code was written, and three findings changed the design:

1. **The LaTeX macros are not in `Glossary/latex-macros.md`.** That page is a
   documentation table of macro *names*. The definitions are in `macros.ts` at
   the repo root, as a TS `Record<string,string>`, and `quartz.config.ts` feeds
   that object to both `Plugin.Latex` and `Plugin.Pseudocode`. The brief said to
   inspect how the glossary page stores them; the answer is that it does not.
2. **The wiki ships a patched `pseudocode.js`** with an `\algname{...}`
   directive that upstream `pseudocode@2.4.1` does not have — and all 58
   pseudocode blocks in the corpus use it. Vendoring from npm would throw a
   parse error on every algorithm block in the wiki. `scripts/vendor-web.sh`
   pulls it from a pinned wiki commit and checks its sha256.
3. **The repo already has an ingestion prompt** —
   `.github/prompts/paper-submission.md`, 238 lines, with five merged `[paper]`
   commits behind it. So `prompts/ingest.md` here is an envelope that points the
   agent at the repo's own contract read from the live worktree, and adds only
   the local checks the server pipeline cannot run. No house style is compiled
   into the binary.

**Built.** The Quartz slug port (`path.ts` line by line, plus github-slugger),
the wikilink resolver, a YAML-subset frontmatter parser, the `macros.ts`
tokenizer, the page index with backlinks, the `ccwiki://` scheme handler and
web controller, the vendored render pipeline, SQLite FTS5 search, the fuzzy
quick-switcher, git sync, and the three-pane UI. Nine hundred lines of it are
ports; the value is in matching Quartz exactly rather than approximately.

**Gates.** `make check` = compile + 47 unit tests. `make test-corpus`
additionally resolves all 673 wikilinks in the real 293-page corpus: 660 pages,
1 asset, 6 folders, 3 same-page anchors, and exactly the 3 known dead links —
matching the recon's independent count. All 297 pages pass the frontmatter
schema check, and all 122 macros parse.

**What surprised us.**

- The quick switcher's model was correct and its *view* was stale.
  `ForEach(Array(results.enumerated()), id: \.element.id)` plus index-based
  selection meant the footer count updated on every keystroke while the rows
  kept showing the previous query. Unit tests could not have caught it; the
  screenshot gate did, on its first run. The rule is now: selection by id,
  never by index, and never enumerate into a `ForEach`.
- `screencapture` needs the Screen Recording permission, which an agent session
  does not have by default. The app grew a `ScreenshotRunner` that drives itself
  through a plan of views and hands off to `scripts/shots.sh` — which turns out
  to be a better gate than ad-hoc screenshots anyway, because it is repeatable.
- Two path bugs cost real time, both from trailing slashes and strict parsers:
  a URL built from a directory carries a trailing `/`, so the scheme handler's
  `hasPrefix(root + "/")` containment check was testing for a double slash and
  404ing every asset; and AMFI rejects `--` inside an XML comment in an
  entitlements file, surfacing as `syntax error near line 16` during codesign.

**Deliberate divergences from the website**, both documented in
`plans/wiki-model.md`: unresolved wikilinks render as visibly broken rather than
as links to nowhere, and the reference byline paragraph is hidden in the page
because the app's own reference bar carries it and stays visible while scrolling.
Everything else — including Quartz's quirks around repeated headings, `a#x#y`
anchors, and case-sensitive slug matching — is reproduced rather than fixed.

**Next: M2, ingestion.** Designed in `plans/ingestion.md`, not yet built.

## 2026-06-28 — Metabolized learnings from the first app on this template

Folded `LEARNINGS.md` (general lessons from building the first app — an
outdoor-weather feature — on this scaffold) into the permanent docs, then
deleted the copy. Where each landed:

- `SWIFTUI-RULES.md` **§5.6** — `foregroundStyle` resolves innermost-wins (a
  tinted container can host a differently-colored inline child; the corollary
  bites the "explicit `.foregroundStyle(.primary)`" habit).
- `SWIFTUI-RULES.md` **§11 Swift Charts** (new) — overlaid lines need distinct
  `series:` or they merge into one path; the x-domain is the union of all
  plotted data, so clip overlays to the primary series' window.
- `SWIFTUI-RULES.md` **§12 Concurrency** (new) — a `@MainActor` type adopting a
  delegate protocol needs an isolated conformance (`@MainActor CLLocationManagerDelegate`).
- `plans/build-system.md` — new "Permissions & capabilities" section: usage
  prompts work in this ad-hoc-signed, no-Xcode bundle given the right
  `NS…UsageDescription` keys; the sandbox decides whether a `com.apple.security.*`
  entitlement is also needed; always design the denied path.

Appended §11/§12 rather than renumbering so the existing §9/§10 cross-references
in `PLAN.md` / `PROGRESS.md` stay valid.

## 2026-06-28 — Template scaffold (the "CCwiki" baseline)

Built the template this repo ships as:

- **Build system** lifted from the Casette app's SwiftPM-only setup and
  generalized: `Package.swift` (one exe + one test target, Swift 6 mode, no
  deps), `build.sh` (swift build → `.app` → codesign, ad-hoc fallback),
  `Makefile` (build/check/test/run/install + sign→notarize→staple→zip `dist`
  pipeline), `Resources/Info.plist`, sandboxed `CCwiki.entitlements`,
  `scripts/make-icon.swift` (pure-CoreGraphics doc-and-table glyph).
- **App**: `NavigationSplitView` with a `SidebarSection` enum driving a lorem
  reading column (`ReadingView`, measure-capped) and a native sortable `Table`
  (`DataTableView`) with a reusable `StatusBadge` and a footer count. State in
  one `@Observable @MainActor AppModel`; type/metrics centralized in `Theme`.
- **`scripts/rename.sh`** — the meta feature: `cp -R` then one command renames
  target, `.app`, bundle id, dirs, and file contents.
- **Tests**: swift-testing suite covering model load + status sort ordering.
- **Docs**: this file, `PLAN.md` (index, written for the fresh-copy workflow),
  `PROBLEMS.md`, and `plans/{architecture,build-system,design-system,renaming}.md`.

Gates run: `make check` ✓, `make test` ✓ (3 tests), `make build` ✓ (icon +
signed `.app`), live launch ✓ — both destinations render correctly, app stays
alive across a sidebar switch (no constraint crash).

Design work was driven through the macos-design, typography-designer, and
swiftui-pro skills per `CLAUDE.md`, before and after writing the views.
