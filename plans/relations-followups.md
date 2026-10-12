# Relations follow-ups: refusal, curation review, proof export, wiki asks

**Spec, 2026-10-12, revised the same day after three critics (§11). Nothing
here is built.** It follows the explorer and the derivation engine
([relations-explorer.md](relations-explorer.md),
[derivations.md](derivations.md)), both built. Rule numbers R1–R14 are
derivations.md §2's. Every number below was computed here with
`scripts/derivations_reference.py` (or throwaway Python that imports it) on
the wiki clone at `ab81f02`, the commit the curation and the golden file
were reviewed against: 262 objects, 283 reductions, 32 barriers. Nothing was
compiled: this machine has no Swift.

> `CLAUDE.md` asks for the **swiftui-pro**, **typography-designer** and
> **macos-design** skills before and after deciding on code. None is
> installed in this session, as [design-system.md](design-system.md)
> records. This spec follows `SWIFTUI-RULES.md` (cited by section) and
> design-system §1 for type. Each track runs whichever of the three is
> installed by then, before and after its code.

Four parts, each a section:

1. **Refusal, recorded** (§1): the maintainer's decision closes
   derivations.md open question 4.
2. **Curation review** (§2): a generated review document, and the wiki's
   own text beside every correction the explorer applies.
3. **Copy a proof** (§3): LaTeX, wiki Markdown and BibTeX.
4. **Wiki asks** (§4): what the wiki could record so most of the curation
   can go, in a form its maintainer can apply, and how CCwiki takes each
   change in.

---

## 0. Decisions

**Made by the maintainer:**

1. **Unmet preconditions are refused, not caveated** (R13). A chain that
   needs a notion of a hypothesis the manifest does not record is not shown
   with a caveat. This applies in the explorer and in the inspector.

**Made by this spec, open to the maintainer in §10:**

2. **Every curation entry cites the wiki verbatim.** Each entry gains
   `cites`: a page, a section and a quote copied from the page's source.
   Scripts and tests check every quote is still on its page. Prose
   `evidence` stays for people.
3. **The review document is generated and committed**
   (`plans/curation-review.md`). `make curation-review` writes it against a
   clone at the golden file's commit. A unit test fails when it is older
   than the curation file. CI does not regenerate it, because CI cannot
   commit.
4. **The explorer shows the wiki's text for every correction it applies.**
   A refused step carries its quotes on its own row. A derivable answer gets
   a last section, "Corrections CCwiki applied", for the corrections no row
   shows, and it swaps with the proof when Show It is clicked.
5. **A proof copies as LaTeX and as wiki Markdown**, from the explorer and
   from the inspector's derived rows. The BibTeX copy holds the inline
   entries from the reference pages; CryptoBib keys are listed in the LaTeX
   header rather than invented.
6. **The asks prefer variant nodes to new fields.** The wiki already has
   variants, and its own review queue is moving that way. A curation entry
   about a hypothesis's regime becomes an edge on a variant. Three asks do
   need new fields: `reverse-class`, `refuted-by`, and a barrier `model`.
   CCwiki decodes all three now, so it is ready the day the wiki ships
   them.

## 1. Unmet preconditions are refused

### 1.1 Edits to derivations.md

Track A1 makes these edits, word for word apart from line wrapping.

- **Status paragraph.** Append: "Revised 2026-10-12: the maintainer
  decided that R13 refuses unmet preconditions (§0 item 4);
  [relations-followups.md](relations-followups.md) adds citations to every
  curation entry and three drift checks (§2a, §8)."
- **§0, new item 4**, after item 3:

  > 4. **Unmet preconditions are refused, never caveated** (R13). A step
  >    whose Statement needs more of a hypothesis than the manifest records
  >    fires only when that hypothesis is given (it is one of the question's
  >    starts), and the claim then says "assuming …", or when a `metBy`
  >    producer establishes it. Otherwise the step is refused and named.
  >    This holds in the explorer and the inspector alike. CCwiki shows no
  >    derived claim with a "precondition not established" caveat. (Decided
  >    2026-10-12; this was open question 4.)

- **§2 R13, the "Refuse, not caveat" bullet**, replaced by:

  > - **Refuse, never caveat** (decided, §0 item 4). R5 gives the reason: a
  >   caveated fact composes further, and caveats pile up. The caveat policy
  >   stays in the reference script (`--precondition-policy caveat`) for
  >   comparison only. `--report` prints what it would add: 58 facts from 15
  >   starts. Nothing in the app reads it.

- **§2a, the key table**: every "Entry" cell gains `cites`; `requires` and
  `weakens` gain `notionMarkdown`; `quarantine` reads "edge, reason, cites";
  `equivalences` reads "edge → `forward`/`reverse` (`record` or
  `unstated`), note, cites"; `statementLint` reads "edge → note, cites: why
  a lint hit is not a dropped conjunct".
- **§2a, after "The evidence rule" paragraph**, add: "Each entry's `cites`
  quotes the wiki verbatim, with page and section, and
  `scripts/derivations_reference.py --check-quotes` checks that every quote
  is still there ([relations-followups.md](relations-followups.md) §2.2).
  [curation-review.md](curation-review.md) puts each entry beside its
  quotes and its effect on the answers."
- **§2a, the sentinel list.** After `equivalencesReviewed`, a golden
  sentinel:

  > - `curationSuperseded`: no entry is one the manifest now records itself
  >   (`reverseClass`, `refutedBy`, or a setting that is no longer the sole
  >   hypothesis of any step) (prints a warning).

  After the Statement lint bullet, two checks that, like it, need the
  clone and run only in the corpus test:

  > - **Quotes** (`curationQuotesFound`): every cited quote is still on its
  >   page (fails the test).
  > - **Curated edges** (`curationEdgesUnchanged`): every reduction the
  >   curation names keeps the kind, hypotheses and conclusion recorded in
  >   the golden file's `curatedEdges`, and an `equivalences` edge also its
  >   class and model (fails the test; any other class or model change
  >   prints a warning).

- **§2a, "Upstream asks"**: the numbered list is replaced by one sentence:
  "**Upstream asks**, which would let most of the file go, are in
  [wiki-asks.md](wiki-asks.md), each with its `ccw:` id, the exact change,
  the pages it touches and the entries it retires."
- **§7, a new bullet** after "Refused steps":

  > - **Refused, never caveated.** No derived claim carries "precondition
  >   not established" or any other caveat of that kind. A step whose
  >   precondition is not established is listed under *Refused steps*, with
  >   the wiki's text, in a no-path answer, and under *Corrections CCwiki
  >   applied* when it shapes a derivable answer
  >   ([relations-followups.md](relations-followups.md) §2.5).

- **§8.** "--selftest runs one check per review finding (45 today)" loses
  "(45 today)". "and **7 mutation records**" becomes "and **10 mutation
  records**". After "the invariants and sentinels by name" add "`curatedEdges`,
  a snapshot of every reduction the curation names,". After the sentence
  listing the seven mutations add: "Three more test the upstream fields of
  [relations-followups.md](relations-followups.md) §4.4: a barrier `model`
  that stops R12, a `reverseClass` that overrides the curation, and a
  `refutedBy` that makes an answer vacuous." "A failing `curationResolves`,
  `regimeLossCurated` or Statement lint" becomes "A failing
  `curationResolves`, `regimeLossCurated`, `curationQuotesFound`,
  `curationEdgesUnchanged` or Statement lint". Append to that paragraph:
  "Then run `make curation-review` against the same clone."
- **§9, open question 4**, replaced in place (the numbering is kept, because
  R5 cites "open question 1"):

  > 4. **Decided 2026-10-12: refuse** (§0 item 4). The inspector refuses as
  >    the explorer does.

- **§10, "Unreviewed preconditions"**: add a final sentence. "Refusal
  applies only to preconditions the curation records. A precondition no one
  has reviewed is still chained, so this risk is unchanged by §0 item 4."
- **§10, "Barriers have no model field"**: append "CCwiki now reads a
  barrier `model` when the wiki records one ([wiki-asks.md](wiki-asks.md)
  ask 3)."
- **§10, "Curation drift"**: its last sentence becomes "Every entry now
  quotes the wiki, and `curationQuotesFound` fails when a quoted passage
  changes; an edit to a Statement outside every quote still goes
  unnoticed."

In `scripts/derivations_reference.py` (Track A1), the comment on
`UNMET_PRECONDITION` becomes: "R13: what a step whose precondition is not
established does. "refuse" is decided (plans/derivations.md §0 item 4);
"caveat" is kept for `--report` only."

### 1.2 Where the UI says it

The refusal is already worded in each refused-step row
(`ExplorerWriter.refusalRow`). Three general statements change, all in
`DerivationWording` (Track C):

| Where | After |
|---|---|
| The footer's ⓘ, last rule (`rules[5]`) | "A step whose Statement needs more of its hypothesis than the wiki's page defines is used only when that hypothesis is one you gave, and the derivation then says “assuming …”, or when the step that gives the hypothesis states the stronger notion. Otherwise CCwiki leaves the step out; it never uses it with a caveat." |
| *Refused steps* header help (today a literal at `ExplorerResult+Compute.swift:411`), moved into `DerivationWording.refusedHelp` | "Steps the wiki records on the way that CCwiki does not chain here, and why. A step that needs more of its hypothesis than the step before it states is left out, not used with a caveat." |
| Inspector "Derived: implies" and "Derived: implied by" help (`impliesHelp`, `impliedByHelp`) | today's text, then "A chain is left out when one of its steps needs more of a hypothesis than the step before it states; ask the Relations Explorer about the pair to see the step." |

**Tests** (`ExplorerResultTests`):

- `rules[5]`, `refusedHelp`, `impliesHelp` and `impliedByHelp` equal the
  strings above.
- The source of `DerivationWording.swift`, read through `#filePath`,
  contains the whole word "caveat" (case-insensitive) only inside
  `rules[5]` and `refusedHelp`.
- No `ExplorerResult` for a fixture query contains "not established".

## 2. Reviewing the curation

The curation has 42 entries: 3 refuted, 2 settings, 3 quarantine,
7 equivalences, 23 requires, 2 statementLint and 2 weakens. Each one changes
answers. The maintainer has to read each entry's claim beside the wiki text
it rests on, and see what it does. Today that means opening the JSON, then
the page, then running the script by hand.

### 2.1 What is wrong with `evidence` today

`evidence` is prose: `"Statement: 'If DLOG is hard in Z_p^* (p prime, g a
generator) …'"`. The quotes are paraphrases with the TeX taken out. Of 29
quoted fragments in `requires` and `weakens`, **4 match the page source**.
No script can check them, a reader cannot find them by search, and an edited
Statement goes unnoticed. That last gap is derivations.md §10's final
residual risk.

### 2.2 Citations the file can be checked against

**The wire shape.** Every entry gains `cites`, a non-empty list.

| Key | Shape after this spec | The entry's prose (`Entry.evidence`) |
|---|---|---|
| `refuted` | `{object, source, text, evidence, cites}` | `evidence` |
| `settings` | `{object, text, evidence, cites}` | `evidence` |
| `quarantine` | `{edge, reason, cites}`; the old `evidence` key is removed | `reason` |
| `equivalences` | `{"<edge>": {forward, reverse, note, cites}}` | `note` |
| `requires` | `{edge, direction?, hypothesis, notion, notionMarkdown?, metBy, evidence, cites}` | `evidence` |
| `statementLint` | `{"<edge>": {"note": "…", "cites": [ … ]}}`; Phase 0 still decodes the old bare string | `note` |
| `weakens` | `{edge, notion, notionMarkdown?, acceptedBy, evidence, cites}` | `evidence` |

The Python `Curation` reads `statementLint`'s keys only, so the object form
does not change it. Phase 0's Swift decoder reads either form (§5.1); without
that, `DerivationCuration.decode` would throw, `bundled` would be nil, and
the app would derive nothing.

```json
{
  "edge": "red-ot-to-mpc-kil88",
  "hypothesis": "ot",
  "notion": "OT secure against malicious parties (it instantiates Kil88's ideal OT)",
  "notionMarkdown": "OT secure against malicious parties",
  "metBy": ["red-cpir-to-ot-dmo00"],
  "evidence": "… (unchanged)",
  "cites": [
    {"page": "content/Reductions/ot-to-mpc-kil88.md", "section": "Statement",
     "quote": "in the OT-hybrid model every two-party functionality can be computed with unconditional security against malicious parties"},
    {"page": "content/Primitives/oblivious-transfer.md", "section": "Malicious Security",
     "quote": "The definitions above are **semi-honest**"},
    {"page": "content/Reductions/cpir-to-ot-dmo00.md", "section": "Statement",
     "quote": "Non-trivial single-server PIR is therefore complete for secure two-party and multi-party computation"}
  ]
}
```

- **`page`**: repository-relative, as `relations.json` writes `page`.
- **`section`**: the heading text without its `#`s, or `null` for anywhere
  in the file. Use `null` to quote frontmatter, such as a `security-loss`
  value.
- **`quote`**: a verbatim copy of the page source: wikilinks, `$…$` and
  `**` stay as they are. Use one quote per contiguous passage. An ellipsis
  inside a quote is not allowed; write two quotes instead.
- **Matching**, one rule implemented twice (Python `locate_quote`, Swift
  `CurationQuote.contains`), held to the same cases by a shared fixture
  (§2.6):
  - Turn CRLF and lone CR into LF, then normalise both page and quote to
    NFC. Compare Unicode scalars (code points), never Swift `Character`s.
  - Collapse every run of `[ \t\n]` to one space, in both.
  - The section is the first ATX heading (`#` to `######`, then a space)
    whose text, trimmed and without closing `#`s, equals `section`. Lines
    inside the frontmatter and inside fenced code blocks are not headings.
    The section runs to the next heading of the same or a higher level, or
    to the end. With `section: null`, it is the whole file, frontmatter
    included.
  - The quote must be a case-sensitive substring of the section.
  - Python also reports the 1-based line of the original file where the
    first match starts, for the review document. Swift only answers found
    or not found.
- **`notionMarkdown`**, optional, on `requires` and `weakens` entries: the
  notion as plain text with `$…$` math in the wiki's macros, and nothing
  else (no wikilinks, links or emphasis), because the LaTeX writer only
  escapes text and expands math (§3.7). The copy writers use it. The app's
  chrome keeps `notion`.
  - BM84: `"DLOG hard in $\\ZZ_p^*$ ($p$ prime, $g$ a generator)"`.
  - AMR25: `"quasi-polynomial hardness of low-noise LPN with noise rate
    $O(\\log^{1+\\beta}(k)/k)$"`.
  - Track A1 writes it for all 25 entries.

**Entry ids** are computed and never stored. The review document, the app
and the asks all use them.

| Key | Id | Example |
|---|---|---|
| `refuted` | `refuted:<object>` | `refuted:circular-evasive-lwe` |
| `settings` | `settings:<object>` | `settings:honest-majority-t-lt-n-over-2` |
| `quarantine` | `quarantine:<edge>` | `quarantine:red-bdh-to-hve-bw07` |
| `equivalences` | `equivalences:<edge>` | `equivalences:red-rabin-ot-to-ot` |
| `requires` | `requires:<edge>:<hypothesis>`, with `~reverse` after the edge for a reverse direction | `requires:red-dlog-to-prg-bm84:dlog` |
| `statementLint` | `statementLint:<edge>` | `statementLint:red-evasive-lwe-to-abe` |
| `weakens` | `weakens:<edge>` | `weakens:red-prp-to-invertible-prf` |

