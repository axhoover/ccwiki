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

`hypotheses` is a **conjunction, never a disjunction**. 29 of the corpus's 283
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
| `circumventedBy` id that does not resolve | That id dropped, the barrier kept, counted in `anomalies` |
| Unknown `kind` on a reduction | Dropped — rendering it as an implication would assert something the wiki did not |
| `inclusion`/`equivalence` with >1 hypothesis | Dropped — a conjunction is not a containment claim |
| `rationale` entry that is not a string | That entry dropped; a `rationale` that is not an object at all becomes an empty table |

A version bump is refused rather than parsed optimistically because the contract
says the number moves when *semantics* change. A half-understood manifest
renders a false claim, which is worse than rendering nothing.

The final-form manifest decodes with **zero anomalies**. The one there used to
be (`bar-oihf-to-ot-bh26` naming a `reduction` consequence by slug where an id
belongs) was fixed upstream; no `reduction` or `object` consequences remain.

## 3a. Fields the final-form manifest added

The wiki's final-form commit kept `version: 1` and changed no field's type, so
every addition is additive and the decoder reads each one with a default.

| Field | On | n | What the app does |
|---|---|---|---|
| `heuristic` | reductions | 2 true | **Never shown as a theorem.** The row says "heuristic candidate", draws a dashed `⇢`/`⇠`, and its tooltip leads with "Candidate construction: the source gives no security reduction." The contract says to skip these edges when deriving anything; the app derives nothing yet. |
| `circumventedBy` | barriers | 2 non-empty | Shown wherever the barrier appears: "circumvented by BH26" in its row on an object page, a **Circumvented by** group on the barrier's page, a **Circumvents** group on the reduction's page. The circumventing reduction need not share the barrier's hyperedge (BAR01 gets around a barrier about {zkp} from {crhf}), so these are lookups by id. |
| `rationale` | both | 198 reductions, 32 barriers | Short sentences keyed by field (`class`, `model`, `heuristic`, `strength`). The page body does not repeat them, so the inspector shows each as the tooltip of the value it justifies, and in row tooltips as "Why fully black-box: …". The site does not show them at all. |
| class `fixed-construction` | classes | 9 barriers | Read from `classes` like any class. It implies only `free`, so such a barrier bites no RTV04-classed reduction. |

`graphSlug` is still ignored (see §2), and `formal` is documented upstream but
appears nowhere.

## 4. `kind` — three claims, three renderings

Rendering all three as one arrow is wrong.

| kind | n | row | group heading |
|---|---|---|---|
| `implication` | 230 | `⇒` / `⇐` (`⇢` / `⇠` if heuristic) | Builds on / Produces |
| `inclusion` | 45 | `⊆` / `⊇` | Contained in / Contains |
| `equivalence` | 8 | `⇔` | Equivalent to — **one** group, on both endpoints |

An inclusion is containment (`IP ⊆ PSPACE`, *not* "IP implies PSPACE"). An
equivalence holds both ways, so it must never be split across a directional
pair. Both take exactly one hypothesis, which is asserted at decode.

**Containments between complexity classes carry no class.** The wiki records
them as class `free`, and its schema says neither the class axis nor the
standard/idealised model axis applies. The site omits both from its line
(`relationMeta.ts`, `isComplexityContainment`), and so does the app:
`RelationsManifest.isComplexityContainment` is the same test (not an
implication, class `free`, a complexity class concluded). 46 edges qualify. A
non-standard model, `quantum setting` on 11 of them, is still shown.

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

**Today, one hyperedge is shared by a reduction and a barrier — that very
BH26 pair — and zero conflicts fire.** So the conflict indicator is computed
and tested but does not currently appear anywhere. That is the honest state,
not a bug. The barrier also lists the reduction in `circumventedBy`, so the
reduction's page files it under "Circumvents" rather than "Barriers on this
hyperedge".

## 6. Variants

131 of the 262 nodes are variants: a named sub-object living as a *section* of a
page, so the graph can name `ring-lwe` without splitting the LWE page.

- **Addressed** as its host's `page` plus `anchor` (with the `#` stripped), which
  goes straight into `AppModel.openPage(_:anchor:)`. Never a page of its own.
- **Never** given a sidebar row or a folder-listing row.
- **Named** `Host § Section`, always: `Hash function § Collision resistance`.
  The section text is the manifest's own `title`, which in the final-form
  manifest is the heading text with any math kept as TeX. The heading alone is
  not a name — both encryption pages have a "CPA Security" section, others
  have "Types" or "Binding", and `owf`, the commonest endpoint in the corpus,
  is the hash function page's "Preimage resistance (one-wayness)". With the
  host, all 262 labels are unique, which the corpus test asserts.
- **Older clones** have `title` equal to `id` on every variant
  (`"abe-selective-security"`). For those the section is the host page's
  heading, read through `WikiPage.headings()`, which computes Quartz-identical
  heading ids; with no clone loaded it is the anchor, humanized.

52 pages host the 131 variants; 35 host more than one.

A literal `$` stands for itself in a title (`IND$-CPA Security`), as the
manifest's contract says. `RelationText.plain` treats `$` as a delimiter only
when a later run of the same length closes it, which is micromark's rule and
the site's `escapeOutsideMath`; it used to delete every `$`, which named
IND-CPA, a different notion, and made one barrier read as a false separation.
For any string without an unpaired `$` the output is unchanged, which matters
because `ConceptRanker` names headings with the same function.

