# Search

Two different problems, two different mechanisms, deliberately not merged:

- **⌘O, the quick switcher** — "I know the page, get me there in four
  keystrokes." Fuzzy subsequence matching over titles, aliases and reference
  paper titles. No tokenizer will rank `pseudorandom-function` first for `prf`.
- **⌘S, full-text search** — "which pages mention this." SQLite FTS5 over the
  whole corpus, with the matching passage in the result.

---

## 1. The index is derived, never authoritative

`~/Library/Application Support/CCwiki/index/search.sqlite3` can be deleted at
any moment with no consequence beyond a brief rebuild. `SearchIndex.reset()` is
a legitimate response to any problem — corruption, a schema change, a version
skew — and the rebuild path takes it automatically if opening fails.

Until schema version 3, a **full** rebuild ran after every load. Now each row
carries the fingerprint of the file it was built from, and a load rewrites only
the rows whose file changed (§3, "Kept in step, not rebuilt"). The full rebuild
is still the definition: it runs whenever the build that wrote the rows is not
this one, and a sync must leave exactly what it would.

## 2. No SwiftPM dependency is needed

The macOS SDK ships a Clang module map for system SQLite with `link "sqlite3"`
in it, so `import SQLite3` both compiles and auto-links
`/usr/lib/libsqlite3.dylib`. **No `systemLibrary` target, no `linkerSettings`,
no header shim** — `Package.swift` stays at zero configuration.

That dylib has FTS5 (verified: `ENABLE_FTS5` in `compile_options`, plus working
`snippet()`, `highlight()` and `bm25()`). macOS 14.0 shipped SQLite 3.43.2 and
everything used here predates that. Avoid `jsonb` (3.45) if that ever comes up.

`SQLITE_TRANSIENT` is a C macro and does not import into Swift; it is declared
in `SQLite.swift`. Not in a file with top-level code, where it would be
implicitly `@MainActor` and unreachable from a nonisolated context.

## 3. Schema: external-content FTS5

```sql
-- Schema version 3 (PRAGMA user_version); any other version is thrown away.
CREATE TABLE doc(id, path UNIQUE, slug, kind, status, title, aliases, headings, body,
                 hash);                -- the fingerprint of the file the row was built from
CREATE TABLE meta(key PRIMARY KEY, value);   -- 'builder': the build that wrote the rows
CREATE VIRTUAL TABLE doc_fts USING fts5(
  title, aliases, headings, body,
  content='doc', content_rowid='id',
  tokenize = "unicode61 remove_diacritics 2",
  prefix = '2 3');
-- plus AFTER INSERT / DELETE / UPDATE triggers
```

Contentless (`content=''`) would be smaller, but `snippet()` needs the original
text and a search result without context is barely a result. The delete trigger
**must** pass the OLD column values — FTS5 uses them to locate the postings.

### Kept in step, not rebuilt

Every library load calls `SearchIndex.sync(pages:backlinks:fingerprints:builder:)`
([reader-comforts.md](reader-comforts.md) §3.4). `hash` is the file's
`ContentFingerprints` digest, and `builder` is the app's `CFBundleVersion` with
the schema version.

- **A different `builder`** (an app update, or a fresh file after Settings ▸
  Storage ▸ Rebuild resets it), or `CCWIKI_FULL_RELOAD=1`, deletes and writes
  every row, then `optimize` and a WAL checkpoint, as every load used to. Any
  change to how a row is built therefore rebuilds once, with no version bump
  to remember.
- **Otherwise** one `SELECT path, hash`, then one transaction: delete the paths
  that are gone, `UPDATE` the rows whose hash differs (the `doc_au` trigger
  keeps FTS in step) and insert the new ones. `optimize` runs only after more
  than 100 writes; FTS5's automerge handles the rest. A load whose index
  already matches, as at a launch, writes nothing at all.
- **The stamp is written in the same transaction as the rows**, so a crash
  never leaves it over rows it does not describe. A row with no known
  fingerprint has `hash = ''`, which never matches, so it is rewritten.
- **Ties are deterministic.** The rankers are built from pages sorted by path,
  and `ORDER BY bm25(…)` breaks ties by `d.path`: rows written incrementally get
  new rowids, so a tie would otherwise fall back to the order rows were written.
  `SearchIndexSyncTests` checks that an index synced from one version of the
  wiki to the next holds the same rows, hits, snippets and scores as a fresh
  build of the second.

### Two tokenizer decisions

- **`remove_diacritics 2` is required.** It is what makes `vigenere` match
  `Vigenère`. Version 1 is the legacy, partially-broken variant.
- **No `tokenchars '-_'`.** Measured against the real corpus: with hyphens as
  token characters, `rsa` stops matching `rsa-assumption` and `one` stops
  matching `one-time-pad`. This wiki is *made of* hyphenated slugs. With the
  default separators you get both behaviours, because `"one-time"` still works
  as an implicit phrase.

