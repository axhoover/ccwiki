# Progress

Running log. Append an entry per meaningful change: what you did, what you
learned, what surprised you (`SWIFTUI-RULES.md` §10.1). Newest at the top.

---

## 2026-08-22 — M2: ingestion

Drop a PDF on the reader, or paste an ePrint/arXiv/DOI/ECCC link (⇧⌘N), and
CityDesk runs `claude` in a throwaway git worktree, streams the transcript into
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

**What surprised us.**

- **`gh auth login` does not imply `git push` works.** `gh auth status` was
  healthy and `git ls-remote` succeeded, but the account's `git_protocol` is
  `ssh`, so no HTTPS credential helper existed and the push would have failed at
  the very end of a twenty-minute job. CityDesk now configures one on its **own
  clone** (`--local`, never the user's global config) and pre-flight refuses to
  start a job that could not push. The rule: anything a job needs at the end
  gets checked at the beginning.
- **The turn budget has to match the workflow.** `--max-turns 60`, copied in
  spirit from the wiki's workflow (which uses 40), was badly wrong: the first
  real run spent 54 turns before writing a single file, because our prompt adds
  four local validation steps that workflow does not have. Raised to 200; the
  real bound on a runaway is the Cancel button and the live cost readout.
- **A dry-run mode paid for itself immediately.**
  `CITYDESK_INGEST_DRY_RUN=1` runs every mechanical step — worktree,
  submodules, pre-flight, composition — and stops before the agent, writing the
  composed prompt into the transcript. It caught the credential gap and the
  prompt substitution bugs for free.

## 2026-08-22 — M1: the reader

CityDesk reads the wiki offline. `make check` (47 tests) and `make shots` both
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
tokenizer, the page index with backlinks, the `citydesk://` scheme handler and
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

## 2026-06-28 — Template scaffold (the "CityDesk" baseline)

Built the template this repo ships as:

- **Build system** lifted from the Casette app's SwiftPM-only setup and
  generalized: `Package.swift` (one exe + one test target, Swift 6 mode, no
  deps), `build.sh` (swift build → `.app` → codesign, ad-hoc fallback),
  `Makefile` (build/check/test/run/install + sign→notarize→staple→zip `dist`
  pipeline), `Resources/Info.plist`, sandboxed `CityDesk.entitlements`,
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
