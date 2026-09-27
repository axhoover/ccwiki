# Search, the next version

**Status: decided 2026-09-27, being built on `claude/search-v2`.** §6 records
the decisions and the design that follows from them; §1–§5 are the proposal
they answered, kept because the reasoning is still the reasoning.

**Original status: proposal, 2026-09-27.** Written so the
maintainer can choose a direction without needing a background in search
engines: each option says what it would feel like to use, what it costs, and
what it risks. The current design is in [search.md](search.md); this assumes
it.

---

## 1. What is weak today, concretely

Search is two tools: ⌘O finds a page by name (fuzzy, over titles and
aliases), ⌘S finds pages whose text mentions something (SQLite FTS5 with
BM25 ranking). Both work. Where they fall short:

1. **Ranking treats every page alike.** Searching `oblivious transfer` can
   put a reference page (a paper) above the concept page, because a paper's
   title is short and says exactly those words. Most of the time the reader
   wants the concept page. This is the backlog item in
   [search.md](search.md) §6.
2. **Word forms do not meet.** `reductions` does not match `reduction`,
   `commitments` does not match `commitment`. The index stores words exactly
   as written.
3. **A typo finds nothing.** `pseudorandm` returns no results and no
   suggestion.
4. **Abbreviations only work where a page lists them.** `OWF` finds the
   one-way function page only if that page lists `OWF` among its aliases;
   body text that says `OWF` does not lead the reader to the concept.
5. **Two tools, two shortcuts.** A reader has to decide in advance whether
   they are looking for a page or for a mention. Many apps now merge the two
   into one box with sections.
6. **Nothing is measured.** Every ranking change so far has been judged by
   eye. There is no list of "for this query, this page should come first".

## 2. The one thing to do before any option: a test set

Best practice in search, before touching ranking, is a small **relevance
test set**: thirty to fifty real queries, each with the page that should
come first. For example `prf` → Pseudorandom function; `AGGM06` → that
reference; `oblivious transfer` → the Oblivious transfer primitive, not a
paper.

It becomes a unit test that reports, for each change, how many queries put
the right page first and how many put it in the top five. (The usual names
for these are success@1 and success@5; the average of 1 / the rank of the
right page is *mean reciprocal rank*.) Then "is the new ranking better?" is
a number rather than an impression, and a change that helps one query and
quietly breaks three others shows up.

The maintainer is the right person to write the queries, because the
question is what a reader of this wiki expects, and CCwiki can draft a first
list from the page titles and aliases for correction. This is cheap —
an afternoon — and every option below depends on it.

## 3. Options, cheapest first

### A. Tune what is there (small: days)

All inside the existing index and query; nothing new to learn for readers.

- **Prefer concept pages.** Multiply a page's score by a factor for its
  kind, so a primitive or an assumption outranks a paper that mentions the
  same words — except when the query looks like a citation key (`AGGM06`),
  when the paper should win. Sketched in [search.md](search.md) §6.
- **Match word forms.** SQLite's full-text engine has a built-in *stemmer*
  (the Porter algorithm, 1980), which files `reductions`, `reduced` and
  `reduction` under one stem. One line of the index definition. The risk is
  over-merging (`universal` and `universe` share a stem); the test set
  catches that.
- **Expand abbreviations from the aliases the wiki already has.** If a query
  word is some page's alias, search for that page's title words too and lift
  that page. `OWF` then finds the one-way function page and every page that
  says "one-way function".
- **Put a page whose title matches first,** whatever the body scores say.

**Feels like:** the obvious page comes first more often. No new UI.

### B. Forgive typos (medium: a week)

Two ways, which can be combined:

- **"Did you mean …?"** Keep the index as it is, and when a search returns
  little, compare the query's words against the index's own vocabulary
  (SQLite exposes it as a table) by edit distance, and offer the nearest
  real word: *No results for "pseudorandm". Did you mean "pseudorandom"?*
  Predictable, cheap, and easy to explain.