### Ranking

`bm25(doc_fts, 14.0, 10.0, 4.0, 1.0)` — title, aliases, headings, body. bm25
returns a **negative** score (more negative is better), so `ORDER BY` ascending.
The weight count must equal the column count, and `snippet()`'s column index is
0-based over the FTS columns.

References are filed under a citation key, so the `title` column indexes both
the key and the paper title: nobody searches for `AGGM06` when they mean
"one-way functions on NP-hardness".

## 4. Escaping the query

FTS5 `MATCH` takes a query **language**, not a literal. `AND`, `OR`, `NOT`,
`NEAR`, `*`, `^`, `:`, `-`, `(`, `)` and `"` all mean something, so raw user
input either throws a syntax error or quietly searches for something else.

`SearchIndex.matchExpression` quotes each whitespace-separated run — inside a
double-quoted FTS5 string nothing is an operator, and an internal `"` is escaped
by doubling. The last token gets a trailing `*` so search feels live while
typing (`"foo"*` is legal; the star goes *outside* the quote).

Three cases that are easy to miss:

- **Strip NUL bytes first.** `sqlite3_bind_text(..., -1, ...)` uses `strlen`, so
  an embedded NUL truncates the expression mid-literal and yields
  `fts5: syntax error`.
- **Drop tokens with no alphanumerics.** They tokenize to the empty phrase,
  which FTS5 rejects outright. If nothing is left, return `nil` and show no
  results rather than running a query that will throw.
- **Errors surface at `sqlite3_step`, not at `prepare`.** A step loop that
  treats anything other than `SQLITE_ROW` as "no more rows" silently renders an
  empty result set for a broken query. `Statement.step()` throws instead.

## 5. The quick switcher's matcher

`FuzzyMatcher` is an fzf-style scorer in about 70 lines: a greedy forward pass
to establish that the needle is a subsequence at all, then a backward refinement
that slides each matched character as late as it can go, which lands runs on word
boundaries. Bonuses for consecutive characters, word starts and an exact prefix;
penalties for gaps and for a late first match; a small penalty for length so
`PRF` beats a long title that also matches.

Each page contributes several candidates — title, every alias, the reference
paper title, the slug — and the best-scoring one wins, with a weight per source
so a title match outranks a slug match. That is how `AGGM06` and
`sorting network` both find the same reference page.

### The bug this cost, and the rule it produced

The first version rendered with
`ForEach(Array(results.enumerated()), id: \.element.id)` and tracked selection
by **index**. When the query changed, the footer count updated but the rows kept
showing the previous query's results: the tuple elements carry no identity of
their own, so SwiftUI had nothing to diff.

The rule: **selection is by id, never by index, and never enumerate a collection
into a `ForEach`.** Both palettes now hold a `String?` id and derive the index
when they need one. `QuickSwitcherRankingTests` locks the ranking down so the
model half can never regress silently again; the view half is covered by
`make shots`.

---

## 6. Backlog: ranking by page kind

> **2026-09-27.** Folded into a wider proposal, with a test set to measure
> ranking changes against: [search-v2.md](search-v2.md). **Built there
> differently**: tiered rules (`ConceptRanker`) rather than a bm25
> multiplier, and references moved to their own search (⇧⌘R). What follows
> is the original request, kept for its reasoning.

**Requested 2026-08-22, deferred until the architecture is done.**

Full-text results should favour the pages you are usually looking for. Two
changes, in order of value:

1. **Weight fields harder.** `bm25(doc_fts, 14.0, 10.0, 4.0, 1.0)` already puts
   title above aliases above headings above body, but the spread is modest and
   a long body can still outrank a title hit. Worth measuring against real
   queries rather than guessing at bigger numbers.
2. **Boost by page kind.** A `primitive` or `assumption` page is almost always
   a better answer than a `reference` — the concept page is what you want, and
   the paper is one click away through it. The exception is when the query
   *is* a citation key or an author code, which is exactly when a reference
   should win.

   The `doc` table already stores `kind`, so this is a multiplier over the bm25
   score rather than a schema change:

   ```sql
   ORDER BY bm25(...) * CASE d.kind
              WHEN 'primitive'  THEN 0.75      -- bm25 is negative, so < 1 promotes
              WHEN 'assumption' THEN 0.75
              WHEN 'reference'  THEN 1.0
              ELSE 0.9 END
   ```

   with the multiplier suppressed when the query matches the citation-key regex
   `^[A-Za-z][A-Za-z+]*\d{2}[a-z]?$`, so `AGGM06` still finds AGGM06 first.

Do this with a fixture of real queries and expected first results, so the
weights are tuned rather than asserted — the same shape as
`QuickSwitcherRankingTests`.
