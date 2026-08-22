# Progress

Running log. Append an entry per meaningful change: what you did, what you
learned, what surprised you (`SWIFTUI-RULES.md` §10.1). Newest at the top.

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
