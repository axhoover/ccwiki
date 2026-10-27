# Efficiency: a quicker load and sync, a cheaper renderer, and three reading features

**Plan, 2026-10-20. Phase 0 and the six tracks are built and merged on
`claude/efficiency`; §5 records what CI measures of them. The three reading
features (§3) are built on `claude/reading-features`.** Each track section,
and each feature's, ends with an "As built" note: where the build departed
from this plan, and why. It lands as two draft PRs:
`claude/efficiency` (Phase 0 and six tracks), then
`claude/reading-features` (three features), which starts from the first and
merges after it (§2.10).

It brings together six read-only analyses of `main` at `21df5d7`, covering
the load, search, the renderer, derivations, the UI and the product. Each
analysis ported the hot loops to Python, ran the real renderer in node, or
ran SQLite in C on the 877-page corpus (wiki `ab81f02`). A critic then read
the first draft against the code. Its corrections are folded in, and every
line reference was checked again at `21df5d7`. No Swift toolchain was
available. So every Swift time below is a CI timing from a debug build, and
everything else about Swift is a count. Background:
[reader-comforts.md](reader-comforts.md) §3, which covers incremental
indexing, D1's timings and the condition for D6. This plan does not build
D6 (§4.2).

> `CLAUDE.md` asks for the **swiftui-pro**, **typography-designer** and
> **macos-design** skills before and after deciding on code. None was
> installed in the sessions that wrote this plan. It follows
> `SWIFTUI-RULES.md`, cited by section. The three features add no type
> style: every new label uses an existing `Theme.Fonts` role. Each track
> runs whichever of the three skills is installed by then, before and after
> its code.

---

## 0. In short

- **Backlinks went from 680 to 1,605 ms on CI** between D1 (`46685be`,
  2026-10-12) and `main` (`21df5d7`, 2026-10-16). The wiki did not change in
  between (§1.1); the code did. `21df5d7` changed the line scans:
  `firstIndex(of: "\n")` became `firstIndex(where: \.isMarkdownLineEnding)`,
  a key path used as a function that makes three `Character` comparisons per
  character. `backlinkMap()` makes 3.67 M of those calls per load, plus
  0.38 M direct calls in its backward walk. No other change on that path
  does even 1% of that volume. This is an inference. Phase 0 settles it in
  one CI run: a test-only copy of the `46685be` backlinks path, with each
  of the four changes behind its own switch, is timed with none, each alone
  and all four on, in the same process (§1.3).
- **The larger finding is that the load throws away much of its work.** It
  builds contexts for 2,492 backlinks when at most 44 are ever shown. It
  parses each page's links three times instead of once. It resolves 3,447
  links when there are 972 distinct ones. It converts 2,752 headings for
  preview cards that need 1,317. Its derivation makes 595,770 step visits,
  and 2,982 of them reach the rule check. Removing that work still pays in a
  release build. The line-end fix mostly matters in debug.
- **At launch, the first page waits for the search sync** (1.1 s in debug
  when the sync has nothing to do), although nothing rendered reads the
  search index. Rendering before the sync is the most visible change here
  (U1).
- **The renderer's waste is in rendering again, not in any single pass.**
  KaTeX typesets every formula again on every re-render, and the review
  renders 12,748 blocks to show 3,512 (J1, J2).
- **The UI's costs are observation fan-out, not compute.** Every git
  progress line re-evaluates every window's root view and the menu bar. The
  explorer's suggestions are computed 11 times per keystroke. The editor
  writes its save state on every key (U4, W1, W2).
- **Order of work:**
  - Phase 0 (M0) is measurement only.
  - Then six tracks run in parallel over disjoint files: **L** the load
    path, **S** search, **X** derivation and explorer, **J** the renderer's
    JavaScript, **U** the app model and main window, **W** the other
    windows. M0 and the six tracks are the efficiency PR.
  - Then the reading-features PR: **F1** backlinks that land on the
    mention, **F2** section links, **F3** saved pages.
- **How changes are proved:** each change is checked, over the whole corpus
  in CI, against the code it replaces: a test-only copy of that code, or,
  for the derivation loop, the old loop kept behind a parameter. No test
  asserts a time.

---

## 1. What the measurements say

### 1.1 The CI numbers, and how far to trust them

`IncrementalCorpusTests` runs in `make test-corpus`. Each figure is the
fastest of 5 builds, on a debug build (-Onone), with the other suites
running alongside.

| Phase | D1, `46685be` (2026-10-12) | `main`, `21df5d7` (2026-10-16) | Change | Code on this phase in between |
|---|---|---|---|---|
| `read` | 251.1 ms | 207 ms | −18% | Frontmatter rewrite; within noise |
| `index` | 18.7 | 16 | −14% | none |
| `manifest` | 7.7 | 7.6 | — | none |
| `labels` | 53.8 | 6.8 | −87% | `RelationText.plain` rewritten: one command regex instead of ~60 replacements and a key sort per call |
| `backlinks` | 680.3 | 1,605 | **+136%** | the line-end predicate; `resolve` splits targets into segments; `GithubSlugger` looks up Unicode properties per scalar |
| `grep` | 32.0 | 19 | −41% | none: noise |
| `derivation` | 471.0 | 640 | +36% | R13's `establishing` lookup on every step visit; `missingQuotes` |
| `previews` | 1,042.8 | 1,051 | +1% | the line-end predicate; a heavier `Heading.plainText`; a cheaper `RelationText.plain` |
| **total** | 2,557.4 | 3,553 | +39% | |

Also on `main`:

| Measurement | Time | Note |
|---|---|---|
| Update after a one-page edit | 4,059 ms | "everything built": `update` is `build` plus a comparison, `LoadedLibrary.swift:83-98` |
| Search sync, in full | 2,984 ms | |
| Search sync, as a no-op | 1,125 ms | |
| Search sync, after one page changed | 1,291 ms | |

**Noise.** The report takes every phase from the single run with the
fastest total (`IncrementalCorpusTests.swift:139-150`). It runs beside the
other suites, and its search lines are single runs. Phases whose code did
not change moved by up to 41% (`grep`). So a change under about 40% in one
phase is not evidence. The +136% in backlinks is.

**Same corpus.** CI clones the live wiki on every run (`ci.yml:80-81`). A
clone fetched on 2026-10-13 had head `ab81f02` (2026-10-04), so D1 read
`ab81f02`. On 2026-10-16 the phases with unchanged code (`index`,
`manifest`) match D1 within noise. The drop in labels is explained by code:
at both commits `RelationLabels` parses host pages only for variants whose
title is their id, and `ab81f02` has none. M0 makes the corpus report print
the wiki commit and the Swift version, so this never has to be inferred
again.

**Which code D1 measured.** D1's table (reader-comforts §3.1) was measured
at `46685be` on the reader-comforts branch, not at `654ca97`, the merge
that landed it. `git diff` shows `WikiIndex`, `Wikilink`, `GithubSlugger`,
`QuartzSlug`, `WikiPage` and `PreviewExcerpt` identical between the two. So
the comparison holds for backlinks and previews.

### 1.2 What one load does, counted

Counts are per load, from line-for-line ports run on the corpus.
M0 prints the same counts from Swift, which confirms or corrects the
ports.

| Work | Count |
|---|---|
| Page bodies | 877 pages, 1,091,044 characters, 0 containing `\r` |
| Links found by `outgoingLinks` | 3,447 (3,412 wikilinks + 35 markdown links). The plans' "3,664 wikilinks" is not what `ab81f02` holds |
| `CodeMask.inertRanges` calls in `backlinkMap` | 2,631: 3 per page, via `WikilinkParser.links` and twice via `LinkScanner` |
| Line-end tests | 3,273,132 in CodeMask and 393,842 in `context`'s forward scan, all through the key path; 377,424 in its backward walk, which tests the property directly |
| Inline-code `Character` steps | 3,114,960 |
| Comment-regex scans / wikilink-regex scans | 2,631 / 1,754 |
| `resolve` calls | 3,447. 972 distinct (target, anchor, embed) keys and 831 distinct targets. 1,770 `GithubSlugger` calls |
| Backlinks | 2,492 to 821 targets: max 44 per target, median 2, p95 8 |
| Context `plainText` | 907,270 characters, 14,952 regex replacements |
| Preview `scope` calls | 887 whole-body scans: 1,096,489 line-end tests, 17,498 `atxHeading`, 2,752 `Heading.plainText` and 2,752 slugs (~30k regex passes). With an early stop: 1,317 plainText and 860 slugs |
| Derivation | 524 single closures, 595,770 step visits. Of these, 516,098 are not ready, 76,690 have a known conclusion and 2,982 reach `check`; 2,256 fire. 1,843 proof trees for the link tables, 1,000 of them for `.all`, which nothing reads |
| `missingQuotes` | 117 citations on 50 pages; 438,835 characters split and normalised to NFC, where 144,745 would do |
| Search sync, even as a no-op | 447 `headings()` calls (771,535 characters, walked twice, plus 723,498 inline steps), 1,882 `Heading.plainText`, 1,882 `RelationText.plain`, 13,495 `Name` inits (6,714 of them rebuilt citer names) |

### 1.3 Why backlinks more than doubled

`21df5d7` made four changes on the backlinks path. Their volumes per load:

| Change | Where | Volume per load |
|---|---|---|
| Line ends found with `firstIndex(where: \.isMarkdownLineEnding)`, a key path used as a function | `Wikilink.swift:102` (CodeMask), `WikiIndex.swift:336` (the forward scan in `context`) | 3,273,132 + 393,842 calls |
| The backward walk tests `isMarkdownLineEnding` directly: three comparisons instead of one | `WikiIndex.swift:333` | 377,424 calls |
| `GithubSlugger.slug`: four Unicode property lookups and a `lowercaseMapping` String per scalar | `GithubSlugger.swift:30-64` | 1,770 calls, 36,456 scalars |
| `resolve` splits each target into path segments | `WikiIndex.swift:241-245` | 3,435 splits |

**The likely cause.** The first two rows are 3.67 M key-path calls and
0.38 M direct ones, against about 40 k operations for the other two. Only
the line-end rows have the volume to add 925 ms, at about 230 ns per test.
That is plausible at -Onone, where neither the key-path application nor the
three comparisons are inlined. The property
`self == "\n" || self == "\r\n" || self == "\r"` evaluates all three
comparisons for every character that is not a line end, which is nearly all
of them.

**A cross-check from previews.** Previews makes 1.10 M of the same calls
and stayed flat (+8 ms). In the same commit, its ~1,450 math spans moved to
the rewritten `RelationText.plain`, which the labels phase shows to be about
8× cheaper. The two cancel only if a call costs 100–200 ns. That would leave
part of the +925 ms to noise. Either way the predicate is the leading
suspect.

**How M0 settles it, in one run.** D1's numbers and `main`'s come from
different CI runs on different runners, and phases whose code did not
change moved by 18–41% between them. So M0 does not compare across runs.
It carries a test-only copy of the whole backlinks path as `46685be` wrote
it: the link parsers, `outgoingLinks`, `context`, `resolve` with the anchor
slugging it calls, and `backlinkMap`'s loop. Each of the four changes above
is in the copy too, as `21df5d7` wrote it, behind its own switch (§2.3
item 3). One process times the copy six ways, interleaved run by run,
minimum of 5 each, beside today's `backlinkMap()`:
- no switch on, which is `46685be`'s path;
- each switch alone, which is that change's cost on its own;
- all four on, which is `21df5d7`'s path.

The corpus has no `\r` (0 of 877 bodies) and no relative or `index` link,
the only links whose page the old `resolve` would change. So all six maps
must be equal, and M0 asserts it. It also asserts that with all four on,
the copy parses, resolves and builds exactly what the app does, so the copy
is the code being timed. §1.3 is right if the two line-end switches carry
most of the difference between no switch and all four. If the slugger or
the segment split carries much of it, the integrator corrects this section
before anything claims a cause.

**The A/B line.** M0 also times four ways of finding a line end over all
bodies (§2.3 item 4). That line decides L1's form, not the cause.

**In release.** The optimiser can reduce a key path used as a function to a
direct call and inline the comparisons. So in the shipped app this
regression is probably small. It still matters: the project measures with
CI's debug numbers, and the D6 decision depends on those numbers being
attributable.

### 1.4 The other phases

- **Derivation (+169 ms, +36%).** This is within the noise band. Two
  changes landed in between:
  - `missingQuotes`, added between `46685be` and `654ca97`: 438,835
    characters per load;
  - R13's `establishing.contains(step.key)`, evaluated on all 595,770 step
    visits before the cheap known-conclusion test
    (`Derivation.swift:1040-1046`).
  M0 times them separately.
- **Previews (1,051 ms).** 887 whole-body scans produce card excerpts that
  mostly need only the first H1.
- **Search no-op sync (1,125 ms).** SQLite's share is 0.4–1.3 ms (measured
  in C on the same rows). The rest is Swift:
  - `ConceptRanker` re-parses 447 pages' headings (0.6–0.8 s, inferred);
  - `Name` inits (0.2–0.3 s, inferred).
  The sync after one page changed should cost a few ms more than the no-op;
  its +166 ms comes from a single sample.
- **The renderer** (node/V8, 883 files, min of 5).
  - Totals: 477 ms for the corpus. Per page: p50 0.16 ms, p99 6.0 ms, max
    19.5 ms (LWE).
  - Where the time goes: KaTeX is 62% overall and 74% on the slowest 20
    pages. The cost grows linearly with page size.
  - Repeated work: the corpus makes 7,320 KaTeX calls over 3,299 distinct
    formulas (with their options), so 54.9% of calls repeat a formula
    already rendered, and on a re-render it is 100%.
- **The UI.** None of these costs is compute:
  - each git progress line (412 per clone) is written to `syncState`, which
    `RootView` in every window, the menu bar and the reader's empty state
    read, so all of them re-evaluate per line;
  - the explorer's suggestions are computed 11 times per keystroke;
  - the editor writes `saveState` on every key;
  - a running job's detail view re-evaluates its whole body 10 times a
    second, and its elapsed time freezes while the agent is quiet.

### 1.5 What is not known

- **No Swift was compiled or timed for this plan.** Nanoseconds per
  operation are inferred from CI phases.
- **WebKit's DOM and layout time** is measured nowhere. node measures
  JavaScript compute only; J3 logs the `ms` value the page already posts.
- **Debug versus release.** Each item says whether it removes work (holds
  in release), changes how cost scales (holds), or is a constant factor
  (may shrink with -O; kept only if CI shows it).
- **No test builds an `AppModel` or an `EditorSession`.** The model's
  `init` stages the web root, loads the job history and observes the app's
  activation, and the suite has never constructed one. So U's and W's checks
  are pure seams, test-local probes and the maintainer's `make shots`
  (§2.8, §2.9). As built, U's and W's suites do construct one, on
  temporary paths, and W's an `EditorSession` too.
- **The ports and references the measurements used:**
  - Python ports of CodeMask, WikilinkParser, LinkScanner, QuartzSlug,
    `resolve`, `backlinkMap`, PreviewExcerpt, ConceptRanker,
    ReferenceRanker and FuzzyMatcher, outside the repo;
  - for the engine, `scripts/derivations_reference.py` (in the repo), run
    from scripts outside the repo, and an instrumented copy of it for the
    step-visit counts and X4's and X5's measurements;
  - SQLite 3.45 for FTS5, outside the repo;
  - the vendored JavaScript in node 22 and jsdom, including the KaTeX call
    sequence J1's cap was chosen from, outside the repo.

  M0 moves the decisive measurements into the corpus suite, so nothing
  depends on these ports.

---

## 2. The efficiency work

### 2.1 Rules every item follows

1. **Before changing a function, keep the old one where a test can run
   it.**
   - **Swift goes to `Tests/CCwikiTests/Legacy/`.** As built, the one
     top-level `enum Legacy` is L's, in `Legacy/LegacyWiki.swift`, with
     `Legacy.Backlink`, the shape `WikiIndex.Backlink` had before L3; S and
     U nest their copies inside their test types, and X keeps its old loops
     behind a parameter. Another file there would be an `extension Legacy`,
     so no two declare it, and a copied `backlinkMap` builds
     `Legacy.Backlink` without a change, however L3 and F1 reshape the
     module's. M0's measurement copy has a namespace of its own, `LegacyD1`,
     so it builds beside L's whichever lands first. Each copy starts:
     "Verbatim copy of <file> at 21df5d7 for equivalence tests. Do not
     edit; delete in the next batch." (M0's copy names `46685be` and the
     backlinks timing instead. It is also the one copy with switches: it
     holds each of `21df5d7`'s four changes to the path as `21df5d7` wrote
     it, behind a switch, and its functions are instance methods so that
     each can read its switch. Its header says so.)
   - **Private helpers come along.** `@testable import` does not reach
     `private`, and the functions being replaced call private helpers:
     `CodeMask.commentRanges` and `inlineInertRanges`, `WikiIndex.context`,
     `PreviewExcerpt.headingLines` and `withoutComments`, `LinkScanner`. So
     a copy takes its whole enclosing type, or the helpers it needs. Or it
     calls an internal wrapper the change keeps: L's copies call
     `WikilinkParser.links(in:)` and `MarkdownLinkParser.links(in:)`, which
     L2 keeps.
   - **Verbatim** means the same code inside the extension. Only the names
     it uses to reach the other copies or the module change: an implicit
     `self` becomes an explicit parameter (`index.resolve`), and a bare
     helper gets its type's name (`WikiIndex.plainText`). Inside
     `extension Legacy`, a copied type shadows the module's type of the
     same name for all of `Legacy`. So a copy that must reach the module's
     type sits in an enum with another name (`Legacy.Backlinks`, not
     `Legacy.WikiIndex`).
   - **The derivation loop is the exception** (X1, X5). It reads the
     engine's private state, checks and rules, hundreds of lines a copy
     could get wrong, and a wrong copy would make the differential test
     meaningless. So the old loop stays in production behind a parameter,
     `visits: .everyStep`, with the new loop the default. `check` and `fact`
     stay shared, and the test compares only the loop. (As built, the
     parameter is `loop: .legacy`, §2.6.)
   - **JavaScript goes to `Tests/CCwikiTests/Fixtures/legacy/`**, with the
     same header as a comment.
   - **The track's corpus test compares old and new** on every input the
     corpus has, plus fixtures for the hazards the corpus lacks: CR LF, a
     lone CR, combining marks after a line end, fences, comments, duplicate
     headings. This is how a change is proved equal without a toolchain: CI
     compiles and runs both versions.
   - **They are kept for one release** after this branch ships, then
     deleted, old loop included (§4.3).