- **A second, substring index.** SQLite's *trigram* tokenizer indexes every
  three-letter sequence, so a query matches inside words and survives a
  typo or two. It is available in the SQLite that macOS 14 ships. It costs
  a larger index (a few megabytes here, which is nothing) and noisier
  results, so it would only be consulted when the main index finds too
  little.

**Feels like:** a mistyped search still gets somewhere.

### C. One search box (medium: a week, mostly design)

Merge ⌘O and ⌘S into one palette with sections, as Spotlight or Raycast do:
**Pages** (by name, the fuzzy matcher) on top, **Mentions** (full text, with
snippets) beneath, Return opening the top hit. ⌘O and ⌘S would both open it.

This is the most visible change and the one with a real downside: the two
tools are fast *because* each does one thing, and a merged list has to be
ranked across two kinds of result. It is a design decision more than an
engineering one, and it is the maintainer's to make.

**Feels like:** one shortcut to remember; less deciding before typing.

### D. Search by meaning (large and uncertain: an experiment)

macOS ships sentence embeddings in its Natural Language framework
(`NLEmbedding`, on-device and offline). Each section of each page could be
turned into a vector once, and a question like *"which primitive gives
forward secrecy?"* matched by meaning rather than words.

The honest assessment: the framework's embeddings are trained on general
English, and this wiki's vocabulary is specialised enough that the quality is
unknown until tried. It would be an experiment on its own branch, judged
against the test set, and kept only if it beats option A on it.

**Feels like:** asking a question instead of guessing keywords — if it works.

### E. Search the relationships (large: a separate feature)

The wiki's relationship data (`relations.json`) makes structured questions
answerable: *what implies oblivious transfer*, *what is known to be
separated from LWE*. That is closer to a query language than to search, and
belongs with the relations inspector rather than in the search box. Listed
so it is not forgotten, not recommended now.

## 4. Recommendation

1. The test set (§2), then **option A** on this branch's successor. It is
   cheap, invisible to learn, and fixes the most common annoyance.
2. Then **B's "Did you mean"**, which is small once A exists.
3. **C** only if, after A and B, having two shortcuts still feels like
   friction. It is a taste call.
4. **D** as a timeboxed experiment on its own branch, if curiosity wins.

## 5. Decisions for the maintainer

- Write, or correct, the test set's queries? (CCwiki can draft them.)
- One search box (C), or keep ⌘O and ⌘S separate?
- Is search-by-meaning (D) worth an experiment?

## 6. Decided, and the design that follows

### What the maintainer chose

- **Three searches with clear jobs**, not one merged box:

  | Shortcut | Searches | Order |
  |---|---|---|
  | ⌘S | Concept pages only, by name and text. **No references.** | Field matched, then section priority, then relevance |
  | ⇧⌘F | Every page, literal text, grep-like, with the lines | Page, then line |
  | ⇧⌘R | References only: key, authors, title, venue, year, abstract, and the concept pages that cite them | Field matched, then relevance |

  ⌘O stays the jump-to-page switcher. ⌘R stays Sync: it means reload in
  nearly every Mac app, so references take ⇧⌘R.
- **Section priority**, the maintainer's call for this wiki: primitives and
  assumptions first, then complexity classes, then glossary, barriers and
  folklore, then reductions. References are not in ⌘S at all.
- **Search by meaning (option D) is dropped**: readers who want that will
  point a general-purpose LLM at the site.
- **The test set is generated, not hand-written** (§6.3), since the
  maintainer should not have to know what makes a good judgment list.

### 6.1 How good search systems order results, and what that means here

Written from knowledge of these systems; this session's network policy
blocked their documentation, so the links in the references were not
re-read while writing this.

- **Tiered rules, not one blended score.** Algolia and Meilisearch both rank
  by a list of rules applied in order, each only breaking the ties the
  previous one left: how many query words matched, typos, how close
  together, **which field matched**, exactness, and only then a custom
  business rule. The effect is predictable: a title match beats any number
  of body matches, which a single BM25 score does not guarantee, since a
  long body full of the word can outscore a short title.
  *Here:* ⌘S sorts by (1) which field matched — name or alias, then a
  heading, then the text; (2) the section priority above; (3) BM25 within
  what is left. The priority is a tie-breaker *after* the field, so a
  complexity class named in the query (`AM`) still beats a primitive that
  mentions it in passing, and among pages that only mention a term, the
  primitive comes first.