**Order** is the same everywhere: refuted, settings, quarantine,
equivalences, requires, statementLint, weakens. Within a key, `refuted`,
`settings`, `requires` and `weakens` keep file order. `quarantine`,
`equivalences` and `statementLint` are sorted by edge id in UTF-8 byte order
(`Derivation.precedes`, Python's `sorted`): the two tables because
`JSONDecoder` does not keep key order, and `quarantine` because
`DerivationCuration.init` takes it as a dictionary, which the existing
tests use. Track A1 reorders the file's `quarantine` array to match.

**Who writes the 42 entries' citations.** Track A1 writes them by hand
from the clone at `ab81f02`, using the existing `evidence` to find each
passage. `--check-quotes` must pass before the track ends. The curation's
SHA-256 changes, so A1 regenerates the golden file against the same clone;
only `curationSHA256` changes in it.

### 2.3 The review document

**Commands** (Track A1; Python standard library only):

```sh
scripts/derivations_reference.py RELATIONS_JSON --curation-report plans/curation-review.md \
    --wiki-root WIKI_ROOT --wiki-commit SHA
scripts/derivations_reference.py RELATIONS_JSON --check-quotes WIKI_ROOT   # exit 1 on any missing quote
```

`--curation-report` refuses unless the SHA-256 of `RELATIONS_JSON` equals
the golden file's `manifestSHA256`. It then prints: "Use a separate clone
at the golden file's commit: `git clone https://github.com/axhoover/cryptology.city
<dir> && git -C <dir> checkout <wikiCommit>`. Never check out a commit in
CCwiki's own clone, which is pull-only." It writes only
repository-relative paths and GitHub URLs, never `WIKI_ROOT`.

**`make curation-review WIKI=…`** (§5.2) requires `WIKI=` on the command
line, runs `--selftest` and then `--curation-report` against it, and fails
when `git -C "$WIKI" rev-parse HEAD` fails (a snapshot clone has no git).

**What "effect" means.** For each entry, the report deletes that one entry,
rebuilds the engine, and compares, in both model settings:

- **Every single-object closure**, for the 234 objects that can start a
  query. A pair the run without the entry derives and the full curation
  does not is one the entry **removes**; the reverse is one it **adds**. A
  pair present in both is **changed** when its chain class, models,
  assumptions or weakened notion differ.
- **Vacuous answers**: the single-object answers whose start is refuted.
- **Backward lists**: for every target, its R11 singles, settings and
  refuted lists, read off the same single-object closures (no pair search,
  so this costs nothing extra).
- **The 72 golden queries**, through `golden_expect`, which includes each
  no-path query's completions. A query is listed when its expectation
  differs.
- **For a `statementLint` entry**: the lint hits that appear without it.

"No effect" is printed only when all of these are unchanged. Measured on
`ab81f02` (default models / idealised included):

| Entry | Removes | Changes | Backward lists | Vacuous | Golden queries |
|---|---|---|---|---|---|
| `requires:red-dlog-to-prg-bm84:dlog` | 32 / 32 | 16 / 30 | 16 / 16 | 0 | `ddh-prg` |
| `requires:red-ot-to-mpc-kil88:ot` | 6 / 6 | 1 / 1 | 1 / 1 | 0 | `etdp-mpc`, `oihf-mpc`, `rabin-ot-mpc`, `rom-mpc-all` |
| `weakens:red-bdh-to-abe-gpsw06` | 22 / 3 | 1 / 20 | 22 / 3 | 0 | `bdh-abe`, `bdh-ibe` |
| `quarantine:red-bdh-to-hve-bw07` | 2 / 2 | 0 / 0 | 2 / 2 | 0 | `bdh-range-query` |
| `refuted:ssddh` | 0 / 0 | 0 / 0 | 2 / 2 | 2 / 2 | `ssddh-ke` |
| `settings:honest-majority-t-lt-n-over-2` | 0 / 0 | 0 / 0 | 1 / 1 | 0 | none |
| `refuted:sidh` | 0 / 0 | 0 / 0 | 0 / 0 | 0 | none: nothing follows from SIDH alone |

**Cost.** Each entry's rerun takes 3.2–4.4 s in CPython on the Linux
container, so the report takes about 2.5 minutes. It runs when the curation
changes, not in CI.

**Layout.** The file is generated and must not be edited by hand. Its first
line is machine-readable, for the staleness test:

````markdown
<!-- curation-review: curation=ef14fbdf…(64 hex) manifest=b0c3fb65…(64 hex) wiki=ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157 entries=42 quotesMissing=0 -->
# Curation review

Generated by `scripts/derivations_reference.py --curation-report`; regenerate with
`make curation-review WIKI=…`. Spec: plans/relations-followups.md §2.

| | |
|---|---|
| Curation | `Resources/derivation-curation.json`, SHA-256 `ef14fbdf…` |
| Generated against | wiki `ab81f02`, relations.json `b0c3fb65…` (the golden file's) |
| Entries | 42: 3 refuted, 2 settings, 3 quarantine, 7 equivalences, 23 requires, 2 statementLint, 2 weakens |
| Quotes | 61 of 61 found |

## Summary

| # | Entry | What it changes | Wiki text | Effect (default) |
|---|---|---|---|---|
| 1 | `refuted:circular-evasive-lwe` | Answers from Circular evasive LWE are vacuous (AMYY25) | `Assumptions/learning-with-errors.md:113`, `:272` | 23 vacuous; golden `circular-evasive-lwe-pke` |
| … | | | | |
| 30 | `requires:red-dlog-to-prg-bm84:dlog` | DLOG ⇒ PRG (BM84) fires only on DLOG hard in Z\_p^\* | `Reductions/dlog-to-prg-bm84.md:23` | removes 32, changes 16; golden `ddh-prg` |

## Entries

### 30. `requires:red-dlog-to-prg-bm84:dlog`

**DLOG ⇒ PRG (BM84)** needs *DLOG hard in Z\_p^\* (p prime, g a generator)*
of its hypothesis DLOG. Met by: nothing; the notion must be given.

[`content/Reductions/dlog-to-prg-bm84.md:23`](https://github.com/axhoover/cryptology.city/blob/ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157/content/Reductions/dlog-to-prg-bm84.md#L23), § Statement

```markdown
If [[discrete-logarithm|DLOG]] is hard in $\ZZ_p^*$ ($p$ prime, $g$ a generator)
```

CCwiki's note: DLOG derived from CDH, DDH or BDH lives in their group, not Z\_p^\*.

**Effect.** Without this entry the engine derives 32 more pairs and changes 16
(default models), and 32 more and 30 changed with idealised models.
Removed, first 8: BDH ⇒\* auxiliary-input OWF, BDH ⇒\* COM, … Changed, first 8:
DLOG ⇒\* COM (assumption dropped), … Golden queries that change: `ddh-prg`.
````

- **"What it changes"** is one generated sentence per kind, in the words of
  derivations.md §7.
- **Quotes** go in a fenced `markdown` block of wiki source under a location
  line linking `page#Lline` at the commit. On GitHub a blockquote would
  typeset `$\ZZ_p^*$` as a MathJax error, turn `**` bold and drop the
  wikilinks' brackets; a fence shows the source as it is. The fence is one
  backtick longer than the longest backtick run in the quote, and at least
  three.
- **Generated strings** (every table cell, and the sentences outside the
  fences) go through one escaper: `\` first, then `|`, `*`, `_`, `$`,
  `` ` ``, `[` and `]` each get a backslash.
- **A missing quote** reads "**Not found on the page at <commit>**". The
  command still writes the document, counts it in `quotesMissing`, and
  exits 1.
- **The header's quote count** in the example (61) is an estimate; the
  track writes the real count.

### 2.4 Keeping it current

| Check | Runs where | Fails when |
|---|---|---|
| `CurationReviewTests` (Swift, new, Track A1) | `make check`, so CI on every push, with no clone | the first line's `curation=` is not the SHA-256 of `Resources/derivation-curation.json`; `manifest=` is not the golden file's `manifestSHA256`; `quotesMissing` is not 0; or the entry ids, read from the `### N. \`<id>\`` headings, are not `DerivationCuration.bundled.entries` in order |
| `curationQuotesFound` (Swift corpus check, Track A2; not a golden sentinel) | `make test-corpus`, so CI against the wiki's head | a cited quote is no longer on its page: re-review the entry |
| `curationEdgesUnchanged` (Swift corpus check, Track A2; not a golden sentinel) | `make test-corpus` | a reduction any entry names (its edge, every `metBy` and `acceptedBy` id) has a different `kind`, `hypotheses` or `conclusion` from the golden file's `curatedEdges`, or an `equivalences` edge a different `class` or `model`. A class or model change on any other curated edge prints a warning: it does not touch a notion requirement, and the wiki classifying DMO00 or DGI+19 is what derivations.md open question 1 asks for |
| `--selftest-units` (Python, Track A1) | `make check` | the shared quote-matching cases, the review document's escaping and fences, or the asks JSON's shape fail (§2.6, §4.1) |

The existing sentinels `curationResolves` and `regimeLossCurated` keep
failing as they do today. When any of these fail, follow derivations.md §8:
review the named entries, edit the curation, regenerate the golden file
with `--golden`, then run `make curation-review` against the same clone.

### 2.5 In the explorer: the wiki's text beside each correction

**Decision: show it.** The curation changes answers in ways no row shows
today:

- DDH ⇒ MPC rests on DMO00 establishing malicious OT for Kil88. No row
  says so.
- DDH ⇒ PRG is three steps through ElGamal, IL89 and HILL99, because BM84
  was refused. The derivable answer does not mention BM84.
- A refused step says why in CCwiki's words, but not where the wiki says
  it.

A reader cannot check a correction whose source they cannot see. So each
correction is shown once, with the wiki's text, on the row that already
names it, or in a last section when no row does.

**On rows that already name the correction** (Track C,
`ExplorerWriter.refusalRow` and `recordedOnPairRow`). A refused step whose
reason is `.requires`, `.weakened` or `.quarantined`, and a recorded-on-pair
row whose status is quarantined, keep their sentence and gain the entry's
citation notes and links (row anatomy below). The entry is the
`.requirement(relationID:isReverse:hypothesis:)` of the refused step, the
`.weakening(relationID:)` of the producer, or the `.quarantine` of the
step. R5 refusals are not curation and are unchanged.

**The section "Corrections CCwiki applied"** (`id: "corrections"`). A pure
function, `CurationTrace` (§6.4), reads the answer the explorer already
has; it never reruns the engine. It is computed **per proof**: one trace
for the shortest proof and, when R6 found one, one for the stronger proof.
Show It swaps the section with the proof, as it swaps every other part of
the verdict that describes the proof shown (`ExplorerResult.Stronger`).

| Effect | Found where | Entry |
|---|---|---|
| assumed | a proof row's `assumed` requirement | `.requirement(relationID:isReverse:hypothesis:)` |
| established by | a requirement on a proof row's step that the row does not assume; the producer is the step of the child row for that hypothesis | `.requirement(…)` |
| kept apart | a proof row with a `weakening` | `.weakening(relationID:)` of that row's step |
| accepted | a proof row whose child row is weakened | `.weakening(relationID:)` of the child's step |
| unstated direction | a step on an equivalence whose `equivalences` entry marks that direction anything but `record`, when the manifest has no `reverseClass` for it (today only ISIS ⇒ SIS) | `.equivalence(relationID:)` |
| not used here | a step in `closure.refused` with a `.requires` reason, whose conclusion is an object on the shown proof, and whose (relation, direction) is on **neither** proof | `.requirement(…)` |
| vacuous | a start with a `refuted` entry, when the manifest records no `refutedBy` on it | `.refuted(objectID:)` |
| setting | a start with a `settings` entry | `.setting(objectID:)` |

- `closure` is `derivation.closure(from:options:)` for the answer's start
  and options: one closure, well under a millisecond, inside the detached
  compute.
- The engine records a step's **first** refusal and never clears it, so a
  step blocked on a weak input can still fire later and land on a proof.
  "Neither proof" keeps such a step out of "not used here".
- A manifest refutation (§4.4, ask 2) is the wiki's own record. It stays in
  the verdict line and makes no item.
- A **no-path answer's** section holds only vacuous and setting items: its
  refusals carry their quotes on their own rows. Forward and backward lists
  get no section; each row's own question shows its section.
- **Order and duplicates.** Each entry appears once, in curation order,
  with all its effects. An entry with no effect in this proof does not
  appear. No items, no section.

**Placement.** The section is appended last in `derivedResult` (after the
barrier context sections) and in `noPathResult` (after the completions),
immediately before `result.initiallyCollapsed` is computed.

- **Section help:** "relations.json leaves out some things the wiki's pages
  state: a condition a step needs, a weaker result a step gives, which
  direction of an equivalence its class covers, that an assumption is
  broken, or that an object is a setting rather than an assumption. CCwiki
  reads each from the page, quoted here, and applies it."
- **Row help:** "CCwiki applies this because relations.json does not record
  it. The quoted text is the wiki's own."

**Titles: each thing is said once.** An effect another row or the verdict
already states gets no sentence of its own:

- *assumed* and *kept apart*: the proof row already says "assuming …" or
  "only …". The item's title is the step, `writer.stepText(step)`.
- *vacuous* and *setting*: the verdict lines already say so. The title is
  `writer.label(objectID)`.
- The other effects have a sentence (table below). An item's title is its
  effects' sentences joined by a space, in effect order; when none has one,
  the step or label as above.

**Sentences** live in `DerivationWording` (Track C) and name things with
`writer.stepText`, `writer.label` and the producer as a step, as
`refusalRow` does. The examples are what they produce on `ab81f02`;
`CurationTraceTests` asserts the exact strings on fixtures.

| Effect | Sentence | Real case |
|---|---|---|
| established by | "Oblivious transfer ⇒ Secure multi-party computation (Kil88, GMW87) needs OT secure against malicious parties (it instantiates Kil88's ideal OT). Private Information Retrieval ⇒ Oblivious transfer (DMO00) establishes it." | DDH ⇒ MPC |
| not used here | "Not used here: Discrete logarithm ⇒ Pseudorandom generator (BM84) needs DLOG hard in Z_p^* (p prime, g a generator), and the Discrete logarithm here comes from Computational Diffie-Hellman ⇒ Discrete logarithm (folklore)." | DDH ⇒ PRG; LWE ⇒ COM (PKE ⇒ COM) |
| accepted | "Pseudorandom function § Invertible PRFs ⇒ Pseudorandom function (folklore) accepts what Pseudorandom permutation ⇒ Pseudorandom function § Invertible PRFs (folklore) gives: an invertible PRF for the forward-oracle game only, over a super-polynomial domain." | any chain through PRP ⇒ iPRF ⇒ PRF |
| unstated direction | "Shortest Integer Solution § ISIS (Inhomogeneous SIS) ⇒ Shortest Integer Solution (folklore) is used with its class unstated: the record's class holds for the other direction only." | ISIS ⇒ CRHF |

**Row anatomy.** It reuses `ExplorerRow`; the only new view code is one
case in `follow`.

- `notes`: one line per citation, `“<quote>” — <page title> § <section>`,
  or `“<quote>” — <page title>` when `section` is null. The quote goes
  through `CurationTrace.plainQuote` (§6.4): wikilinks and markdown links
  become their display text, then `PreviewExcerpt.plainText` drops paired
  emphasis and backticks and reduces math through `RelationText.plain`.
  `RelationText`'s symbol table gains `\ZZ` → `ℤ` (no manifest title uses
  `\ZZ`, so no label changes). BM84's quote reads "If DLOG is hard in ℤ_p^*
  (p prime, g a generator)"; the OT page's reads "The definitions above are
  semi-honest".