2. **Equality is exact:** `==` on the existing Equatable values, and
   byte-identical output for JavaScript.
3. **No test asserts a duration.** Timings are printed (§2.3).
4. **Each item gives its effect in two ways.** First, in debug, which is
   what CI measures. Second, why it should hold in release, as one of:
   *removed work* (fewer passes or calls), *asymptotic* (changes how cost
   scales) or *constant factor* (may shrink with -O).
5. **No self-patching caches** (SWIFTUI-RULES §3.2). The memos here (L4, L6,
   J1, W4) are pure functions of immutable inputs. Each lives and dies with
   one load, one call, one web view or one library generation.
6. **Swift 6 strict concurrency.** No `static var`. Switches that exist for
   tests are parameters with defaults: X1's and X5's `visits` (as built,
   `loop`), X4's `prefilter`.
7. **M0's report calls only entry points every track keeps:**
   - `CodeMask.inertRanges(in:)`, `WikilinkParser.links(in:)`,
     `MarkdownLinkParser.links(in:)`, `WikiIndex.outgoingLinks(in:)`,
     `resolve(_:from:)`, `WikiIndex.plainText(_:)`, `backlinkMap()`,
     `Backlink.sourcePath` and `.context`, `WikiPage.headings()`,
     `WikiIndex.pages` and `.assets`, and the `Wikilink`, `MarkdownLink`
     and `WikiIndex.Target` types as they are;
   - `PreviewExcerpt.scope(of:anchor:)`,
     `LinkPreviews(index:manifest:labels:)`;
   - `Derivation(manifest:)`, `missingQuotes(pageText:)`,
     `answer(from:to:options:)`, `implying(_:options:)`;
   - `ConceptRanker(pages:)`, `ReferenceRanker(pages:backlinks:)`,
     `SearchIndex.indexableBody(_:)`, `SearchIndex.sync(...)`;
   - `WikiIndex.quickSwitch(_:limit:excluding:recent:)`;
   - `PageRenderer.request(for:)`, `RenderRequest.jsonPayload()`,
     `MacroTable.load(cloneRoot:)`, and in JavaScript `CCwiki.render`,
     `CCwikiMarkdown.create` and `CCwikiMarkdown.reviewEntries`.

### 2.2 The items, ranked

The items are ranked by user-visible payoff per unit of risk. The **CI**
column says what confirms each one:
- **timing:** a constant factor or an inferred effect. CI's printout
  decides whether the item stays.
- **counts:** removed work, proved by equality tests. The timing is printed
  for the record.
- **UI:** behaviour, checked by the existing tests and by the maintainer's
  `make shots`.

| # | Item | Track | Size | Kind | CI |
|---|---|---|---|---|---|
| 1 | U1 Render the page before the search sync | U | S | the sync leaves the first page's path | timing (the sync's own line) |
| 2 | L1 Find line ends by scanning bytes | L | S | constant factor | timing (the A/B line) |
| 3 | L3 Build backlink contexts only when shown | L | S | asymptotic | counts |
| 4 | L2 Parse each page's links once | L | S | removed work | counts |
| 5 | J1 Memoise KaTeX per web view | J | S | asymptotic on re-render | counts + JSC timing |
| 6 | W1 Compute the explorer's suggestions once per evaluation | W | S | removed work (11×) | UI |
| 7 | W2 Editor writes `saveState` only when it changes | W | S | removed work, if the toolchain notifies on equal values | UI + probe |
| 8 | U4 A sync progress line stops rewriting `syncState` | U | S | asymptotic per line | UI + test |
| 9 | U2 ⌘O sorts once, and only when shown | U | S | removed work (ICU) | UI |
| 10 | W3 Job detail: transcript and clock as leaf views | W | S | fixes a frozen clock | UI |
| 11 | X1 Precompute R13's flags per step | X | S | constant factor | timing |
| 12 | X2 Parse each quoted page once | X | S | removed work | counts |
| 13 | L4 Resolve each distinct link once per load | L | S | removed work | counts |
| 14 | S1 Compute headings once per page in a full sync | S | S | removed work | counts |
| 15 | S2 Do the full rewrite through FTS5 `'rebuild'` | S | S | removed work (C) | timing |
| 16 | S3 The reference ranker reuses the concept ranker's names | S | S | removed work | counts |
| 17 | U3 The Relations inspector stops reading the explorer's question | U | S | removed work | test |
| 18 | X3 Drop dead derivation work at load | X | S | removed work | counts |
| 19 | L6 Build section cards once per load | L | S | asymptotic | counts |
| 20 | U5 The sidebar's Cited by rows as equatable leaves | U | S | removed work (with L3) | UI |
| 21 | J2 Render review blocks only when shown | J | S | asymptotic | counts + JSC timing |
| 22 | X4 Run a Horn prefilter before on-demand closures | X | M | asymptotic | counts + timing |
| 23 | L5 Preview cards stop at the first H1 | L | M | removed work | counts |
| 24 | X5 Semi-naive layers and phase skipping | X | M | asymptotic | counts |
| 25 | S4 Build the concept ranker from a stored outline | S | M | asymptotic | counts |
| 26 | W4 The editor preview reuses its overlaid index | W | S | removed work | test |
| — | J3 Log the render time the page posts | J | S | measurement only | — |

### 2.3 Phase 0: measure first (M0)

M0 is one commit, test and CI only, landed before any track. CI's run of it
is the baseline, copied into §5. It owns:
- `Tests/CCwikiTests/IncrementalCorpusTests.swift`;
- the new `Tests/CCwikiTests/RenderCorpusTests.swift`;
- the new `Tests/CCwikiTests/Legacy/LegacyBacklinks.swift` (`enum
  LegacyD1`, §2.1 rule 1);
- `.github/workflows/ci.yml`.

**1. Per-phase minimums.** Each `LoadTimings` phase is reported as its own
minimum over the 5 runs, instead of the phases of the run with the fastest
total. The median total stays.

**2. Provenance in the report itself.** The report's head prints the wiki
commit (`git -C <wiki> log -1 --format='%h %cs'`) and the first line of
`swift --version`, both run with `Process`, and "unknown" when either
fails. It also says "measured alone" when `CCWIKI_TIMINGS_ALONE` is set, and
keeps the existing "beside the other suites" otherwise. So the copy inside
`make test-corpus` is attributable too, not only the standalone step.

**3. Backlinks, `46685be` against `21df5d7`, in one run.**
- **The copy.** `Legacy/LegacyBacklinks.swift` holds, inside
  `extension LegacyD1`, a `struct D1Backlinks` made from the loaded index
  and a set of switches. `D1Backlinks.Changes` is an `OptionSet` with
  one switch for each change in §1.3: CodeMask's line ends, `context`'s line
  ends, the slugger, and `resolve`'s segment split. The copied functions
  are methods of `D1Backlinks`, so each reads its switch, and their calls to each
  other reach the copies. The copy holds, as `46685be` wrote them:
  - `Wikilink.swift`'s `WikilinkParser`, `CodeMask`, `MarkdownLinkParser`
    and the private `LinkScanner`, plus its private `UInt8` extension,
    which stays at file scope since an extension cannot nest. The
    `Wikilink` and `MarkdownLink` structs stay the module's. All three
    CodeMask passes per page take the CodeMask switch.
  - `WikiIndex`'s `backlinkMap`, `outgoingLinks(in:)`, `resolve(_:from:)`
    and the private `context(of:in:)`, which calls the module's
    `WikiIndex.plainText(_:)`.
  - `resolve`'s tables. `slugToPath`, `aliasOwners` and `basenameIndex` are
    private to `WikiIndex`, so `init` builds them again as `assemble` does,
    from the files `build` assembled from (`WikiIndex.contentFiles(root:)`),
    outside the timed code. They are the index
    phase's work, so they are built as `21df5d7` builds them, which differs
    from `46685be` only for an alias that ends in `.md`. The first
    assertion below catches any table that comes out different.
  - `QuartzSlug.splitAnchor` and `transformInternalLink`, with the private
    `addRelativeToStart`. These are the functions on `resolve`'s path that
    reach the slugger, so they must reach the copy's. The rest of
    `QuartzSlug` did not change, and the copy calls it as it is.
  - `GithubSlugger.slug` and its private `survives`.

  Behind each switch is that change as `21df5d7` wrote it. That includes
  a file-private copy of `isMarkdownLineEnding`, under another name since a
  same-named `Character` property would be ambiguous beside the module's,
  so the line keeps its meaning whatever L1 does to the module's. The loop
  builds its own `D1Backlinks.Backlink`, so it still compiles after L3 and F1 change
  the module's `Backlink`.
- **The lines.** Seven, each the minimum of 5 on the loaded library,
  interleaved run by run so that whatever slows the runner slows them
  alike:
  - the copy with no switch on: `46685be`'s path;
  - the copy with each switch alone, each printed with its difference from
    the first line;
  - the copy with all four on: `21df5d7`'s path;
  - `backlinkMap()` as built.
- **Assertions.**
  - With all four on, the copy's `outgoingLinks` and `resolve` equal the
    app's for every link on every page. Its map equals `backlinkMap()`'s,
    each list mapped to `D1Backlinks.Backlink(sourcePath:context:)`, in order.
    So the copy is the code being timed.
  - It counts the bodies that hold `\r` and the links whose page the
    copy's `46685be` `resolve` changes, and prints both. When both are 0,
    as on the corpus, all six maps must be equal. Otherwise the report says
    "not compared".
- **Reading it.** The first copy line is `46685be`'s cost and the all-four
  line is `21df5d7`'s, in one process. Each switch's difference is that
  change's cost on its own. The four need not add up to the whole exactly,
  since each line is its own minimum on a noisy runner. §1.3 is right if
  the CodeMask and `context` switches carry most of the difference between
  the first line and the all-four line. If the slugger or the segment
  split carries much of it, §1.3 is wrong, and the integrator corrects it
  (§2.10 item 1). At M0 the as-built line matches the all-four line within
  noise. As the tracks land only the as-built line moves, since the copies
  stay as they are.

**4. Sub-phase lines.** Each is the minimum of 5 runs, on the library
already loaded:
- **Line ends, A/B.** Over all bodies, find every line end four ways:
  - (a) `firstIndex(where: \.isMarkdownLineEnding)`, as today;
  - (b) `firstIndex { $0.isMarkdownLineEnding }`;
  - (c) `firstIndex(of: "\n")`, as before `21df5d7`;
  - (d) the UTF-8 byte scan L1 proposes.

  The test file defines all four, so the line keeps its meaning after L1.
  It prints the four times and the line counts, and asserts that (a), (b)
  and (d) count alike. It prints how many bodies contain `\r`; when that is
  0, (c) must agree too.
- **Load path:**
  - `CodeMask.inertRanges` over all bodies;
  - `outgoingLinks(in:)` over all bodies;
  - `resolve` over every link;
  - `plainText` over each backlink's line (the test cuts the line itself);
  - `backlinkMap()`.
- **Previews:**
  - `PreviewExcerpt.scope(of:anchor: nil)` over all bodies;
  - `LinkPreviews(index:manifest:labels:)`.
- **Derivation:**
  - `Derivation(manifest:)` alone and `missingQuotes` alone;
  - `answer` for `owf`⇒`pke`, `pke`⇒`ot` and `ddh`⇒`io`, and `implying` for
    `pke`, `ot`, `mpc` and `nizk`, in both settings. All of these ids are in
    the golden file's queries.
- **Search:**
  - `ConceptRanker(pages:)`;
  - `ReferenceRanker(pages:backlinks:)`;
  - `headings()` over the non-reference pages;
  - `SearchIndex.indexableBody` over all bodies;
  - the no-op sync, as the minimum of 5;
  - the full sync, as the minimum of 3.
- **⌘O, one keystroke.** `index.quickSwitch(q)` for every prefix of
  "learning with errors", "pke" and "oblivious", which is the work
  `refreshQuickSwitcher` does on the main actor per keystroke, with no
  debounce: 2,977 `FuzzyMatcher` calls and 8,931 arrays. It prints the
  slowest prefix, and the empty-query sort on its own. §4.2's deferral of
  FuzzyMatcher rests on this line. As built, it times the query empty
  (opening ⌘O), "p", "pr" and "prf", and prints how many pages and names
  the matcher searches.

**5. Counts beside the times.** These are deterministic: pages, links,
distinct resolve keys, backlinks, targets, the maximum backlinks per target,
and headings on non-reference pages. They check §1.2's port counts against
Swift.

**6. `RenderCorpusTests` (JavaScriptCore, runs only with `CCWIKI_WIKI`).**
- **Setup.** It has its own loader and its own shell:
  - a fresh `JSContext` per run, with a copy of `MarkdownScript`'s `atob`
    shim, but not `MarkdownScript.prelude`, which also stubs KaTeX;
  - the vendored scripts in `index.html`'s order: the real `katex.min.js`,
    `pseudocode.js`, markdown-it and its plugins, GithubSlugger,
    `ccwiki-markdown.js`;
  - a copy of `FixesJsTests`' DOM shell without its
    `katex.renderToString` override. That shell is `private static`, and
    it replaces KaTeX with a function returning its input;
  - then `ccwiki.js`.
- **Payloads.** What the app sends: `PageRenderer(index:).request(for:)`
  for each page, with `MacroTable.load(cloneRoot:)`'s macros, through
  `jsonPayload()` into `CCwiki.render`. The output is the stub page's
  `innerHTML`.
- **Orders.** Each runs in a fresh context, and each is the minimum of 3:
  - a first render of every page, in path order;
  - each page twice in a row (A A B B …), timing the second renders;
  - the corpus twice in path order (A … Z A … Z), timing the second pass;
  - LWE twice in a row.

  Both re-render orders are printed, because a memo's cap treats them very
  differently (§2.7, J1).
- **Review.** `CCwikiMarkdown.reviewEntries` for a one-line edit to the
  middle non-blank line of every page, with `md` made by
  `CCwikiMarkdown.create` from the same macro table. It prints the time.
- **Assertions.** Nothing about time. It does assert that each page's
  second render equals its first, in both orders. That holds today, and J1
  must keep it.
- **Coverage.** The stub page's `querySelectorAll` finds nothing, so there
  is no pseudocode pass. These numbers cover markdown-it and prose KaTeX,
  which is most of what J1 targets.

**7. CI runs these suites alone, on pull requests, `main` and manual runs.**
After "Corpus and search relevance", add this step. Its condition is the
one ci.yml already uses to keep `make release` off ordinary pushes, since a
macOS minute counts ten times against the account's Actions quota:

```yaml
      - name: Load and render timings, measured alone
        if: ${{ !cancelled() && (github.event_name != 'push' || github.ref == 'refs/heads/main') }}
        env:
          CCWIKI_WIKI: ${{ runner.temp }}/wiki
          CCWIKI_TIMINGS_ALONE: "1"
        run: |
          [ -d "$CCWIKI_WIKI/content" ] || exit 0
          git -C "$CCWIKI_WIKI" log -1 --format='wiki %h %cs'
          swift test --no-parallel --filter 'IncrementalCorpusTests|RenderCorpusTests'
```

The copy that runs inside `make test-corpus`, on every push, keeps its
assertions, and its numbers carry the "beside the other suites" label. The
step reuses `make check`'s debug build and adds about 2–3 minutes where it
runs. A push to a branch without a pull request skips it, which is why the
integrator opens the efficiency PR with M0 (§2.10 item 1).

**What each line should do after the tracks.** The "before" figures are
CI's numbers on `main`, or M0's first run for lines that are new. The
"after" figures are estimates from counts, not promises. §5 records what CI
actually prints.

