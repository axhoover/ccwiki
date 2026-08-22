# CityDesk

**A native macOS reader for the [cryptology.city](https://cryptology.city) wiki,
and a launcher for headless agent jobs that ingest papers and open PRs against
it.**

This file is the index. Depth lives in [plans/](plans/); the running log lives in
[PROGRESS.md](PROGRESS.md). A future agent should be able to read this file plus
`PROGRESS.md` and be up to speed.

---

## 1. What it is, in one paragraph

CityDesk is a *client* of `axhoover/cryptology.city`. The GitHub repo is the only
canonical store; the app owns no content. It keeps a pull-only git clone in
Application Support, renders pages offline with a vendored Markdown + KaTeX +
pseudocode.js pipeline in a `WKWebView`, and resolves `[[wikilinks]]` by porting
Quartz's own slug rules exactly. Separately, it runs `claude` in throwaway git
worktrees to draft paper-ingestion PRs — always draft, never merged.

## 2. Getting started

```sh
make check     # compile + 47 unit tests — run this after every change
make run       # build the .app and launch it
make shots     # drive the app and capture screenshots (the visual gate)
make help      # everything else
```

First launch clones the wiki (~35 MB) into
`~/Library/Application Support/CityDesk/repo` and builds the search index. After
that, reading needs no network. Setup details are in [README.md](README.md).

## 3. The non-negotiables

These are architectural constraints, not preferences. Changing one is a
redesign, not a refactor.

| Constraint | Why | Where |
|---|---|---|
| The clone is **pull-only** | The app is a reader; a dirty reader checkout is a bug with no good recovery | `GitService.sync` uses `--ff-only` and says so loudly when it fails |
| Jobs run in **git worktrees** | A job cannot dirty the reader's checkout, and jobs can run in parallel | `GitService.addWorktree`, `AppPaths.worktrees` |
| Rendering is **fully offline** | Reading must work on a plane | Vendored into `Resources/web/`; a CSP header and a scheme handler make it structural, not aspirational |
| The **search index is derived** | Never authoritative, safe to delete at any time | `SearchIndex.reset()` is a legitimate answer to any problem |
| **PDFs never enter the repo** | They are job inputs; References pages point at eprint/arXiv/DOI | `AppPaths.library` sits outside the clone |
| **Never merge a PR** | The app's job ends at "draft PR opened" | `prompts/ingest.md`, Step 6 |

## 4. Where things live

```
.
├── Makefile                 the entry point for everything — `make help`
├── build.sh                 swift build → .app bundle → codesign
├── prompts/ingest.md        the agent prompt template for an ingestion job
├── scripts/
│   ├── vendor-web.sh        fetch the pinned offline render pipeline (run once)
│   ├── shots.sh             drive the app and capture screenshots
│   ├── window-id.swift      helper for shots.sh
│   └── make-icon.swift      generates build/AppIcon.icns
├── Resources/
│   ├── Info.plist
│   └── web/                 the reader: index.html, app.css, citydesk.js, vendor/
├── CityDesk/                CityDesk.entitlements (NOT sandboxed — see §5)
├── Sources/CityDesk/
│   ├── App/                 CityDeskApp, AppModel, AppPaths, Theme, ScreenshotRunner
│   ├── Wiki/                pure, testable: slugs, wikilinks, frontmatter, macros, index
│   ├── Reader/              the WKWebView, its scheme handler, and the render request
│   ├── Search/              SQLite FTS5 and the fuzzy quick-switcher matcher
│   ├── Jobs/                subprocess plumbing, tool discovery, git
│   └── UI/                  the SwiftUI views
└── Tests/CityDeskTests/     47 tests; see §6
```

## 5. Documentation index

- [plans/architecture.md](plans/architecture.md) — the layers, what each owns,
  and the path from `git pull` to a rendered page.
- [plans/wiki-model.md](plans/wiki-model.md) — the Quartz slug port, wikilink
  resolution, the frontmatter subset, and the macro table. **The fiddliest code
  in the app and the most heavily tested.**
- [plans/render-pipeline.md](plans/render-pipeline.md) — the vendored JS, why
  each package, the `citydesk://` scheme handler, and the CSP.
- [plans/search.md](plans/search.md) — the FTS5 schema, tokenizer choices, and
  query escaping.
- [plans/ingestion.md](plans/ingestion.md) — the worktree lifecycle, the prompt
  composition rule, and what CityDesk checks before and after the agent runs.
- [plans/build-system.md](plans/build-system.md) — `make` / `build.sh`, the
  release pipeline, and why the app is not sandboxed.
- [plans/design-system.md](plans/design-system.md) — the two type systems (app
  chrome vs document), the macOS idioms applied, and the visual gate.
- [PROGRESS.md](PROGRESS.md) — running log, newest first.
- [PROBLEMS.md](PROBLEMS.md) — things that bit us.
- [SWIFTUI-RULES.md](SWIFTUI-RULES.md) — hard-won SwiftUI rules; the code here
  follows them and cites them inline.

## 6. Testing

`make check` compiles and runs the suite. Two components carry the weight, both
because they are exactly reproducible and silently wrong when they drift:

- **`QuartzSlugTests` / `GithubSluggerTests`** — a port of the wiki's own
  `quartz/util/path.test.ts`, assertion for assertion, plus the two slugifiers'
  divergent character rules. If these fail, the app shows links the website does
  not have.
- **`WikilinkResolutionTests`** — end-to-end resolution against a fixture wiki
  carrying one of every hazard in the real corpus: a two-owner alias, a
  case-mismatched alias, a `KEY - Title.md` filename with `&` and `(`, a folder
  with no index note, an asset embed, and wikilinks inside code fences.
- **`FuzzyMatcherTests` / `QuickSwitcherRankingTests`** — the ⌘O ranking.
- **`CorpusTests`** — runs only when `CITYDESK_WIKI` points at a real clone
  (`make test-corpus`). Resolves all ~673 wikilinks in ~300 pages, validates the
  whole frontmatter schema, and parses the live macro table.

`make shots` is the other half of the gate: it drives the real app through a
plan of views and captures each one. See
[plans/design-system.md](plans/design-system.md).

## 7. The working agreement

- Keep this `PLAN.md` as the index; put depth in `plans/`; log in `PROGRESS.md`.
- Run `make check` after every change and `make shots` before trusting a UI one.
- You may open PRs. **Never merge to `main` yourself** — and the app must never
  merge one either.