## 7. `unlisted`

32 nodes: 30 objects and 2 variants (`prg-in-nc0` and
`schnorr-identification-protocol`). Real nodes — they appear as endpoints, in rows, and in the closure —
kept out of **browse and navigation only**: the sidebar tree, folder listings,
and the quick switcher. 24 of the 32 take part in an edge, so they do show up
in relation rows, which is correct.

**Only an object hides a page.** A variant shares its host's `path`, so an
unlisted variant counting would hide a listed host and every other section on
it. Both unlisted variants sit on unlisted hosts today, so this was latent;
`unlistedPaths` now filters on `kind: object`, and a fixture pins it.

They remain fully findable in ⌘S, which is search rather than browse.

This is an independent filter from `hidesStubs`; the two compose in
`AppModel.isBrowsable`.

## 8. Honest uncertainty is displayed honestly

The manifest's values for "we do not know" are deliberate, and the UI is built
not to launder them into confidence.

- **`class: "unstated"` (76 of 283)** — shown as itself, de-emphasized, with a
  tooltip saying the source does not say which notion of reduction is meant.
  Never "black-box", never guessed, never blank-as-if-missing. The site omits
  it from its line; the inspector's summary shows it, because there it answers
  a question the summary visibly asks, and it links to the glossary's
  "Unstated" section. `fully-black-box` is now the plurality (132), and where
  the source does not state it, `rationale.class` says why.
- **`source: ["folklore"]` (86 reductions, 4 barriers)** — a provenance label
  in ordinary styling. It means the wiki has no attribution, never that none
  exists, and it is not an error.
- **`status: "stub"` (1 reduction, no barriers)** — shown with the same
  `StatusBadge` as everywhere else, and **its class and model are suppressed
  entirely** rather than printed. The spec is explicit that a stub's typing is
  not evidence, so showing `unstated · standard` under one would dress a default
  up as a finding. Stubs are *marked, not hidden* — `hidesStubs` deliberately
  does not apply here. (At the migration 202 of 343 reductions were stubs; the
  rule matters far less now, and costs nothing.)
- **`heuristic: true` (2)** — a candidate construction, never a theorem; see
  §3a.
- **`propositions[].believed`** is upstream's soft lint flag. The barrier
  summary shows it beside a complexity consequence ("coNP ⊆ AM · believed
  false"), as context for what the barrier's conclusion would cost. It never
  changes a row or a rule.

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
is more than one — its conclusion, any barrier on the same hyperedge, and from
`circumventedBy` what the page circumvents or is circumvented by (§3a).

**It leads with the page's own record, under "This result".** The final-form
wiki moved kind, class, model, sources and security loss out of the page body
into a line the site splices under the H1 at build time (`relationMeta.ts`), so
before this the app showed none of them for the page being read. The summary
is a label–value grid in the manner of a Get Info panel, built purely in
`PageRelations.facts(for:manifest:)`:

| Reduction | Barrier |
|---|---|
| Kind, with its arrow | Strength |
| Proof: "Heuristic candidate", only if heuristic | Against: "Fully black-box reductions" |
| Class (not on a stub or a containment) | Assuming: each `conditionalOn`, an object or free text |
| Model, named as the site names it (not on a stub; not "standard" on a containment) | Would imply: each consequence, with "believed true/false" for a proposition |
| Via, Sources, Security loss | Sources |

Each value's tooltip is the record's `rationale` for it when there is one,
else its full text. A value that leads somewhere the clone has is a link: the
class to its section of `Glossary/reduction-classes`, an idealised model to its
glossary page, a source to its reference page, an assumption to its object, a
proposition to its page. Security loss goes through `RelationText.plain`,
whose table now covers the losses' macros (`\Adv`, `\calX`, `\ell`, `\mapsto`,
`\bmod`); the rendered page will carry the same loss as real KaTeX once the
site's meta line is reproduced in the reader.

Model names follow the site everywhere, rows included: "random oracle model",
"CRS model", "generic group model", "quantum setting", and "non-standard model"
for `other`.

**Row hygiene.** Every relation, barrier and object row has a context menu —
Open, Open on cryptology.city, Copy Link, Copy Wikilink, and Copy Statement (or
Copy Name) — wired to the same calls as the sidebar and Backlinks, and rows
hide the list separator as Outline and Backlinks do.

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
├── RelationsManifest.swift   decode, index, the class closure, the barrier rule,
│                             circumvention, complexity containments
├── RelationLabels.swift      display names; TeX → plain text for chrome; the
│                             site's model names and citation keys
└── PageRelations.swift       path → ordered groups of rows, and the summary's
                              facts (pure, testable)
Sources/CCwiki/UI/
└── RelationsView.swift       the inspector tab
Tests/CCwikiTests/
└── RelationsTests.swift      44 tests; corpus checks gated on CCWIKI_WIKI
```

`RelationText.plain` exists because manifest titles are wiki source carrying
`$…$` math written with the site's KaTeX macros, and a SwiftUI `Text` has
neither KaTeX nor the macro table. The vocabulary is small and closed — 20
commands across the manifest's 610 titles, plus a handful more in the 75
security losses — so the substitution is exact rather than a guess; anything
outside it loses its backslash and keeps its letters.