| Report line | Before | After, expected | Moved by |
|---|---|---|---|
| backlinks: the `46685be` copy, each switch alone, all four, as built (same run) | new | `46685be` well below all four; most of the difference in the CodeMask and `context` switches, if §1.3 is right | the copies: nothing; as built: L1–L4 |
| line ends A/B | new | (a) well above (d) | (M0 only; decides L1's form) |
| `backlinks` | 1,605 ms | below D1's 680 ms: what remains is one parse per page and 972 resolves | L1–L4 |
| `previews` | 1,051 ms | about half: plainText 2,752 → 1,317, CodeMask passes 887 → 430 | L1, L5 |
| `derivation` | 640 ms | below D1's 471 after X1–X3. After X5 the closures are a small part of it (step visits ÷ 199) | X1–X3, X5 |
| `read`, `index`, `manifest`, `labels`, `grep` | 207, 16, 7.6, 6.8, 19 | unchanged | — |
| update after a one-page edit | 4,059 ms | falls with the full build; D6 is not built | L, X |
| search sync, in full | 2,984 ms | minus 447 duplicate `headings()` calls; minus 110–150 ms of SQLite, since CI's sync writes a fresh file | L1, S1, S2 |
| search sync, no-op (min of 5) | 1,125 ms (one run) | ≲ 0.35 s (estimate) | L1, S3, S4 |
| `answer` / `implying` lines | new | closure counts fall 30× or more on no-path answers and implied-by | X4, X5 |
| ⌘O, one keystroke | new | unchanged: FuzzyMatcher is deferred (§4.2) | — |
| JSC first render of the corpus | new | about −11 to −14%: one context renders the whole corpus, so formulas repeated across pages hit (a page alone in a fresh web view gains only 4–5%) | J1 |
| JSC, each page again right after itself | new | about −55% | J1 |
| JSC, LWE again right after itself | new | about −75% (20.9 → 4.9 ms in V8) | J1 |
| JSC, the corpus a second time in path order | new | little change (about −10% in V8): J1's cap is below the corpus's 3,299 formulas on purpose | J1 |
| JSC review entries | new | about −40% | J2 |

### 2.4 Track L: the load path, links, backlinks and previews

L's legacy copies are one file, `Legacy/LegacyWiki.swift`, at `21df5d7`:
- the whole `CodeMask` enum;
- `WikiPage.headings()`, as `Legacy.headings(of:)`, calling the copied
  CodeMask;
- `backlinkMap`'s loop, `outgoingLinks` and the private `context(of:in:)`,
  as `Legacy.Backlinks`. They call the kept parser wrappers and today's
  `resolve`, and build `Legacy.Backlink`;
- the whole `PreviewExcerpt` enum and `LinkPreviews` struct, which build the
  module's `LinkPreview` values.

**L1. Find line ends by scanning bytes.** *S, constant factor, CI: timing.*
- **Change.** A new `Sources/CCwiki/Wiki/MarkdownLineEnd.swift` holds two
  helpers.
  - `next(in:from:) -> (end: String.Index, next: String.Index)` runs
    `text.utf8[from...].firstIndex { $0 == 0x0A || $0 == 0x0D }`. `next` is
    `end` + 2 for CR LF, `end` + 1 otherwise, and `endIndex` at the end.
  - `start(in:before:)` finds the last 0x0A or 0x0D before an index, for
    the backward walk.

  They are used by:
  - `CodeMask.inertRanges` (`Wikilink.swift:102`);
  - `WikiPage.headings()` (`WikiPage.swift:233`);
  - `WikiIndex.context` (`WikiIndex.swift:330-336`).

  The inline-code scan stays per `Character`, because a backtick followed by
  a combining mark is not `` ` `` as a Character.
  `Character.isMarkdownLineEnding` stays for `DiffGuard.swift:1156`, which
  is not on a hot path.
- **Effect in debug.** It removes the key-path predicate from 3.67 M calls
  per load in backlinks (and the property from 0.38 M more), 1.10 M in
  previews, 1.54 M per search sync through `headings()`, and from every
  render's link parse. M0's same-run comparison gives the size. Rule: if
  M0's A/B shows (d) no faster than (b), land (b), the one-token change,
  instead.
- **In release.** The key path is mostly optimised away. What remains is
  that a byte compare is cheaper than stepping a grapheme cluster.
- **Why it is exact.** Unicode's UAX #29 rules GB3–GB5 make CR and LF
  grapheme boundaries everywhere except inside CR LF, and the code already
  treats CR LF as one line end. So every byte offset the scan finds is the
  same Character boundary the old scan found.
- **Tests** (new `LoadEquivalenceCorpusTests.swift`).
  - On all 877 bodies: `CodeMask.inertRanges` equals
    `Legacy.CodeMask.inertRanges`, and `headings()` equals
    `Legacy.headings(of:)`.
  - Fixtures, in `FixesWikiparseTests`: a CR LF page, a lone CR,
    `"\n\u{301}"`, `"\r\u{301}"`, `"\r\r\n"`, text ending in `\r`, the
    empty text, and a fence closed on a CR LF line.

**L2. Parse each page's links once.** *S, removed work, CI: counts.*
- **Change.**
  - Add `WikilinkParser.links(in:inert:)` and
    `MarkdownLinkParser.links(in:inert:wikilinks:)`. `LinkScanner` takes
    both inputs instead of computing them again (`Wikilink.swift:385-405`).
  - A new `LinkParse.links(in:)` computes `CodeMask.inertRanges` once and
    the wikilinks once, and returns both kinds of link.
  - `WikiIndex.outgoingLinks(in:)` (`WikiIndex.swift:288-292`) uses it, and
    so does `PageRenderer` (`RenderRequest.swift:156-161`).
  - The existing `links(in:)` entry points stay as wrappers. RelationLabels,
    PageRelations, ProofCitations and WikiPage do not change. `Wikilink`
    and `MarkdownLink` do not change either: M0's `46685be` copy builds
    them.
- **Effect.** Per load:
  - CodeMask: 2,631 → 877 calls, which removes 2.18 M line-end tests,
    2.08 M inline steps and 1,754 comment-regex scans;
  - wikilink-regex scans: 1,754 → 877.

  Every render, and every `linkedPaths` call (per open tab per update),
  goes from 3 passes to 1. Removed work, so it holds in release.
- **Why it is exact.** The same functions run on the same inputs, once
  instead of three times.
- **Tests.**
  - `outgoingLinks` equals `Legacy.Backlinks.outgoingLinks` for every corpus
    body and every relation-meta line. `Wikilink` is Equatable, ranges
    included.
  - The new parse's keyed list equals what `RenderRequest` built before, for
    every page.
  - MarkdownLinkTests, WikilinkResolutionTests and FixesWikiparseTests are
    unchanged.

**L3. Build backlink contexts only when shown.** *S, asymptotic, CI:
counts.*
- **Change.**
  - `WikiIndex.Backlink` (`WikiIndex.swift:315-322`) stores `sourcePath`
    and `line: Substring`: the line around the link, a slice of the page
    body with no copy.
  - `context` becomes a computed property: `WikiIndex.plainText(String(line))`.
  - `id` becomes `sourcePath`. `backlinkMap`'s `seen` set already allows
    one entry per source per target.
  - In `InspectorView.swift:92-125` each row becomes a leaf
    `BacklinkRow(link:)`. It is `Equatable`, comparing the backlink only,
    and the list applies `.equatable()`. Without that, SwiftUI may evaluate
    the body of a row whose input did not change, and run `plainText` again
    (SWIFTUI-RULES §6.3). Its `==` is `nonisolated static func ==`: a View
    is main-actor isolated under Swift 6, and Equatable's requirement is
    not.
  - `SidebarView.swift:109` (`.help(backlink.context)`) compiles unchanged.
    It would then run `plainText` for every citing page each time the
    sidebar's body is evaluated, on navigation and on tree and selection
    changes. U5 makes those rows equatable leaves too.
  - The three `Backlink(sourcePath:context:)` calls in
    `ReferenceRankerTests.swift` become `(sourcePath:line:)`.
- **Effect.** Every load and update loses 2,492 plainText calls (14,952
  regex replacements over 907,270 characters). Showing the busiest page
  (hash-function) costs at most 44. Resident memory falls by 0.77 MB, since
  a context was stored once per target it named. The regex work is ICU's,
  so this holds in release.
- **Why it is exact.** The same function runs later, on the same line.
- **Tests.**
  - For every corpus target, the list mapped to
    `Legacy.Backlink(sourcePath:context:)` equals
    `Legacy.Backlinks.backlinkMap`'s, in order, and ids are unique within
    each list.
  - IncrementalLibraryTests and MarkdownLinkTests compile unchanged:
    Backlink stays Equatable, equal lines give equal contexts, and
    `\.context` still reads.
  - ReferenceRanker reads only `sourcePath`, so the relevance reports must
    print the same numbers.
- **Seam.** This is the seam F1 builds on.

**L4. Resolve each distinct link once per load.** *S, removed work, CI:
counts.*
- **Change.** Inside `backlinkMap()`, keep a local `[ResolveKey: Target]`,
  keyed by the fields `resolve` reads: `target`, `rawAnchor` and `isEmbed`.
  `isBlockRef` is derived from `rawAnchor`, and `sourcePath` is unused
  (`WikiIndex.swift:206-272`). The table lives for one call.
- **Effect.** Resolves fall from 3,447 to 972, and the `^https?://` regex
  runs 972 times instead of 3,447. `GithubSlugger` calls fall from 1,770 to
  at most 3 per distinct anchored key. Removed work, so it holds in release.
- **Tests.** For every link on every corpus page, the cached target equals
  `resolve(link, from:)`, and `backlinkMap` equals the legacy one.

**L5. Preview cards stop at the first H1.** *M, removed work, CI: counts.*
- **Change, in `PreviewExcerpt` (`PreviewExcerpt.swift:50-160`).**
  - **No anchor, or an empty one:** find the first H1 by streaming the
    lines and tracking fences with the same line classifier CodeMask uses,
    extracted so the fence rule stays one code path. Call
    `Heading.plainText` only on level-1 ATX lines outside fences, until the
    first non-empty one; no slugger is needed.
  - **A comment the first pass could not pair:** when the text without
    comments still contains `%%`, take today's path.
  - **An anchor:** today's path, since the slugs up to the target are needed
    to deduplicate them.
  - **CR LF:** `withoutComments` skips its `"\r\n"` replacement when
    `body.utf8.contains(0x0D)` is false. The test must be on UTF-8:
    `"\r\n"` is one Character, so a Character search for `"\r"` does not
    find it on a CR LF page.
  - `scope(of:anchor:)` and `Scope` keep their shape; M0 calls them.
- **Why "removed work", not "asymptotic".** `withoutComments` and the
  `split(separator: "\n")` still run over the whole body
  (`PreviewExcerpt.swift:51-52`), and `Scope.lines` holds every remaining
  line: a Character-level pass over all 1.10 M characters per load. The
  item removes the heading work, not that pass. A builder may also have
  the no-anchor path produce lines lazily, from the H1's offset, with
  `firstParagraph(inLines:)` pulling them. Then a card costs the text up to
  its first paragraph, and the item is recorded as asymptotic. That part is
  optional.
- **Change, in the callers.**
  - `firstParagraph(inLines:)` already reduces each candidate's inline text
    (`PreviewExcerpt.swift:155`). A sibling returns that text with the
    paragraph, and the card uses it, so `LinkPreview.swift:172` stops
    running `inlineWithoutLinks` a second time. `firstParagraph(in:anchor:)`
    and `firstParagraph(inLines:)` keep returning `String?`, so
    LinkPreviewTests compile unchanged.
  - The VoiceOver label (`LinkPreview.swift:44-66`) is computed when read,
    not in `init`. `LinkPreview`'s memberwise init keeps its signature, which
    the legacy `LinkPreviews` calls.
  - `LinkPreviews` gains an internal `card(forPath:)`, for the tests:
    `cards` is private.
- **Effect.** From the port:
  - `Heading.plainText`: 2,752 → 1,317 calls;
  - slugs: 2,752 → 860;
  - `atxHeading`: 17,498 → 6,356 calls;
  - CodeMask passes: 887 → 430.

  The paragraph reduction halves. At least 1,447 `RelationText.plain` calls
  move from the load to the at most ~55 cards a render reads. Removed work,
  so it holds in release.
- **Why it is exact.** The port's lazy scope matched today's excerpts on
  all 877 pages: 638 excerpts, 0 differences.
- **Tests.**
  - `scope(of:anchor:)` gives the same `heading`, `isWholePage` and `lines`
    as `Legacy.PreviewExcerpt.scope` on every corpus page, with anchor nil,
    with `"abstract"`, and with every heading id on the page. `Scope` is
    not Equatable, and the copy has its own, so the test compares fields.
  - For every path, `card(forPath:)` equals
    `Legacy.LinkPreviews(...).preview(path:anchor: nil)`.
  - LinkPreviewTests are unchanged.
  - Fixtures: an empty H1 before a real one, an H1 inside a fence, an
    unpaired `%%`, and a CR LF page.
- **Risk.** Medium. The first-H1 rule has to match `headingLines` exactly,
  and the exhaustive comparison is the guard. This is the last item in L.

**L6. Build section cards once per load.** *S, asymptotic, CI: counts.*
- **Change.**
  - `LinkPreviews` holds a `final class SectionCards: Sendable` box with an
    `OSAllocatedUnfairLock<[String: LinkPreview?]>` (`import os`), keyed
    `"path#anchor"`.
  - `preview(path:anchor:)` (`LinkPreview.swift:116-122`) consults it before
    `sectionCard` (`:370-398`).
  - LinkPreviews is rebuilt on every load, so the box goes with the data it
    was computed from and needs no invalidation. LinkPreviews is not
    Equatable, so the box changes no comparison.
- **Effect.** A render of a page with section links stops re-scanning each
  target page. The worst case is `Reductions/ibe-to-pke.md`: 5 cards, 38 KB
  and 57 headings on every render. One pass over the corpus goes from 4,522
  plainText calls and 3.03 MB re-scanned to none after the first view. This
  is main-actor work, and it holds in release.
- **Tests.** For every page P and every heading id A of P,
  `preview(path: P, anchor: A)` called twice equals
  `LinkPreviews.sectionCard(...)` called directly, and equals
  `Legacy.LinkPreviews`' `preview(path: P, anchor: A)`.

**As built** (`eff/L`: one commit per item in §2.2's order, then one
review fix). The tests are in `LoadEquivalenceCorpusTests.swift`, with
fixtures there and in FixesWikiparseTests (`lineEnds`, `loneCRLines`).
- **L5 is removed work.** `scope` still splits the whole body, because
  LinkPreviewTests reads `Scope.lines` as an array. With no anchor it stops
  at the first level-1 heading outside a fence whose text is not empty,
  and takes the old path when the text without comments still has a CR or
  a `%%`. The siblings that return the reduced text are
  `firstParagraphInline(in:anchor:)` and `firstParagraphInline(inLines:)`.
  No `card(forPath:)` was added: the card test compares
  `preview(path:anchor: nil)`.
- **`MarkdownLinkParser.links(in:)` keeps its own parse.** It finds
  CodeMask's ranges and the wikilinks itself, as `LinkScanner(text)` did,
  not through `LinkParse`. L's copies read their markdown links through
  it, so the markdown half of L2's test compares the old code with the
  new; through `LinkParse` it compared the new code with itself (the
  review's finding). No production code calls it.
- **L4 and L6 key exactly.** `WikiIndex.LinkResolutions` keys on (target,
  rawAnchor, isEmbed) compared byte for byte, since String's `==` is
  canonical equivalence and two spellings of an accented letter need not
  slug alike. `SectionCards` keys on a (path, anchor) struct, not
  `"path#anchor"`, so no path or anchor can collide.
- **One difference from the old code, outside the corpus.** For a
  markdown link right after a Unicode Prepend character (U+0600, say) at
  the start of a line, the old code began the line inside that grapheme
  cluster, or trapped at the start of the text. The new code begins it
  right after the line end. No page has such a character, and wikilinks
  never reach that code.
- **L1's form still waits on M0's A/B line.** If (d) is no faster than
  (b), `MarkdownLineEnd`'s body becomes the closure, and its callers stay
  as they are.

### 2.5 Track S: search sync

**S1. Compute headings once per page in a full sync.** *S, removed work,
CI: counts.*
- **Change.** In `sync` and `rebuild` (`SearchIndex.swift:200-258`), compute
  `page.headings()` once per page. Pass the result to a new
  `ConceptRanker(pages:headings:)` and to `write(_:digest:headings:with:)`
  (`:365`, whose `headings()` call is at `:379`). `init(pages:)` stays as a
  convenience for ConceptRankerTests.
- **Effect.** A full sync makes 877 `headings()` calls instead of 1,324. It
  walks 1.09 M characters instead of 1.86 M, and makes 2,742 plainText calls
  instead of 4,624. Removed work, so it holds in release.
- **Tests** (new `SearchEquivalenceTests.swift`).
  - On the corpus, `ConceptRanker(pages:headings:)` gives the same entries
    and vocabulary as `ConceptRanker(pages:)`. Add `Equatable` to `Entry`,
    `Heading` and `Name` where they lack it; all three are in
    `ConceptRanker.swift`.
  - SearchIndexSyncTests and the six relevance reports are unchanged.

**S2. Do the full rewrite through FTS5 `'rebuild'`.** *S, removed work (in
C), CI: timing.*
- **Change.** Inside `writeAll`'s transaction (`SearchIndex.swift:275-291`):
  1. `DROP TRIGGER doc_ai` and `doc_ad`;
  2. `DELETE FROM doc`;
  3. plain inserts;
  4. `INSERT INTO doc_fts(doc_fts) VALUES('rebuild')`;
  5. re-create both triggers from one SQL constant that `schema` also uses;
  6. stamp, then `COMMIT`.

  `optimize` and the checkpoint run as today. `doc_au` is untouched, so an
  incremental sync behaves as before.
- **Effect.** Measured in C on the real rows:

  | Case | Today | With `'rebuild'` |
  |---|---|---|
  | Fresh file: the first launch; Rebuild, since `performLoad(.rebuild)` calls `searchIndex.reset()` first (`AppModel.swift:1137-1140`); S4's first launch, since `open()` resets on a schema bump; any sync that fell back to `reset()` | 195–233 ms | 82–87 ms |
  | Populated index: the launch after an app update, whose builder stamp differs, and `CCWIKI_FULL_RELOAD=1` | 385–469 ms | 85–124 ms |

  This is C, so it holds in release. CI's full-sync line writes a fresh
  temporary file, so it shows the first row.
- **Why it is exact.** In C on the corpus, the result rows were identical in
  (path, snippet, bm25): 1,389 and 1,967 rows, over the query sets with both
  kind filters. `integrity-check` passed, and a later update through `doc_au`
  answered the same.
- **Tests.**
  - The existing `syncEqualsFreshBuild` (which runs `integrity-check`),
    `builderChangeRebuilds`, `rebuildLeavesNoStamp` and
    `unchangedWritesNothing`.
  - New: rewrite a populated index, update one row, and compare every answer
    with a fresh build.
  - The relevance reports are unchanged.

**S3. The reference ranker reuses the concept ranker's names.** *S, removed
work, CI: counts.*
- **Change.**
  - `SearchIndex.rank` builds ConceptRanker first, then passes
    ReferenceRanker each citer's `[Name]`. These are the names ConceptRanker
    built from `[page.title] + page.aliases`, without the stem it appends
    (`ConceptRanker.swift:96`).
  - `RelationText.plain(via.title)` is memoised by path inside
    `ReferenceRanker.init` (`ReferenceRanker.swift:115-143`).
  - `ReferenceRanker(pages:backlinks:)` stays for its tests.
- **Effect.** Each sync makes 6,781 `Name` inits instead of 13,495, and
  2,135 `RelationText.plain` calls instead of 3,003. Removed work, so it
  holds in release.
- **Tests.**
  - Built both ways, ReferenceRanker has equal entries: keys, citer paths,
    via, and the names' exact and folded forms.
  - The ⇧⌘R relevance reports are identical.

**S4. Build the concept ranker from a stored outline.** *M, asymptotic, CI:
counts.*
- **Change.**
  - Schema version 4 adds `doc.outline TEXT`: a JSON array of [text, id]
    pairs from `page.headings()`. FTS does not index it, and no trigger
    changes.
  - `sync` first reads `SELECT path, hash, outline FROM doc` and decides the
    writes.
  - It then builds ConceptRanker from headings parsed for the rows it writes
    and outlines decoded for the rows it keeps. A row that fails to decode
    is parsed.
- **Why not split the existing `headings` column on `"\n"`.**
  `Heading.plainText` decodes character references, so `&#10;` puts a line
  break in a heading's text, and the joined column cannot be split back
  exactly.
- **What the schema bump costs.** `open()` sees the old `user_version` and
  calls `reset()`, so the first launch of the new build writes a fresh
  file: S2's first row, 82–87 ms of SQLite. Every app update already pays a
  full rewrite, through the builder stamp.
- **Effect.**
  - A no-op or launch sync makes no `headings()` calls instead of 447. It
    reads about 28 k characters instead (+0.2 ms in C).
  - A pull's sync parses only the pages that changed.
  - Estimate for the no-op in debug, with S3: about 0.2–0.35 s. This holds
    in release.
- **Tests.**
  - For every corpus page, the decoded outline equals
    `headings().map { ($0.text, $0.id) }`.
  - ConceptRanker built from outlines equals ConceptRanker built from
    pages.
  - A corrupted outline falls back to parsing.
  - `syncEqualsFreshBuild`, and the relevance reports unchanged.
- **Rank.** Last in S, because U1 already takes the sync off the first
  page's path.

**As built** (`eff/S`: one commit per item; the review found nothing).
The tests are in `SearchEquivalenceTests.swift`: six on fixtures, and
four on the corpus that print a line each (§5).
- **The legacy copies are nested,** as `SearchEquivalenceTests.Legacy` at
  the end of that file, since `Legacy/` was not in S's files. Nested, they
  cannot clash with L's top-level `enum Legacy`.
- **S4 reads about 72 k characters of JSON** on a no-op, not the 28 k
  above, which is the `headings` column's size. That is the port's count.
  `doc.outline` is `TEXT NOT NULL DEFAULT ''`, written by
  `SearchIndex.encoded(_:)`. Of the rows kept, only a non-reference page's
  outline is decoded, since the concept ranker parses only those pages.
- **The rankers are built in a `defer`,** after the writes rather than
  before them, so they are rebuilt however the writing ends. They are
  built from the outlines of the rows written and kept, and parse only the
  pages they lack. Their final state is the same, and the logged sync time
  still includes them.
- **S2** drops `doc_ai` and `doc_ad` with `IF EXISTS`, and makes them
  again from `insertDeleteTriggers`, the constant the schema interpolates.
  `populatedRewrite` compares a rewrite over a populated index, and an
  update, a delete and an insert after it, with a fresh build and with
  every row inserted through `doc_ai`.
- SearchIndexSyncTests' `version2Resets` now expects `user_version` 4.

### 2.6 Track X: derivation and explorer

X keeps no legacy copy. Its old loop stays in production behind a
parameter (§2.1 rule 1), and X2's old behaviour is the wrapper X2 keeps.

**X1. Precompute R13's flags per step.** *S, constant factor, CI: timing.*
- **Change.**
  - `Engine.init` (`Derivation.swift:918-938`) builds `establishes: [Bool]`
    and `makesWeak: [Bool]` aligned with `steps`, and a second pair aligned
    with `defaultSteps`.
  - `run` (`:1032-1115`) tests the known-conclusion depth first, and reads
    `state.established[key]` only for a flagged step. Four steps are
    flagged.
  - **The old loop stays.** `Engine.closure(from:options:)` gains
    `visits: Visits = .flagged`. `.everyStep` runs today's `run`, verbatim,
    kept beside the new one. Every existing call compiles unchanged.
- **Effect.** Each load loses 595,770 `StepKey` builds and `Set<StepKey>`
  lookups, which are String hashes at -Onone. In release this is roughly
  10–25 ms (estimate).
- **Tests.**
  - New `DerivationEquivalenceTests.swift` (corpus): for every engine
    (`mainEngine`, each of `restrictedEngines` and `cleanEngines`,
    `cleanAnyEngine`, `relaxedEngine`), every object and both settings,
    `closure(..., visits: .everyStep)` and the default give the same facts,
    weak facts, `established` and `refused`. The engines are internal
    `let`s, so the test reaches them.
  - DerivationTests and DerivationCorpusTests are unchanged: 84 golden
    queries, 16 mutations, closure sizes, counts and invariants.

**X2. Parse each quoted page once.** *S, removed work, CI: counts.*
- **Change.** A new `CurationQuote.Page(text)` holds a page's NFC lines and
  headings. `missingQuotes` (`DerivationChecks.swift:234-257`) builds one
  per path, and a `contains(quote, section:)` runs against it
  (`CurationQuote.swift:29-80`). The CR and CR LF split stays ahead of NFC.
  `contains(_:section:in:)` stays, as a wrapper that builds a `Page`.
- **Effect.** Per load, 144,745 characters are split and normalised instead
  of 438,835 (117 citations on 50 pages). Removed work, so it holds in
  release.
- **Tests.**
  - The existing `Fixtures/quote-cases.json`, which Python and Swift share.
  - DerivationCorpusTests' check that every quote is still on its page.
  - `missingQuotes` equals, in order, a loop that calls the kept
    `contains(_:section:in:)` once per citation, as today's code does.
  - CurationQuoteTests and CurationEvidenceTests.

**X3. Drop dead derivation work at load.** *S, removed work, CI: counts.*
- **(a) Build only the `.standard` link table** (`Derivation.swift:533`).
  `derivedImplications` and `derivedSources` lose their `options`
  parameter. Every caller passes `.standard`:
  `PageDerivations.swift:163-164`, and six lines in DerivationTests (682,
  690, 692, 695, 767 and 1011), which drop the argument.
- **(b) Stop storing `derivedBarriers`** (`:423`, `:532`). The stored
  property is read at ten sites, and each calls `allDerivedBarriers()`
  instead, bound once where it is read twice:
  - `DerivationChecks.swift:104`;
  - `DerivationCorpusTests.swift:89`, `147`, `218` and `221` (one binding
    for the last two);
  - `DerivationTests.swift:559`, `793`, `797` and `1010`;
  - `ExplorerResultTests.swift:327`.

  The method `derivedBarriers(from:to:)` keeps its name, so a site that is
  missed reads a function and fails to compile; none can silently change
  meaning. Do not make it a computed property.
- **(c) Carry `unstatedSteps` on `Derivation.Link`.** `makeLinkTable`
  computes it from the proof it already builds (`:645-667`), with the loop
  `ExplorerWriter.unstatedSteps` runs. `PageDerivations.row`
  (`PageDerivations.swift:219-220`) reads it, instead of building a proof
  for every derived row on the main actor at every RelationsView
  evaluation. On LWE that is 163 trees and 831 tree rows per evaluation.
- **Effect.**
  - Each load loses 1,000 proof trees, 272 barrier pairs and 4 uncached
    closures.
  - Each inspector evaluation builds no proof trees.
  - Removed work, so it holds in release.
- **Tests.**
  - (a): nothing reads `.all`.
  - (b): DerivationCorpusTests compares the records with the golden, and
    `DerivationTests.swift:559` still expects 6.
  - (c): for every standard link, `link.unstatedSteps` equals an
    `ExplorerWriter`'s `unstatedSteps(proof)`, and `relationCount` equals
    `proof.relationIDs.count`.
  - PageDerivationsTests.

**X4. Run a Horn prefilter before on-demand closures.** *M, asymptotic, CI:
counts and timing.*
- **The filter.** For each engine and step set (`defaultSteps` for
  `.standard`, `steps` for `.all`, the clean engine's own), build a
  counter-based Horn closure over object indexes (Dowling–Gallier). It is
  monotone, so it can continue from a base. The callers below take a
  parameter `prefilter: Bool = true`, for the test.
- **Where it skips the rule-engine closure.** Wherever the target is not in
  the Horn closure:

  | Caller | Horn closure checked |
  |---|---|
  | Each completion candidate z (`DerivationAnswer.swift:482-500`) | start ∪ {z} |
  | Each implied-by pair (`DerivationBackward.swift:96-130`) | {a, b} |
  | `chainExists` (`DerivationBarriers.swift:125-137`) | start, over the clean steps |
  | `isDerivable` (`:351-358`) | start ∪ {conclusion} |
- **Effect.** Closure counts:

  | Query | Today | With the filter |
  |---|---|---|
  | Completions, `owf`⇒`pke` | 161 | 5 |
  | Completions, `pke`⇒`ot` | 162 | 0 |
  | Completions, `ddh`⇒`io` | 169 | 0 |
  | Implied-by `ot` | 412 | 0 |
  | Implied-by `pke` | 96 | 38 |
  | Implied-by `nizk` | 611 | 154 |
  | Implied-by, all 234 targets, default | 168,113 | 907 |
  | Implied-by, all 234 targets, models included | 205,902 | 1,842 |

  In the Python reference, the `owf`⇒`pke` answer goes from 146 to 18 ms and
  implied-by `ot` from 513 to 35 ms. The explorer recomputes on every edit
  to a question, so this is felt while typing. Asymptotic, so it holds in
  release.
- **Why it is exact.** Every fact the engine derives comes from a step in
  the same set whose hypotheses are all derived: in full, weakened, or as a
  `metBy` producer's established fact. So the engine's facts are a subset of
  the Horn closure, and a skipped closure could not have reached the target.
  With the prefilter, the reference's golden file regenerates byte-identical.
- **Tests.**
  - A corpus test with the prefilter on and off compares `implying(t)` for
    every target in both settings, and `completions` for every golden
    no-path query.
  - DerivationCorpusTests.
- **Risk.** Use the step set that matches the options. Never use the
  relaxed engine's set, which includes quarantined steps.

**X5. Semi-naive layers and phase skipping.** *M, asymptotic, CI: counts.*
- **Change.**
  - **Precompute, per engine:** `consumers[object]`, the positions of the
    steps that read it in ascending order, once for `defaultSteps` and once
    for `steps`; and the list of zero-hypothesis steps.
  - **Track new facts:** `State` keeps `buckets[depth]` of object indexes,
    appended by `add`, `addWeak` and `addEstablished`. An established fact's
    object is its requirement's hypothesis. The buckets persist across
    phases.
  - **Visit less:** at layer k, visit the union of the consumers of
    `buckets[k − 1]`, deduplicated with a stamp array and in ascending
    order, plus the zero-hypothesis steps at layer 1. The loop body, the
    layer counter and the termination are unchanged.
  - **Skip phases:** phase 2 runs only when phase 1 saw a `.waits`. Phase 3
    runs only when some non-default step's first hypothesis has a fact.
  - **Share work between settings:** both settings of a single closure come
    from one `State`, finalised after phase 2 for `.standard` and continued
    with phase 3 for `.all`.
  - `Visits` gains `.semiNaive`, X1's flags included, and it becomes the
    default. `.everyStep` stays; `.flagged` may go.
- **Effect.** Step visits per load fall from 595,770 to 2,991 (9,486 with
  semi-naive layers alone). In CPython the 524 closures went from 268 to
  33 ms. Every on-demand closure gains the same. Asymptotic, so it holds in
  release.
- **Why it is exact.** The Python port gave the same facts, weak facts,
  established facts and refusals in all 4,716 closures (9 engines × 262
  objects × 2 settings), and the golden file is byte-identical.
- **Tests.**
  - X1's differential test, now against `.semiNaive`, comparing facts, weak
    facts, `established` and `refused`: every object × engine × setting,
    plus every golden start set and seeded random start sets of 2–3
    objects.
  - The Python reference stays the naive specification.
- **Risk.** The highest in X. The trigger must include weak and established
  facts. The weakened-hypothesis refusal (`Derivation.swift:1060-1064`) is
  recorded while visiting a step that is not ready, so the visit set must
  still reach that step at the same layer. The differential test, refusals
  included, is the guard. X5 lands last in X, in its own commit, and can be
  reverted alone.

**As built** (`eff/X`: one commit per item, then one review fix). The
tests are the new `DerivationEquivalenceTests.swift` (four corpus tests
that print a line each, §5, and `quotePageReused` on the shared quote
cases) and new DerivationTests on an every-rule fixture (`loopsAgree`,
`prefilterAgrees`, `inspectorUnstatedSteps`). The golden file is
unchanged.
- **The old loop is `Engine.Loop.legacy`,** not `visits: .everyStep`.
  `Engine.closure(from:options:loop:)` defaults to `.current`, which is X1
  and X5 together; there is no `.flagged` or `.semiNaive`. `.legacy` runs
  `legacyRun`, the `21df5d7` `run` byte for byte, for all three phases,
  and reads the closure back densely, scanning every object as `21df5d7`
  did (`result(of:…dense:)`). Before the review's fix both loops shared
  X5's read-back from `reached`, so the tests never held it to the old one.
- **The prefilter switches** are `prefilter: Bool = true` on `implying`,
  `completions`, `chainExists` and `isDerivable`.
- **X3(b) has ten read sites,** as listed above, not the critic's seven.
  Each calls `allDerivedBarriers()` by name. X3(a)'s six DerivationTests
  calls exist too, and drop `options:`.
- **X5** gives both settings of a single closure from one run,
  `Engine.closures(from:)`, which `Derivation.init` uses. Phase 3 also
  runs when a non-default step has no hypothesis.
- No legacy file was written. When the copies go, `Engine.Loop.legacy`,
  `legacyRun`, `dense:` and the `prefilter:` switches go with them.

### 2.7 Track J: the renderer's JavaScript

**J1. Memoise KaTeX per web view.** *S, asymptotic on re-render, CI: counts
and JSC timing.*
- **Change** (`ccwiki.js:61-70` `installKatexMacros`; clear the cache in
  `ensureMarkdown`'s rebuild branch, `:339-351`).
  - **Cache:** wrap the patched `renderToString` with a `Map` keyed by an
    option signature plus `"\0"` plus the expression. The signature is every
    merged option except `macros`, as name=value.
  - **When it does not cache:** when an option's value is an object or a
    function; when the merged macros are not `currentMacros`; or when the
    expression matches `/\\(?:gdef|xdef|global)(?![A-Za-z@])/`, which also
    clears the map. A call that throws caches nothing.
  - **Size:** **1,000** entries, the least recently used going first (as
    built; below).
  - **Macro table changes:** `ensureMarkdown` clears the map when it
    rebuilds, and turns caching off if any macro body holds a global
    definition.
  - **Coverage:** prose and display math, preview cards and pseudocode,
    since `pseudocode.js` calls the same patched function.
- **The cap, from measured hit rates.** On the corpus's real call sequence
  (7,320 calls, 3,299 distinct keys, 4.39 M characters of HTML), node 22,
  with first in, first out, as the plan first had it:

  | Second render | Cap 1,000 | Cap 2,000 | Cap 2,500 | Cap 3,300 |
  |---|---|---|---|---|
  | Each page again right after itself (A A B B …) | 99.9% hits | 100% | 100% | 100% |
  | 100 visits drawn at random from the 87 primitive and assumption pages (about 59 distinct), then Back (50 seeded sessions) | 91.5% | 100% | 100% | 100% |
  | The 100 pages with the most formulas (2,234 distinct), most first, then Back | 67.0% | 92.8% | 100% | 100% |
  | The corpus a second time in path order (A … Z A … Z) | 49.2% | 54.7% | 54.9% | 100% |
  | Most HTML held per web view | 1.48 M characters | 2.88 M | 3.51 M | 4.39 M |

  The third row is a worst case for a Back history: the 100 pages with the
  most distinct formulas each, which are 36 reductions, 33 primitives, 17
  assumptions and 14 other pages. Visited in path order, fewest first, or
  in 50 seeded shuffles, it gives 65–67%, 91–92%, 100% and 100%. At a cap
  of 2,500 it holds at most 3.16 M characters.

  Any one page fits any cap: LWE, the largest, has 166 keys. Every
  re-render the app makes is of a page that web view rendered recently:
  Back and Forward, the editor's preview of the page being edited, the
  current page after a pull or a preference change, a review refresh. So
  the plan sized a first-in-first-out cap to hold a whole Back history
  (`NavigationHistory.capacity` is 100), and chose 2,500.

  **As built, the cap is 1,000, the least recently used going first.** The
  build measured both on the same call sequence. A hit moves its entry to
  the end, so a page rendered again keeps the formulas it just used, which
  first in, first out drops from among the oldest: at 1,000 it missed 0.1%
  even on a page rendered right after itself. At 1,000, least recently
  used holds 82.1% of a 100-page Back history in path order and 100% in
  shuffled orders, all of a 50-page one, and at most about 1.6 M
  characters. render-pipeline.md §3, "The KaTeX memo", has its hit rates
  for each limit. The worst-case row above was measured first in, first
  out only. A second pass over the whole corpus in one web view thrashes
  any cap smaller than its 3,299 formulas. No reader does that, so the cap
  is not sized for it, and M0's path-order line is expected to move
  little.
- **Effect.** In V8 (markdown-it, KaTeX and pseudocode; no DOM; min of 5,
  all caps in one run, first in, first out), the second render of the
  corpus:

  | Order | No memo | Cap 1,000 | Cap 2,000 | Cap 2,500 | Cap 3,300 |
  |---|---|---|---|---|---|
  | Each page again right after itself | 444 ms | 199 ms | 207 ms | 192 ms | 194 ms |
  | The corpus a second time in path order | 476 ms | 470 ms | 472 ms | 427 ms | 195 ms |

  The capped columns of the first row differ only by noise. A re-render of
  LWE goes from 20.9 to 4.9 ms. A first render gains 4–5%, from repeats
  within the page. A first pass over the corpus in one web view gains
  11–14%: 54% of its calls repeat a formula already rendered, on that page
  or an earlier one. Re-renders happen on Back and Forward, at every 300 ms
  pause in the editor preview, after a pull or a preference change, and
  when the review refreshes. As built, memory is at most about 1.6 M
  characters of HTML and keys per web view, reached only after 1,000
  distinct formulas in that view. This is JavaScript, so the Swift build
  does not change it.
- **Why it is exact.** In jsdom running the real `ccwiki.js`, 1,766 of 1,766
  renders were byte-identical with and without the memo: the corpus twice in
  one web view, also with a cap of 50, and rendered twice. In KaTeX 0.16.47
  only `\gdef` and `\global\let` write the shared macros object. No page and
  no `macros.ts` uses `\gdef`, `\xdef` or `\global`.
- **Tests** (new `RenderMemoTests.swift`, JSC, `CCWIKI_WIKI`).
  - Every formula of every page goes through the patched wrapper twice and
    must equal the vendored `katex.renderToString` in a second, unpatched
    context with the same options.
  - A `\gdef` fixture clears the map and matches the unpatched output.
  - M0's `RenderCorpusTests` still finds every second render equal to the
    first, in both orders.
  - `FixesJsTests.noticesKeepMacros` still passes.
  - Document the memo and its cap in render-pipeline.md §3.
- **Why this one.** The UI analysis proposed a per-render map inside
  `ccwiki-markdown.js`. This wrapper also covers pseudocode and previews,
  and it was proved through the real shell. One memo, not two.

**J2. Render review blocks only when shown.** *S, asymptotic, CI: counts
and JSC timing.*
- **Change.** `topLevelBlocks` (`ccwiki-markdown.js:954-984`) pushes blocks
  whose `html` is a memoised ES5 getter. It keeps the same try/catch
  fallback to `<pre>`. Gap entries never read it.
  `CCwikiMarkdown.reviewEntries(md, file)` keeps its signature, which M0
  calls.
- **Effect.**

  | Case | Today | Lazy |
  |---|---|---|
  | Block renders, one-line edit to every page | 12,748 | 3,512 |
  | `reviewEntries`, corpus (V8) | 807 ms | 457 ms |
  | `reviewEntries`, LWE | 24.3 ms | 5.4 ms |

  It runs when a review opens and at every save while it is open.
- **Why it is exact.** With simulated one-line edits, the entries JSON was
  byte-identical for 883 of 883 files.
- **Tests.**
  - Copy today's `ccwiki-markdown.js` to
    `Tests/CCwikiTests/Fixtures/legacy/ccwiki-markdown.js`, with §2.1's
    header as its first line.
  - RenderMemoTests loads old and new into two JSC contexts and compares
    `JSON.stringify(reviewEntries(...))` for a one-line edit to every corpus
    page. The stub katex is enough here.
  - ReviewEntriesTests and FixesJsTests are unchanged.
- **Risk.** Old-side blocks now render after the new side is parsed.
  `linkDestinations` (`ccwiki-markdown.js:837-843`) is filled at parse time,
  and the last writer wins. Output could differ only if two raw destinations
  normalised to the same href with different targets. That never happens in
  the corpus, and the corpus comparison is the guard.

**J3. Log the render time the page posts.** *S, measurement only.*
- **Change.** `WebController.swift:278-297` logs `message["ms"]` with the
  path, at debug level under category `render`.
- **Effect.** No change in behaviour. It gives WebKit before and after
  numbers for J1 and J2 on a Mac.

**As built** (`eff/J`: one commit per item, then four fixes after the
review and a record of how they were checked). The tests are in
`RenderMemoTests.swift`: rule tests on a KaTeX stub that numbers its
answers, `sharedTable` against the vendored KaTeX, the review against
`Fixtures/legacy/ccwiki-markdown.js` (`reviewHazards`,
`reviewLinkDestinations`, `reviewTableChanges`,
`reviewRendersShownBlocks`), and two corpus tests that print a line each
(§5). render-pipeline.md §3 documents the memo ("The KaTeX memo") and the
lazy review ("Blocks render when shown").
- **J1 is least recently used, capped at 1,000** (above), not first in,
  first out at 2,500.
- **J1's rules are wider than above.** §2.7's KaTeX facts were incomplete:
  KaTeX 0.16.47 also keeps `\@eqnsw` in the shared table between formulas,
  set by numbered environments, `\nonumber` and `\notag`; `\tag` sets
  `\df@tag`; and after every formula KaTeX deletes `\color` and
  `\current@color` from the table. So:
  - a formula with an `@`, or naming `\begin`, `\nonumber` or `\notag`, is
    never kept;
  - a global definition (`\gdef`, `\xdef` or `\global` as a control word,
    or a `globalGroup` call) empties the memo and turns it off until
    `ensureMarkdown` installs another table, since what it defined can
    define more when a later formula uses it;
  - the memo is off for a table with a macro body that holds a global
    definition, an `@`, `\begin`, `\nonumber` or `\notag`, or a macro named
    `\color` or with an `@` in its name.

  No wiki formula or macro meets any of these, so the hit rates do not
  move.
- **J2 replays link destinations.** The risk §2.7 accepted does change
  output: 3 hazard fixtures differed. Each text's parse records the
  destinations it asks `normalizeLink` about (`parseWithDestinations`), and
  a block's first read asks again before it renders.
- **J2 renders every block,** the old text's first, as they rendered
  before, when a block's formula or the live table could change KaTeX's
  table. A formula that only reads the table still renders lazily. No wiki
  page has such a formula, so the corpus counts stand: 3,512 blocks
  instead of 12,748 for a middle-line edit, 5,240 instead of 12,814 for
  the first and last lines.
- **J3** also sends the page's `path` in its `rendered` message, since
  another render may have been asked for before the message arrives.
- **The JSC expectations in §2.3** were made at 2,500 first in, first out.
  In V8 the built memo gave −60% on each page rendered again right after
  itself, −5% on a first render of every page, and nothing on the corpus
  a second time in path order (render-pipeline.md §3). The first is the
  case Back, Forward and the editor's preview resemble.

### 2.8 Track U: the app model and the main window

No test builds an `AppModel` (§1.5). U's tests call pure seams, in a new
`MainWindowSeamTests.swift`. What they cannot reach, the maintainer's
`make shots` checks.

**U1. Render the page before the search sync.** *S, CI: timing (the sync's
own line).*
- **Change**, in `AppModel.performLoad` (`AppModel.swift:1176-1190`):
  1. Start the sync (`async let searched`).
  2. Await the revision check: `loadedRevision` must be set before a page
     renders (corrections §3.5).
  3. Notify the sessions and refresh the quick switcher.
  4. Await the sync.
  5. Re-run the open ⌘S, ⇧⌘R and ⇧⌘F queries.
  6. Run the job housekeeping.

  `libraryDidLoad` splits into `sessionsDidLoad(_:)` and `searchDidSync()`.
- **This supersedes a documented order.** reader-comforts §4.1 (the
  `App/AppModel.swift` row) fixes the load as the revision check, then
  `searchIndex.sync`, then housekeeping, then `libraryDidLoad`. The comment
  at `AppModel.swift:1176-1177` says "the page on screen waits for both".
  U1's commit updates the comment, records the new order in reader-comforts
  §3.2 beside "Loads are serialized", and marks the order in §4.1's row as
  superseded by this item.
- **Effect.** At launch and after every pull, the first page appears
  without waiting for the sync. In debug that saves about 1.1 s when the
  sync has nothing to do, and about 3 s on the launch after an app update
  (a full rewrite). The saving is smaller in release, never zero. A search
  typed meanwhile waits on the actor, as today.
- **Why it is safe.** Nothing a render reads touches `SearchIndex`:
  `RenderRequest` and `PageRenderer` reference no search type.
- **Tests.** ReaderSessionStateTests, LibraryRefreshTests and
  SessionStartPlanTests. Shots of ⌘S right after launch.
- **Risk.** `ScreenshotRunner` may assume search is ready when the page
  appears. The maintainer's `make shots` checks the ⌘S captures.

**U2. ⌘O sorts once, and only when shown.** *S, removed work, CI: UI.*
- **Change.**
  - In `presentQuickSwitcher` (`ReaderSession.swift:586-592`), the excluded
    path is set at `:588`, the query reset at `:589` and the second refresh
    at `:590`. Replace the last two with an explicit empty case:
    `if model.quickSwitcherQuery.isEmpty { model.refreshQuickSwitcher() } else { model.quickSwitcherQuery = "" }`.
    A query already empty, as when ⌘O opens in window B after window A with
    a different page to leave out, then refreshes once without relying on
    `didSet` (`AppModel.swift:465-467`) running for an equal value.
  - `sessionsDidLoad` (U1) refreshes only if some session has
    `quickSwitcherPresented`.
- **Effect.** Opening ⌘O sorts 877 titles once instead of twice, each sort
  about 5,450 `localizedCaseInsensitiveCompare` calls. A load with no
  switcher open sorts nothing. This is ICU work, so it holds in release.
- **Tests.** Shots of ⌘O in one window and then in another, each list
  leaving out its own window's page, and of ⌘O after a pull with none open.

**U3. The Relations inspector stops reading the explorer's question.** *S,
removed work, CI: test.*
- **Change.**
  - **(a) A yes/no instead of a query.** `explorerQuestion`'s guard
    (`AppModel.swift:1601-1608`) moves into a `nonisolated static`
    `canExplore(_ named: [String], manifest:derivation:)`, as `siteURL` is
    one. The instance `canExplore(from:to:)` calls it without reading
    `explorerQuery`, and `explorerQuestion` is built on it, so the two
    cannot disagree.
  - Seven call sites decide visibility with `canExplore(from:to:)` and build
    the query in the action, with `model.explore(from:to:)`, which reads the
    toggle then (SWIFTUI-RULES §3.5):
    - `RelationsView.swift:132` (a barrier row's `exploring:`);
    - the `exploring(_:role:focus:)` helper, `:266`, `:268`, `:272` and
      `:274`, which returns the objects to ask about instead of a query;
    - `:389` (an object row's context menu);
    - `DerivedRelationsSections.swift:165`.

    `RelationsExplorerView.swift:733` is the explorer itself, which reads
    its question anyway. It stays.
  - **(b) The subject alone.** `canExploreCurrentPage`
    (`ReaderSession.swift:740-745`), which the menu bar reads, builds a
    whole `PageRelations` to read its subject. A new static
    `PageRelations.subject(path:manifest:)` gives the subject alone.
- **Effect.** Editing a question in the explorer no longer rebuilds
  PageRelations and PageDerivations in every window showing the Relations
  tab (163 derived rows each on LWE). The menu bar stops building every
  relation group of the page being read.
- **Tests.**
  - The static `canExplore` on a fixture manifest: false for a complexity
    class, an unknown id or an empty derivation; true for ordinary objects.
  - For every corpus page, `PageRelations.subject(path:manifest:)` equals
    `PageRelations(path:manifest:).subject` (`Subject` is Equatable).
  - Shots of the Relations tab's Explore items.

**U4. A sync progress line stops rewriting `syncState`.** *S, asymptotic
per line, CI: UI and test.*
- **Change.**
  - `appendSyncLine` (`AppModel.swift:1386-1395`) stops writing
    `syncState = .running(line.text)` at `:1393-1394`. It writes a new
    `private(set) var syncProgress: String?` instead.
  - `syncState = .running(phaseText)` is still written at the phase
    changes (`:1295`, `:1328`), and every assignment of `syncState` clears
    `syncProgress`.
  - `syncProgress` is read in two places only:
    - a leaf `SyncProgressText` in the status bar's `.running` case
      (`RootView.swift:243-249`), showing `syncProgress ?? message`
      (SWIFTUI-RULES §6.3);
    - `SyncLogView.subtitle(for:progress:hasLog:)`, so the open sheet keeps
      showing the latest line. The new parameter defaults to nil, so
      FixesUiTests compile unchanged.
  - Every other reader of `syncState` stays as it is, since the state now
    changes only between phases: the toolbar (`RootView.swift:137`, `:143`),
    the Sync menu item (`CCwikiApp.swift:365`), Sync Now
    (`SidebarView.swift:79`), the reader's empty state
    (`ReaderView.swift:252`, `:258`), Settings (`SettingsView.swift:290`,
    `:293`), `RelationsView.swift:782` and `RelationsExplorerView.swift:91`.
- **Effect.** Each progress line (412 or more per clone) redraws one `Text`
  per window, and the sheet when it is open. `RootView`, the menu bar and
  the empty state that every window shows during the first clone
  re-evaluate only at phase changes, about 3 times per sync.
- **Tests.**
  - `SyncLogView.subtitle`: `.running("Fetching…")` with a progress line
    reads "Running: " and that line; with nil it reads
    "Running: Fetching…"; the other states ignore it.
  - Shots of the idle, running (the line moving), succeeded and failed
    states, and of the sheet open during a sync.

**U5. The sidebar's Cited by rows as equatable leaves.** *S, removed work
with L3, CI: UI.*
- **Change.** `citingRow(_:)` (`SidebarView.swift:90-114`) becomes a leaf
  `CitingRow(backlink:)`, `Equatable` with a `nonisolated static func ==`
  comparing the backlink, applied with `.equatable()`, as L3 does for
  `BacklinkRow`. It reads `backlink.sourcePath` and `backlink.context` only,
  which compile before and after L3, so U and L land in either order.
- **Effect.** After L3, a citing row runs `plainText` for its tooltip when
  its backlink changes, not at every evaluation of the sidebar.
- **Tests.** Shots of the sidebar on a reference page.

**As built** (`eff/U`: one commit per item; the review found only an
error in the builder's report, so nothing was fixed in the code).
- **⇧⌘F's open query runs again in `sessionsDidLoad`,** before the sync,
  not after it as step 5 has it: TextGrep reads the pages `apply` sets, not
  the search index. `searchDidSync` runs ⌘S's and ⇧⌘R's again.
  reader-comforts.md §3.2 records the new order, and architecture.md §3
  shows it.
- **The tests construct a real `AppModel`,** contrary to §1.5 and the
  first paragraph above. `AppModelObservationTests.swift`, in place of
  `MainWindowSeamTests.swift`, builds one on temporary paths with a fixture
  clone. Its init and load reach no git and no network, and the suite runs
  serialized. It has 8 tests; the 2 on the real wiki return early without
  `CCWIKI_WIKI`. U1's test checks that a query typed during a load is
  answered from the index the load wrote; it does not prove the order.
- **U2** is `AppModel.resetQuickSwitcher(excluding:)`, which
  `presentQuickSwitcher` calls, with the empty query as its own branch.
  `quickSwitcherExcludedPath` is `private(set)`. A load with no switcher up
  sorts nothing, and a test checks it (it fails at `21df5d7`).
- **U3's legacy copy is nested,** a `private enum Legacy` in that file,
  since `Legacy/` was not in U's files. The static `canExplore` is compared
  with the copy of `explorerQuestion` on the fixture manifest, with and
  without derivations, and on the real one.
- **U4.** Every write of `syncState` goes through `enterSyncPhase`, which
  clears `syncProgress`. The status bar moved to `UI/StatusBar.swift`,
  unchanged but for its running line, with the leaf `SyncProgressText`. A
  `withObservationTracking` test checks that `syncState`'s readers are
  told once per phase, never per line.
- **U5's `CitingRow`** is private to `SidebarView.swift`.

### 2.9 Track W: the other windows

No test builds an `EditorSession`, which needs an `AppModel` (§1.5). W's
tests are in a new `WindowObservationTests.swift`.

**W1. Compute the explorer's suggestions once per evaluation.** *S, removed
work, CI: UI.*
- **Change.** In `RelationsExplorerView.swift:361-411`:
  - compute `let items = suggestions` once in `suggestionPane`;
  - derive the highlight once, and pass each row a Bool;
  - put the `onChange` handlers on `items.map(\.id)` and on that highlight;
  - `moveHighlight` (`:375-381`) computes the suggestions once.
- **Effect.** Each keystroke or arrow press makes 595
  `FuzzyMatcher.match` calls instead of 6,545, on the main actor.
- **Tests.** RelationObjectMatcherTests. Shots of the highlighted row and
  of VoiceOver's count announcement.

**W2. The editor writes `saveState` only when it changes.** *S, removed
work, CI: UI and a probe.*
- **Change.** At `EditorSession.swift:174` (and the same form at `:232`):
  `let next: SaveState = hasUnsavedText ? .saving : .saved; if saveState != next { saveState = next }`.
- **Effect.** Typing redraws only SourcePane. The editor's chrome and the
  Jobs window's Open Draft PR gate (`JobDetailView.swift:613-645`, a
  private-text scan plus `fileExists`, run twice) update twice per burst of
  typing instead of on every key.
- **Whether it gains anything depends on the toolchain.** Newer Observation
  macro expansions skip the notification when an Equatable value is
  assigned an equal one, and on those W2 changes nothing. So the test is a
  probe: a test-local `@Observable` class holding an
  `EditorSession.SaveState` of `.saving`, assigned `.saving` again under
  `withObservationTracking`. It prints whether CI's toolchain notified on
  the equal assignment, and asserts nothing about it. If it did not, §5
  records W2 as insurance against the toolchain, not a gain.
- **Tests.** The probe, and the editor's save and conflict tests.

**W3. Job detail: transcript and clock as leaf views.** *S, CI: UI.*
- **Change.** In `JobDetailView.swift`:
  - `TranscriptView(job:)` owns the ScrollViewReader, the
    LazyVStack/ForEach, the tail bar, the follow-tail `onChange` and
    `followsTail`, and it alone reads `job.log` (`:495-560`).
  - `ElapsedTime(startedAt:finishedAt:)` wraps its Text in
    `TimelineView(.periodic(from: startedAt, by: 1))` while the job runs
    (`:201-221`; SWIFTUI-RULES §1.3). Today the time is computed from
    `Date()` in the body (`Job.swift:466-469`).
- **Effect.** A transcript flush (up to 10 Hz) updates only the list. The
  elapsed time ticks during silent tool calls; today it freezes, then
  jumps.
- **Tests.** Shots of a running and a finished job. The Job and JobCenter
  tests are unaffected.

**W4. The editor preview reuses its overlaid index.** *S, removed work, CI:
test.*
- **Change.** A small value, `PreviewOverlayCache`, holds `(overlay index,
  newPagePaths)`, keyed by `model.libraryGeneration` and the review
  snapshot's identity. EditorSession keeps one, and `previewRequest`
  (`AppModel+Editor.swift:99-122`) asks it before calling
  `index.overlaying(added)`.
- **Effect.** For jobs that add pages, each 300 ms preview pause no longer
  runs `WikiIndex.assemble` over about 900 files (CI's `index` phase:
  16 ms in debug) or parses the added pages again.
- **Tests.** On the cache value alone, with no session: for a fixture index
  and a job snapshot that adds a page, the cached overlay resolves the
  page's links as one built fresh (each link's href and kind), and the cache
  rebuilds when the generation or the snapshot changes.

**As built** (`eff/W`: one commit per item, then two review fixes). The
tests are in `WindowObservationTests.swift`.
- **W3: `followsTail` stays `@State` in `JobDetailView`,** and reaches
  `TranscriptView` as a `@Binding`, so Follow survives a switch to Changes
  and back, as it did. **`ElapsedTime` ticks only while the job
  `isActive`:** preparing, running or publishing. A job awaiting review
  has no `finishedAt`, so the first version ticked for as long as a review
  was shown, which may be days; it now shows a fixed time, as `21df5d7`
  did.
- **W4 is `PreviewOverlay`,** keyed on the library generation plus the
  review's added and renamed files, compared whole, not on the snapshot's
  identity. Every autosave takes the review again, with a new tree, digest
  and text, so a key on the whole review rebuilt the overlay at nearly
  every pause (the review's blocking finding). The added and renamed files
  are all `ReviewPayload.addedPages(in:)` reads, so the key is exact.
  `overlayKept`, `overlayKeptAcrossSaves` and `overlayRebuilt` compare each
  request with a private copy of the `21df5d7` request body.
- **W2's probe** prints "window observation: @Observable notifies
  observers of an equal assignment on this toolchain; the editor's
  save-state guard is removed work: its test fails without it", or "does
  not notify" and "insurance: its test passes without it".
  `keystrokeKeepsSaving` builds a real `AppModel` and an `EditorSession`
  on a restored awaiting-review job, with a `.txt` file so no web view is
  made. There were no EditorSession save or conflict tests at `21df5d7` to
  run.
- **W1** moved VoiceOver's count announcement into the suggestion pane,
  `onChange(of: items.map(\.id), initial: true)`.

### 2.10 File ownership, merge order and the two PRs

| Owner | Writes |
|---|---|
| M0 | `Tests/CCwikiTests/IncrementalCorpusTests.swift`, new `RenderCorpusTests.swift`, new `Legacy/LegacyBacklinks.swift`, `.github/workflows/ci.yml` |
| L | `Sources/CCwiki/Wiki/{Wikilink,WikiPage,WikiIndex,PreviewExcerpt,LinkPreview}.swift`, new `Wiki/MarkdownLineEnd.swift`, `Reader/RenderRequest.swift`, `UI/InspectorView.swift`; tests: new `LoadEquivalenceCorpusTests.swift`, new `Legacy/LegacyWiki.swift`, `ReferenceRankerTests.swift` (three constructors), `FixesWikiparseTests.swift` (fixtures) |
| S | `Sources/CCwiki/Search/{SearchIndex,ConceptRanker,ReferenceRanker}.swift`; new `SearchEquivalenceTests.swift` |
| X | `Sources/CCwiki/Wiki/{Derivation,DerivationChecks,CurationQuote,DerivationAnswer,DerivationBackward,DerivationBarriers,PageDerivations}.swift`; tests: `DerivationTests.swift`, `DerivationCorpusTests.swift`, `ExplorerResultTests.swift`, new `DerivationEquivalenceTests.swift` |
| J | `Resources/web/{ccwiki.js,ccwiki-markdown.js}`, `Sources/CCwiki/Reader/WebController.swift`, new `RenderMemoTests.swift`, new `Fixtures/legacy/ccwiki-markdown.js`, `plans/render-pipeline.md` |
| U | `Sources/CCwiki/App/{AppModel,ReaderSession}.swift`, `UI/{RootView,SidebarView,SyncLogView,RelationsView,DerivedRelationsSections}.swift`, `Wiki/PageRelations.swift` (one static), `plans/reader-comforts.md`; new `MainWindowSeamTests.swift` |
| W | `Sources/CCwiki/UI/{RelationsExplorerView,JobDetailView}.swift`, `App/{EditorSession,AppModel+Editor}.swift`; new `WindowObservationTests.swift` |
| Integrator | this file's §5, and §1.3 if M0 corrects it; `PROGRESS.md`; `PLAN.md`, including a row that indexes this plan; `CHANGELOG.md`; `README.md` if anything there changes |
| F (second PR) | `Sources/CCwiki/Wiki/WikiIndex.swift`, `UI/InspectorView.swift`, `App/ReaderSession.swift`, `Reader/{WebController,CCwikiURL}.swift`, `Corrections/SourceLineMap.swift`; tests: new `BacklinkMentionTests.swift`, `SourceLineMapTests.swift`, `ReaderContextMenuTests.swift`, new `SectionLinkCorpusTests.swift` |
| G (second PR) | new `Sources/CCwiki/Wiki/SavedPages.swift`, `App/{Settings,AppModel,CCwikiApp}.swift`, `UI/SidebarView.swift`; new `SavedPagesTests.swift` |

Within each PR the tracks' files are disjoint. The second PR's tracks
then edit some of the first's files (`WikiIndex`, `InspectorView`,
`ReaderSession`, `AppModel`, `SidebarView`), from its head. No track edits
§5, `PROGRESS.md`, `PLAN.md`, `CHANGELOG.md` or `README.md`, so parallel
tracks never conflict on the shared docs. Each track hands the integrator
its commits and what it expects CI to print.

1. **M0 lands first.** The integrator pushes it and opens the efficiency
   PR as a draft at the same time. The standalone timing step is gated off
   ordinary pushes to a branch, so only a `pull_request` run (or a manual
   `workflow_dispatch` run) has it. With the PR open, every later push to
   `claude/efficiency` also runs the `pull_request` workflow, and §5 is
   filled from that run's "measured alone" report, never from the "beside
   the other suites" copy, whose phases move by up to 41% (§1.1). M0's run
   is the baseline in §5. If its backlinks lines contradict §1.3, the
   integrator corrects §1.3 before any track claims a cause.
2. **Then L, S, X, J, U and W, in any order.** Each branches from M0's
   commit. Within a track, the items land in the order of §2.2, each as its
   own commit. Builders do not push. The integrator merges one track at a
   time and pushes after each, one CI run per track, so §5's columns
   attribute each change to a track; the sub-phase lines already isolate
   the items within it. It waits for each run to finish before the next
   push: ci.yml's `concurrency` cancels a run in progress on the same ref,
   so a push made too soon loses the previous track's numbers. L first is
   preferable, since it carries the regression.
3. **Interfaces between tracks are fixed by this plan:**
   - L keeps `Backlink.sourcePath` (S reads it), `Backlink.context` (M0 and
     U5 read it), `headings()`'s signature (S calls it), and `Wikilink`,
     `MarkdownLink`, `WikiIndex.Target`, `WikiIndex.pages` and `.assets`,
     `WikiIndex.plainText(_:)`, `outgoingLinks(in:)` and `resolve(_:from:)`
     as they are. M0's `46685be` copy builds on all but the last two, and
     checks itself against those two;
   - X keeps `answer` and `implying`, which M0 calls, and every existing
     `closure(from:options:)` call compiles through the defaulted `visits`
     (as built, `loop`);
   - J keeps `CCwiki.render`'s payload and `reviewEntries`' signature, which
     M0's `RenderCorpusTests` uses;
   - no track changes an entry point §2.1 item 7 lists.
4. **Two draft PRs** (SWIFTUI-RULES §10.4: small, themed batches):
   - **The efficiency PR**, `claude/efficiency` into `main`: M0 and tracks
     L, S, X, J, U and W.
   - **The reading-features PR**, `claude/reading-features`: tracks F and G
     (§3). It starts from `claude/efficiency`'s head, since F1 builds on L1
     and L3, and merges after it.

   The integrator opens both as drafts: the efficiency PR when it pushes
   M0 (item 1), and the reading-features PR when it pushes the first of F
   and G. The maintainer merges them; no agent does.

---

## 3. Reading features worth building now

These are three of the product analysis's top five: its #1 and #2, and #5
in place of #3 and #4. They are ranked by value for effort and by how much
CI can verify. They build on the efficiency PR's seams and make the second
PR, in two tracks: **F** (F1, F2) and **G** (F3). As built, each track was
reviewed and fixed on its own branch, and both merged without a conflict.
Save Section, which needs both tracks, is the integrator's one commit
after the merges (§3.3).

### 3.1 F1. Backlinks that land on the mention (M, 1–2 days; product #1)

**What the reader sees.**
- **Groups.** The Backlinks tab groups rows by the kind of the linking page:
  - **Mentioned in:** every page that is not a reduction, barrier or
    reference. Open by default.
  - **Reductions and Barriers**, then **References:** collapsed by default,
    each with a count in its header. On a page no prose mentions, the
    first group there opens instead.

  On primitive and assumption pages, 82% of today's rows (517 of 629) are
  reductions or barriers, which the Relations tab already lists.
- **Rows.** Each row shows the page's title and the line that mentions this
  page, at most 3 lines as today. A page that mentions it on several lines
  shows "N mentions", with a disclosure listing each line. 702 mentions (22%)
  are hidden today; LWE has 18 of them and PKE 27.
- **Landing.** Clicking a mention opens that page scrolled to the block
  holding the mention, outlined for 1.2 s. ⌘-click and the context menu
  open it elsewhere, landing on the mention too.
- **Unchanged:** the sidebar's Cited by rows.

**Model.**
- `Backlink { sourcePath, mentions: [Substring] }`: one entry per linking
  page per target, as now, so ReferenceRanker and search are unchanged.
- `mentions` holds the distinct lines, in source order, that contain a link
  resolving to the target. `mentions[0]` is L3's `line`, so `context` reads
  it. `init(sourcePath:line:)` stays as a convenience, so
  ReferenceRankerTests and U5's `CitingRow` compile unchanged.
- Nothing is added to the load beyond about 700 more slices.

**From a mention to the rendered block.** The line is computed only on a
click:
1. Count the line ends in `line.base[..<line.startIndex]` with L1's helper.
   `line.base` is the page's `body`, a `String`, so this is a 0-based
   *body* line.
2. `SourceLineMap` maps a 1-based *file* line, and its
   `init(fileText:renderedMarkdown:)` needs the raw file with its
   frontmatter, which `WikiPage` does not keep. So F adds a body-relative
   form to `Corrections/SourceLineMap.swift`:
   `init(body:renderedMarkdown:)`, the same alignment with a `bodyOffset`
   of 0, against `RenderRequest.markdown` (the body plus the relation-meta
   splice); and `renderedLine(forBodyLine:)`, which is
   `renderedLine(forFileLine: line + bodyOffset + 1)`.
3. Reveal that rendered line.

**What it builds on.**
- L3's `Backlink.line` and L1's `MarkdownLineEnd`.
- `SourceLineMap` (`SourceLineMap.swift:30-88`), whose lines are counted as
  markdown-it counts them, as L1's are.
- `WebController.revealSourceLines(_:mark:)` (`WebController.swift:413`)
  and `ccwiki.js` `revealSourceLines` (`:766`). These scroll to the
  innermost block and outline it; the editor preview already uses them. No
  JavaScript change.
- `WebController.render(_:thenFind:)` (`:122`), the model for a
  `thenReveal` that ReaderSession passes the way it passes `pendingFind`.

**Tests.**
- **Corpus:** for every target, the linking pages and their order equal
  `Legacy.Backlinks.backlinkMap`'s, and `mentions[0]`'s context equals the
  legacy context. The total number of mentions equals the number of distinct
  (source, target, line) triples counted separately from `outgoingLinks` and
  `resolve`.
- **Corpus, the line map:** for every page and every body line n,
  `SourceLineMap(body:renderedMarkdown:).renderedLine(forBodyLine: n)`
  equals `SourceLineMap(fileText:renderedMarkdown:)` mapping file line
  `bodyOffset + n + 1`.
- **Units:** a mention's rendered line on LF, CR LF and lone-CR fixtures; a
  link inside code is not a mention; two links on one line make one
  mention; a mention below the relation-meta splice maps past the inserted
  lines.
- **Shots:** the grouped pane and a landing.

**Files.** `Wiki/WikiIndex.swift`, `UI/InspectorView.swift`,
`App/ReaderSession.swift`, `Reader/WebController.swift`,
`Corrections/SourceLineMap.swift`.

**As built** (track F: `aa37e65`, a typing fix, then four commits for a
review's six findings). The model, the line map and the landing are as
specified. The tests are `BacklinkMentionTests` and `SourceLineMapTests`.
The corpus test compares against `Legacy.backlinkMap(of:)`, L's copy in
`Legacy/LegacyWiki.swift`: the `Legacy.Backlinks.backlinkMap` named above
was the plan's name for it, and no such type was built.
- **How many mentions were hidden.** The "702 mentions (22%)" above counts
  a page's extra links to the target, not its extra lines. By distinct
  lines, the model built here, a port counting wikilinks at `ab81f02`
  gives 505 hidden lines (LWE 5, PKE 2).
- **The groups' open state is the window's.** `ReaderSession` keeps what
  the reader opened and closed (`isBacklinkGroupOpen(_:among:)`,
  `toggleBacklinkGroup(_:among:)`). Held in the inspector's view, it was
  lost when ⌥⌘I hid the inspector. It is not kept across launches, as the
  Relations tab's derived sections are: that would have touched
  `AppModel` and `Settings`, which are G's. A group nobody has touched
  follows `BacklinkGroup.opensByDefault(among:)`.
- **A page no prose mentions opens its first group.** Otherwise the tab
  opened on closed headers alone on 181 of the corpus's 818 targets. 126
  of them are references, where the reason to close a group, that the
  Relations tab lists its rows, does not hold.
- **A row keeps its first line.** With several mentions, the first shows
  under the title until "N mentions" is opened, and the open list holds
  every line. The first build hid it, on 428 of 2,474 rows.
- **Each page's list starts at the top, its rows closed.** A row is known
  by its linking page, so an open "N mentions" came along to the next page
  that the same page links to. The List takes the page's path as its id.
- **A reveal waits for its own page.** `WebController` holds it with the
  page's path. Only that page's "rendered" message, or a failed render,
  ends the wait, and another page asked for drops it. The first build let
  any message use it up, so a quick second click could outline a block of
  the wrong page.
- **The mention is looked up at the click.** `openMention(_:of:_:)` reads
  the window's backlinks then, not the row's slices, which a load may have
  replaced (SWIFTUI-RULES §3.5).
- **A new tab or window lands too.** `ReaderWindow` and `SessionStartPlan`
  carry the body line as `revealing`, beside `find`. That touched
  `OpenInReader.swift`, `ReaderWindowView.swift`, `ReaderWindow.swift` and
  `ReaderSessionState.swift`, outside F's files in §2.10, since they are
  the path `find` already takes.
- **Not built:** the shots. `ScreenshotRunner` has no step for the grouped
  pane or a landing yet.
- **Left open:** `pendingFind` has the race the reveal had. It predates
  F, and the same rule would fix it.

### 3.2 F2. Section links (S, ≤ 1 day; product #2)

**What the reader sees.**
- **The page's context menu.** A right-click inside a section of a page adds
  three items after "Copy Link to Page":
  - **Copy Link to Section:** the cryptology.city URL with `#id`.
  - **Copy Wikilink to Section:** `[[stem#Heading]]`.
  - **Copy CCwiki Link to Section:** `ccwiki://…#id`, which opens CCwiki at
    that section from Notes, Obsidian or a TeX comment. In CCwiki Dev it is
    `ccwiki-dev://…#id`: the link is built with
    `BuildIdentity.externalURLScheme(for: .current)`, so a link copied from
    Dev opens Dev, which is what BuildIdentity's split is for.

  They appear only when the click falls under a heading
  (`ReaderSelection.heading`, `CorrectionTarget.swift:289-296`).
- **Outline rows.** In the inspector they get a context menu with the same
  three items, plus `OpenElsewhereItems` (New Tab, New Window at that
  section). So PKE § CPA and § CCA can sit side by side.
- **The wikilink's form.** It names the page by its stem when the stem is
  unique, and otherwise by its content-relative path without `.md`. It
  names the section by the heading text when that round-trips: the text has
  none of `[ ] | # ^` or a line break, and its slug equals the id. Otherwise
  it uses the id, which is the only way to reach a duplicate heading's `-1`
  id.

**What it builds on.**
- `AppModel.siteURL(slug:anchor:)` (`AppModel.swift:1541`, nonisolated
  static), so AppModel is not edited.
- `CCwikiURL.page(path:anchor:)` (`Reader/CCwikiURL.swift:35`), which
  always writes the internal `ccwiki://` scheme. A new
  `CCwikiURL.external(page:anchor:channel:)` swaps in
  `BuildIdentity.externalURLScheme(for:)`.
- `ReaderContextTarget` (`WebController.swift:668`), whose groups are
  unit-tested without a menu.
- `OpenElsewhereItems`.

**Tests.**
- **Menu:** ReaderContextMenuTests gains a section group that appears only
  with a heading, with its titles and order.
- **Corpus round trip, for every heading of every page:**
  - the URL fragment equals the rendered id;
  - the wikilink resolves through `WikiIndex.resolve` to
    `.page(path, anchor: id)`;
  - for both channels, the copied link read back through
    `CCwikiURL.internalString(for:channel:)` and `destination(of:)` is
    `.page(path, id)`.

**Files.** `Reader/WebController.swift`, `Reader/CCwikiURL.swift`,
`UI/InspectorView.swift`, plus the section items' wiring in
`App/ReaderSession.swift`.

**As built** (track F: `e6396e9`). As specified, with three details. The
tests are `ReaderContextMenuTests` and `SectionLinkCorpusTests`.
- **The wikilink is read back before it is offered.**
  `WikiIndex.wikilink(toSection:text:onPage:)` tries the stem, then the
  path, each with the heading's text, then its id. It returns the first
  form that `WikilinkParser` and `resolve` take back to the section, and
  nil when none does, which leaves the item out. A heading's text also
  may not hold a `\`.
- **The outline's rows are equatable leaves** (`OutlineRow`). A context
  menu's content is built with the row's body. Without `.equatable()`,
  every scroll that moved the highlight parsed and resolved every
  heading's wikilink again (SWIFTUI-RULES §6.3). `.listRowSeparator` sits
  outside it.
- **Save Section joined the group at integration** (§3.3), as its last
  item in both menus.

### 3.3 F3. Saved pages (S–M, 1–2 days; product #5)

**What the reader sees.**
- **Saving.** Wiki ▸ Save Page (⌘D, Safari's bookmark key, unused in CCwiki
  today) saves the page. When the page is already saved, the item reads
  Remove from Saved.
- **The list.** A **Saved** section sits at the top of the sidebar, above
  Cited by. It is collapsible and hidden when empty. Whether it is open is
  the same in every window and kept between launches
  (`AppModel.showsSavedPages`). New entries go to the end. Rows can be
  reordered by dragging, or with Move Up and Move Down in each row's menu
  and as VoiceOver actions. Each row has `OpenElsewhereItems` and Remove
  from Saved. A missing page's row offers Search the Wiki for “title”
  instead of `OpenElsewhereItems`. Wiki ▸ Saved Pages lists the entries
  for the keyboard, as Safari's Bookmarks menu does; a missing page is
  disabled there. It persists across launches and is the same in every
  window.
- **After a pull.** In `AppModel.apply`, in the same step that installs
  the new index, a saved page whose file went is looked up by its stored
  title. First it is tried as `[[title]]` resolves it (aliases and
  basenames), taking a whole page only and never a section. Then it is
  tried as the one page with exactly that title. Found, the row points
  there and takes that page's title. Not found, it stays, dimmed, reading
  "No longer in the wiki", and a click searches ⌘S for its title. The
  2026-10-04 pull deleted 101 pages, so this case is real.
- **Sections.** "Save Section" joins F2's section group, after G's model
  is on the branch. A saved section's row reads its page's title over
  "§ Heading", and Wiki ▸ Saved Pages names it "Page § Heading".

**Model.**
- A pure `SavedPages` value with `{path, anchor?, title, savedAt}` and
  these operations: add, remove, move, contains, and
  `reconciled(with: WikiIndex)`.
- It persists as JSON in UserDefaults, as `CCwikiSettings.explorerRecents`
  does (`App/ExplorerSettings.swift:30-39`), through a new accessor in
  `App/Settings.swift`. CCwiki Dev's separate bundle id keeps its list
  apart.

**Tests.**
- `SavedPagesTests`: add, remove, reorder, and a persistence round trip.
- Reconciliation against a fixture index where one page is deleted and one
  renamed with its old name kept as an alias.
- Shots of the sidebar section.

**Files.** New `Wiki/SavedPages.swift`, `App/Settings.swift`,
`App/AppModel.swift`, `UI/SidebarView.swift`, `App/CCwikiApp.swift`.

**As built** (track G: `9b73789` to `de0340c`, then five commits for six
of a review's nine findings; two more were this section's text and
design-system.md's, and the ninth is the shots. Save Section is one
commit at integration, and the integrated branch's review gave it two
more: none under the page's title, and a section looked up on its page
after a pull). The model, its JSON and the sidebar section are as
specified. The tests are `SavedPagesTests`, and `SavedPagesModelTests`,
which loads a real `AppModel` over the fixture clone.
- **Reconciliation also takes the one page with exactly the title.** A
  slug keeps its case, so no link with the old title finds a file renamed
  from `Oblivious RAM.md` to `oblivious-ram.md`. Over the wiki's 51
  renames, the link alone finds 25. With the exact title it finds 43, and
  never a wrong page. The other 8 changed their title with their file
  name, before the wiki had frontmatter titles, and no lookup finds them.
  Neither finds any of the 101 pages the 2026-10-04 pull deleted, so they
  read as missing, as they should. The link is taken only when it
  resolves to a whole page: a stored title with a `#` would otherwise
  point at a section of another page.
- **Open or closed is app-wide.** As a fresh `@State` per sidebar, Saved
  opened again in every new tab and window and after a relaunch. It is now
  `AppModel.showsSavedPages`, kept in the user defaults, as the derived
  sections are.
- **Move Up, Move Down and Wiki ▸ Saved Pages are additions.** A drag has
  no keyboard or VoiceOver form on macOS, and the rows are
  selection-disabled buttons that ↑ and ↓ skip. Someone using only the
  keyboard can open a saved page from the menu and remove the page being
  read with ⌘D, but cannot reorder or remove the other entries.
- **Save Section** is the last item of F2's section group, in the page's
  menu under a heading and in the outline's, and reads Remove Section from
  Saved once the section is saved. The entry keeps the heading as the
  outline showed it, in an optional `sectionTitle`, so a list written
  before reads unchanged. Reconciliation looks up a page by its title
  alone, and a section follows its page. On the page, the section is
  found by its id and takes its heading's text as it is now, or else by
  its heading and takes that heading's id. Found neither way, its heading
  was renamed or removed: its row's second line is dimmed and reads
  "§ Heading — no longer on the page", and the row and Wiki ▸ Saved
  Pages open the page at its top. That state is worked out with each
  load and never stored. The outline's headings are the ATX headings
  `WikiPage.headings()` reads: rendered in node, each of the 877 pages'
  outlines has as many, at the same levels. A heading with math shows its
  source, as the outline does: 14 of the 1,772 headings below a page's
  title. No title or heading holds a §, so "Page § Heading" is never
  ambiguous. `ReaderContextTarget.saveSectionItem(outline:isSaved:)` builds
  the page menu's item and is tested without a menu, as the section links
  are.
- **The page's title has no Save Section,** because Save Page covers it.
  The title is the page's first heading when it is at level 1
  (`ReaderContextTarget.isPageTitle(_:in:)`), as on every page of the
  wiki. A right-click in a lead paragraph falls under it, on 562 pages. A
  later level-1 heading is a section like any other: 63 pages have 110,
  such as LWE's Attacks, so the rule is not "below level 1".
- **Not built:** the shots. They need a `save:` step in
  `ScreenshotRunner`, which removes in its teardown only an entry it
  added, so CCwiki Dev's own list is left as it was.

### 3.4 Deferred, and why

| Feature | Size | Why not now |
|---|---|---|
| Peek a definition (product #3) | M | 44% of section links land on a game, so the value is real. But it needs a second `WKWebView` in a floating `NSPanel`, and its focus, memory and panel behaviour can only be judged on a Mac. Build it after F1–F3, with J1 in place: a peek renders formulas the page just rendered. |
| Full CryptoBib BibTeX (#4) | M | Needs `crypto.bib` (about 40 MB) at the wiki's pinned submodule commit, and a golden file made by the site's own `formatBibtex` in node. Neither can be fetched or generated without network access. Next batch, golden first. |
| Page history and provenance (#6) | M | `git log --follow` and blame plumbing plus a diff view. Snapshot readers have no history, and reflow commits make blame misleading. It needs its own spec. |
| A page's papers offline in one step (#7) | M | Changes PaperFetcher's queue and has to respect ePrint's rate limits, which only a Mac session can check. |
| Notes on passages (#8) | L | The largest item. CurationQuote's re-anchoring rule makes it feasible later. |
| Reopen Closed Tab; match counts in Find on Page | S each | Small and safe. Left out to keep this branch to three features; first candidates for the next. **Built next**, on `claude/undo-close-tab-find-count`: Edit ▸ Undo Close Tab (⌘Z, [reader-comforts.md](reader-comforts.md) §7), and the find bar's "3 of 17" ([render-pipeline.md](render-pipeline.md), "Find on Page's count"). |
| A graph canvas; "what rests only on assumption X" | — | Rejected. No reading task was found where a canvas beats the inspector and the Explorer. The second, prototyped on the reference engine, says false things at variant granularity. |

---

## 4. Risks, and what is left out on purpose

### 4.1 Risks

1. **§1.3's cause is an inference until M0 runs.** M0 settles it in one
   run, with a copy of the `46685be` path whose four changes are each
   behind a switch. If the line-end switches do not carry the difference,
   the slugger and segment switches say where it is. L2–L4 still remove
   real work, but this document is corrected before it names a cause.
2. **Legacy copies only prove what the corpus and fixtures exercise.**
   Fixtures cover what the corpus lacks: CR, CR LF, combining marks, fences,
   unpaired comments, duplicate headings. A legacy copy that someone edits
   proves nothing, so each carries a "do not edit" header. A copy that
   reaches the wrong type through shadowing (§2.1 rule 1) would compare new
   with new; the copies' enums are named to avoid it.
3. **L5 and X5 carry logic of their own.** Each lands last in its track, in
   its own commit, and can be reverted alone. X5's old loop stays in
   production behind `visits: .everyStep` (as built, `loop: .legacy`) for
   one release.
4. **U1 reorders a launch** and supersedes reader-comforts' documented
   order. Something may assume search is ready when the page appears. The
   revision check stays before the render, and the maintainer's shots check
   the ⌘S captures.
5. **S2 drops and recreates triggers.** It does so inside the transaction,
   and SQLite's DDL is transactional, from one SQL constant shared with the
   schema.
6. **S4's schema bump** resets the index on the new build's first launch,
   which then writes a fresh file. Every app update already pays a full
   rewrite.
7. **J1 and global definitions.** A future page using `\gdef` empties the
   memo and, as built, turns it off until another macro table is
   installed: correct, only slower. render-pipeline.md §3 documents it,
   with the other ways KaTeX changes its table.
8. **CI time.** The standalone timing step adds about 2–3 minutes, only on
   pull requests, `main` and manual runs. The new corpus equivalence tests
   add about 1–2 minutes to `make test-corpus` on every push. All are
   debug.
9. **Memory.** J1 holds at most 1,000 entries, about 1.6 M characters of
   HTML and keys, per web view. L6 holds at most a few hundred cards per
   load. L3 and F1 slices share the bodies' storage.
10. **Debug versus release.** CI measures debug. The constant-factor items
    (L1, X1) stay only if CI shows them. A user may never notice them, but
    they keep the project's own measurements attributable.
11. **U and W are checked mostly by eye.** No test builds an `AppModel` or
    an `EditorSession`, so their behaviour rests on pure seams, the W2
    probe and `make shots`, which only the maintainer can run. As built,
    two suites construct an `AppModel` and one an `EditorSession` (§2.8,
    §2.9); the views still rest on `make shots`. No test did before, so if
    CI fails at `AppModel`'s init, those two suites are the place to look.

### 4.2 Left out on purpose

- **D6, reusing unchanged artifacts across updates.** reader-comforts §3.2
  item 3 decides it on a release build's in-memory total above 300 ms. This
  branch changes that total, so it must be measured again first, on the
  maintainer's Mac: this branch adds no release-build CI job (§4.3). The
  safe first slice, reusing `Derivation` when `relations.json`'s digest is
  unchanged, is recorded for that decision.
- **Deferring renders in hidden tabs** (window occlusion). CI cannot verify
  it, and whether a background tab reports itself occluded has to be checked
  on a Mac.
- **TextGrep without its copies of every line.** It saves 1.6 MB; small.
- **Precompiled regexes.** A constant factor of unverified size, and L3, L4
  and L5 remove most of the calls first.
- **FuzzyMatcher's per-keystroke arrays.** ⌘O is the only search path that
  runs on the main actor on every keystroke, with no debounce: 2,977 match
  calls and 8,931 arrays. It is deferred on M0's ⌘O line: if its slowest
  prefix stays within a frame (16 ms) in debug, it waits; if not, it is the
  next batch's first item. U2 takes the ICU sorts either way.
- **⇧⌘R's per-query citer memo.** It runs on the actor after a 120 ms
  debounce, so the saving is small.
- **The NFC fast path below U+0300 in quotes.** A constant factor.
- **`Frontmatter.parse` splitting all 28,816 lines when 12,591 are
  frontmatter.** The read phase moved within noise; measure it first.
- **A page-level HTML cache, or HTML shared between tabs.** After J1 it
  saves about 2.7 ms on LWE, and sharing would post HTML across processes.
- **Sending the macro table on every render** (3.35 KB, 33 µs). Not worth a
  protocol change.
- **`make shots` in CI.** It needs a GUI session, so it stays the
  maintainer's gate.

### 4.3 Decided, and what stays open

1. **No release-build CI job in this branch.** Each run would cost a release
   test build against the account's Actions quota. Whether to add a manual
   (`workflow_dispatch`) job that runs reader-comforts §3.2's release
   command, so that D6 is decided on numbers the repo can see, stays a
   question for the maintainer.
2. **The Legacy copies, and the old derivation loop, are kept for one
   release** after this branch ships, then deleted in the next batch.
3. **⌘D is Save Page's shortcut** (§3.3).

---

## 5. Results, filled in from CI

From the `pull_request` runs' "measured alone" reports, a debug build on
CI's `macos-15` runner, every figure the fastest of 5 unless the line says
otherwise, all on the same live wiki (`7649bcf`, 2026-10-19, 885 pages)
and Swift 6.1.2. The rows follow M0's five reports in the order they
print.

**One column for the six tracks, not one per track.** §2.10 planned a push
and a CI run per track. The tracks touch disjoint files, and each line
below belongs to one track's code (§2.2 names it), so they were merged and
pushed together, which saved five pairs of macOS runs at ten times the
minute. Two runs of the merged tracks are given, so the noise between runs
shows: the same code moved by up to a fifth between them. In the `main`
column, "—" means the line did not exist at `main`, and the figures are
D1's at `ab81f02`, which is why the counts differ.

| Report line | `main` (21df5d7) | M0 baseline (969d41a) | Six tracks, run 1 (9922a9e) | Six tracks, run 2 (e17ca99) |
|---|---|---|---|---|
| wiki commit / Swift version | `ab81f02` (inferred) / — | `7649bcf` / 6.1.2 | `7649bcf` / 6.1.2 | `7649bcf` / 6.1.2 |
| full build, each phase the fastest of 5: `read` / `index` / `manifest` / `labels` / `grep` | 207 / 16 / 7.6 / 6.8 / 19 ms (the fastest run's phases) | 243.5 / 22.2 / 10.6 / 7.4 / 23.1 ms | 249.5 / 17.0 / 7.7 / 7.1 / 20.4 ms | 235.4 / 17.9 / 8.0 / 7.7 / 21.3 ms |
| … `backlinks` | 1,605 ms | 1,914.4 ms | **278.6 ms** | **252.5 ms** |
| … `derivation` | 640 ms | 727.0 ms | **117.4 ms** | **114.4 ms** |
| … `previews` | 1,051 ms | 2,517.7 ms | **664.1 ms** | **554.2 ms** |
| full build in memory: fastest / median | 3,553 ms / not recorded | 5,627.6 / 5,985.4 ms | **1,413.7 / 1,568.2 ms** | **1,258.0 / 1,349.6 ms** |
| fingerprint scan alone |  | 77.1 ms | 96.7 ms | 95.4 ms |
| update after a one-page edit | 4,059 ms | 5,202.0 ms | **1,433.4 ms** | **1,248.1 ms** |
| update after an alias change / a manifest change |  | 5,274.0 / 5,069.6 ms | 1,454.9 / 1,432.6 ms | 1,167.6 / 1,211.3 ms |
| search sync, one run each: in full / as a no-op / after one page changed | 2,984 / 1,125 / 1,291 ms | 4,134.2 / 1,690.7 / 1,797.5 ms | 1,475.5 / **329.3** / 339.6 ms | 956.7 / **213.6** / 210.7 ms |
| counts: pages / scalars of body / bodies with `\r` (vs §1.2) | from the ports: 877 / 1,091,044 / 0 | 885 / 1,097,933 / 0 | the same | the same |
| counts: links (wikilinks, markdown links) / distinct resolve keys / distinct targets | 3,447 (3,412, 35) / 972 / 831 | 3,489 (3,450, 39) / 974 / 832 | the same | the same |
| counts: backlinks / pages linked to / most to one page / headings on non-reference pages | 2,492 / 821 / 44 / 1,882 on 447 pages | 2,530 / 822 / 44 / 1,890 on 455 pages | the same | the same |
| line ends A/B, every body (15,440 lines): (a) / (b) / (c) / (d) | — | 335.7 / 61.9 / 29.3 / 14.0 ms | 357.4 / 76.7 / 39.9 / 15.9 ms | 301.5 / 62.4 / 32.9 / 17.7 ms |
| load path: `CodeMask.inertRanges`, every body | — | 376.6 ms | **78.4 ms** | **54.3 ms** |
| … `outgoingLinks(in:)`, every body | — | 1,240.9 ms | **250.7 ms** | **184.9 ms** |
| … `resolve`, every link | — | 91.7 ms | 109.8 ms | 102.0 ms |
| … `plainText`, every backlink's line (914,081 scalars) | — | 114.5 ms | 285.1 ms | 210.0 ms |
| … `backlinkMap()` | — | 1,629.9 ms | **345.6 ms** | **252.7 ms** |
| previews: `PreviewExcerpt.scope`, every body / `LinkPreviews` | — | 1,603.2 / 2,115.2 ms | **223.6 / 702.6 ms** | **177.9 / 553.6 ms** |
| derivation: `Derivation(manifest:)` / `missingQuotes` | — | 548.3 / 77.7 ms | **87.5 / 40.0 ms** | **64.5 / 38.8 ms** |
| explorer, standard / idealised: answer `owf` ⇒ `pke`, `pke` ⇒ `ot`, `ddh` ⇒ `io` | — | 205.5 / 317.5, 245.9 / 386.9, 329.6 / 486.1 ms | **9.3 / 6.2, 5.9 / 7.0, 6.6 / 7.2 ms** | **6.2 / 6.3, 5.7 / 5.6, 6.7 / 7.1 ms** |
| explorer, standard / idealised: implying `pke`, `ot`, `mpc`, `nizk` | — | 151.3 / 315.3, 776.9 / 1,650.0, 842.8 / 1,721.0, 1,293.5 / 2,427.0 ms | **13.4 / 20.9, 12.2 / 16.9, 19.9 / 31.0, 53.8 / 96.8 ms** | **12.3 / 18.9, 12.8 / 15.3, 21.5 / 29.1, 47.9 / 102.8 ms** |
| search: `ConceptRanker` / `ReferenceRanker` | — | 1,399.5 / 218.1 ms | **279.1 / 87.6 ms** | **249.9 / 91.0 ms** |
| search: `headings()`, non-reference pages / `indexableBody`, every body | — | 1,186.9 / 289.5 ms | **206.3** / 349.1 ms | **157.7** / 270.3 ms |
| search: sync as a no-op (fastest of 5) / full sync into a fresh file (fastest of 3) | — | 1,708.2 / 5,527.4 ms | **198.1 / 1,117.3 ms** | **177.4 / 949.4 ms** |
| ⌘O, one keystroke over 855 pages and 2,908 names: opening with no query / "p" / "pr" / "prf" | — | 17.5 / 24.9 / 21.5 / 22.4 ms | 10.8 / 15.6 / 14.8 / 12.8 ms | 13.2 / 16.5 / 15.7 / 13.4 ms |
| backlinks, one process: the `46685be` copy / all four switches / `backlinkMap()` as built | — | 651.6 / 1,725.5 / 1,743.2 ms | 682.4 / 1,498.9 / **214.7 ms** | 775.6 / 1,833.9 / **252.5 ms** |
| … each switch alone, Δ from the `46685be` copy: CodeMask line ends / `context` line ends / slugger / segment split | — | +946.6 / +114.6 / +38.1 / +54.1 ms | +715.8 / +123.4 / +20.3 / +22.1 ms | +955.8 / +167.4 / +116.3 / +46.7 ms |
| … the six maps the same, or why they were not compared | — | the same: no `\r`, and no link resolves to another page at `46685be` | the same | the same |
| JSC, each page twice in a row: first / again | — | 2,216.4 / 2,151.9 ms | 1,765.2 / **1,061.1 ms** | 1,976.8 / **1,154.1 ms** |
| … LWE in that order: first / again | — | 50.2 / 45.7 ms | 41.7 / **16.7 ms** | 49.4 / **17.5 ms** |
| JSC, the corpus twice in path order: first / again | — | 2,294.9 / 2,157.9 ms | 1,969.2 / 1,996.8 ms | 2,296.1 / 2,429.1 ms |
| … LWE in that order: first / again | — | 48.1 / 44.8 ms | 42.1 / 40.3 ms | 44.3 / 76.3 ms |
| JSC: pages rendered / with KaTeX's output / failed; the same the second time and in either order? | — | 885 / 474 / 0; yes | 885 / 474 / 0; yes | 885 / 474 / 0; yes |
| JSC review, a one-line edit to every page: all pages / LWE | — | 4,726.5 / 106.1 ms | **3,020.0 / 32.1 ms** | **3,548.7 / 41.7 ms** |
| … entries / with HTML / with KaTeX's output | — | 4,778 / 3,515 / 775 | the same | the same |

**Reading it.**
- **§1.3 is right.** In one process, CodeMask's line ends by key path cost
  +946.6 ms of the +1,073.9 ms between the `46685be` copy and `21df5d7`'s;
  the other three changes cost 38 to 115 ms each. The A/B line puts the
  byte scan (d) at 14 to 18 ms against 300 to 360 ms for the key path, so
  L1 keeps its form.
- **A load** in memory went from 5.6 s to 1.3–1.4 s, and an update after a
  one-page edit from 5.2 s to 1.2–1.4 s: backlinks −85%, previews −75%,
  derivation −84%. Reading the files (about 240 ms) is now the largest
  phase after previews.
- **A sync** that changes nothing went from 1.7 s to about 0.2 s, and a
  full one into a fresh file from 5.5 s to about 1 s.
- **The explorer** answers in about 6 ms instead of 0.2–0.5 s, and its
  slowest implied-by list here (`nizk`, idealised models on) takes 0.1 s
  instead of 2.4 s.
- **The renderer.** A page rendered again right after itself costs about
  half (LWE: 46 → 17 ms). The second pass over the corpus in path order
  does not gain, as J1 expected: its cap of 1,000 is below the corpus's
  formulas on purpose. The review of a one-line edit to every page went
  from 4.7 s to 3.0–3.5 s.
- **Two lines moved the wrong way.** `plainText` over every backlink's
  line rose from 114.5 to 210–285 ms, though neither `plainText` nor the
  test's inputs changed. No load runs it any more (L3 works out a context
  only when it is shown), and this plan does not explain the change.
  `indexableBody` moved from 289.5 to 270–349 ms, within the noise between
  the two runs.
- **The test run.** The corpus step on the merged tracks first failed one
  test, `isAuthenticatedCaches`: a fake `gh` that answers at once was not
  heard within `GitHubAuth.deadline`'s 15 s, because the new equivalence
  suites held every cooperative thread. The same test took 74 s at the
  baseline and 155 s there; trivial tests took 62 and 75 s, and the git
  publishing tests about 90 and 175 s. Two changes followed: the deadline
  (and `Tripwire.deadline`) became task-locals that a test whose `gh`
  answers at once scopes long, and the derivation sweeps run one task
  fewer than the cores at a time (`fewAtATime`).

**The tracks' own lines.** These come from `make test-corpus`, beside the
other suites, and W2's from `make check`, in the run on `e17ca99`. Each times the old code and the
new in one process, or only counts, so one CI run fills it. The expected
values are the builders' ports and counts at `ab81f02`; CI's counts move
with the live wiki.

| Line, as printed | Item | Expected | CI |
|---|---|---|---|
| "L1 line ends on bytes": `CodeMask.inertRanges`, `headings()`, old → new | L1 | both faster; with M0's A/B line, it decides L1's form || CodeMask 439.7 → 69.5 ms; `headings()` 954.4 → 341.3 ms |
| "Backlinks (L1, L3, L4)": `backlinkMap()` old → new; every context read afterwards; the busiest page's | L1, L3, L4 | a large drop; the busiest page has 44 || 1,852.3 → 352.2 ms; every context afterwards 272.4 ms; the busiest page's 44 in 7.6 ms |
| "L2 links parsed once": `outgoingLinks(in:)` over every body, a render's link list for every page, old → new | L2 | new below old || 778.7 → 235.9 ms; 839.4 → 381.3 ms |
| "L4 resolutions per sweep": links, resolved | L4 | about 3,447 links, about 972 resolved || 3,489 links, 974 resolved |
| "L6 section cards once per load": anchors, worked out directly; the first time; the second time | L6 | about 2,742 anchors; the second time near 0 || 2,750 anchors; 3,215.3 ms directly; 3,106.0 ms the first time; 3.9 ms the second |
| "L5 scope stops at the first H1": every whole-page scope, old → new; anchored scopes compared | L5 | a large drop || 825.2 → 249.7 ms; 4,520 anchored scopes compared |
| "L5 cards": `LinkPreviews(index:manifest:labels:)`; the old excerpts alone; every label, read afterwards | L5 | || 703.6 ms; 1,341.3 ms; 180.1 ms |
| "Search sync, headings parsed once (S1)": `ConceptRanker` as before; `headings()` on every page; `ConceptRanker` from those outlines; full sync | S1 | a full sync makes 877 `headings()` calls instead of 1,324 || 332.5 ms; 323.4 ms; 126.9 ms; full sync 1,340.4 ms |
| "Search sync, the full rewrite through 'rebuild' (S2)": every row through the triggers; a fresh file; over an older index | S2 | the fresh file well below the triggers (in C: 82–87 against 195–233 ms) || 1,670.3 ms; 1,632.8 ms; 1,480.0 ms: little gain here, where each run includes the rankers and the rows, beside the other suites |
| "Search sync, citing pages named once (S3)": `ReferenceRanker` as before; handed the concept ranker's names; naming each page once itself | S3 | 6,781 `Name` inits instead of 13,495 || 1,960 citers from 378 pages: 328.8 ms; 112.4 ms; 135.0 ms |
| "Search sync, the concept ranker from stored outlines (S4)": both rankers as a no-op built them before; a no-op after a relaunch (fastest of 3); after one page changed | S4 | a no-op parses no page (447 before) || 1,489.0 ms; 249.6 ms; 529.3 ms |
| "derivation loops": closures compared, differing; a load's single-object closures with the `21df5d7` loop / the current one / sharing a run; `Derivation.init` | X1, X5 | about 11,000 closures, 0 differ; the current loop far below the old (about 199× fewer visits), sharing below that || 10,314 closures on 9 engines, 0 differ; 524 closures: 754.1 / 38.9 / 19.9 ms; `Derivation.init` 100.4 ms |
| "derivation quotes": citations, pages, missing; a parse per citation / once per page | X2 | 117 citations on 50 pages, 0 missing; once per page about a third of the time || 117 citations on 50 pages, 0 missing; 112.7 / 54.1 ms |
| "derivation links": inspector rows, with unstated steps, differing | X3 | about 1,663 rows, about 800 with unstated steps, 0 differ || 1,663 rows, 803 with unstated steps, 0 differ |
| "derivation prefilter": implied-by for every target in both settings, with / without; differing; no-path completions, chains and circumventions compared | X4 | 234 targets, 0 differ; 46, 439 and 4 compared; with well below without || 234 targets, 0 differ; 20,190.5 ms with, 171,522.0 ms without (summed over tasks); 46, 439 and 4 compared |
| "The KaTeX memo on the real wiki": formulas a pass; before the memo; pass 1 and pass 2 rendered and remembered; remembered by limit | J1 | about 7,320 formulas; about 3,621 then 3,538 rendered (50.5% and 51.7% remembered); at 1,000, page again 100% and about 1.57 M characters || 7,355 formulas; 3,744 ms before; 3,637 then 3,555 rendered (50.6% and 51.7%); at 1,000, page again 100% and 1.59 M characters |
| "The review's blocks rendered when shown": middle, ends, added and deleted, blocks and ms before and after | J2 | middle 12,748 → 3,512; ends 12,814 → 5,240; added and deleted the same || 3,540 files, identical: middle 12,717 → 3,515 blocks (6,865 → 4,181 ms); ends 12,764 → 5,246 (6,953 → 4,015 ms); added and deleted 6,382, the same |
| "Explore From Here on the corpus": offered, withheld | U3 | offered above 0 || 1,442 offered, 248 withheld |
| "window observation" (`make check`): `@Observable` notifies, or does not, on an equal assignment | W2 | "notifies" on Swift 6.1, so W2 removes work; "does not notify" makes it insurance || "notifies": the save-state guard is removed work |