- **Records per section, grouped by page.** Documentation search (Algolia's
  DocSearch is the common example) indexes each section under its page and
  heading trail, and a hit opens *at that section*. *Here:* a hit whose best
  match is a heading opens at that heading's anchor.
- **Field-scoped search for literature.** Reference managers and
  bibliographies (Zotero's quick-search modes, dblp, Google Scholar's author
  search) search authors, title and year by default and the full record only
  when asked, fold accents (`Lázló` = `Laszlo`), and let a year narrow a
  result. *Here:* ⇧⌘R ranks a citation-key or author match above a title
  match above an abstract match, folds diacritics, treats a four-digit
  number as a year, and adds one field this wiki has that a library does
  not: the concept pages that cite the paper. Searching *oblivious transfer*
  in ⇧⌘R then finds first the papers the OT page cites, then papers whose
  abstract mentions it.
- **Grep is exhaustive and unranked.** A literal-text search is for "every
  place this string occurs": results in page order with the matching lines,
  no relevance, nothing hidden. *Here:* ⇧⌘F, over references too.
- **Measure with a judgment list.** Relevance work everywhere starts from
  queries with known right answers and a few numbers: success@1, success@5,
  mean reciprocal rank, and the rate of queries that return nothing.

### 6.2 Build order on the branch

1. **The measuring harness** (§6.3), run in CI against a fresh clone of the
   wiki, with today's ⌘S as the baseline.
2. **⌘S as concept search**: references out, tiered ranking, heading hits
   open at the heading, Porter stemming if the numbers say it helps.
3. **⇧⌘R reference search.**
4. **⇧⌘F literal search.**
5. Then "Did you mean …?" (option B), if the zero-result rate warrants it.

### 6.3 The test set, generated from the wiki

- **Navigational, ⌘S:** every primitive, assumption and complexity class,
  queried by its title and by each alias it alone owns, must come first.
  About a hundred and fifty queries, regenerated from the wiki each run, so
  the set grows with it.
- **Priority, ⌘S:** for any query, no complexity class, reduction or
  reference may outrank a primitive or assumption that matched in the same
  or a better field.
- **Navigational, ⇧⌘R:** every reference by its citation key, and by its
  paper title, must come first; by first author's surname and year, it must
  be in the top three.
- **Thresholds, not perfection:** the wiki changes daily, so the tests
  report the numbers and fail only below a floor, set from the first
  honest measurement. A failing query is printed, which is where a missing
  alias in the wiki usually shows up.

## References

- SQLite FTS5 — tokenizers (`porter`, `trigram`), `bm25()`, `fts5vocab`:
  <https://www.sqlite.org/fts5.html>
- S. Robertson and H. Zaragoza, *The Probabilistic Relevance Framework:
  BM25 and Beyond*, Foundations and Trends in Information Retrieval 3(4),
  2009 — the ranking function FTS5 implements.
- M. F. Porter, *An algorithm for suffix stripping*, Program 14(3), 1980 —
  the stemmer behind FTS5's `porter` tokenizer.
- Apple, `NLEmbedding`:
  <https://developer.apple.com/documentation/naturallanguage/nlembedding>
- Algolia, ranking criteria and the tie-breaking algorithm:
  <https://www.algolia.com/doc/guides/managing-results/relevance-overview/in-depth/ranking-criteria/>
- Meilisearch, ranking rules:
  <https://www.meilisearch.com/docs/learn/relevancy/ranking_rules>
- Algolia DocSearch, records and hierarchy:
  <https://docsearch.algolia.com/docs/record-extractor/>
- Zotero, searching (quick-search modes): <https://www.zotero.org/support/searching>
