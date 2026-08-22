# Search

Two different problems, two different mechanisms, deliberately not merged:

- **⌘O, the quick switcher** — "I know the page, get me there in four
  keystrokes." Fuzzy subsequence matching over titles, aliases and reference
  paper titles. No tokenizer will rank `pseudorandom-function` first for `prf`.
- **⇧⌘F, full-text search** — "which pages mention this." SQLite FTS5 over the
  whole corpus, with the matching passage in the result.

---

## 1. The index is derived, never authoritative

`~/Library/Application Support/CityDesk/index/search.sqlite3` can be deleted at
any moment with no consequence beyond a brief rebuild. `SearchIndex.reset()` is
a legitimate response to any problem — corruption, a schema change, a version
skew — and the rebuild path takes it automatically if opening fails.

A **full** rebuild runs after every pull. The corpus is ~300 pages and ~800 KB;
a full rebuild is about a tenth of a second, which is much simpler than tracking
which files a pull touched and cannot drift.

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
CREATE TABLE doc(id, path UNIQUE, slug, kind, status, title, aliases, headings, body);
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