- **A quote no longer on its page.** The app syncs the wiki daily, while
  its bundled curation stays as reviewed. At library load (§5.3) the app
  checks every citation against the clone. A citation that is missing reads
  "No longer on <page title> as quoted; CCwiki still applies this as
  reviewed at wiki <first 7 of `reviewedAgainst.wikiCommit`>." in place of
  its quote, and the row help loses its second sentence.
- `links`: one per distinct cited page, titled by the page: a reduction by
  `writer.reductionName`, a barrier by `writer.barrierTitle`, an object page
  by its label, and any other page by its file name without `.md`. Each
  targets the page's first cited section, `.section(path:anchor:)` with the
  anchor from `GithubSlugger.slug(section)`, or `.page(path)` when every
  citation of that page has `section: null`.
- `primary`: the first citation's target. `page`: a `PageLink` to the first
  cited page (kind "Reduction", "Barrier" or "Page"), so the context menu
  offers Open (`SWIFTUI-RULES` §7.4).
- `statement` (Copy Statement): the title, then the notes, one per line.
- `wraps = true`; the row is selectable.

**Wording rules.**

- CCwiki's own sentences say what CCwiki did and what the wiki says. They
  never say the wiki is wrong, and never use the words "error", "fix" or
  "caveat". The rule covers CCwiki's templates, not notions or quotes,
  which are the wiki's words ("error rate", "Learning with Errors").
- "Correction" and "Corrections" appear only in the section title.

**Not in the inspector.** The inspector's rows already say "Assuming …",
and the explorer is one click away (Show Proof).

### 2.6 Tests for §2

| Behaviour | Test |
|---|---|
| `cites`, `notionMarkdown` and `reviewedAgainst.wikiCommit` decode; a file without them still decodes; `statementLint` decodes as a bare string and as `{note, cites}`; entry ids and order as §2.2; 42 entries, ids unique | `CurationEvidenceTests` (Phase 0) |
| Every bundled entry has a citation; each `page` starts `content/` and ends `.md`; no quote contains `…`; no `notionMarkdown` contains `[[`, `](` or `**` | `CurationEvidenceTests` |
| Quote matching: CRLF, NFC, whitespace runs, section scoping, a heading inside a fence, the first of two equal headings, frontmatter with `section: null`, a missing section | `CurationQuoteTests` (A2) and Python `--selftest-units` (A1), both reading `Tests/CCwikiTests/Fixtures/quote-cases.json` (A1) |
| The review document: a quote with `$\ZZ_p^*$`, `**` and `[[a\|b]]` comes out inside a fence unchanged; a cell with `\|` and `*` is escaped; `--selftest` finds non-zero effects for `refuted:ssddh` and `settings:honest-majority-t-lt-n-over-2`, and BM84's 32 removals | Python `--selftest-units` and `--selftest` (A1) |
| The review document is current | `CurationReviewTests` (A1) |
| Quotes are still on their pages; curated edges unchanged | `DerivationCorpusTests` (A2), gated on `CCWIKI_WIKI` |
| The trace, on fixtures: each effect of the table; an established-by producer named; "not used here" only when the refused step concludes a node on the proof and is on neither proof (a fixture where a step blocked on a weak input later fires); two proofs that use different entries give different traces; a manifest refutation gives no item; one item per entry; curation order; empty for a proof that touches no entry | `CurationTraceTests` (C), on `ExplorerFixture` plus a small curation with citations |
| `plainQuote` on BM84's quote and the OT page's "Malicious Security" quote | `CurationTraceTests` |
| `sections.last?.id == "corrections"` for a derivable and a no-path answer; Show It swaps, removes or adds the section; a refused row carries its quotes and links; no correction row's title equals a refused row's or a verdict line's text; a missing quote's note; CCwiki's template sentences, rendered with fixture notions, contain none of `\b(caveat\|error\|errors\|fix\|fixes\|fixed)\b` (case-insensitive; notes and links excluded) | `ExplorerResultTests` (C) |

## 3. Copy a proof

### 3.1 Where

| Surface | What it copies | How |
|---|---|---|
| Explorer, a row with a proof (every proof row, and forward and backward rows) | that row's proof | context menu |
| Explorer, window key | the selected rows' proof if every selected row with a proof has the same one; otherwise the answer's proof (§6.3); otherwise nothing | Edit menu and shortcuts |
| Inspector, a row under "Derived: implies" or "Derived: implied by" | the row's proof, from `derivation.answer(from: row.query.from, to: row.query.to, options: .standard)`, computed on click: one answer, milliseconds | context menu |

**Context menus.** "Copy Proof as Text" moves into a submenu:

```
Copy Statement
Copy Proof As        ▸  Text
                        LaTeX
                        Wiki Markdown
Copy BibTeX of Cited Works        (explorer only, and only when it has entries)
```

- The explorer shows "Copy BibTeX of Cited Works" only when a cited work
  has an inline entry (§3.6). Apple's guidance for context menus is to
  hide an unavailable item rather than dim it, as `rowMenu` already does.
- The inspector shows only the submenu: its proof is computed on click, so
  nothing knows at menu time whether there is BibTeX to copy, and Show
  Proof is one click away.
- Context menus show no shortcuts. The inspector has no menu-bar
  equivalent, and a shortcut shown there would not work.

**Edit menu.** The same structure as the context menu, so the commands
are one submenu and one item rather than four new top-level items in every
window:

```swift
CommandGroup(after: .pasteboard) {
    Divider()
    Menu("Copy Proof As") {
        Button("Text") { … }
        Button("LaTeX") { … }.keyboardShortcut("c", modifiers: [.command, .option])
        Button("Wiki Markdown") { … }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
    }
    .disabled(action == nil)
    Button("Copy BibTeX of Cited Works") { … }
        .disabled(action?.hasInlineEntries != true)
}
```

| Item | Shortcut | Why this key |
|---|---|---|
| LaTeX | ⌥⌘C | Option-Copy copies another form of the same thing, as Finder's Copy as Pathname is ⌥⌘C. Free in CCwiki, and after the rest of the batch (§12). The text system's Copy Style, also ⌥⌘C, is in a Format menu CCwiki does not have |
| Wiki Markdown | ⌥⇧⌘C | the second form; free in CCwiki, in the batch and in the system set |

Key equivalents inside a menu-bar submenu still fire and still show. The
explorer publishes a `ProofCopyAction` through `focusedSceneValue`, as the
reader publishes `FindAction`. It publishes nil, so the commands are
disabled, while the suggestions pane is showing (the answer underneath is
not on screen and may not match what is being typed) and whenever
`result.state != .answer`. Track B adds ⌥⌘C and ⌥⇧⌘C to
relations-explorer.md §2.9 (Keyboard) and to §2.11's table of taken
shortcuts, as "Copy Proof As (Edit menu)", and to design-system.md §4, the
app's shortcut map, which the other two specs in the batch extend after it.

### 3.2 The shape: steps in dependency order

A proof tree is depth-first from the target (R7). A copy reads better in the
order a paper argues: every step after the steps that give its hypotheses.
`ProofExport` (§6.3):

- Folds the flat rows into a tree, as `ProofOutline` does.
- Emits the steps **post-order**: each step's hypotheses' steps, in the
  edge's order, then the step itself.
- Skips givens and "shown above" references.
- Keeps each (reduction, direction) once.
- An equivalence used both ways is two steps; it still counts as one of the
  N recorded reductions.
- The conjunction stays whole: a step is one item with every hypothesis,
  joined by ∧.
- It carries what the provenance needs: N, the depth, the chain class with
  its unstated count, the models (the non-standard models of its own
  steps), the refuted starts, and whether the answer is a recorded one-step
  result (`depth == 1`). Every one of these is the copied proof's own, so a
  copy made with Show It on states the stronger proof's N, depth and class.

### 3.3 Names and citation keys

**Names** (`ProofNames.name`, §6.3):

1. **A page object**: its first alias. 130 of the 131 page objects have
   one: DDH, cPIR, OT, KEM.
2. **A variant whose id has no hyphen**: the id in capitals. There are six,
   and these are the names the wiki's reduction titles use: OWF, CRHF,
   SSDDH, SXDH, CSIDH, FRI.
