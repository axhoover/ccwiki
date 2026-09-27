# Relations

How CCwiki consumes `relations.json` — the wiki's relationship hypergraph.

Upstream spec: `docs/relations-json.md` in `axhoover/cryptology.city`. (The
canonical URL it names for itself, `https://cryptology.city/docs/relations-json`,
**404s** as of 2026-08-24; only the GitHub source resolves. That URL is also the
value of the manifest's own `schema` field.)

---

## 1. The one rule everything else follows from

**A reduction is a hyperedge: a set of hypotheses, conjoined, implying one
conclusion.**

```
{ A₁, …, Aₙ }  ⇒  B     of class C
```

`hypotheses` is a **conjunction, never a disjunction**. 42 of the corpus's 343
reductions have more than one. Flattening those into pairwise object-to-object
edges would render `{sparse-lpn, ddh} ⇒ she` as two independent implications —
a false mathematical claim that the wiki does not make.

So the reduction is its own node throughout: `object → reduction → object`.
Barriers attach to the reduction layer, never as an edge between two objects.

This is enforced in three places, not one:

| Where | How |
|---|---|
| `RelationsManifest` | No API returns a `(from, to)` pair. Every query returns whole `Relation` values. Nothing downstream can flatten what it never receives. |
| `PageRelations` | One row per relation, deduplicated by relation id within a group. |
| `RelationsTests` | Asserts across the whole corpus that row counts track *edges*, not endpoint pairs, and that no group ever repeats a row. |

Assumptions that are each *independently* sufficient are already separate
entries with one hypothesis each, so disjunction is never inferred. An entry with
three hypotheses genuinely needs all three.

## 2. Where the file comes from — the clone, not the network

CCwiki reads `.reductions/relations.json` from inside the clone. It never
fetches `https://cryptology.city/static/relations.json`.

Three reasons, in order of weight:

1. **Version skew becomes impossible.** The manifest is a pure function of
   `content/`, so the clone hands us the manifest and the pages it describes at
   the same commit. A separate fetch could return a manifest newer than the
   pages on disk, whose `page` paths point at files we do not have.
2. **Reading stays offline**, which is a non-negotiable (`PLAN.md` §3). A
   network fetch would make relationships the only part of the reader needing
   one.
3. **There is no refetch policy to get wrong.** `GitService.sync` does a full
   `git clone` — no `--depth`, no `--filter`, no sparse checkout — so the file
   is already on disk, and `AppModel.loadLibrary()` already runs after every
   pull. Never on a timer; reloaded on sync.

This is the same contract `MacroTable` has with `macros.ts`: a file at the clone
root that the repo's own tooling treats as an interface, read directly, never
throwing.

**The join is `page` → `WikiPage.path`.** The manifest's `page` is
repo-relative (`content/Primitives/x.md`); strip `content/` and it is the app's
own page identity. Object-kind nodes are 1:1 with pages.

> `graphSlug` is an undocumented field present on every node, holding the
> folder-qualified slug. It is *not* used: the stability contract says consumers
> must ignore unknown keys, and the documented `page` field is a better join
> anyway. The documented `slug` is only a basename and is not enough to address
> a page.

## 3. Degrading

`RelationsManifest.load` never throws. Every failure produces an empty manifest
plus a `Diagnostic`, which becomes one entry in the status bar's warnings menu
and a designed empty state in the pane.

| Failure | Result |
|---|---|
| File absent | Empty + "Sync to fetch it". **This is a clone that predates the reductions migration** — the common case, not an error. |
| Unreadable / malformed | Empty + diagnostic |
| `version != 1` | Empty + diagnostic naming the version. **No partial parse.** |
| Unknown keys | Ignored silently — required by the contract |
| Endpoint or consequence that does not resolve | That row dropped, everything else kept, counted in `anomalies` |
| Unknown `kind` on a reduction | Dropped — rendering it as an implication would assert something the wiki did not |
| `inclusion`/`equivalence` with >1 hypothesis | Dropped — a conjunction is not a containment claim |

A version bump is refused rather than parsed optimistically because the contract
says the number moves when *semantics* change. A half-understood manifest
renders a false claim, which is worse than rendering nothing.

There is one known anomaly upstream today: `bar-oihf-to-ot-bh26` names a
`reduction` consequence `ot-from-oihf-non-black-box`, which is a slug where an
id belongs. That consequence is dropped; the barrier survives.

## 4. `kind` — three claims, three renderings

Rendering all three as one arrow is wrong.

| kind | n | row | group heading |
|---|---|---|---|
| `implication` | 277 | `⇒` / `⇐` | Builds on / Produces |
| `inclusion` | 46 | `⊆` / `⊇` | Contained in / Contains |
| `equivalence` | 20 | `⇔` | Equivalent to — **one** group, on both endpoints |

An inclusion is containment (`IP ⊆ PSPACE`, *not* "IP implies PSPACE"). An
equivalence holds both ways, so it must never be split across a directional
pair. Both take exactly one hypothesis, which is asserted at decode.

## 5. The class partial order, and which way it points

`classes[X].implies` points from the **narrower** notion to the **broader** one:
every `fully-black-box` reduction is also a `relativizing` one. The closure is
computed from the file; it is never hardcoded.

**The rule:** a barrier ruling out class `B` contradicts a reduction of class `C`
on the same hyperedge **iff `C implies* B`**.

`classSentinels` (currently just `unstated`) sit outside the order and are
comparable to nothing, so the rule never fires on them.

Getting this backwards inverts every barrier in the corpus. The regression test
uses a real pair: `red-oihf-to-ot-bh26` is class `free`, `bar-oihf-to-ot-bh26` is
class `fully-black-box`, and they share a hyperedge. The correct answer is **no
conflict** — `free` implies nothing. Inverted, this pair reports a
contradiction, which is how you find out.

**Today, five hyperedges are shared by a reduction and a barrier and zero
conflicts fire.** So the conflict indicator is computed and tested but does not
currently appear anywhere. That is the honest state, not a bug.

## 6. Variants

131 of the 261 nodes are variants: a named sub-object living as a *section* of a
page, so the graph can name `ring-lwe` without splitting the LWE page.

- **Addressed** as its host's `page` plus `anchor` (with the `#` stripped), which
  goes straight into `AppModel.openPage(_:anchor:)`. Never a page of its own.
- **Never** given a sidebar row or a folder-listing row.
- **Named** by the host page's heading text: `Learning with errors § Evasive
  LWE`. This is necessary, not decorative — **every variant in the corpus has
  `title` equal to its own `id`** (`"abe-selective-security"`), so the manifest
  cannot name them. `WikiPage.headings()` already computes Quartz-identical
  heading ids, so the section's real heading is available. Falls back to the
  host title plus a humanized anchor when no clone is loaded.

48 pages host the 131 variants; 31 host more than one.

## 7. `unlisted`

30 objects, all `kind: object`. Real nodes — they appear as endpoints, in rows,
and in the closure — kept out of **browse and navigation only**: the sidebar
tree, folder listings, and the quick switcher. 28 of the 30 take part in an
edge, so they do show up in relation rows, which is correct.

They remain fully findable in ⌘S, which is search rather than browse.

This is an independent filter from `hidesStubs`; the two compose in
`AppModel.isBrowsable`.

## 8. Honest uncertainty is displayed honestly

The manifest's values for "we do not know" are deliberate, and the UI is built
not to launder them into confidence.

- **`class: "unstated"` (280 of 343)** — shown as itself, de-emphasized, with a
  tooltip saying the source does not say which notion of reduction is meant.
  Never "black-box", never guessed, never blank-as-if-missing.
- **`source: ["folklore"]` (188 reductions, 13 barriers)** — a provenance label
  in ordinary styling. It means the wiki has no attribution, never that none
  exists, and it is not an error.
- **`status: "stub"` (202 reductions + 16 barriers)** — shown with the same
  `StatusBadge` as everywhere else, and **its class and model are suppressed
  entirely** rather than printed. The spec is explicit that a stub's typing is
  not evidence, so showing `unstated · standard` under one would dress a default
  up as a finding. Stubs are *marked, not hidden* — `hidesStubs` deliberately
  does not apply here, because silently dropping 60% of the relationships is
  worse than showing them badged.
- **`propositions[].believed`** is upstream's soft lint flag. Not surfaced.

## 9. The pane

A third inspector tab, not an inline section. The wiki now generates a
`## Participates in` block **into the markdown itself**, which the reader already
renders — so an inline pane would duplicate it. The tab earns its place by
carrying what that block does not: kind, class, model, status and source.

**Rows show the end of the edge you are not on.** The group heading already
names your end and the direction, so repeating it in every row costs two of the
lines a row gets and pushes the differing part off the end. This was found by
`make shots`, not by a test — the model was correct and the layout was
unreadable, which is exactly what the visual gate is for
(`SWIFTUI-RULES.md` §9.3).

The conjunction survives that compression: any *other* hypothesis is named
underneath as "also needs …". On the DDH page, the real edge
`{ddh, sparse-lpn} ⇒ she` renders as

```
⇒ Homomorphic encryption § Somewhat homomorphic encryption (SHE)
also needs Learning parity with noise § Sparse Learning Parity with Noise
unstated · CHKV25
```

— one row, one claim, and visibly not `DDH ⇒ SHE` on its own. Both endpoints
here are variants, so both are named by their host page and section.

That same edge is also the clearest illustration of why disjunction is never
inferred: CHKV25 gives **three** entries — `{dcr, sparse-lpn}`,
`{ddh, sparse-lpn}` and `{linearly-homomorphic-pke, sparse-lpn}`, all concluding
SHE. Three independently sufficient partners, already split into three
conjunctions by the wiki. Nothing has to guess.

A conjunction in
the *primary* line (the "Produces" direction) gets four lines rather than two,
because truncating `DDH ∧ LPN ∧ LWE ∧ PRG in NC¹` mid-list would leave a claim
about fewer assumptions than the theorem needs.

On a reduction or barrier page the page itself *is* the edge, so the pane shows
its hypotheses — under a heading that says "Hypotheses — all of them" when there
is more than one — its conclusion, and any barrier on the same hyperedge.

## 10. What this did not change

`WikiIndex.backlinkMap()` is untouched and still backs the Backlinks tab and the
sidebar's "Cited by" section. The manifest does **not** subsume it: backlinks
span References, Glossary, Folklore and notes, which the manifest's own caveats
say were deliberately left out. Relations sit *beside* backlinks, never instead
of them.

Worth knowing: the migration rewrote the host pages' `# Other results` bullets
to point at reduction pages rather than at the endpoint pages, so the backlink
graph changed shape underneath. `fuzzy-identity-based-encryption` lost its
backlink from `attribute-based-encryption` and gained one from
`Reductions/abe-to-fuzzy-ibe`. Corpus link count went from 673 to 3,277.

## 11. Files

```
Sources/CCwiki/Wiki/
├── RelationsManifest.swift   decode, index, the class closure, the barrier rule
├── RelationLabels.swift      display names; TeX → plain text for chrome
└── PageRelations.swift       path → ordered groups of rows (pure, testable)
Sources/CCwiki/UI/
└── RelationsView.swift       the inspector tab
Tests/CCwikiTests/
└── RelationsTests.swift      33 tests; corpus checks gated on CCWIKI_WIKI
```

`RelationText.plain` exists because manifest titles are wiki source carrying
`$…$` math written with the site's KaTeX macros, and a SwiftUI `Text` has
neither KaTeX nor the macro table. The vocabulary is small and closed — 20
commands across all 674 titles — so the substitution is exact rather than a
guess; anything outside it loses its backslash and keeps its letters.
