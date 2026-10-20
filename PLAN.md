# CCwiki

**A native macOS reader for the [cryptology.city](https://cryptology.city) wiki,
and a launcher for headless agent jobs that ingest papers and open PRs against
it.**

This file is the index. Depth lives in [plans/](plans/); the running log lives in
[PROGRESS.md](PROGRESS.md). A future agent should be able to read this file plus
`PROGRESS.md` and be up to speed.

---

## 1. What it is, in one paragraph

CCwiki is a *client* of `axhoover/cryptology.city`. The GitHub repo is the only
canonical store; the app owns no content. It keeps a pull-only git clone in
Application Support, renders pages offline with a vendored Markdown + KaTeX +
pseudocode.js pipeline in a `WKWebView`, and resolves `[[wikilinks]]` by porting
Quartz's own slug rules exactly. Separately, it runs `claude` in throwaway git
worktrees to draft paper-ingestion PRs — always draft, never merged.

## 2. Getting started

```sh
make check     # compile + 101 unit tests — run this after every change
make run       # build the .app and launch it
make shots     # drive the app and capture screenshots (the visual gate)
make help      # everything else
```

First launch clones the wiki (~35 MB) into
`~/Library/Application Support/CCwiki/repo` and builds the search index. After
that, reading needs no network. A build from source is **CCwiki Dev**
(`build/CCwiki Dev.app`, bundle id `com.axhoover.ccwiki.dev`), which keeps its
own clone, index and settings under `CCwiki-Dev`, so it runs beside the
installed release without touching it ([plans/build-system.md](plans/build-system.md)).
Setup details are in [README.md](README.md).

## 3. The non-negotiables

These are architectural constraints, not preferences. Changing one is a
redesign, not a refactor.

| Constraint | Why | Where |
|---|---|---|
| The clone is **pull-only** | The app is a reader; a dirty reader checkout is a bug with no good recovery | `GitService.sync` uses `--ff-only` and says so loudly when it fails |
| **Reading needs nothing installed** | A Mac without the Command Line Tools has no working `git`, and a reader must not be asked to install them | `SnapshotService` fetches a tarball of the branch head when there is no `git`; same layout, plus a marker naming the commit |
| A release is **signed with the maintainer's Ed25519 key**, and the app installs nothing it cannot verify | There is no Developer ID; the signature is what makes an update trustworthy | `ReleaseKey`, `UpdateInstaller`, `make package`; see [plans/distribution.md](plans/distribution.md) §3 |
| Jobs run in **git worktrees** | A job cannot dirty the reader's checkout, and jobs can run in parallel | `GitService.addWorktree`, `AppPaths.worktrees` |
| Rendering is **fully offline** | Reading must work on a plane | Vendored into `Resources/web/`; a CSP header and a scheme handler make it structural, not aspirational |
| The **search index is derived** | Never authoritative, safe to delete at any time | `SearchIndex.reset()` is a legitimate answer to any problem |
| **PDFs never enter the repo** | They are job inputs; References pages point at eprint/arXiv/DOI | `AppPaths.library` sits outside the clone |
| **Never merge a PR** | The app's job ends at "draft PR opened" | `Publisher` opens a draft with `gh pr create --draft`; nothing in CCwiki runs `gh pr merge` or `gh pr ready`. See [plans/corrections.md](plans/corrections.md) §6.5 |
| **Nothing reaches GitHub without an approval** | An agent, or a slip in the editor, must not be able to publish; the maintainer reads the diff first | Every job stops in `awaitingReview`; only `JobCenter.approve` → `Publisher` pushes. Agent jobs run sealed (no `gh` or push credentials) and a `Tripwire` checks for anything CCwiki did not push; `prompts/ingest.md` Step 6 hands over instead of pushing. See [plans/corrections.md](plans/corrections.md) §5–§6 |
| **House style is never compiled in** | The wiki maintains its own ingestion contract, and a snapshot of it in a Mac app goes stale immediately | `PromptComposer` fills placeholders only; the rules are read from the worktree |
| A reduction is a **hyperedge, never a pair** | `hypotheses` is a conjunction. Flattening `{sparse-lpn, ddh} ⇒ she` into two object-to-object edges asserts two implications the wiki does not make — a false mathematical claim, not a rendering shortcut | No API in `RelationsManifest` returns a `(from, to)` pair; see [plans/relations.md](plans/relations.md) §1 |

## 4. Where things live

```
.
├── Makefile                 the entry point for everything — `make help`
├── build.sh                 swift build → .app bundle → codesign
├── prompts/ingest.md        the agent prompt template for an ingestion job
├── prompts/correct.md       the agent prompt template for a described correction
├── scripts/
│   ├── vendor-web.sh        fetch the pinned offline render pipeline (run once)
│   ├── shots.sh             drive the app and capture screenshots
│   ├── window-id.swift      helper for shots.sh
│   ├── derivations_reference.py  the derivation engine's spec, executable;
│   │                        writes Tests/CCwikiTests/Fixtures/derivations-golden.json
│   └── make-icon.swift      generates build/AppIcon.icns
├── Resources/
│   ├── Info.plist
│   ├── derivation-curation.json  reviewed corrections to relations.json that
│   │                        the derivation engine reads (plans/derivations.md §2a)
│   └── web/                 the reader: index.html, app.css, ccwiki-markdown.js
│                            (the DOM-free Markdown half), ccwiki.js, vendor/
├── CCwiki/                CCwiki.entitlements (NOT sandboxed — see §5)
├── Sources/CCwiki/
│   ├── App/                 CCwikiApp, AppModel, AppPaths, JobCenter, EditorSession,
│   │                        Theme, ScreenshotRunner
│   ├── Wiki/                pure, testable: slugs, wikilinks and markdown links,
│   │                        frontmatter, macros, index, the relations manifest,
│   │                        and the site's relation-meta line (RelationMeta)
│   ├── Reader/              the WKWebView, its scheme handler, and the render request
│   ├── Search/              SQLite FTS5, the ⌘S and ⇧⌘R rankers, ⇧⌘F grep, the quick switcher
│   ├── Corrections/         pure: CorrectionTarget, SourceLineMap, IssueComposer
│   ├── Jobs/                subprocess plumbing, tool discovery, git; the ingestion
│   │                        and correction runners, the review snapshot, DiffGuard,
│   │                        Publisher, Tripwire
│   └── UI/                  the SwiftUI views
└── Tests/CCwikiTests/     about 870 tests (2026-10-12); see §6
```

## 5. Documentation index

- [plans/architecture.md](plans/architecture.md) — the layers, what each owns,
  and the path from `git pull` to a rendered page.
- [plans/wiki-model.md](plans/wiki-model.md) — the Quartz slug port, wikilink
  resolution, the frontmatter subset, and the macro table. **The fiddliest code
  in the app and the most heavily tested.**
- [plans/render-pipeline.md](plans/render-pipeline.md) — the vendored JS, why
  each package, the `ccwiki://` scheme handler, the CSP, and how LaTeX is
  copied (⌘C, the context menu, the pseudocode copy row).
- [plans/search.md](plans/search.md) — the FTS5 schema, tokenizer choices,
  query escaping, and the ranking backlog.
- [plans/search-v2.md](plans/search-v2.md) — **shipped in 0.1.2**: three searches (⌘S concepts, ⇧⌘F literal, ⇧⌘R
  references), the generated relevance test set CI reports on, the ranking
  rules and measurements for ⌘S (§6.4) and ⇧⌘R (§6.5), ⇧⌘F's literal
  search (§6.6), ⌘S's typo correction (§6.7), and joined or split words
  (§6.8).
- [plans/relations.md](plans/relations.md) — how `relations.json` is consumed:
  the hyperedge rule, the class partial order and which way it points, variants
  ("Host § Title"), heuristic candidates, circumventions, rationale, and how
  every "we do not know" value is displayed honestly.
- [plans/derivations.md](plans/derivations.md) — **built on
  `claude/relations-explorer`, revised after a red team**: what CCwiki may conclude by chaining recorded
  reductions. Fourteen rules (conjunction-respecting Horn closure, the default
  model filter, no free or unstated step after an idealised-model step, chain
  class by composition, conflicts checked against any derivation, derived
  barriers only when sound, preconditions and weakened notions the manifest
  does not record, refuted assumptions), the curation file that supplies
  them (§2a), the Swift `Derivation` API, UI wording, residual risks (§10),
  the review's dispositions (§11), and the golden file the corpus test
  checks. Reference implementation: `scripts/derivations_reference.py`
  (`--selftest`, `--lint WIKI_ROOT`).
- [plans/relations-explorer.md](plans/relations-explorer.md) — **built on
  `claude/relations-explorer`**: the UI and integration half of derivations. The *Does A imply
  B?* explorer window (⇧⌘E), the inspector's collapsed "Derived" sections, and
  link previews on hover. It covers the honesty contract the UI enforces, the
  existing shortcut map, and a Phase 0 of shared seams. Four parallel tracks
  (engine, explorer, inspector, previews) then own disjoint files, with exact
  Swift interfaces. §6.7 lists where it differs from derivations.md.
- [plans/ingestion.md](plans/ingestion.md) — the worktree lifecycle, the prompt
  composition rule, and what CCwiki checks before and after the agent runs.
- [plans/build-system.md](plans/build-system.md) — `make` / `build.sh`, the
  release pipeline, and why the app is not sandboxed.
- [plans/design-system.md](plans/design-system.md) — the two type systems (app
  chrome vs document), the macOS idioms applied, and the visual gate.
- [plans/roadmap.md](plans/roadmap.md) — what we deliberately deferred and how
  we would build it: a better ingestion pipeline, a graph view, and smaller
  things. §1 (a human review step before the PR) and §3 (page corrections
  from the reader) are built ([corrections.md](plans/corrections.md)).
- [plans/audit-2026-09.md](plans/audit-2026-09.md) — a full read-through
  aimed at "what happens when a stranger downloads this": eight first-launch
  breakers, the correctness tail, reader usability gaps, performance, and a
  suggested order of work. **Start here for the next batch of fixes.**
- [plans/distribution.md](plans/distribution.md) — signing and notarization,
  a release workflow, and three tiers of update mechanism (an in-app check,
  a Homebrew cask, Sparkle) with what each costs in this codebase.
- [plans/relations-followups.md](plans/relations-followups.md) — **built on
  `claude/relations-followups`, first of the batch**: unmet preconditions stay refused, a
  generated review of the curation file with the wiki text each entry cites,
  the wiki's text beside each adjustment in the explorer, Copy Proof As LaTeX,
  wiki Markdown and BibTeX, and the asks for the wiki as a ready-to-apply
  document.
- [plans/curation-review.md](plans/curation-review.md) — **generated**
  (`make curation-review WIKI=…`): each of the 47 curation entries beside the
  wiki text it quotes and its effect on the golden answers. **For the
  maintainer to review.**
- [plans/wiki-asks.md](plans/wiki-asks.md) — twenty-one things the wiki could record
  so the curation can go, page by page, with
  [wiki-asks.inbox.json](plans/wiki-asks.inbox.json) for the wiki's review
  pipeline. The maintainer files them; CCwiki never writes to the wiki.
- [plans/reader-comforts.md](plans/reader-comforts.md) — **built on
  `claude/reader-comforts` (all but D6), second of the batch**: native tabs and windows, each with its own
  `ReaderSession`; a reference's paper on request, in a window of its own; and
  a library load that rebuilds only what changed.
- [plans/corrections.md](plans/corrections.md) — **built on
  `claude/page-corrections`, third of the batch**: correct a page yourself,
  have an agent draft it, or open an issue; and a review step before anything
  reaches GitHub, for every job, with DiffGuard and a rendered diff. §16 and
  §17 record the review notes and the seams with the other two specs.
- [plans/update-integrity.md](plans/update-integrity.md) — why CCwiki came
  back as 0.1.0 after updates (a second copy with the same bundle id, most
  likely), and the fix: the dev and release channels (`CHANNEL`, CCwiki Dev),
  an updater that swaps in one step and deletes the old bundle, and a launch
  check that finds other copies. §1 lists the commands that tell which copy
  ran; §4 what is still unproven without a Mac.
- [plans/efficiency.md](plans/efficiency.md) — **built on
  `claude/efficiency`, and its reading features on
  `claude/reading-features`**: where a load, a sync, a derivation and a
  render spend their time on the 877-page wiki, measured first (Phase 0)
  and then cut in six file-disjoint tracks, each held equal to the code it
  replaces; §5 holds CI's timings before and after. Then three reading
  features (§3): backlinks grouped by kind that open the linking page at
  the line that mentions this one, links to a section (the site, a
  wikilink, a `ccwiki://` link), and saved pages and sections in the
  sidebar (⌘D). Each track and feature ends with an "As built" note.
- [PROGRESS.md](PROGRESS.md) — running log, newest first.
- [PROBLEMS.md](PROBLEMS.md) — things that bit us.
- [SWIFTUI-RULES.md](SWIFTUI-RULES.md) — hard-won SwiftUI rules; the code here
  follows them and cites them inline.

## 6. Testing

`make check` compiles and runs the suite. The components that carry the weight
are the ones that are exactly reproducible and silently wrong when they drift:

- **`QuartzSlugTests` / `GithubSluggerTests`** — a port of the wiki's own
  `quartz/util/path.test.ts`, assertion for assertion, plus the two slugifiers'
  divergent character rules. If these fail, the app shows links the website does
  not have.
- **`WikilinkResolutionTests`** — end-to-end resolution against a fixture wiki
  carrying one of every hazard in the real corpus: a two-owner alias, a
  case-mismatched alias, a `KEY - Title.md` filename with `&` and `(`, a folder
  with no index note, an asset embed, and wikilinks inside code fences.
- **`FuzzyMatcherTests` / `QuickSwitcherRankingTests`** — the ⌘O ranking.
- **`SubmissionSourceTests`** — the ePrint/arXiv/DOI/ECCC URL shapes people
  actually paste, and that a slug is safe as both a branch and a directory name.
- **`ClaudeStreamTests`** — `stream-json` → transcript, and the four outcomes:
  a PR URL, a deliberate abort, an error, and a non-JSON line.
- **`PromptCompositionTests`** — every placeholder is filled, and the template
  still defers to the wiki's own contract rather than restating it.
- **`RelationsTests`** — `relations.json`: that a multi-hypothesis reduction is
  never split into several rows, that `implies` is read narrower → broader (a
  live pair pins the direction, because inverting it inverts every barrier in
  the corpus), that each `kind` files under its own heading, and that every
  failure mode degrades to an empty manifest plus a diagnostic rather than a
  guess. See [plans/relations.md](plans/relations.md).
- **`CorpusTests`** — runs only when `CCWIKI_WIKI` points at a real clone
  (`make test-corpus`). Resolves all ~3,300 wikilinks in ~712 pages, validates the
  whole frontmatter schema, parses the live macro table, and checks every
  invariant `relations.json` is supposed to hold.

`make shots` is the other half of the gate: it drives the real app through a
plan of views and captures each one. See
[plans/design-system.md](plans/design-system.md).

## 7. The working agreement

- Keep this `PLAN.md` as the index; put depth in `plans/`; log in `PROGRESS.md`.
- Run `make check` after every change and `make shots` before trusting a UI one.
- You may open PRs. **Never merge to `main` yourself** — and the app must never
  merge one either.