3. **Any other variant**: its title when the title names its host, that
   is, contains as a whole word, ignoring case and a trailing plural "s",
   the host's name, one of its aliases, its title or its title's last word
   ("Low-noise LPN", "Rabin OT", "BLS signatures", "Invertible PRFs").
   Otherwise "<host name> <title>" ("PKE CPA Security", "SKE CPA Security",
   "COM Binding", "ABE Selective Security", "OT Malicious Security", "RSA
   Φ-Hiding").
4. **Anything else**: `RelationLabels.label`.

On `ab81f02` this keeps 77 variant titles, prefixes 48 and names 6 by id,
and no two of the 262 objects share a name. Two variants are titled "CPA
Security" and two "CCA Security"; titles such as "Binding", "Selective
Security" or "Types" cannot be read alone in a paper. This matches the
wiki's house style ("Use the canonical abbreviation …
`[[pseudorandom-function|PRF]]`", CLAUDE.md) and its reduction titles
("OWF ⇒ PRG").

**Citations.** A reduction's `source` is either the token `folklore` or the
wiki's own wikilinks to reference pages. On this manifest there are 301
source entries: 86 folklore, 195 that resolve to a page with a
`cryptobib_key`, and 20 to a page with an inline `bibtex` (19 of the 283
reductions). Every non-folklore entry resolves. Of the 430 reference pages:

- **358 carry `cryptobib_key`.** Most keys have a venue prefix
  (`EC:DiCMalOst00`, `STOC:Kilian88`). Some journal keys have none
  (`GolGolMic86`, `HILL99`, `CraSho03`).
- **72 carry an inline `bibtex` entry.** In 69 of them the entry's key is
  the wiki's key (`GMW87`). In 3 it is not: GK96's entry is `GK96a`, KR03's
  is `KemReg03`, and KSV02's is `KitSheVya02`.

**The `\cite` key** is, in order of preference:

1. the page's `cryptobib_key`;
2. otherwise the inline entry's own key, read from `@type{KEY,`;
3. otherwise the wiki's key (`RelationText.citationKey`), and the item's
   comment says so (§3.4).

So a paper whose bibliography is `crypto.bib` plus the BibTeX copy resolves
every key. CryptoBib is the common bibliography in cryptography; the wiki
checks keys against it (`vendor/cryptobib`).

**Resolution.** `ProofCitations` parses each source entry with
`WikilinkParser`, resolves it with `WikiIndex.resolve(_:from:)` from the
reduction's page, and reads `cryptobib_key` and `raw("bibtex")` from the
page's frontmatter, as `ReaderView.referenceBar` does. A refutation's
`source` is a bare key ("CD22"); `citation(forKey:)` finds its page as the
one file in `References/` named `<key> - …`. With no index loaded, every
key falls back to the wiki's key.

### 3.4 LaTeX

A comment header, an optional vacuity sentence, then an `enumerate` with one
`\item` per step. Real output for DDH ⇒ MPC:

```latex
% DDH ⇒* MPC: derived by CCwiki from 4 recorded reductions (cryptology.city relations.json at ab81f02ff4a0).
% Each step is a result the wiki records. The chain is CCwiki's composition: the wiki does not state it.
% Class unstated: 3 steps do not state theirs.
% Math uses no cryptology.city macros.
% In CryptoBib (crypto.bib): C:DGIMMO19, EC:DiCMalOst00, STOC:Kilian88.
% Not in CryptoBib; Copy BibTeX of Cited Works gives their entries: GMW87.
\begin{enumerate}
  \item DDH $\Rightarrow$ TDH by~\cite{C:DGIMMO19}. % red-ddh-to-tdh-dgi-19 (DDH ⇒ TDH): unstated
  \item TDH $\Rightarrow$ cPIR by~\cite{C:DGIMMO19}. % red-tdh-to-cpir-amr25 (TDH ⇒ cPIR): unstated
  \item cPIR $\Rightarrow$ OT by~\cite{EC:DiCMalOst00}. % red-cpir-to-ot-dmo00 (cPIR ⇒ OT): unstated
  \item OT $\Rightarrow$ MPC by~\cite{STOC:Kilian88,GMW87}, for OT secure against malicious parties, which~\cite{EC:DiCMalOst00} establishes. % red-ot-to-mpc-kil88 (OT ⇒ MPC): fully black-box
\end{enumerate}
```

GapSVP ⇒ PKE, a quantum step:

```latex
% GapSVP ⇒* PKE: derived by CCwiki from 2 recorded reductions (cryptology.city relations.json at ab81f02ff4a0).
% Each step is a result the wiki records. The chain is CCwiki's composition: the wiki does not state it.
% Fully black-box: every step is. Uses the quantum setting.
% Math uses no cryptology.city macros.
% In CryptoBib (crypto.bib): STOC:Regev05.
\begin{enumerate}
  \item GapSVP $\Rightarrow$ LWE by~\cite{STOC:Regev05}, in the quantum setting. % red-gapsvp-to-lwe-reg05 (GapSVP ⇒ LWE): fully black-box
  \item LWE $\Rightarrow$ PKE by~\cite{STOC:Regev05}. % red-lwe-to-pke-reg05 (LWE ⇒ PKE): fully black-box
\end{enumerate}
```

SSDDH ⇒ KE, one recorded step from a refuted start:

```latex
% SSDDH ⇒ KE: recorded in the wiki (cryptology.city relations.json at ab81f02ff4a0).
% Math uses no cryptology.city macros.
% In CryptoBib (crypto.bib): EC:CasDec23, PQCRYPTO:JaoDeF11.
SSDDH is known to be false~\cite{EC:CasDec23}, so this implication is vacuous.
\begin{enumerate}
  \item SSDDH $\Rightarrow$ KE by~\cite{PQCRYPTO:JaoDeF11}. % red-sidh-to-ke-jdf11 (SSDDH ⇒ KE): unstated
\end{enumerate}
```

Low-noise LPN ⇒ OT, an assumed precondition, using `notionMarkdown`:

```latex
  \item Low-noise LPN $\Rightarrow$ TDH by~\cite{TCC:AbrMalRoy25}, assuming quasi-polynomial hardness of low-noise LPN with noise rate $O(\log^{1+\beta}(k)/k)$. % red-noise-level-to-tdh-amr25 (Low-noise LPN ⇒ TDH): unstated
```

**The rules.**

- **"A ⇒ B by \<reduction\>, \cite{…}".** In LaTeX the "by" is the
  citation, which a paper wants in the text. The reduction's id and title
  go in the item's comment.
- **Each item** is
  `<hypotheses joined by " $\wedge$ "> $\Rightarrow$ <conclusion> by~\cite{<keys>}`,
  then these qualifiers, in this order, each after a comma:
  - `in the <model name>` when the model is not standard, using
    `DerivationWording.modelName`. `other` reads "in a non-standard model";
    a stub reads "through a stub reduction".
  - `used right to left` for the reverse direction of an equivalence.
  - `assuming <notion>` for each assumed precondition.
  - `for <notion>, which~\cite{<producer keys>} establishes` for each
    precondition a `metBy` producer met.
  - `giving only <notion>` for a weakened conclusion.

  A folklore step reads `… $\Rightarrow$ B (folklore).` The item ends with
  `.` and one comment:
  `% <relation id> (<reduction title, plain>): <class>`, with `<class>` from
  `ExplorerWriter.className` for the direction used. When a key fell back to
  the wiki's key, the same comment ends `; <key> has no BibTeX key on its
  reference page` (once per such key).
- **The header**, every line a comment:
  - For a chain of two or more steps: the statement with ⇒*, "derived by
    CCwiki from N recorded reductions", the relations.json revision
    (`model.headRevision`, first 12 characters); then
    `DerivationWording.derivedFooter`; then the chain-class line from
    `DerivationWording.chainClass` with a full stop, followed by "Uses the
    …" when a step is outside the standard model. For one step:
    `% <A ⇒ B>: recorded in the wiki (cryptology.city relations.json at …).`
  - `% Math uses no cryptology.city macros.` Proofs are pasted into papers
    that lack the wiki's preamble, so math is written out, like the
    reader's "Copy Algorithm as LaTeX (No Macros)".
  - `% In CryptoBib (crypto.bib): <keys>.` when any `\cite` key is a
    CryptoBib key, in order of first appearance. With 195 of 215 cited
    works in CryptoBib, this line makes the LaTeX copy complete on its own
    for most proofs.
  - `% Not in CryptoBib; Copy BibTeX of Cited Works gives their entries: <keys>.`
    when any cited work has an inline entry.
- **A refuted start** adds a visible sentence after the header, outside
  every comment, so a compiled paper says it:
  `<name> is known to be false~\cite{<keys>}, so this implication is vacuous.`
  One sentence per refuted start, the start names joined by " and ".
- **⇒\* appears only in the header comment.** Each item is one recorded,
  cited step, so it is written ⇒. That is the honesty contract of
  relations-explorer.md §1, applied to a copy.

### 3.5 Wiki Markdown

For pasting into a wiki page, a Notes bullet or "# Other results". The
format is a numbered list in the same order. The provenance goes in an HTML
comment: invisible on the site, ignored by the wiki's lint (`HTML_COMMENT`
is masked), and deletable by whoever pastes. Real output for OWF ∧ KEM ⇒
PKE:

```markdown
<!-- OWF ∧ KEM ⇒* PKE: derived by CCwiki from 4 recorded reductions (cryptology.city relations.json at ab81f02ff4a0). Each step is a result the wiki records. The chain is CCwiki's composition: the wiki does not state it. Fully black-box: every step is. -->
1. [[hash-function#preimage-resistance-one-wayness|OWF]] ⇒ [[pseudorandom-generator|PRG]] by [[owf-to-prg-hill99|OWF ⇒ PRG]] — [[HILL99 - A Pseudorandom Generator from Any One-Way Function|HILL99]].
2. [[pseudorandom-generator|PRG]] ⇒ [[pseudorandom-function|PRF]] by [[prg-to-prf-ggm86|PRG ⇒ PRF (GGM)]] — [[GGM86 - How to construct random functions|GGM86]].
3. [[pseudorandom-function|PRF]] ⇒ [[symmetric-key-encryption|SKE]] by [[prf-to-ske|PRF ⇒ CPA-secure SKE]] — folklore.
4. [[key-encapsulation-mechanism|KEM]] ∧ [[symmetric-key-encryption|SKE]] ⇒ [[public-key-encryption|PKE]] by [[kem-and-ske-to-pke|KEM + SKE ⇒ PKE]] — [[CS03 - Design and Analysis of Practical Public-Key Encryption Schemes Secure against Adaptive Chosen Ciphertext Attack|CS03]].
```

A refuted start, SSDDH ⇒ KE:

```markdown
<!-- SSDDH ⇒ KE: recorded in the wiki (cryptology.city relations.json at ab81f02ff4a0). -->
[[supersingular-isogeny-diffie-hellman#decisional-variant-ssddh|SSDDH]] is known to be false ([[CD22 - An efficient key recovery attack on SIDH|CD22]]), so this implication is vacuous.

1. [[supersingular-isogeny-diffie-hellman#decisional-variant-ssddh|SSDDH]] ⇒ [[key-exchange|KE]] by [[sidh-to-ke-jdf11|SSDDH ⇒ KE]] — [[JDF11 - Towards quantum-resistant cryptosystems from supersingular elliptic curve isogenies|JDF11]].
```

**The rules.**

- **Objects** are linked the way the generated "Participates in" sections
  link them: `[[slug|name]]`, or `[[slug#anchor|name]]` for a variant, with
  the name of §3.3. A name with `$` becomes a markdown link with
  `escapeOutsideMath`, which the wiki's `wikilink-math` lint requires.
  - Track B changes `RelationMeta.link(_:_:)` from `private` to internal
    so the writer reuses it. Nothing else in that file changes.
- **"by"** links the reduction page by its slug, with its own title. Here
  the title does say more than the step: "PRF ⇒ CPA-secure SKE", "PRG ⇒
  PRF (GGM)".
- **The citation** is the `source` entries verbatim, joined by ", " after
  " — ", which is the wiki's Statement convention. A folklore step ends
  " — folklore.".
- **Qualifiers** are the LaTeX ones in the same order, with the notion as
  `notionMarkdown` verbatim, or else `notion` through `MarkdownText.escape`.
- **A refuted start** adds a visible paragraph before the list:
  `<object link> is known to be false (<source wikilinks>), so this implication is vacuous.`
  The source is the reference page's wikilink when it resolves, else the
  bare key.
- **One step:** `<!-- A ⇒ B: recorded in the wiki (…). -->` and a one-item
  list.

### 3.6 BibTeX of cited works

Only for proofs where a cited work has an inline entry on its reference
page; for every other proof `ProofBibTeX.write` returns nil, the explorer's
context menu hides the item, and the Edit-menu item is disabled. Real output
for DDH ⇒ MPC:

```bibtex
% Works cited by the proof of DDH ⇒* MPC that are not in CryptoBib, from cryptology.city's reference pages. The others: C:DGIMMO19, EC:DiCMalOst00, STOC:Kilian88.

@inproceedings{GMW87,
  author    = {Oded Goldreich and Silvio Micali and Avi Wigderson},
  title     = {How to Play {ANY} Mental Game or A Completeness Theorem for Protocols with Honest Majority},
  booktitle = {Proceedings of the 19th Annual ACM Symposium on Theory of Computing (STOC 1987)},
  pages     = {218--229},
  year      = {1987}
}
```

- Entries appear in the order of first appearance in the steps,
  de-duplicated by `\cite` key, copied verbatim
  (`Frontmatter.raw("bibtex")`, as the reader's BibTeX button copies them),
  separated by blank lines.
- One comment line comes first; it names the CryptoBib keys only when there
  are some.
- CCwiki has no `crypto.bib`: the reader's clone does not check out
  submodules, and only a job worktree does. Synthesising an entry from a
  reference page's frontmatter would invent a record under CryptoBib's key,
  and that clashes with the real one in a paper that loads `crypto.bib`.

### 3.7 Escaping

**`TeXText.escape(_:macros:)`** is pure. It splits the text into math and
text spans by the site's rule, the pairing `RelationText.plain` uses: a `$`
that opens no span is literal.

- **Inside math:** the wiki's macros are expanded by
  `MacroTable.expanded(_:)`, a new extension in Track B's file, so
  `MacroTable.swift` is unchanged. Each name in the table is replaced only
  as a whole control word. The pass repeats until the text stops changing,
  at most 10 times. That is the reader's expansion rule (render-pipeline.md
  §3); the reader does it in JS, and this is the Swift twin. Nothing else
  inside math changes.
- **Outside math:**

| In | Out |
|---|---|
| `\ { } & % # _` | `\textbackslash{} \{ \} \& \% \# \_` |
| `^ ~` | `\^{}` `\textasciitilde{}` |
| `$` (unpaired) | `\$` |
| `< > \|` | `\textless{}` `\textgreater{}` `\textbar{}` |
| `⇒ ⇔ ∧ ⇒*` | `$\Rightarrow$` `$\Leftrightarrow$` `$\wedge$` `$\Rightarrow^*$` |
| `§ – — …` | `\S{}` `--` `---` `\ldots{}` |
| Greek letters with a LaTeX command | in math: `Φ` → `$\Phi$`, `λ` → `$\lambda$`, `ε` → `$\epsilon$`, … |
| the symbols `RelationText` produces | in math: `≤ ≥ ≠ ⊆ ⊂ ⊇ ⊃ ∩ ∪ ∈ ∉ → ↦ ↔ ∀ ∃ × · ± ≈ √ ∞ ℓ ℤ` → `$\le$` … `$\mathbb{Z}$` |
| Latin-1 letters (Håstad) and ’ “ ” | unchanged: pdfLaTeX reads UTF-8 input by default since 2018 and has these |

pdfLaTeX, which LNCS and IACR papers use, stops on a Greek letter or a math
symbol outside math ("Unicode character Φ not set up for use with LaTeX"),
hence the two mapped rows. `ProofWriters.swift` holds the table; it is the
inverse of `RelationText.symbols` plus the Greek alphabet.

Comment lines are not escaped: anything after `%` is ignored, newlines
excepted. Newlines in a comment are replaced by spaces.

**`MarkdownText.escape(_:)`** is `RelationMeta.escapeOutsideMath`, plus
`*` and `_` escaped outside math. So the plain `notion` "DLOG hard in Z_p^*"
does not open emphasis; it becomes `DLOG hard in Z\_p^\*`.

| Case | TeX | Markdown |
|---|---|---|
| `IND$-CPA Security` (a variant title) | `IND\$-CPA Security` | `IND\$-CPA Security`, inside a markdown link |
| `$k$-Linear assumption` | `$k$-Linear assumption` | a markdown link whose text keeps `$k$` |
| `Honest majority ($t < n/2$)` | `Honest majority ($t < n/2$)` | as is, as a markdown link |
| `Pseudorandom generator in $\mathrm{NC}^1$` | unchanged | as is |
| `RSA Φ-Hiding` (a copy name) | `RSA $\Phi$-Hiding` | as is |
| `… error rate l^(-delta)` with a `λ` (a plain notion) | `… $\lambda$ …` | as is |
| `Hash function § Preimage resistance (one-wayness)` (a label, only in a fallback) | `Hash function \S{} Preimage …` | as is |

### 3.8 Tests for §3

All in `ProofExportTests` (Track B). They are pure. They build their own
manifest with `ExplorerFixture.manifest(objects:reductions:barriers:)`,
whose `source` entries are wikilinks matching a temporary-directory
`WikiIndex` (built as `LinkPreviewTests.makeIndex()` builds one) with three
reference pages: one with `cryptobib_key`, one KR03-shaped (inline entry
whose key differs from the wiki's), and one with neither.

| Behaviour | Check |
|---|---|
| Dependency order | `owf ∧ kem ⇒ pke` gives OWF ⇒ PRG, PRG ⇒ PRF, PRF ⇒ SKE, KEM ∧ SKE ⇒ PKE, in that order; a shared sub-proof appears once; givens and references give no item |
| The conjunction is never split | `a ∧ b ∧ c ⇒ d` is one item containing both `\wedge`s, and one Markdown line containing two ∧ |
| LaTeX exact | the fixture chain's whole string, header included, byte for byte |
| Markdown exact | likewise; a variant links `slug#anchor`; a `$` title becomes a markdown link |
| BibTeX | nil when no cited work has an inline entry (all-folklore, and all-CryptoBib); otherwise the entries verbatim and de-duplicated; the LaTeX header lists the CryptoBib keys |
| `\cite` key mapping | a CryptoBib key; the KR03 shape; fallback to the wiki key with `; <key> has no BibTeX key on its reference page` in the item's one comment; folklore gives no `\cite` |
| Honesty | for N ≥ 2 the header says "derived by CCwiki from N recorded reductions" and has ⇒*; for N = 1 it says "recorded in the wiki" and has no ⇒*; no item contains ⇒\*; a refuted start's sentence is outside any comment in LaTeX and outside the HTML comment in Markdown |
| Show It | the copy of a stronger proof states its own N, depth, class and models; for the shortest proof, `ProofExport.models` equals the fact's |
| Qualifiers | a quantum step, a reverse step, an assumed and a `metBy` precondition, and a weakened conclusion each produce their phrase in order |
| Names | two variants titled "CPA Security" on different hosts get two names; a hyphenless variant id is capitalised; a title naming its host is kept |
| Names, corpus | gated on `CCWIKI_WIKI`: no two manifest objects share a name |
| Escaping | the table in §3.7, case by case, for both writers; macro expansion as a whole word (`\st` leaves `\stA`) and repeated to a fixed point |
| The selection rule | `ExplorerResult.proofCopy(selection:showingStronger:)`: one selected proof row; two rows of the same proof; rows of two different proofs fall back to the answer's; Show It gives the stronger proof's copy; a forward or backward list with nothing selected gives nil |

## 4. The wiki asks

### 4.1 Where they live, and how they are applied

- **`plans/wiki-asks.md`** is the human document. Track A1 writes it from
  §4.2. Each ask has six parts:
  - what CCwiki needs and why, with the numbers below;
  - the exact change: frontmatter, `scripts/generate-relations.mjs`,
    `scripts/lint.mjs` and `scripts/lint-edges.mjs`, and the docs;
  - the affected pages;
  - the wiki's own open items it relates to;
  - the curation entries it would retire;
  - how CCwiki takes it in.
- **`plans/wiki-asks.inbox.json`** holds the same asks in the wiki's review
  inbox format (`.review/README.md` § The inbox):
  - one object `{"source", "items"}`;
  - each item has `id` (prefix `ccw:`), `kind`, `summary`, `pages` (a page
    the change creates ends ` (new)`), `proposed_action` (the exact change),
    and `rationale`, `related`, `needs_paper` and `confidence` where they
    apply;
  - nothing else, because any other key makes the wiki reject the file.
  - `--selftest-units` checks the keys, the `<prefix>:<name>` ids (unique,
    never `r<n>:`), the kinds (a copy of the wiki's `INBOX_KINDS`), that
    every curation entry the JSON names as retired exists, and that
    `wiki-asks.md` names each `ccw:` id. The wiki's own check is
    authoritative: `wiki-asks.md` tells the maintainer to run
    `node scripts/review/round.mjs inbox` in the wiki after copying.
- **How the maintainer applies them.** The content asks go through the
  wiki's pipeline: copy the JSON to the wiki's `.review/inbox/` on `main`,
  for example as `ccwiki-derivations-2026-10.json`. The next monthly round
  then verifies each item with its two adversarial verifiers and proposes
  it on the review page. The three schema asks (§4.2 asks 1–3) change the
  wiki's scripts, so they are better as one ordinary PR in the wiki repo.
  Their items are in the JSON too, so the round can see they exist.

The maintainer files both. CCwiki and its implementing agents never do
(§5.6).

**Overlap with the wiki's own queue.** The wiki's inbox
(`final-form-2026-10-04.json`) and round 2's open paper items already cover
several of derivations.md §2a's asks. The CCwiki items do not repeat them;
they name them in `related`.

| Wiki item | Covers |
|---|---|
| `ffr:schema-convention-10` | a machine-readable refutation marker; ask 2 below picks its option B |
| `ffr:schema-convention-9` | how a barrier between models is typed; ask 3 |
| `ffr:schema-convention-14` | honest-majority "settings" as edges from a secure-channels node; CCwiki's two `settings` entries (§4.3) |
| `ffr:verification-gap-8` | ISIS ⇔ SIS's unproved direction; `equivalences:` and `requires:` on that edge |
| `ffr:node-granularity-3` | YZW+19 on a new `subexponential-lpn-above-half` variant |
| `ffr:node-granularity-11` | AMR25 on a quasi-polynomial low-noise LPN variant |
| `ffr:missing-edge-4` | a KP-ABE adaptive node; ask 5 |
| `ffr:content-error-26`, `ffr:verification-gap-29` | Kil88's OT ⇒ MPC and OT ⇒ COM Statements; ask 4 |
| `fu2:node-granularity-12`, `fu2:node-granularity-13` (round 2, paper section) | Wee22's dropped LWE conjunct; BW07's composite-order hypotheses: the 3 `quarantine` entries |

### 4.2 The asks

Inbox kinds are the wiki's (`INBOX_KINDS`). "Retires" names the curation
entries the change makes redundant.

**Ask 1. `reverse-class` on every equivalence** (`ccw:schema-reverse-class`,
`schema-convention`).

- **Need.** An equivalence's two directions can be different theorems
  (R1). CCwiki keeps a table of all 7 eligible equivalences to say which
  direction the record's `class` covers. An optional field could not
  replace it: an absent field reads the same as a manifest from before the
  field existed.
- **Change.** `reverse-class`, the class of conclusion ⇒ hypothesis,
  **required** on reduction pages with `kind: equivalence`.
  - Producer, in the `reductions.push` record after `class`:
    `...(p.fm.kind === "equivalence" ? { reverseClass: p.fm["reverse-class"] ?? "unstated" } : {})`.
  - Lint:
    - add `"reverse-class"` to `OPTIONAL_KEYS` and `EDGE_FRONTMATTER`;
    - error `edge-reverse-class-missing` on an equivalence without it;
    - error `edge-reverse-class` on any other kind;
    - the value is a class or `unstated`;
    - `RATIONALE_FIELDS.reduction["reverse-class"] = "reverseClass"`;
    - the contradiction check reads `reverse-class` for a barrier on the
      reverse pair.
  - Docs: `docs/relations-json.md` § reductions and `schema/README.md`
    § What the hyperedge asserts.
- **Values for the 8 equivalences**, from CCwiki's review:

  | Page | `class` | `reverse-class` |
  |---|---|---|
  | `cpa-security-to-cpa-security.md` | fully-black-box | fully-black-box |
  | `linear-secret-sharing-schemes-lsss-to-msp.md` | free | free |
  | `module-lwe-to-lwe-ls15.md` | fully-black-box | fully-black-box |
  | `module-lwe-to-ring-lwe-ls15.md` | fully-black-box | fully-black-box |
  | `rabin-ot-to-ot.md` | fully-black-box | fully-black-box |
  | `qip-to-pspace.md` | free | free |
  | `isis-inhomogeneous-sis-to-sis.md` | `unstated` (was fully-black-box) | fully-black-box; unless `ffr:verification-gap-8` splits the page first |
  | `rsa-to-fac-dlo24.md` | its directions differ in **model** too (RSA ⇒ FAC is trivial in the standard model; FAC ⇒ RSA is DLO24's generic-ring theorem), which no class field can say. Split it into two implications and retire the id per the stability contract: `red-rsa-to-fac` (folklore, standard) and `red-fac-to-rsa-dlo24` (`model: other`) | |

- **Retires** the 7 `equivalences:` entries: 6 by the field, DLO24's by
  the split.

**Ask 2. `refuted-by` on objects and variants** (`ccw:schema-refuted-by`,
`schema-convention`, related `ffr:schema-convention-10`, recommending its
option B).

- **Need.** R14 marks circular evasive LWE, SIDH and SSDDH false. The wiki
  states this in prose only.
- **Change.** An optional `refuted-by`, a list of reference wikilinks.
  - On an object page it marks the page's own object only, never its
    variants, so CSIDH on the SIDH page stays unmarked.
  - In a variant's mapping form, beside `anchor` and `formal`.
  - A family in which only some formulations are false gets no marker on
    its host. Private-coin evasive LWE, of which "several … formulations are
    false" (`learning-with-errors.md:268`), stays unmarked.
  - Producer, for the page object:
    `...(p.fm["refuted-by"] ? { refutedBy: [].concat(p.fm["refuted-by"]) } : {})`.
    For a variant: `...(typeof v === "object" && v?.["refuted-by"] ? { refutedBy: [].concat(v["refuted-by"]) } : {})`.
    Both are omitted when empty, as `formal` is.
  - Lint:
    - add `"refuted-by"` to `OPTIONAL_KEYS`, with an error unless the page
      is an object page;
    - the variants loop (`lint.mjs` around line 536, which today checks only
      `anchor`) also checks a mapping's keys: `anchor`, `formal` and
      `refuted-by` only. No page uses the mapping form today, so this flags
      nothing;
    - each `refuted-by` entry resolves to a reference page, by the
      `edge-source` check without the `folklore` token.
  - Docs: `docs/relations-json.md` § objects. In `schema/README.md`
    § Refutations are attacks, add "…and the refuted object or variant
    carries `refuted-by`, so a consumer deriving consequences can mark
    implications from it vacuous."
- **Pages.**
  - `content/Assumptions/learning-with-errors.md`:
    `circular-evasive-lwe: {anchor: "#circular-evasive-lwe", refuted-by: ["[[AMYY25 - Evasive LWE Attacks, Variants & Obfustopia|AMYY25]]"]}`.
  - `content/Assumptions/supersingular-isogeny-diffie-hellman.md`:
    top-level `refuted-by: ["[[CD22 - An efficient key recovery attack on SIDH|CD22]]"]`,
    and `ssddh: {anchor: "#decisional-variant-ssddh", refuted-by: [same]}`.
- **Retires** the 3 `refuted:` entries.

**Ask 3. `model` on barriers** (`ccw:schema-barrier-model`,
`schema-convention`, related `ffr:schema-convention-9`).

- **Need.** R12 propagates a primitive-to-primitive barrier through side
  reductions as if it were proved in the standard model (derivations.md
  §10). The lint already accepts `model` on a barrier page, but the
  producer drops it.
- **Change.**
  - Producer, in `barriers.push` after `class`: `model: p.fm.model ?? "standard",`.
    It is always emitted, as on reductions.
  - `RATIONALE_FIELDS.barrier.model = "model"`.
  - Docs: `schema/README.md` § Which model to record currently says "On a
    barrier, which has no `model` field, the model's node is the
    hypothesis". It becomes: "`model` on a barrier is the model its theorem
    is proved in, `standard` by default. A barrier saying X fails in a
    model also keeps the model's node as its hypothesis."
- **Pages.**
  - `content/Barriers/no-rom-to-ke-hmo-19.md`: `model: rom`.
  - `content/Barriers/no-agm-to-ggm-kz22.md`: as `ffr:schema-convention-9`
    decides.
  - No other barrier needs one today. The oracle separations are
    `relativizing`, not idealised-model theorems.
- **Retires** nothing, and closes the §10 risk "Barriers have no model
  field".

**Ask 4. Malicious OT as a node** (`ccw:node-malicious-ot`,
`node-granularity`, related `ffr:content-error-26` and
`ffr:verification-gap-29`).

- **Change.**
  - `ot-to-mpc-kil88.md` and `ot-to-com.md`: `hypotheses: [malicious-ot-security]`.
    The variant exists on `oblivious-transfer.md#malicious-security`.
  - `cpir-to-ot-dmo00.md`: `conclusion: malicious-ot-security`. Its
    Statement already says single-server PIR is complete for secure
    computation.
  - A new folklore page `malicious-ot-security-to-ot.md`: `{malicious-ot-security} ⇒ ot`,
    `class: fully-black-box`, rationale "the identity map; a protocol
    secure against malicious parties is secure against semi-honest ones".
    The verifiers should confirm this holds for the OT page's definitions.
  - Ids stay: this is node refinement on the same theorem.
- **Effect,** checked by patching the manifest:
  - every answer survives under the variant's name: `malicious-ot-security
    ⇒* MPC`, and DDH ⇒* MPC through DMO00;
  - `OT ⇒ MPC` and `OT ⇒ COM` "assuming malicious OT" become R9 hints
    ("its section Malicious Security derives the target").
- **Retires** `requires:red-ot-to-mpc-kil88:ot` and `requires:red-ot-to-com:ot`.

**Ask 5. Weakened conclusions as nodes** (`ccw:node-weakened-conclusions`,
`node-granularity`, related `ffr:missing-edge-4`).

- **GPSW06.** `bdh-to-abe-gpsw06.md`: `conclusion: abe-selective-security`.
  The patched manifest gives the same pair under the variant's name: 1 lost,
  1 gained.
- **PRP ⇒ invertible PRF.** On `pseudorandom-function.md`, a new heading
  for the forward-game notion with the variant `invertible-prf-forward`.
  - `prp-to-invertible-prf.md`: `conclusion: invertible-prf-forward`.
  - Two folklore pages: `{invertible-prf} ⇒ invertible-prf-forward` (the
    strong game implies the forward one) and
    `{invertible-prf-forward} ⇒ prf` (the forward game is the PRF game,
    which the curation's evidence already quotes).
- **Retires** both `weakens:` entries.

**Ask 6. Hypotheses on regime and notion variants**
(`ccw:node-hypothesis-regimes`, `node-granularity`). Each row re-points a
hypothesis; the ids stay.

| Edge page | Hypothesis now | Proposed node | Exists? | Retires |
|---|---|---|---|---|
| `dlog-to-prg-bm84.md` | `dlog` | `dlog-zp-star`, "DLOG in $\ZZ_p^*$", a heading on `discrete-logarithm.md` | new | `requires:…bm84:dlog` |
| `tdp-to-nizk-bfm88.md` (FLS90) | `tdp` | `doubly-enhanced-certified-tdp` on `trapdoor-permutation.md`, beside `enhanced-trapdoor-permutation` (related `ffc:verification-gap-1`) | new | `requires:…bfm88:tdp` |
| `pke-to-com.md` | `pke` | a variant for perfectly correct CPA-secure PKE with certifiable keys, on `public-key-encryption.md` | new | `requires:red-pke-to-com:pke` |
| `abe-to-be.md` | `abe` | `cp-abe-adaptive-security`; KW19's (`k-linear-assumption-to-abe-rw13.md`) and Wee25's (`succinct-lwe-to-abe-wee25.md`) conclusions likewise if their Statements are adaptive CP-ABE (`needs_paper`) | exists | `requires:red-abe-to-be:abe` |
| `subexponential-lpn-to-crhf-yzw-19.md` | `subexponential-lpn` | as `ffr:node-granularity-3` | proposed there | `requires:…yzw-19:subexponential-lpn` |
| `subexponential-lpn-to-ot-yz16.md`, `subexponential-lpn-to-pke-yz16.md`, `subexponential-lpn-to-prc-cg24.md`, `lwe-to-zero-bit-prc-cg24.md` | `subexponential-lpn` | one variant for constant-noise LPN that is $2^{\omega(\sqrt n)}$-hard, if YZ16's and CG24's regimes agree (`needs_paper`), plus a folklore edge from the above-half variant | new | the 4 YZ16 and CG24 entries |
| `noise-level-to-tdh-amr25.md` | `lpn-low-noise` | as `ffr:node-granularity-11` | proposed there | `requires:…amr25:lpn-low-noise` |
| `lwe-to-leveled-fully-homomorphic-encryption-bgv12.md` | `lwe` | an LWE variant with modulus-to-noise ratio exponential in the depth, which Pei09 concludes (ask 9) | new | `requires:…bgv12:lwe` |
| `fe-to-io.md` | `functional-encryption` | a variant for single-key, sub-exponentially secure, weakly compact public-key FE, on `functional-encryption.md` | new | `requires:red-fe-to-io:functional-encryption` |
| `ddh-and-lpn-and-lwe-and-nc1-prg-to-io-jls21.md` | `sxdh`, `lwe`, `lpn`, `prg-in-nc0` | sub-exponential variants of each, with LPN over $\ZZ_p$. The shared prime $p$ stays in the Statement | new | 3 of the 4 entries; CCwiki keeps one for the shared prime |

Not asked: Wat09's IBE and HIBE need DBDH and DLIN in **one** group. No
node can say that, so CCwiki keeps its four entries.

**Ask 7. CS03's DEM** (`ccw:node-cs03-one-time-dem`, `node-granularity`).

- **Need.** The KEM + SKE ⇒ PKE Statement says "a one-time-secure SKE (the
  DEM)", but the hypothesis is the whole `ske` node. So KEM alone never
  gives PKE: the 15 pairs under CS03 in R11 are a record gap
  (derivations.md §2 R11).
- **Change.**
  - Add the heading "One-time security" on `symmetric-key-encryption.md`,
    with the variant `ske-one-time`.
  - `kem-and-ske-to-pke.md`: `hypotheses: [kem, ske-one-time]` (refinement;
    the id stays).
  - Two folklore pages: `{ske} ⇒ ske-one-time` and `{prg} ⇒ ske-one-time`
    (a pseudorandom pad; encrypt-then-MAC with a one-time MAC for the CCA
    notion).
- **Effect.** With ask 8's KEM ⇒ OWF, KEM derives PKE.

**Ask 8. Missing X ⇒ OWF edges** (`ccw:missing-edge-owf`, `missing-edge`,
`needs_paper` where noted).

- **Need.** A short list of the edges derivations.md §1 says are missing.
  Each is a folklore or textbook result that the wiki does not record.
- **Effect.** Each is measured by adding it alone, as an unstated,
  standard-model, folklore implication, and counting new default derived
  pairs (1,022 today). All 11 together add **432**.

  | Edge | Proposed source | New pairs |
  |---|---|---|
  | `{ot} ⇒ owf` | IL89 (`needs_paper`: which theorem) | 170 |
  | `{ske} ⇒ owf` | IL89 (`needs_paper`) | 104 |
  | `{com} ⇒ owf` | IL89 (`needs_paper`) | 90 |
  | `{crhf} ⇒ owf` | folklore, for a compressing family | 63 |
  | `{mac} ⇒ owf` | IL89 (`needs_paper`) | 59 |
  | `{prf} ⇒ owf` | folklore | 44 |
  | `{sis} ⇒ owf` | Ajt96 (`needs_paper`) | 32 |
  | `{dlog} ⇒ owf` | folklore: $x \mapsto g^x$ | 32 |
  | `{lpn} ⇒ owf` | folklore, or BFKL93 (`needs_paper`) | 31 |
  | `{kem} ⇒ owf` | `needs_paper`: IL89 does not treat KEMs; the verifiers find the source | 17 |
  | `{one-time-signature} ⇒ owf` | Rom90 (`needs_paper`) | 15 |

  The counts overlap; for example, SIS also reaches OWF through Ajt96's
  CRHF once CRHF ⇒ OWF exists.
- **Pages.** Eleven new reduction pages in `content/Reductions/`. The
  reference pages for IL89, Ajt96 and Rom90 exist; BFKL93's is listed
  ` (new)`.

**Ask 9. Pei09 and BLPRS13 as edges** (`ccw:missing-edge-lwe-classical`,
`missing-edge`, `needs_paper` for the regimes).

- **Need.** Both are cited in the Notes of `gapsvp-to-lwe-reg05.md` (lines
  32–33) and recorded as no edge.
- **Change.**
  - `{gapsvp} ⇒ <the LWE variant of ask 6 for large moduli>` (Pei09,
    classical, $q \ge 2^{n/2}$).
  - `{gapsvp} ⇒ lwe` (BLPRS13, classical, with the dimension loss in
    `security-loss`).
  - Both are `model: standard`.
- **Effect.**
  - GapSVP ⇒ PKE loses its quantum tag.
  - Through BGV12 re-pointed at the same variant, GapSVP ⇒ leveled FHE
    comes back. That is the one R13 refusal in derivations.md §6 that the
    literature resolves.

**Ask 10. BDOZ11's field size** (`ccw:verification-gap-bdoz11-field`,
`verification-gap`, `needs_paper: true`).

- **Need.** The Statement of
  `additively-homomorphic-encryption-to-mpc-with-preprocessing-bdoz11.md`
  does not say BDOZ11 needs a large plaintext field. So QR ⇒ MPC with
  preprocessing is still derived through GM's $\ZZ_2$ encryption
  (derivations.md §10). CCwiki does not add a condition the wiki does not
  state.
- **Change.** State the requirement in the Statement, cited. Then either
  re-point the hypothesis at a large-field variant, or let CCwiki add a
  `requires` entry that cites the new sentence.

### 4.3 What the asks would buy

- **Asks 1–7, with the wiki's own items, retire 35 of the 42 entries and
  add 1:**
  - 7 equivalences and 3 refuted entries;
  - 3 quarantine entries, through the wiki's own `fu2:` items;
  - 2 weakens entries;
  - 18 of the 23 requires entries (ISIS's through
    `ffr:verification-gap-8`);
  - 2 settings entries, through `ffr:schema-convention-14` (option A). The
    honest-majority variants then become conclusions of a new
    `secure-channels-model` node, so CCwiki adds one entry,
    `settings:secure-channels-model`, which keeps that node listed apart
    and out of completions as R14 treats settings today. Treating it as a
    model node instead would scope every result through it, which the
    record does not ask for.
- **What changes in the answers.** The re-pointing patches keep every pair,
  renamed to the variant, with one exception: MPC's backward list loses its
  two setting rows, because the honest-majority variants no longer imply
  MPC. Each variant instead lists `secure-channels-model` as its setting.
- **Asks 8 and 9 add answers:** 432 default pairs from the OWF edges, and
  classical lattice chains.
- **What remains** is 8 entries:
  - 5 requires entries: JLS21's shared prime and Wat09's four;
  - the 2 `statementLint` entries, which are CCwiki's own review notes and
    stay CCwiki's;
  - `settings:secure-channels-model`.

### 4.4 How CCwiki takes each change in

The fields are decoded additively, now, by Track A2, so CCwiki is ready
whenever the wiki regenerates `relations.json`. An absent field costs a
default, as everything in `RelationsManifest`'s DTO does.

| Ask | Decoding (`RelationsManifest.swift` and the Python `Manifest`) | Engine (both engines, same rule) | Entries then superseded | Detected by |
|---|---|---|---|---|
| 1 | `Relation.reverseClass: String?`, nil when absent | an equivalence with `reverseClass` present: forward takes `class`, reverse takes `reverseClass`, and the `equivalences` table is ignored for it. Absent: today's behaviour (an older manifest). R3 still makes a stub unstated both ways | `equivalences:<id>` | `curationSuperseded` (a warning, like `equivalencesReviewed`); DLO24's by `curationResolves` once its id retires |
| 2 | `RelationObject.refutedBy: [String]`, empty when absent | `Derivation.init` merges each object with a non-empty `refutedBy` into its working curation (`curation.adding(refutations:)`), so every rule that reads `curation.refuted` (R11 sources, completions, the forward-list banner, the inspector) applies it with no other edit. A manifest refutation is `Refutation(objectID:source:text:evidence:)` with `source` the entries' citation keys joined by ", ", `text` "Its page records the attack.", and `evidence` the entries. The manifest's wins over the file's | `refuted:<id>` | `curationSuperseded` |
| 3 | `Barrier.model: String`, `"standard"` when absent | R12 propagates only barriers whose `model` is `standard`. R8 and the invariants are unchanged and still check every barrier: a standard-model relativizing chain also contradicts a barrier proved relative to an oracle, and `chain_exists` already uses standard steps only. `ExplorerWriter.barrierMeta` and the inspector's barrier meta (`PageRelations`) add the model name when it is not standard; `ExplorerWriter.barrierRow` adds the note "This barrier is proved in the <model name>." | none | n/a |
| 4–7, 9 | none | none | the re-pointed edges' `requires:` and `weakens:` entries | `curationResolves` fails (the hypothesis is gone), or `curationEdgesUnchanged` fails (the conclusion changed under a kept id) |
| fu2 items | none | none | `quarantine:` | `curationEdgesUnchanged` |
| `ffr:schema-convention-14` | none | none | `settings:` | `curationSuperseded`: a setting object that is no longer the sole hypothesis of any eligible step |
| 8, 9 | none | none | none | golden drift: new derived pairs. The corpus test's drifted mode already handles this |

The verdict line for a manifest refutation then reads "The hypothesis is
known to be false (CD22), so this implication is vacuous. Its page records
the attack.", naming the key once.

**`curatedEdges`** is a new golden key, written and read by Track A2:

```json
"curatedEdges": {"red-ot-to-mpc-kil88": {"kind": "implication", "hypotheses": ["ot"], "conclusion": "mpc", "class": "fully-black-box", "model": "standard"}, …}
```

It covers every reduction id the curation names: each entry's edge, every
`metBy` and `acceptedBy` id, quarantine, equivalences and statementLint.

**The new sentinels and mutations.** Python `sentinels()` gains
`curationSuperseded`, so the golden `sentinels` object has the key, and
Swift `Sentinels.byName` has it too. Three mutation records are added,
making 10. `apply_patch`, and the Swift `GoldenPatch` that mirrors it, learn
`reductionPatches`, `[{"id", "set": {…}}]`, alongside `barrierPatches`. The
corpus test's guard on patched ids that the manifest lacks
(`GoldenPatch.barrierIDs` today) becomes `GoldenPatch.patchedIDs` and covers
both.

| Mutation | Patch | Query | Asserts |
|---|---|---|---|
| `barrier-model-not-propagated` | `barrierPatches: [{id: bar-owp-to-crhf-sim98, set: {model: rom}}]` | owf ⇒ crhf | no derived barrier from Sim98; the derived-barrier count drops by Sim98's 13; invariants hold |
| `reverse-class-field` | `reductionPatches: [{id: red-rabin-ot-to-ot, set: {reverseClass: "unstated"}}]` | ot ⇒ rabin-ot | chain class `unstated` (fully black-box today, through the curation); the entry is listed by `curationSuperseded` |
| `refuted-by-field` | added objects: `syn-r` with `refutedBy: ["[[X - Y\|X]]"]`; added reduction `red-syn-r-to-pke` | syn-r ⇒ pke | `vacuous: ["syn-r"]` |

**Tests for §4.**

| Behaviour | Test |
|---|---|
| The inbox JSON's shape, ids, kinds and cross-references | Python `--selftest-units` (A1), in `make check` |
| Decoding: absent fields give nil, `[]` and `"standard"`; present fields decode; a wrong type costs only that field | `RelationsTests` (A2) |
| Each engine rule on a fixture, without a clone: `reverseClass` wins over the curation; `refutedBy` makes an answer vacuous, keeps the object out of `implying(_:)`'s singles, gives the forward-list banner and puts the key once in the verdict line; a ROM barrier is not propagated, is still checked for conflicts, and gets its note | `DerivationTests` (A2), `ExplorerResultTests` cases written by A2 |
| The three mutations, `curationSuperseded` and `curatedEdges` | `DerivationCorpusTests` (A2) against the regenerated golden file |

## 5. Tracks: who owns which file

There is one small **Phase 0**, then four tracks.

### 5.1 Phase 0: the evidence API

One commit, landed first by the integrator. It compiles and changes no
behaviour.

| File | Change |
|---|---|
| `Sources/CCwiki/Wiki/DerivationCuration.swift` | `Citation`, `Entry`, `Entry.Key`, the stored `entries` and `entry(_:)` (§6.1); `reviewedCommit`; `adding(refutations:)`; decode `cites` on every raw entry, `notionMarkdown` on requires and weakens, `note` on equivalences, and `reviewedAgainst.wikiCommit`, all optional; `statementLint` through a `RawLint` that decodes either a bare string or `{note, cites}`, so `DerivationCuration.statementLint` stays `[String: String]` holding the note; `var notionMarkdown: String? = nil` on `Requirement` and `Weakening`, so the synthesized memberwise inits gain a defaulted parameter and `DerivationTests.swift`'s nine calls compile unchanged |
| `Tests/CCwikiTests/CurationEvidenceTests.swift` (new) | §2.6's first two rows. The citation check is all-or-nothing: if any bundled entry has a citation, every entry must have one. It passes on today's file and binds once A1 lands |

### 5.2 Track A1: the curation, the review document and the documents

- **Owns:**
  - `Resources/derivation-curation.json`
  - `plans/curation-review.md` (new, generated)
  - `plans/wiki-asks.md` (new), `plans/wiki-asks.inbox.json` (new)
  - `plans/derivations.md` (§1.1)
  - `Makefile`
  - `Tests/CCwikiTests/CurationReviewTests.swift` (new)
  - `Tests/CCwikiTests/Fixtures/quote-cases.json` (new: the shared
    matching cases)
- **Edits in `scripts/derivations_reference.py`** (A2 edits other
  functions): `locate_quote`, `check_quotes`, `curation_report` and their
  helpers (new); `selftest_units` (new, needs no manifest);
  `selftest_report` (new: the BM84 ablation and the non-zero ssddh and
  settings effects), called by one added line in `selftest`; `main`'s new
  flags `--check-quotes`, `--curation-report`, `--selftest-units`; the
  `UNMET_PRECONDITION` comment.
- **Regenerates** the golden file once, for the new `curationSHA256` only.
- **Builds:** `cites` and `notionMarkdown` for all 42 entries; the review
  document against `ab81f02`; the asks document and its JSON.
- **The Makefile:**

  ```make
  # Regenerate plans/curation-review.md (plans/relations-followups.md §2.3).
  # WIKI= is required: a clone whose relations.json is the golden file's.
  curation-review:
  	@[ "$(origin WIKI)" != "file" ] || { echo "✗ give WIKI=<a clone at the golden file's wikiCommit>"; exit 1; }
  	@[ -d "$(WIKI)/content" ] || { echo "✗ no wiki clone at $(WIKI)"; exit 1; }
  	@commit=$$(git -C "$(WIKI)" rev-parse HEAD) || { echo "✗ $(WIKI) is not a git clone"; exit 1; }; \
  	python3 -I scripts/derivations_reference.py "$(WIKI)/.reductions/relations.json" --selftest && \
  	python3 -I scripts/derivations_reference.py "$(WIKI)/.reductions/relations.json" \
  	  --curation-report plans/curation-review.md --wiki-root "$(WIKI)" --wiki-commit "$$commit"
  ```

  `check` gains `python3 -I scripts/derivations_reference.py
  --selftest-units` after `swift test`. `curation-review` joins `.PHONY` and
  `make help`. `--selftest` stays out of `test-corpus`: its checks are the
  review's findings on the reviewed commit, and CI's clone is the wiki's
  head, where the drifted-mode corpus test is the check.

### 5.3 Track A2: upstream fields, the Swift checks, and the golden file

- **Owns (new):** `Sources/CCwiki/Wiki/CurationQuote.swift`,
  `Tests/CCwikiTests/CurationQuoteTests.swift`.
- **Edits:**

| File | Where |
|---|---|
| `Wiki/RelationsManifest.swift` | `RelationObject.refutedBy`, `Relation.reverseClass`, `Barrier.model`; the matching `Raw*` DTO fields and `CodingKeys` |
| `Wiki/Derivation.swift` | `init(manifest:curation:)`: merge manifest refutations through `curation.adding(refutations:)` before anything reads it; `StepTable.init`'s equivalence branch (`reverseClass` precedence); `var unverifiedCitations: Set<DerivationCuration.Citation> = []` |
| `Wiki/DerivationBarriers.swift` | R12's barrier filter (`model == "standard"`) |
| `Wiki/DerivationChecks.swift` | `Sentinels.curationSuperseded` and `superseded`; `missingQuotes(pageText:)`; `CuratedEdge`, `changedCuratedEdges(since:)` |
| `Wiki/ExplorerWriter.swift` | `barrierMeta` (the model name); `barrierRow` (the model note) |
| `Wiki/PageRelations.swift` | the barrier row's meta: the model name |
| `App/AppModel.swift` | `loadLibrary`'s detached task: build the derivation, then set `unverifiedCitations` from `missingQuotes`, reading each cited page from `contentRoot` (about 30 small files). reader-comforts, which merges next, moves this body into `LoadedLibrary.build(cloneRoot:)` and carries the step with it (§12) |
| `Tests/CCwikiTests/RelationsTests.swift`, `DerivationTests.swift`, `DerivationCorpusTests.swift` | §4.4's rows; `curationQuotesFound` and `curationEdgesUnchanged` from the golden file's `curatedEdges`; `GoldenPatch.reductionPatches` and `patchedIDs` |
| `Tests/CCwikiTests/ExplorerResultTests.swift` | the manifest-refutation verdict line and the barrier note (one new test function each) |

- **Python** (`scripts/derivations_reference.py`): `Manifest` (the three
  fields), `Derivation.__init__` (merging `refutedBy` into its curation),
  `build_steps` (`reverseClass`), R12's barrier filter, `sentinels`,
  `golden` (`curatedEdges`), `apply_patch` (`reductionPatches`),
  `MUTATIONS`, and `selftest_upstream` (new), called by one added line in
  `selftest`.
- **Regenerates the golden file last**, after rebasing on A1.

### 5.4 Track B: copy a proof

- **Owns (new):**
  - `Sources/CCwiki/Wiki/ProofExport.swift` (`ProofExport`, `ProofFormat`)
  - `Sources/CCwiki/Wiki/ProofCitations.swift`
  - `Sources/CCwiki/Wiki/ProofWriters.swift` (`ProofNames`, `ProofLaTeX`,
    `ProofMarkdown`, `ProofBibTeX`, `ProofWriterContext`, `TeXText`,
    `MarkdownText`, `MacroTable.expanded`)
  - `Sources/CCwiki/App/AppModel+ProofExport.swift`
  - `Sources/CCwiki/UI/ProofCopyCommands.swift` (`ProofCopyAction`, its
    `FocusedValueKey`, and `ProofCopyCommandItems`)
  - `Tests/CCwikiTests/ProofExportTests.swift`
- **Edits:**

| File | Where |
|---|---|
| `Wiki/ExplorerResult.swift` | `ProofCopy` gains `let export: ProofExport`; `func proofCopy(selection:showingStronger:)` |
| `Wiki/ExplorerResult+Compute.swift` | the `ProofCopy(…)` in `derivedResult` (~152); `strongerProof` gains `refutations:` and builds its export from the stronger chain's own depth and class (~213–249); its call in `derivedResult` passes `answer.refutedStarts` |
| `Wiki/ExplorerResult+Lists.swift` | `factRow`'s `ProofCopy(…)` (~375), with the start's refutations from `writer.derivation.curation.refuted` |
| `Wiki/RelationMeta.swift` | `link(_:_:)`: `private` → internal |
| `UI/RelationsExplorerView.swift` | `rowMenu`: the "Copy Proof As" submenu, and "Copy BibTeX of Cited Works" when it has entries; `.focusedSceneValue(\.proofCopyAction, …)`, nil while suggestions show or with no answer |
| `UI/DerivedRelationsSections.swift` | the row context menu: the "Copy Proof As" submenu, last, after Copy Statement, through `model.copyDerivedProof(from:to:as:)`. reader-comforts later inserts Open in New Tab and Open in New Window after Open “…” (§12) |
| `App/CCwikiApp.swift` | in `CCwikiCommands`: `@FocusedValue(\.proofCopyAction)` and `CommandGroup(after: .pasteboard) { ProofCopyCommandItems(action: proofCopyAction) }` |
| `plans/relations-explorer.md` | §2.9's table: ⌥⌘C and ⌥⇧⌘C in results; §2.11's table of taken shortcuts: both, as "Copy Proof As (Edit menu)"; §2.6's context menu: the submenu |
| `plans/design-system.md` | §4's table: ⌥⌘C and ⌥⇧⌘C, "Copy proof as LaTeX / as wiki Markdown (Relations Explorer)" |

### 5.5 Track C: the wiki's text in the explorer, and the refusal wording

- **Owns (new):**
  - `Sources/CCwiki/Wiki/CurationTrace.swift`
  - `Sources/CCwiki/Wiki/ExplorerResult+Corrections.swift`
    (`correctionsSection`, `ExplorerWriter.curationEvidence`)
  - `Tests/CCwikiTests/CurationTraceTests.swift`
- **Edits:**

| File | Where |
|---|---|
| `Wiki/DerivationWording.swift` | `rules[5]`, `impliesHelp`, `impliedByHelp` (§1.2); new `refusedHelp`, `correctionsTitle`, `correctionsHelp`, `correctionHelp`, `unverifiedQuote(pageTitle:commit:)`, and one function per effect sentence (§2.5) |
| `Wiki/ExplorerResult.swift` | `Stronger` gains `var corrections: ExplorerSection? = nil`; `sections(showingStronger:)` removes the shortest proof's corrections section and appends the stronger proof's, when it has one; `ExplorerRow.Target` gains `case section(path: String, anchor: String)` |
| `Wiki/ExplorerResult+Compute.swift` | `derivedResult`: after the barrier context sections, append the shortest proof's section and set `result.stronger?.corrections` from the stronger proof's trace (after B's `strongerProof` call); `noPathResult`: append after `completionsSection`. Both before `initiallyCollapsed`. The refused section's `help:` reads `DerivationWording.refusedHelp`. `recordedOnPairRow`: a quarantined row gains the entry's notes and links. C does not touch `strongerProof` |
| `Wiki/ExplorerWriter.swift` | `refusalRow`: the entry's notes and links for `.requires`, `.weakened` and `.quarantined` |
| `Wiki/RelationLabels.swift` | `RelationText.symbols` gains `\ZZ` → `ℤ` |
| `UI/RelationsExplorerView.swift` | `follow`: `.section(path, anchor)` calls `model.openPage(path, anchor: anchor)` inside `showInReader` |
| `Tests/CCwikiTests/ExplorerResultTests.swift` | §1.2's and §2.6's rows |

### 5.6 Shared files and merge order

| File | Tracks | Hunks |
|---|---|---|
| `scripts/derivations_reference.py` | A1, A2 | A1: its new functions, `main`'s flags, one line in `selftest`. A2: the engine's functions, `golden`, `apply_patch`, `MUTATIONS`, one line in `selftest` |
| `Tests/CCwikiTests/Fixtures/derivations-golden.json` | A1, A2 | A1 regenerates for the curation SHA; A2 regenerates last |
| `Wiki/ExplorerResult.swift` | B, C | B: `ProofCopy` and `proofCopy(…)`. C: `Stronger.corrections`, `sections(showingStronger:)`, `Target.section` |
| `Wiki/ExplorerResult+Compute.swift` | B, C | B: the `ProofCopy(` lines and `strongerProof`. C: the tails of `derivedResult` and `noPathResult`, the refused section's `help:`, `recordedOnPairRow` |
| `UI/RelationsExplorerView.swift` | B, C | B: `rowMenu`, the focused value. C: one case in `follow` |
| `Wiki/ExplorerWriter.swift` | A2, C | A2: `barrierMeta`, `barrierRow`. C: `refusalRow` |
| `Tests/CCwikiTests/ExplorerResultTests.swift` | A2, C | each adds its own test functions |

**Merge order.**

1. Phase 0.
2. A1, B and C in parallel. C's tests use their own fixture curation, so
   they do not wait for A1's citations.
3. A2 after A1, rebased on it: A2's golden file is the final one, and it
   must carry A1's curation SHA. The two land in that order with nothing
   between them, so the corpus test's exact mode never sees A1's golden
   file without A2's sentinel and mutations. (A1's own golden file has
   neither, so A1 alone passes.)
4. B before C, to keep the `+Compute`, `ExplorerResult.swift` and
   `RelationsExplorerView.swift` hunks apart; C rebases on B.
5. **Across the batch, this feature merges to `main` first**, then
   reader-comforts, then corrections (§12).

**Every track:**

- runs `make check` after every change;
- writes no `PROGRESS.md`, `PLAN.md` or `CHANGELOG.md`. The integrator
  writes all three: an index entry for this file, `curation-review.md` and
  `wiki-asks.md`; the log; and a What's New paragraph in CHANGELOG.md's
  topmost unreleased section (0.2.0 today; §12) for the proof copies (Edit → Copy Proof As, ⌥⌘C and ⌥⇧⌘C) and for the
  wiki's text beside each correction;
- never writes to the wiki clone, pushes to `axhoover/cryptology.city`,
  copies the inbox file there, or opens issues or PRs there. Draft PRs go to
  the CCwiki repo only, and no one merges to `main`. The maintainer files
  the asks.

## 6. Interfaces, exactly

### 6.1 Curation evidence (Phase 0)

```swift
extension DerivationCuration {
    /// A passage of the wiki an entry rests on, verbatim.
    struct Citation: Hashable, Sendable {
        let page: String          // repository-relative: "content/Reductions/ot-to-mpc-kil88.md"
        let section: String?      // heading text without #s; nil = the whole file
        let quote: String         // the page source, verbatim
        /// "Reductions/ot-to-mpc-kil88.md": what `AppModel.openPage` and `.page(_)` take.
        var contentPath: String { get }
    }

    /// One entry of the file, in the order of §2.2.
    struct Entry: Hashable, Sendable, Identifiable {
        enum Key: Hashable, Sendable {
            case refuted(objectID: String)
            case setting(objectID: String)
            case quarantine(relationID: String)
            case equivalence(relationID: String)
            case requirement(relationID: String, isReverse: Bool, hypothesis: String)
            case statementLint(relationID: String)
            case weakening(relationID: String)
        }
        let key: Key
        /// "requires:red-dlog-to-prg-bm84:dlog"; see §2.2.
        let id: String
        /// The file's prose: evidence, reason or note.
        let evidence: String
        let cites: [Citation]
    }

    /// Every entry of the file, in §2.2's order. Built in `init`; a manifest
    /// refutation merged by `adding(refutations:)` is not an entry.
    let entries: [Entry]
    func entry(_ key: Entry.Key) -> Entry?
    /// `reviewedAgainst.wikiCommit`.
    let reviewedCommit: String?

    /// A copy whose `refuted` also holds these, replacing the file's for the
    /// same object. Everything else, `entries` included, is unchanged.
    func adding(refutations: [Refutation]) -> DerivationCuration
}

// DerivationCuration.Requirement and .Weakening each gain:
//     var notionMarkdown: String? = nil   // plain text and $…$ math only
// `DerivationCuration.init` gains `citations: [Entry.Key: [Citation]] = [:]`,
// `evidence: [Entry.Key: String] = [:]` and `reviewedCommit: String? = nil`,
// so tests can build a curation with citations without JSON. Its
// `quarantine: [String: String]` parameter is unchanged.
```

### 6.2 Checks (Track A2)

```swift
enum CurationQuote {
    /// Whether `quote` is in `section` of `page` under §2.2's rule: CRLF to
    /// LF, NFC, whitespace runs collapsed, compared as Unicode scalars.
    static func contains(_ quote: String, section: String?, in page: String) -> Bool
}

extension Derivation {
    struct MissingQuote: Hashable, Sendable {
        let entryID: String
        let citation: DerivationCuration.Citation
    }
    /// `pageText` takes a content-relative path (`Citation.contentPath`), as
    /// `statementLint(pageText:)` does. A page it cannot read counts as missing.
    func missingQuotes(pageText: (String) -> String?) -> [MissingQuote]

    /// Set on every library load from `missingQuotes`: by `AppModel.loadLibrary`
    /// today, by `LoadedLibrary.build` and `.update` after reader-comforts,
    /// also when `update` reuses the derivation. It depends on page text,
    /// not on the manifest. Read by Track C.
    var unverifiedCitations: Set<DerivationCuration.Citation>

    struct CuratedEdge: Hashable, Sendable {
        let kind: String
        let hypotheses: [String]
        let conclusion: String
        let reductionClass: String
        let model: String
    }
    struct ChangedEdge: Hashable, Sendable {
        let relationID: String
        let entryIDs: [String]
        let was: CuratedEdge
        let now: CuratedEdge?     // nil: the edge is gone
        /// Kind, hypotheses or conclusion changed, or class or model on an
        /// `equivalences` edge. Otherwise a warning.
        let fails: Bool
    }
    func changedCuratedEdges(since snapshot: [String: CuratedEdge]) -> [ChangedEdge]
}

// Sentinels gains:
//     var curationSuperseded = true     // a warning; in byName
//     var superseded: [String] = []     // entry ids
```

Python, mirrored: `locate_quote(text, quote, section) -> int | None` (the
line, for the report; A1), `check_quotes(cur, wiki_root) -> list` (A1),
`curation_report(dv, wiki_root, wiki_commit) -> str` (A1). The
`sentinels()` result gains `curationSuperseded` and `_detail.superseded`
(A2).

### 6.3 Proof export (Track B)

```swift
/// What a copy command puts on the pasteboard. `bibtex` is the cited works,
/// not the proof.
enum ProofFormat: String, CaseIterable, Sendable { case text, latex, wikiMarkdown, bibtex }

/// A proof in dependency order, with what the writers need (§3.2).
struct ProofExport: Sendable, Hashable {
    struct Step: Sendable, Hashable {
        let relationID: String
        let hypotheses: [String]         // the whole conjunction, in the edge's order
        let conclusion: String
        let isReverse: Bool
        let model: String                // effective (R3, R4)
        let reductionClass: String       // effective, per direction
        let isStub: Bool
        let source: [String]             // the relation's `source`, as recorded
        let assumed: [DerivationCuration.Requirement]
        /// Preconditions a producer met: the requirement and the producer's relation id.
        let established: [Established]
        let weakening: DerivationCuration.Weakening?
        struct Established: Sendable, Hashable {
            let requirement: DerivationCuration.Requirement
            let producer: String
        }
    }
    let start: [String]
    let target: String
    let steps: [Step]                    // post-order, each (relation, direction) once
    let relationCount: Int               // the N of "from N recorded reductions"
    let depth: Int
    let chainClass: Derivation.ChainClass
    let unstatedSteps: Int
    let models: [String]                 // its steps' non-standard models, sorted by Derivation.precedes
    let refutations: [DerivationCuration.Refutation]
    var isRecordedResult: Bool { depth == 1 }

    /// `depth` and `chainClass` are this proof's own: the fact's for the
    /// shortest proof, `StrongerChain.depth` and `.chainClass` for R6's.
    init(proof: Derivation.ProofTree, start: [String], target: String, depth: Int,
         chainClass: Derivation.ChainClass, unstatedSteps: Int,
         refutations: [DerivationCuration.Refutation], manifest: RelationsManifest)
}

enum ProofNames {
    /// §3.3's rule.
    static func name(_ objectID: String, manifest: RelationsManifest, labels: RelationLabels) -> String
}

struct ProofCitations: Sendable {
    struct Citation: Sendable, Hashable {
        let entry: String                // "[[GGM86 - …|GGM86]]" or "folklore"
        let key: String                  // "GGM86"; "folklore"
        let referencePath: String?       // "References/GGM86 - How to construct random functions.md"
        let cryptobibKey: String?
        let bibtex: String?              // verbatim
        var isFolklore: Bool { get }
        /// \cite key (§3.3); nil for folklore.
        var texKey: String? { get }
    }
    static let empty: ProofCitations
    init(index: WikiIndex?)
    func citations(_ source: [String], from relationPath: String) -> [Citation]
    /// A refutation's bare key: the `References/<key> - …` page.
    func citation(forKey key: String) -> Citation
}

struct ProofWriterContext: Sendable {
    let manifest: RelationsManifest
    let labels: RelationLabels
    let citations: ProofCitations
    let macros: MacroTable
    let revision: String?                // the clone's HEAD
    /// Some cited work has an inline entry: Copy BibTeX is offered.
    func hasInlineEntries(_ proof: ProofExport) -> Bool
}

enum ProofLaTeX { static func write(_ proof: ProofExport, context: ProofWriterContext) -> String }
enum ProofMarkdown { static func write(_ proof: ProofExport, context: ProofWriterContext) -> String }
enum ProofBibTeX { static func write(_ proof: ProofExport, context: ProofWriterContext) -> String? }
enum TeXText { static func escape(_ text: String, macros: MacroTable) -> String }
enum MarkdownText { static func escape(_ text: String) -> String }
extension MacroTable { func expanded(_ tex: String) -> String }

// ExplorerResult.swift
struct ProofCopy: Sendable, Hashable {        // existing fields kept
    let export: ProofExport
}
extension ExplorerResult {
    /// The selected rows' proof when every selected row with a proof has the
    /// same one. Otherwise the answer's: `stronger?.copy` when
    /// `showingStronger`, else `sections.first { $0.id == "proof" }?.rows.first?.proof`.
    /// nil for forward and backward lists with no proof row selected.
    func proofCopy(selection: Set<String>, showingStronger: Bool) -> ProofCopy?
}

// UI/ProofCopyCommands.swift
struct ProofCopyAction: Equatable {
    let id: UUID
    let copy: (ProofFormat) -> Void
    let hasInlineEntries: Bool
    static func == (a: Self, b: Self) -> Bool    // by id, as FindAction
}
extension FocusedValues { var proofCopyAction: ProofCopyAction? { get set } }  // the macOS 14 key form, as FindAction's

// App/AppModel+ProofExport.swift
extension AppModel {
    var proofWriterContext: ProofWriterContext { get }
    /// Text goes through `ProofCopy.text(revision:)`, as today.
    func copyProof(_ copy: ProofCopy, as format: ProofFormat)
    /// The inspector's rows: computes the answer with `.standard` options, then copies.
    func copyDerivedProof(from: [String], to: String, as format: ProofFormat)
}
```

### 6.4 Corrections (Track C)

```swift
struct CurationTrace: Sendable, Hashable {
    enum Effect: Sendable, Hashable {
        case assumed(relationID: String, isReverse: Bool, hypothesis: String)
        case establishedBy(relationID: String, isReverse: Bool, hypothesis: String, producer: String)
        case notUsedHere(relationID: String, isReverse: Bool, hypothesis: String, producer: String)
        case keptApart(relationID: String)
        case accepted(producer: String, consumer: String)
        case unstatedDirection(relationID: String, isReverse: Bool)
        case vacuous(objectID: String)
        case setting(objectID: String)
        /// The entry it belongs to (§2.5's table).
        var entryKey: DerivationCuration.Entry.Key { get }
    }
    struct Item: Sendable, Hashable, Identifiable {
        let entry: DerivationCuration.Entry
        let effects: [Effect]
        var id: String { entry.id }
    }
    let items: [Item]                    // curation order, each entry once
    var isEmpty: Bool { items.isEmpty }

    /// One proof's trace. `other` is the answer's other proof, if any: a
    /// refused step on it is not "not used here". Includes the starts' items.
    static func derived(_ proof: Derivation.ProofTree, other: Derivation.ProofTree?,
                        closure: Derivation.Closure, start: [String],
                        derivation: Derivation) -> CurationTrace
    /// A no-path answer's: vacuous and setting items only.
    static func starts(_ start: [String], derivation: Derivation) -> CurationTrace
    /// Wikilinks and markdown links to their text, then `PreviewExcerpt.plainText`.
    static func plainQuote(_ markdown: String) -> String
}

extension ExplorerResult {
    /// nil when the trace is empty. `idPrefix` keeps the stronger proof's
    /// row ids apart from the shortest's: "corrections", "stronger-corrections".
    static func correctionsSection(_ trace: CurationTrace, idPrefix: String,
                                   writer: ExplorerWriter) -> ExplorerSection?
}

extension ExplorerWriter {
    /// One entry's citation notes and links (§2.5's row anatomy), for a
    /// refused row, a recorded-on-pair row or a correction row.
    func curationEvidence(_ key: DerivationCuration.Entry.Key,
                          rowID: String) -> (notes: [String], links: [ExplorerRow.Link])
}
```

## 7. Tests and gates, by behaviour

| Behaviour | Proved by |
|---|---|
| R13 refuses; the UI says so and says "caveat" nowhere else | `ExplorerResultTests` (§1.2); the existing `DerivationTests` for R13 |
| The curation's citations decode, are complete and ordered; both `statementLint` forms decode | `CurationEvidenceTests` |
| Quote matching is the same rule in Python and Swift | `CurationQuoteTests` and `--selftest-units` on `quote-cases.json` |
| Every quote is on its page at the reviewed commit | `--check-quotes`, and `make curation-review` (A1, before merging) |
| Every quote is still on its page at the wiki's head | `DerivationCorpusTests` in CI; in the app, the "no longer on" note |
| The review document is current and complete | `CurationReviewTests` in `make check` |
| The review document renders on GitHub | `--selftest-units` (fences, escaping) |
| A curated edge changed under its id | `DerivationCorpusTests`, from `curatedEdges` |
| The wiki's text beside each correction | `CurationTraceTests`, `ExplorerResultTests` |
| Proof copies: order, formats, names, keys, escaping, honesty, selection | `ProofExportTests` |
| The asks are valid inbox items | `--selftest-units`; then the wiki's `round.mjs inbox` |
| Upstream fields decode and apply, identically in both engines | `RelationsTests`, `DerivationTests`, the three golden mutations in `DerivationCorpusTests`, and `--selftest` |

**The visual gate cannot see the explorer.** `ScreenshotRunner` has no
explorer step today (its steps are home, page, folder, switcher, search,
the inspector tabs, appearance, ingest, welcome, What's New, Settings and
Jobs). These must be checked by eye on a Mac:

- refused rows and the corrections section wrap their notes and do not
  truncate; a link opens the cited section, not the top of the page;
- the "Copy Proof As" submenu renders in both context menus; "Copy BibTeX
  of Cited Works" appears in the explorer's only for a proof that cites
  GMW87 or another inline entry;
- Edit → Copy Proof As shows ⌥⌘C and ⌥⇧⌘C, both fire, and the submenu is
  disabled with no answer and while the suggestions pane is showing;
- a copied LaTeX block compiles with pdfLaTeX in a document that loads
  `crypto.bib` (try RSA Φ-Hiding);
- a copied Markdown block, pasted into a wiki page, passes `npm run lint`.

## 8. Risks

- **Hand-copied quotes.** 42 entries need about 60 quotes copied verbatim.
  `--check-quotes` catches a typo before merge. It cannot catch a quote
  that is real but beside the point. The review document puts each quote
  next to the claim, which is the check.
- **Quote sentinels fail CI on wiki edits.** The review rounds rewrite
  Statements, so `curationQuotesFound` will fail CI from time to time. That
  is the intended signal (§10, decision 2). The fix is a re-review of the
  named entries, not a regenerated quote. Until a release ships the
  re-reviewed curation, the app says the quote is no longer on the page.
- **The report is slow**, at about 2.5 minutes. If the curation grows it
  slows linearly. It is not run in CI.
- **CCwiki's sentences could read as the wiki's errors.** The wording rules
  in §2.5 forbid that, and `ExplorerResultTests` checks the templates.
- **Copies leave CCwiki's labelling behind.** A pasted LaTeX block shows
  cited steps, and the "derived by CCwiki" line is a comment. That is
  correct for a paper, where the composition becomes the author's claim.
  Every step is still the wiki's recorded, cited result, and a vacuous
  implication says so in visible text.
- **Copy names are a heuristic.** §3.3's rule is checked for uniqueness on
  the corpus, not for taste: "HE Bootstrappable SHE" and "CRH Auxiliary-input
  one-wayness" are what it gives. A wiki `short-name` field would end this;
  it is not asked for yet (§10 item 7).
- **CryptoBib keys** depend on the wiki's `cryptobib_key` values being
  right. The wiki's own `sync-cryptobib` checks them.
- **Notions without `notionMarkdown`** fall back to the escaped ASCII
  paraphrase, `O(log\^{}(1+beta)(k)/k)`. Track A1 writes all 25, so this
  matters only for future entries.
- **Upstream field names may differ.** CCwiki decodes the names asked for.
  If the wiki picks others, the change is a rename in two decoders and a
  regenerated golden file.
- **Superseded detection is partial.** A re-pointed edge is caught through
  `curationResolves` and `curationEdgesUnchanged`, not by a field. A
  correction the wiki makes only in prose is still not caught. That
  remains derivations.md §10's risk, now narrower.

## 9. Deliberately not done

- **Regenerating the review document in CI.** CI cannot commit, and a
  generated file that CI rewrites is one nobody reviews. CI checks that it
  is current instead.
- **Synthesising BibTeX for CryptoBib keys**, or reading a `crypto.bib`
  that may be in a job worktree. Keys are listed (§3.4).
- **A caveat mode in the app**, by the maintainer's decision.
- **A corrections section for forward and backward lists, or in the
  inspector** (§2.5). **BibTeX in the inspector's menu** (§3.1).
- **Opening the wiki PR or inbox file from CCwiki.** The app's job pipeline
  only drafts ingestion PRs.
- **Typesetting the plain `notion` strings.** `notionMarkdown` covers the
  copies; the chrome keeps plain text.
- **`--selftest` in `make test-corpus`** (§5.2).
- **An explorer step in `make shots`.** It is worth adding, but it is a
  change to `ScreenshotRunner` and to `shots.sh`'s window capture, and
  beyond these four parts.

## 10. Decisions for the maintainer

Each has a recommendation; the spec is written to it.

1. **Show the wiki's text beside every correction in the explorer?**
   Recommended: yes, on the refused rows and in a last section, explorer
   only. The alternative is the review document alone, which leaves readers
   unable to check an answer.
2. **Should a cited quote that has left its page fail CI, or only warn?**
   Recommended: fail, like `curationResolves`. A warning nobody reads leaves
   a stale correction changing answers in the app.
3. **Regimes and notions: variant nodes, or a free-text per-hypothesis
   field?** Recommended: variants. They exist, the wiki's own review is
   moving that way (`ffr:node-granularity-3`, `-11`), and a free-text field
   could not express `metBy`, so CCwiki could not drop entries.
4. **Refutations: `ffr:schema-convention-10` option B, per formulation?**
   Recommended: yes, with no inheritance from a page to its variants.
5. **BibTeX for CryptoBib references: list the keys, or synthesise
   entries?** Recommended: list them, in the LaTeX header.
6. **⌥⌘C for LaTeX and ⌥⇧⌘C for wiki Markdown?** Recommended: yes. The
   alternative is no shortcuts, with the commands in the Edit menu only.
7. **Copy names: §3.3's rule, or the page title?** Recommended: the rule,
   as the wiki's house style and its reduction titles name things. It names
   OWF "OWF" only through the hyphenless-id clause; a wiki `short-name`
   field on variants would be cleaner if more such cases appear.
8. **DLO24: split into two implications rather than add a per-direction
   model?** Recommended: split. A `reverse-model` field would serve one
   page.
9. **Build the upstream decoding now, or after the wiki ships?**
   Recommended: now. It is small, tested on fixtures and pinned by golden
   mutations, and CCwiki is then ready the day `relations.json` changes. If
   the wiki adopts different names, it is a rename.
10. **Who files the asks?** Recommended: the maintainer copies
    `plans/wiki-asks.inbox.json` into the wiki's `.review/inbox/` on
    `main`, runs `round.mjs inbox` there, and opens one wiki PR for asks
    1–3.
11. **`secure-channels-model` as a setting or a model node?** Recommended:
    a setting (§4.3), if the wiki takes `ffr:schema-convention-14` option A.

## 11. Review notes

Three critics (architecture, macOS UX, safety and honesty) reviewed the
first draft. Every finding was checked against the code and the corpus.
All were adopted except as noted here.

| Finding | Disposition |
|---|---|
| Route every `curation.refuted` read through a new `isRefuted(_:)` and `refutation(of:)` (safety) | Rejected for the architecture critic's version: `Derivation.init` merges manifest refutations into the working curation, so the seven read sites, including `DerivationBackward.swift:73, :80` and `ExplorerResult+Lists.swift:101`, pick them up unedited, and Phase 0 no longer touches `Derivation.swift` |
| Producer emits `reverseClass ?? class` always (architecture) vs. lint requires the field (safety) | Both: the lint requires `reverse-class` on every equivalence and the producer always emits it, so presence means the page states it rather than a default standing in for it |
| Compute `hasInlineBibTeX` per inspector row (UX) vs. leave BibTeX out of the inspector (architecture) | The latter: simpler, and Show Proof is one click away. The explorer's context menu hides the item when empty, as the UX critic asked |
| List R8's three conflict sites for the barrier `model` (architecture) | Superseded: R8 and the invariants are no longer changed, only R12 (safety critic) |
| Run `--selftest` and `--check-quotes` in `test-corpus` (architecture) | Partly: the manifest-free checks run in `make check` as `--selftest-units`, and the shared `quote-cases.json` holds the two matchers to the same cases. `--selftest` asserts review findings on the reviewed commit and would fail on CI's head clone, so `make curation-review` runs it instead; `--check-quotes` there would repeat `curationQuotesFound` |
| Variant names: "<host> <title>" unless the title contains the host's name or alias (UX) | Adopted with two refinements found by running it: whole-word matching with a plural "s" and the host's title and head noun (substring matching kept "CPA Security" because SKE's alias "SE" is in "security", and prefixed "BLS signatures"); and hyphenless variant ids in capitals, which gives OWF, CRHF and SSDDH their usual names |
| No golden query starts at SSDDH, so the report would call `refuted:ssddh` ineffective (safety) | Partly wrong: golden query `ssddh-ke` exists and would have changed. The settings entries would indeed have read "no effect", so the vacuous and backward-list measures were added. The golden file's no-path records already include completions, so no separate completion measure was needed |
| Label effects found only on the stronger proof "in the stronger derivation" (safety) | Superseded by per-proof traces that swap with Show It (UX) |
| Python/Swift line-number parity for quotes (architecture) | Swift answers found or not found only; Python alone reports the line, for the document |
| A sentence for `refusedWeakened`, and `refused`/`quarantined` trace effects (architecture) | Superseded: refused steps carry their quotes on their own rows (UX), so the trace has no refusal effects and each refusal is stated once |
| Manifest refutation text "The wiki records an attack on <label>." (UX) | Adopted as "Its page records the attack.": `Derivation.init`, which builds it, has the manifest but no labels. The key still appears once in the verdict line |

## 12. Seams with the rest of the batch

[reader-comforts.md](reader-comforts.md) and [corrections.md](corrections.md)
are built beside this spec, from the same base. **They merge to `main` one at
a time: this spec first, then reader-comforts, then corrections.** This spec
is the smallest and the most self-contained. Of the files the other two
edit, it touches `AppModel.swift` (one step of the library load),
`CCwikiApp.swift` (one Edit-menu group and one `@FocusedValue`),
`RelationsExplorerView.swift`, `DerivedRelationsSections.swift`,
`RelationLabels.swift` and design-system §4's table. Landing it first leaves
the other two a few lines each to carry. §5.6's order still holds inside it.

Nothing here changes for the later two. This is what they do with it:

- **`unverifiedCitations`.** reader-comforts moves the load's detached body
  into `LoadedLibrary.build(cloneRoot:)` and carries this step with it.
  Its incremental `update` recomputes the set on every load, also when it
  reuses the derivation (reader-comforts §3.4): the set depends on page
  text, and a pull can edit a cited page without touching `relations.json`.
- **The inspector's derived rows.** reader-comforts inserts Open in New Tab
  and Open in New Window after Open “…”. Copy Proof As stays last. A
  ⌘-click on a derived row still shows the proof: reader-comforts leaves
  these rows out of its ⌘-click rule, because their click opens the
  explorer, not a page. The whole menu is in reader-comforts §10.
- **Copy Proof As with several reader windows.** Nothing in this spec reads
  the page being read. The explorer is one window however many readers are
  open, so its `ProofCopyAction` focused value works as written. The
  inspector's copies go through `model.copyDerivedProof`, which stays on
  `AppModel` with the library.
- **`RelationsExplorerView`.** `follow`'s new `.section` case calls
  `model.openPage(path, anchor:)`. reader-comforts keeps that call for
  windows that are not readers (its §1.8) and changes only the
  `openWindow` calls in `showInReader` and `openReaderIfAlone`.
- **`RelationLabels.swift`.** reader-comforts' D3 adds `Equatable` at the end
  of the file. This spec edits only `RelationText.symbols`.

**Keys.** ⌥⌘C and ⌥⇧⌘C stay free after the batch. reader-comforts adds ⌘N,
⌘T and ⌥⌘P; corrections adds ⌥⌘E, and ⌘↩ in an editor window only.

**For the lead: one word, two meanings.** The explorer's last section is
"Corrections CCwiki applied", and the code calls it `correctionsSection`,
`correctionsTitle` and `correctionHelp`. Corrections, merging two features
later, puts "Describe a Correction…" in the Wiki menu and correction jobs in
Jobs, meaning a change a reader proposes to a page. A reader who has used
one will look for the other in the explorer's section. Renaming this
section (to something like "What CCwiki reads from the pages", which is what
its help says) costs a string and a few identifiers before Track C is
built, and more afterwards. The spec is unchanged until the lead decides.

**The CHANGELOG.** "The topmost unreleased section" is 0.2.0 today. Whether
the batch ships in 0.2.0 or opens 0.3.0 is the lead's call (corrections §17).
