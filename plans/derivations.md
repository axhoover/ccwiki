# Derivations

What CCwiki may conclude by chaining the wiki's recorded reductions, and how it
says so.

**Status: specified 2026-10-10 on `claude/relations-explorer`, revised the
same day after a two-reviewer red team (§11).** The engine is specified here
and implemented in Python as `scripts/derivations_reference.py`, run on the
real manifest (wiki `ab81f02`, `relations.json` v1: 262 objects, 283
reductions, 32 barriers). It reads one more input, CCwiki's reviewed
corrections in `Resources/derivation-curation.json` (§2a).
`Tests/CCwikiTests/Fixtures/derivations-golden.json` records its answers. The
Swift port is `Sources/CCwiki/Wiki/Derivation*.swift` with
`DerivationCuration.swift` (§3); it must give the same answers on the same
manifest and curation, and the corpus test (§8, `DerivationCorpusTests`)
checks this. `DerivationTests` covers each rule on fixtures whose expected
values were computed with the reference script. Read [relations.md](relations.md) first; this assumes its
hyperedge rule (§1 there) and its class order (§5 there). The UI half is
[relations-explorer.md](relations-explorer.md); §11 lists what it must pick
up from this revision. Revised 2026-10-12: the maintainer decided that R13
refuses unmet preconditions (§0 item 4);
[relations-followups.md](relations-followups.md) adds citations to every
curation entry and three drift checks (§2a, §8).

---

## 0. What the maintainer decided

1. **CCwiki shows derived relations.** Each one is labelled *derived by CCwiki
   from N recorded reductions* and shown as a proof tree whose every step
   links to its reduction page. CCwiki never claims a separation because no
   path exists. Recorded barriers are shown. Barriers CCwiki derives are
   shown too, labelled as derived, and only if the rule that produces them is
   sound (§2, R12).
2. **Default model filter**: standard, quantum and CRS models are on. The
   idealised models (`rom`, `generic-group`, `algebraic-group`) and `other`
   are off. A toggle turns them on, and anything that relies on one is
   tagged.
3. **Three features** use this engine: a *Does A imply B?* explorer window;
   transitive *everything this implies* and *everything implying this*
   sections in the Relations inspector, visibly marked as derived; and link
   previews on hover. The previews show recorded data only and never a
   derived claim.
4. **Unmet preconditions are refused, never caveated** (R13). A step whose
   Statement needs more of a hypothesis than the manifest records fires only
   when that hypothesis is given (it is one of the question's starts), and
   the claim then says "assuming …", or when a `metBy` producer establishes
   it. Otherwise the step is refused and named. This holds in the explorer
   and the inspector alike. CCwiki shows no derived claim with a
   "precondition not established" caveat. (Decided 2026-10-12; this was open
   question 4.)

The wiki's own `--derive` mode is plain Horn closure, and it **ignores
`model`** (`docs/relations-json.md` § Closure). CCwiki is deliberately
stricter. On this manifest, plain closure produces these false or unproved
claims, and each one led to a rule below:

| Plain closure says | Why it is wrong | Rule |
|---|---|---|
| ROM ⇒ OIHF ⇒ OT ⇒ MPC | BH26's OIHF ⇒ OT is non-black-box, so it does not carry over into the random-oracle world; the wiki says so (`content/Reductions/rom-to-oihf-bh26.md:27`, `oihf-to-ot-bh26.md:23`) | R5 |
| CDH ≡ DLOG | DLOG ⇒ CDH is FKL18's theorem in the **algebraic group model** (`red-dlog-to-cdh-fkl18`) | R4 |
| FAC ⇒ RSA ⇒ TDP ⇒ PKE | FAC ⇒ RSA is the reverse of DLO24's equivalence, proved only against **generic ring** algorithms (`model: other`, `red-rsa-to-fac-dlo24`) | R4, R5 |
| DLOG ⇒ BQP | `dlog ⊆ bqp` is Shor's *attack*, an inclusion of a problem in a class, not an implication | R1, R2 |
| {SXDH, LWE, LSN, NC⁰-PRG} ⇒ iO | JLS21 needs sub-exponential LPN **over Z_p** with polynomially many samples; CIMR25's LSN ⇒ LPN gives binary LPN with k(1+Ω(η)) samples | R13 |
| GapSVP ⇒ LWE ⇒ leveled FHE | BGV12 needs a modulus-to-noise ratio exponential in the depth; Reg05 gives a prime poly(n) modulus | R13 |
| ETDP ⇒ OT ⇒ MPC | EGL's OT is semi-honest (as is the OT page's definition); Kil88 needs OT secure against malicious parties | R13 |
| BDH ⇒ ABE ⇒ IBE | GPSW06 gives selectively secure KP-ABE; ABE ⇒ IBE turns adaptive ABE into adaptive IBE | R13 |
| BDH ⇒ HVE | BW07's Statement needs composite-order groups and three assumptions; the record has one prime-order hypothesis | R13 |
| Circular evasive LWE ⇒ PKE | The hypothesis is false (AMYY25), so the implication is vacuous | R14 |

---

## 1. What a derived relation is, and what it is not

A **derivation** of `B` from a set `S` is a proof tree. Its leaves are
members of `S`. Each internal node is one recorded reduction that fires once
**all** its hypotheses are derived. This is Horn-clause forward chaining, and
it is the only way the conjunction survives: `{kem, ske} ⇒ pke` fires only
when both are present, never on either alone. Nothing in the engine ever
handles an object-to-object pair (relations.md §1).

A derived relation is a **claim CCwiki makes**, not one the wiki makes. Its
strength is the strength of its weakest step, and the engine records that
strength explicitly: the step classes (R6), the models used (R4), and any
notion it had to assume of a start (R13).

**A derivation is only as precise as the record's nodes.** A node is a page
or a page section. A theorem often needs more of its hypothesis than the
node defines (a hardness regime, a field, a group, a security level) or
proves less of its conclusion than the node defines (selective rather than
adaptive security). The manifest records neither, so chaining across such a
gap proves things the cited theorems do not. CCwiki corrects the gaps the
review found, from the wiki's own Statements, in a curation file (§2a, R13).
**Gaps nobody has reviewed remain**, and §10 says how large that risk is.

**No derivation is never a separation.** The manifest is incomplete in ways
that matter: OT, PRF, SKE, MAC, COM, CRHF, OTS, KEM, SIS, LPN and CDH do not
derive OWF in it, DLOG does only through BM84 (assuming Z_p^\*), KEM does
not derive PKE (CS03 asks for an SKE), and LWE ⇒ ABE (GVW13) is absent. The only statements that something *cannot* be
derived are recorded barriers, and derived barriers under R12, which come
from them.

---

## 2. The rules

Each rule is a named constant or function in `scripts/derivations_reference.py`,
cited as R1–R14 in its comments.

### R1. Eligible edges

| Edge | Treatment | n |
|---|---|---|
| `implication` | eligible, `hypotheses ⇒ conclusion` | 230 |
| `equivalence` | eligible in **both directions**, each with its own class (below); the backward use is marked `reverse` and named in the tree ("⇔, used right to left") | 8 |
| `inclusion` | **excluded**: containment, not implication (`IP ⊆ PSPACE`) | 45 |
| `heuristic: true` | **excluded**: "an edge of the graph, not a theorem" (`docs/relations-json.md` § Caveats) | 2 |

**An equivalence's directions are classed separately.** The record has one
`class`, but its two directions can be different theorems. ISIS ⇔ SIS is the
case in the default filter: its own Statement says SIS ⇒ ISIS is immediate
and ISIS ⇒ SIS "holds only under conditions on the column count and norm
bound". So a direction takes the record's class only where the curation's
`equivalences` table (§2a) says `record`. A direction marked `unstated`, and
both directions of an equivalence the table does not list, are `unstated`.
The record's `model` applies to both directions. That can only under-claim:
DLO24's trivial RSA ⇒ FAC carries `other` and is off by default. Today all 7
eligible equivalences are reviewed, and one direction is scoped: ISIS ⇒ SIS,
which is also given an R13 precondition.

Of the 8 equivalences, 7 are eligible; R2 removes `qip ⇔ pspace`. After
R1–R3 and R13's quarantine there are **236 directed steps** (7 reverse), and
the default filter (R4) leaves 201.

### R2. Complexity classes take no part

Any edge with a `complexity-class` endpoint is excluded. A class may not be
the start or the target of a query, which instead returns *unsupported*: "BQP
is a complexity class; classes are related by containment, not derived".

There are three reasons:

- **Their containments are not implications.** All 45 inclusions have a
  complexity-class endpoint. Five of them put an assumption in a class
  (`dlog ⊆ bqp`, `dlog ⊆ np`, `dlog ⊆ conp`, `dlog ⊆ tfnp`, `fac ⊆ tfnp`). Each
  of those is an attack or a membership fact, and none says DLOG implies
  anything.
- **The mixed implications conclude a statement about a class, not the
  existence of a primitive.** Four edges remain after R1:
  `{owf, ip} ⇒ czk` (BGG90), `owf ⇒ czk`, `{owf, io} ⇒ ppad-hardness`, and
  `qip ⇔ pspace`. These belong with the class lattice (roadmap idea 7), as
  conditional facts on its nodes.
- **Barriers on classes are non-containments.** Nine of the 32 barriers have
  a complexity-class endpoint (six are between two classes), and R12 must not
  mix them with primitives.

### R3. Stubs

`status: stub` means "do not treat a stub's `class` or `model` as evidence".
One reduction is a stub today: `red-noise-level-to-depir-cimr25-2`,
High-noise LPN ⇒ SK-DEPIR. A stub step is eligible **only with the toggle
on**. Its model is taken as `unknown`, which R5 treats as idealised, and its
class as `unstated`. Anything that relies on it is tagged *stub*. A stub
**barrier** is listed with its record, tagged *stub*, and never propagated
(R12) or used to flag a conflict (R8).

### R4. Models

| Set | Models | By default |
|---|---|---|
| Default | `standard`, `quantum`, `crs` | on |
| Idealised | `rom`, `generic-group`, `algebraic-group`, `other`, and `unknown` (stubs) | off; on with the toggle |

Every derived fact carries the **set of non-standard models** its derivation
uses (`quantum`, `crs`, and the idealised ones). The UI shows these as tags.
`quantum` is on by default because Reg05's GapSVP ⇒ LWE is quantum, and
readers expect lattice assumptions to reach PKE. Such a chain is tagged
*uses a quantum reduction*.

**Model nodes.** `rom`, `ggm` and `agm` are the model pages (`MODEL_PAGES` in
the wiki's `scripts/participates-in.mjs`). They and their variants are model
nodes: `shoup-generic-group-model`, `maurer-generic-group-model` and
`structured-generic-group-model`. `{rom} ⇒ X` reads "X holds in the
random-oracle model" (`schema/README.md` § Which model to record).
Therefore:

- An edge whose sole hypothesis is a model node is in that node's model,
  **whatever its `model` field says**. Today all 8 such edges already agree
  with their record. The rule guards against a future mis-typed one leaking
  into default results.
- A model node is never a conclusion. An edge concluding one would be
  excluded; none exists.
- A model node is never offered as a completion (R10).
- With the toggle off, a model node given as a start derives nothing, and the
  answer says why: "The random oracle model is a model, not an assumption.
  What the wiki proves in it appears with idealised models included."

**Clean facts first.** The closure runs in up to three phases, and a later
phase never replaces a fact an earlier one found:

1. **Clean**: the default steps; no precondition is assumed (R13).
2. **Assumed**: the default steps again; a precondition on a *given* start
   may now be assumed, and the fact carries the assumption as a tag.
3. **Idealised** (toggle only): every eligible step; the facts it adds are
   model-scoped.

So turning the toggle on only *adds* facts, and a fact with a derivation that
needs no assumption and no idealised model shows that derivation.

### R5. Composition after an idealised step

A fact is **model-scoped** if its derivation uses a step in an idealised
model (or a stub step). A step may fire on hypotheses that include a
model-scoped fact **only if its class implies\* `relativizing`**. Under the
current order only `fully-black-box` and `relativizing` do. A step of any
other class is refused there: `free`, `unstated`, `semi-black-box`,
`weakly-black-box`, the ∀∃ classes, and `fixed-construction`. A refused step
is reported in the answer as an explanation, never as a fact.

*Why relativizing.* A relativizing reduction holds relative to every oracle Π
(RTV04; `reduction-classes.yaml`): if the hypotheses exist relative to Π, so
does the conclusion. "X holds in the random-oracle model" means X exists
relative to a random oracle, so a relativizing step carries X into Y relative
to the same oracle. A non-relativizing step need not. BH26 is the
counterexample in the data: a random oracle gives an OIHF
(`red-rom-to-oihf-bh26`), OIHF ⇒ OT holds by a non-black-box argument
(`red-oihf-to-ot-bh26`, class `free`), yet no fully black-box construction of
OT from a random oracle exists (IR89), and the wiki's Statement says so
(`content/Reductions/oihf-to-ot-bh26.md:23`).

*Why `unstated` is refused, not caveated.* An unstated step may or may not
relativize. Firing it with a caveat would add **50 facts from 10 single
starts** (GGM ⇒ OT through DGI+19, AMR25 and DMO00; FAC ⇒ PKE through RSA78;
DCR ⇒ TDP). Some are true, but a caveated fact composes further, caveats pile
up, and *derived by CCwiki* would rest on a footnote. The refusal loses true
facts and never adds a false one; the answer names the blocking step.
Classing a handful of unstated edges upstream would recover most of these
(open question 1).

*Checked on the data* (`invariants` and `queries` in the golden file):

- With the toggle on, ROM derives exactly {OIHF, Merkle puzzles}. ROM ⇒ OT
  is refused at `red-oihf-to-ot-bh26`, and the refusal cites the recorded
  barrier on that step, `bar-oihf-to-ot-bh26`. ROM ⇒ MPC is also refused at
  Kil88 (R13).
- ROM ⇒ KE is not derived; the answer shows `bar-rom-to-ke-hmo-19`.
- GGM ⇒ PKE is derived (Sho97's DDH, then ElGamal, fully black-box) and
  tagged *generic group model*. GGM ⇒ OT is refused at
  `red-ddh-to-tdh-dgi-19` (`unstated`).
- FAC ⇒ RSA is derived with the toggle, tagged *non-standard model*. FAC ⇒
  PKE is refused at `red-rsa-to-pke-rsa78` (`unstated`).

*An approximation, stated.* For an oracle model (ROM), "relativizes" is
exactly the property needed. GGM, AGM and the generic ring model **restrict
the adversary**; composing there needs the step's reduction to keep the
adversary generic or algebraic. The manifest does not record that, so CCwiki
applies the same test to every idealised model and says "holds in the generic
group model", nothing stronger (open question 2).

### R6. Chain class

The chain class of a derivation is the **first of `fully-black-box`,
`relativizing`, `free`** that every step's class implies\* (reflexively, by
the manifest's own closure). If no class qualifies, which happens exactly
when some step is `unstated`, the chain class is `unstated`.

| Chain class | Claimed when | Why composition preserves it |
|---|---|---|
| Fully black-box | every step is fully black-box | Composing two such reductions nests the fixed constructions and the fixed reductions; the result is again one fixed, oracle-only construction and reduction (RTV04). With a conjunction, the reduction breaks one of the hypotheses, which is still black-box in each. |
| Relativizing | every step implies relativizing | ∀Π (A^Π ⇒ B^Π) and ∀Π (B^Π ⇒ C^Π) give ∀Π (A^Π ⇒ C^Π). |
| Free | every step has a class (none `unstated`) | Every class implies `free`; composing implications is an implication. |
| Unstated | some step is `unstated` | The chain is still an implication, since every non-heuristic edge is a proved theorem. CCwiki makes no class claim about it. For R8 and R12 only, an unstated chain counts as `free`. |

CCwiki **never claims** semi-black-box, weakly-black-box or a ∀∃ class for a
chain. A chain made of such steps is reported as `free`. (No reduction in
today's corpus uses them.)

**The shown derivation has minimal depth, and that is not always the
strongest one.** The answer then also reports the strongest chain class over
all derivations, with its depth ("A fully black-box derivation exists in 3
steps"), computed by rerunning the closure over only the steps whose class
implies each composable class in turn. The stronger derivation must prove
**the same notion** of the target (both full, or both the same weakened
notion, R13) and use **no model, assumption or caveat** the shown one does
not; otherwise no line is shown. 24 derived pairs get the line. (Before the
review it was 55, and DDH ⇒ invertible PRF was one of them, wrongly: its
fully black-box route through PRP ⇒ iPRF concludes only the forward-game
notion.)

### R7. Forward chaining, depth and proof trees

```
closure(S, toggle):
  known := { s ↦ given | s ∈ S };  weak := {}
  phase 1 (clean) and phase 2 (assumed) over the default steps;
  phase 3 (toggle only) over all eligible steps
  each phase, layer k = 1, 2, …:
    a step fires at layer k iff
      every hypothesis is known with depth < k (or, for a consumer the
        weakening accepts, weakly known with depth < k),
      its conclusion is not known (a weakening step: not weakly known either),
      R5 allows it, and R13's preconditions are met
    each new conclusion takes the PREFERRED firing step at its first layer
    stop when a layer adds nothing and k exceeds every known depth
```

- **Depth** is the height of the tree: `1 + max(depth of hypotheses)`.
- **Preferred** means the least, in order, of: the number of non-standard
  models; the number of assumed preconditions; the chain-class rank (fully
  black-box, relativizing, free, unstated); the reduction id, compared by
  UTF-8 bytes; and forward before reverse. Every fact is fixed once assigned,
  so trees are consistent and the answer is deterministic. The Swift port
  must use this exact order.
- **Proof trees** are DAGs. Each fact appears once with its subtree; a later
  occurrence is a reference ("shown above"), never a copy. A row that
  consumed a weakened fact walks to that fact, not to a later full one.
- **N recorded reductions** is the number of distinct reduction ids in the
  tree. An equivalence used both ways counts once.

### R8. Barriers in an answer

**Which.** Every answer lists the recorded barriers on the **exact
hyperedge** (the start set equals the barrier's `hypotheses`, and the target
is its `conclusion`), and with a single start those on the reverse pair. It
also lists the derived barriers (R12) on the pair, derivable or not.

**How each is shown.** A recorded barrier shows its class, strength,
`conditionalOn`, consequences and `circumventedBy`, exactly as the inspector
does (relations.md §3a), plus a **qualifier** the UI must print beside its
title, which the wiki writes as an unqualified "No reduction from A to B":

| Barrier | Qualifier |
|---|---|
| `status: stub` | "Stub: its class and consequences are not evidence." |
| class `unstated` | "Rules out a kind of reduction the wiki does not classify; see its statement." |
| class `fixed-construction` | "Refutes only the construction named on its page; building the target another way is not ruled out." |

Each consequence is read **at its own class** (falling back to the barrier's)
and by its kind:

| Consequence | Effect |
|---|---|
| `contradiction` | rules the reduction out |
| `complexity` with `believed: false` | rules it out, under the community's belief |
| `complexity` with `believed: true` | not a barrier: the reduction "would imply" the proposition, a major result (IR89's P ≠ NP framing in the docs) |
| `object`, `reduction` | shown, not interpreted |

**Conflicts.** When the target is derived, a barrier on the pair is context,
not a contradiction, unless **any** derivation, not just the shown one,
contradicts it. For each consequence that rules out at class B, the engine
asks whether some composable class c with c ⇒\* B derives the target using
only **standard-model, non-stub steps with no assumed precondition** (an
all-unstated chain counts against B = `free`). Derived barriers on the pair
get the same test. A `believed: true` consequence that is met is reported
apart as a major-result flag. Either would mean the record is inconsistent;
the corpus test asserts neither happens, on every barrier and every derived
barrier, and on this manifest neither does.

**Context, not conflict.** A chain that uses a quantum, CRS or idealised
step, assumes a precondition, or concludes a weakened notion is never a
conflict: a barrier is a statement about standard-model reductions from the
node as the wiki defines it. When such a chain stands beside a barrier, the
answer carries a scope note ("This barrier concerns standard-model
reductions; this derivation uses the quantum setting."). OIHF ⇒ OT is
derived (`free`, BH26) beside `bar-oihf-to-ot-bh26` (`fully-black-box`),
which the barrier itself lists as circumvented.

### R9. Hosts and variants

CCwiki never infers host ⇔ variant edges. A variant is a section of a page,
and the manifest has no edge between `lpn` and its noise regimes, or between
`pke` and `pke-cca2-security`. Recorded edges between them (`rabin-ot ⇔ ot`)
are used like any other. A no-path answer adds up to four hints, each
labelled *related by the page, not by a recorded reduction*:

| Hint | Example on this manifest |
|---|---|
| Sections of the **target** that are derived | anything ⇒ Hash function: its section *Preimage resistance (one-wayness)* (`owf`) is |
| The **target's host** is derived | never when the host is a premise (TDP ⇒ ETDP used to suggest "TDP ⇒ TDP"), and never beside a recorded or non-redundant derived barrier, since a section is usually the stronger notion |
| Sections of a **start** that derive the target | LPN ⇒ PKE: *Low-noise LPN* and *Mid-noise LPN* each do; LWE ⇒ Ring LWE: *Rank-1 module LWE* does |
| The **host of a start** derives the target | Rabin OT ⇒ MPC: OT does, assuming malicious security (R13) |

### R10. The no-path answer

In this order:

0. **Recorded on this pair**: every reduction on the exact hyperedge (or its
   reverse), with what CCwiki did with it: used; not on the shown
   derivation, with any precondition it needs; *stub*, used only with the
   toggle; *idealised model*, used only with the toggle; *heuristic*;
   *quarantined*, with the reason (R13); *inclusion*; *class endpoint*.
   Derivable answers carry the same list.
1. **Recorded barriers** on the pair and its reverse, with their qualifiers
   (R8).
2. **Derived barriers** (R12), not covered by another. Redundant ones appear
   only under *Show reasoning*.
3. **With idealised models included**: when the toggle is off and turning it
   on would derive the target, say so with the model tags. FAC ⇒ RSA:
   "derivable in a non-standard model (DLO24)". When that derivation uses a
   stub, say "uses a stub reduction, whose class and model are not
   evidence", never "idealised".
4. **Refused steps**, in either mode: the steps R5 or R13 refused on the
   derivation plain closure would have used, each with its reasons, and the
   recorded barriers on the refused step's own pair or on (start, its
   conclusion), which often say more than the refusal (ROM ⇒ OT cites
   `bar-oihf-to-ot-bh26`).
5. **Host and variant hints** (R9).
6. **Completions**: single objects `Z` with which the recorded reductions
   reach the target:
   - `Z` is a `primitive` or `assumption`; not a model node, a setting or a
     refuted object (R14); not already derived from the start;
   - `Z` alone does not reach the target (that belongs in R11), and
     `start ∪ {Z}` does;
   - only the weakest: drop `Z` when another candidate `Z′` follows from `Z`
     and `Z` does not follow from `Z′`;
   - then a `Z` that `start ∪ {target}` itself reaches is **set aside**:
     adding it only restates the target. It is shown instead as "the
     question becomes start ⇒ Z" (OWF ⇒ PKE: KEM; KEM ⇒ PKE: SKE; CRHF ⇒
     DS: one-time signature). The weakest are chosen before setting aside,
     so a stronger object never stands in for one set aside;
   - sorted by depth, non-standard models, assumptions, chain class, tree
     size, id; at most 8, with the total.
7. **The footer**, fixed text:

   > CCwiki found no derivation from the reductions the wiki records. This is
   > not a separation: the record is incomplete, and only the barriers listed
   > here are results, each for the class of reduction it names.

### R11. Everything implying X (backward closure)

- **Single objects**: every `A` (not a class, a model node, a setting or a
  refuted object) whose closure reaches `X`, each with its tags: depth,
  models, chain class, assumed preconditions, and a weakened notion if only
  that is derived. This is exact, read from the single-object closures.
- **Settings** (R14) that reach `X` are listed apart: MPC: "In the
  honest-majority setting (t < n/2, RB89; t < n/3, BGW88)".
- **Refuted objects** are never listed; their number is kept for *Show
  reasoning*.
- **Pairs the recorded reductions use jointly**: `{A, B}` that reach `X`
  through a recorded conjunctive reduction where neither reaches `X` alone by
  the recorded reductions. This says nothing about need: either may suffice
  on its own, and the record does not know it. The UI never writes
  "minimal", "needs both" or "neither alone". Each pair carries the same tags
  as a single row, and each group the union of its pairs' models and
  assumptions. Candidates come from the conjunctive steps, and each is
  verified with a real closure; exact under the default filter.
- **Grouped by the conjunctive edge where the two halves meet**: the
  conjunctive step nearest the root whose hypotheses neither half derives
  alone. Larger conjunctions (JLS21 has four hypotheses) are shown as the
  edge itself, with its tags.
- Caps: 40 single rows and 12 pairs per group, with totals.

PKE, default filter: **27 single objects; 39 pairs in 5 groups**: SW14
`{owf, io}` 21, CS03 `{kem, ske}` 15, Wat09, GHJS25 and GHJS25 1 each.
CS03's 15 are a record gap, not a joint requirement: its Statement needs only
a one-time DEM, so KEM alone gives PKE. NIZK has 8 single objects and 116
pairs (SW14 87, KMY20 29), all in the CRS model and some quantum.

### R12. Derived barriers

A barrier says `(∃ a class-C reduction {X} ⇒ Y) ⇒ Q`. If `X ⇒* A′` and
`B′ ⇒* Y` by reductions of class C, then a class-C reduction `A′ ⇒ B′` would
compose into a class-C reduction `X ⇒ Y`, so `Q` follows:
**`(∃ class-C A′ ⇒ B′) ⇒ Q`**.

This is sound only when every condition below holds, and CCwiki emits a
derived barrier only then:

- **The barrier** has one hypothesis, both endpoints are primitives, and it
  is not a stub. Each **consequence that rules out** (R8: a contradiction, or
  a complexity proposition with `believed: false`) is propagated at its own
  class C ∈ {fully-black-box, relativizing, free}. A consequence that would
  only be a major result, or of kind `object` or `reduction`, is never
  propagated, and nor is any class outside the three.
- **Side edges** are single-hypothesis, non-heuristic, not stubs, not
  quarantined, **standard-model only**, have **no R13 precondition and no
  weakened conclusion**, and have a class that implies\* C. For C = `free`,
  unstated side edges count too: they are proved implications. A quantum or
  CRS side reduction gives a quantum or CRS reduction X ⇒ Y, which the
  barrier does not rule out. A side edge with a precondition does not relate
  the nodes as the barrier means them (PKE ⇒ COM needs certifiable keys;
  Kil88's OT ⇒ COM needs malicious OT).
- **Every node on the side chains**, both endpoints included, is a
  `primitive`. A black-box reduction *to* a fixed hardness assumption is not
  what the barrier quantifies over.
- **A start set** S gets a derived barrier when every member of S is reached
  from X by side edges: a class-C reduction from the conjunction composes
  into one from X, by the conjunction case of R6. {OWF, PRG} ⇒ PKE gets
  GKM+00's.
- **Strength and `conditionalOn`** are inherited, and the consequence is
  carried. **`circumventedBy` is not inherited blindly**: a circumvention of
  X ⇒ Y is listed for A′ ⇒ B′ only if B′ is derivable from A′ through it
  (its hypotheses are in cl(A′) and B′ is in cl(A′ ∪ {its conclusion})).
  Otherwise the answer says "BH26 circumvents the barrier's own pair, OIHF ⇒
  OT; that does not reach ETDP."
- **Redundant**, shown only under *Show reasoning*, when a recorded non-stub
  barrier or an already kept derived barrier on the same pair rules out at
  least as much: a class C′ with C ⇒\* C′, a strength no weaker
  (unconditional over conditional) and a consequence no weaker (contradiction
  over complexity). Candidates are taken broadest class first.

Soundness rests on the side edges' class labels: IL89's PKE ⇒ OWF must really
be fully black-box. That is why every derived barrier names its barrier and
each side reduction, and why none appears as a row in the inspector's
Barriers group.

The manifest has **no `model` field on barriers**. R12 relies on today's
only model-scoped barrier, `bar-rom-to-ke-hmo-19`, having a model-node
hypothesis, which the primitive rule excludes. A primitive-to-primitive
barrier proved only in an idealised model would be propagated wrongly (§10).

On this manifest: **406 derived records, 272 primitive pairs, 270 of them not
recorded, from 9 barriers**: IR89 153, GKM+00 OWF ⇏ PKE 103, GKM+00 PKE ⇏
OT 84, Haj18 17, GKM+00 PKE ⇏ TDP 16, GKM+00 OT ⇏ PKE 15, Sim98 13, BH26 4,
GKM+00 OT ⇏ TDP 1. (451 and 297 before the review; the difference is six
side edges that now carry a precondition or a weakened conclusion: PKE ⇒
COM, Kil88's OT ⇒ MPC and OT ⇒ COM, ABE ⇒ BE, FE ⇒ iO and PRP ⇒ iPRF.) No derived barrier
is contradicted by any clean standard-model derivation of its class, nor by
a recorded standard-model reduction on its pair.

### R13. Preconditions, weakened conclusions and quarantine

These come from the curation (§2a), never from the engine's own judgement.

- **A requirement** says that a step's hypothesis `h` must be a stronger
  notion `N` than `h`'s node defines. The step fires only when `h`'s fact is
  - **given**: the derivation then carries "assuming N" as a tag, found only
    in phase 2 (R4), so a derivation that needs no assumption wins; or
  - **concluded by a reduction in `metBy`**, whose own Statement establishes
    `N` (DMO00 for Kil88's malicious OT).

  Otherwise the step is **refused** and named, with `N` and the step that
  produced `h`.
- **A weakening** says that a step concludes only a weaker notion `W` than
  its node defines. Its fact is kept apart from the node's full fact, is
  labelled "only W", and never blocks a full fact found later. Only the
  steps in `acceptedBy` may use it, and their conclusions are full (the
  forward-game iPRF is a PRF). Every other step is refused on it.
- **Quarantine**: a reduction whose recorded hypotheses do not match its own
  Statement is never used. It appears in R10 item 0 and in refused steps,
  with the reason.
- **No parameter tracking.** A regime is never carried along a chain, even a
  parameter-preserving one. LS15's degree-1 identity keeps the modulus, so
  rank-n module LWE ⇒ LWE ⇒ BGV12 is true, but it is refused. That is
  conservative.
- **Refuse, never caveat** (decided, §0 item 4). R5 gives the reason: a
  caveated fact composes further, and caveats pile up. The caveat policy
  stays in the reference script (`--precondition-policy caveat`) for
  comparison only. `--report` prints what it would add: 58 facts from 15
  starts. Nothing in the app reads it.

On this manifest the curation removes 62 default derived pairs and adds none
(1,084 → 1,022, of which 45 now carry an assumption). The biggest losses are
BDH (26: selective ABE, BM84 on BDH's group) and CDH (16: BM84 needs
Z_p^\*, and the record has no DLOG ⇒ OWF). Everything lost is listed by
`--report`.

### R14. Refuted assumptions and settings

- **Refuted** objects (curation): circular evasive LWE (AMYY25), SIDH and
  SSDDH (CD22). A query from one is still answered, since the implication
  holds, but marked **vacuous**: "The hypothesis is known to be false
  (AMYY25), so this implication is vacuous." A refuted object is never an R11
  source and never a completion. Nothing derives one today; if something
  did, the derivation would be shown as usual, and it would mean the start is
  false too.
- **Settings** (curation): the honest-majority variants of MPC, t < n/2 and
  t < n/3. They are corruption settings in which MPC exists unconditionally,
  not assumptions. Queries from them work; R11 lists them apart; they are
  never completions.

---

## 2a. The curation file

`Resources/derivation-curation.json` holds what the manifest does not record.
`build.sh` copies it into `Contents/Resources`, where the app reads it with
`Bundle.main` (like `welcome.md`); tests read it through `#filePath`; the
reference script reads it by default (`--curation` overrides).

**The evidence rule.** Every entry cites the wiki's own text: a reduction's
Statement or `securityLoss`, or an assumption page. CCwiki never adds a
condition the wiki does not state. A condition known only from the
literature is an upstream ask, not an entry (BDOZ11's field size, §11).

Each entry's `cites` quotes the wiki verbatim, with page and section, and
`scripts/derivations_reference.py --check-quotes` checks that every quote is
still there ([relations-followups.md](relations-followups.md) §2.2).
[curation-review.md](curation-review.md) puts each entry beside its quotes
and its effect on the answers.

| Key | Entry | Today |
|---|---|---|
| `refuted` | object, source, text, evidence, cites | `circular-evasive-lwe`, `sidh`, `ssddh` |
| `settings` | object, text, evidence, cites | the two honest-majority variants |
| `quarantine` | edge, reason, cites | BW07 (composite order, three assumptions); Wee22 BE and Wee22 ABE (drop LWE) |
| `equivalences` | edge → `forward`/`reverse` (`record` or `unstated`), note, cites | all 7 eligible; ISIS ⇒ SIS `unstated` |
| `requires` | edge, direction, hypothesis, notion, `notionMarkdown`, `metBy`, evidence, cites | 23 entries on 18 edges, below |
| `weakens` | edge, notion, `notionMarkdown`, `acceptedBy`, evidence, cites | GPSW06 (selective KP-ABE; none), PRP ⇒ iPRF (forward game; iPRF ⇒ PRF) |
| `statementLint` | edge → note, cites: why a lint hit is not a dropped conjunct | HLL23, CHKV25 |

`requires`, today:

| Edge | Hypothesis must be | `metBy` |
|---|---|---|
| JLS21 | SXDH, LWE, LPN, NC⁰-PRG each sub-exponentially hard; prime order p = O(2^λ); LWE and LPN over Z_p; LPN with poly samples | — |
| BGV12 | LWE with modulus-to-noise ratio exponential in L | — |
| AMR25 low-noise LPN ⇒ TDH | quasi-polynomial hardness of low-noise LPN | — |
| FE ⇒ iO | public-key, single-key, sub-exponentially secure, weakly compact FE | — |
| ISIS ⇒ SIS (forward) | ISIS in the column-count and norm regime where it implies SIS | — |
| FLS90 (`red-tdp-to-nizk-bfm88`) | doubly enhanced, certified TDP | — |
| YZW19, YZ16 ×2, CG24 ×2 | subexponential LPN with exponent ≥ ½ (YZW19: > ½) | — |
| BM84 | DLOG in Z_p^\* | — |
| PKE ⇒ COM | perfectly correct PKE with certifiable keys | — |
| ABE ⇒ BE | CP-ABE with disjunctive policies | RW13 (KW19), Wee25 |
| Kil88 OT ⇒ MPC, OT ⇒ COM | OT secure against malicious parties | DMO00 |
| Wat09 IBE, Wat09 HIBE | DBDH and DLIN in one symmetric prime-order group | — |

**Sentinels** (golden `sentinels`, recomputed on any manifest):

- `curationResolves`: every id in the file resolves (fails the test).
- `regimeLossCurated`: every eligible reduction whose `securityLoss` says
  sub-exponential or quasi-polynomial has a `requires` entry (fails the test).
- `equivalencesReviewed`: every eligible equivalence is in the table (prints a
  warning; unreviewed ones are already unstated both ways).
- `curationSuperseded`: no entry is one the manifest now records itself
  (`reverseClass`, `refutedBy`, or a setting that is no longer the sole
  hypothesis of any step) (prints a warning).
- **Statement lint** (`--lint WIKI_ROOT`; the corpus test runs the same check
  on the clone): an assumption the Statement links before its citation that
  is neither an endpoint nor an endpoint's host page is a possible dropped
  conjunct, unless quarantined or listed under `statementLint`. Today it
  finds exactly the reviewed cases.
- **Quotes** (`curationQuotesFound`): every cited quote is still on its page
  (fails the test).
- **Curated edges** (`curationEdgesUnchanged`): every reduction the curation
  names keeps the kind, hypotheses and conclusion recorded in the golden
  file's `curatedEdges`, and an `equivalences` edge also its class and model
  (fails the test; any other class or model change prints a warning).

**Upstream asks**, which would let most of the file go, are in
[wiki-asks.md](wiki-asks.md), each with its `ccw:` id, the exact change, the
pages it touches and the entries it retires.

---

## 3. Data structures and API (Swift sketch)

A pure value type in `Sources/CCwiki/Wiki/Derivation.swift`, built once from a
`RelationsManifest` and a `DerivationCuration`, `Sendable`, with no UI and no
I/O, like `PageRelations`. It has no API that returns an object pair. A step
carries its whole hypothesis list.

The sketch below is where the design started. The built type keeps its names
and nesting and is a superset of relations-explorer.md §6.6, which is the
surface the UI compiles against: the answers also carry recorded-on-pair
statuses, conflicts, the scope note, refuted, setting and model starts, hints,
completions and question-becomes; refusals are typed (`Derivation.Refusal`);
derived barriers carry their consequence, per-start up paths and split
circumventions. It is split by concern: `Derivation.swift` (types, eligible
steps, forward chaining, proof trees, the inspector's lookups),
`DerivationAnswer.swift` (R8–R10, R13, R14), `DerivationBarriers.swift` (R8,
R12), `DerivationBackward.swift` (R11), `DerivationChecks.swift` (invariants,
sentinels, Statement lint) and `DerivationCuration.swift` (§2a). Inside, a
closure runs over dense object indexes rather than string keys; every order
the golden file can see is the script's.

```swift
struct DerivationCuration: Sendable, Decodable {   // Resources/derivation-curation.json
    // The file's arrays are keyed here by their `object` or `edge` field.
    struct Requirement: Hashable, Sendable { let relationID: String; let isReverse: Bool
        let hypothesis: String; let notion: String; let metBy: Set<String> }
    struct Weakening: Hashable, Sendable { let relationID: String; let notion: String
        let acceptedBy: Set<String> }
    struct Refutation: Sendable, Decodable { let source: String; let text: String; let evidence: String }
    let refuted: [String: Refutation]                  // R14
    let settings: Set<String>                          // R14
    let quarantine: [String: String]                   // R13: id -> reason
    struct Directions: Sendable, Decodable { let forward: String; let reverse: String } // "record" | "unstated"
    let equivalences: [String: Directions]
    let requires: [Requirement]
    let weakens: [String: Weakening]
}

struct Derivation: Sendable {
    struct Options: Hashable, Sendable {
        var includesIdealisedModels = false        // R4's toggle
    }

    /// One directed use of a reduction (R1): an equivalence yields two.
    struct Step: Hashable, Sendable {
        let relationID: String
        let hypotheses: [String]                   // the conjunction, whole
        let conclusion: String
        let isReverse: Bool
        let model: String                          // effective (R3, R4)
        let reductionClass: String                 // effective, per direction (R1, R3)
        let isStub: Bool
        let requirements: [DerivationCuration.Requirement]   // R13
        let weakening: DerivationCuration.Weakening?         // R13
    }

    enum ChainClass: String, Sendable, Comparable {
        case fullyBlackBox = "fully-black-box", relativizing, free, unstated
    }

    struct Fact: Sendable {
        let objectID: String
        let depth: Int                             // 0 = given
        let step: Step?                            // nil = given
        let models: Set<String>                    // non-standard models used
        let isModelScoped: Bool                    // R5
        let chainClass: ChainClass                 // R6
        let assumes: Set<DerivationCuration.Requirement>     // R13, on givens
        let weakening: DerivationCuration.Weakening?         // R13: only this notion
        let weakInputs: Set<String>                // hypotheses consumed weakened
    }

    struct Closure: Sendable {
        let start: Set<String>
        let options: Options
        let facts: [String: Fact]                  // full notion
        let weakFacts: [String: Fact]              // weakened notion only (R13)
        let refused: [Refusal]                     // R5, R13, for explanations
        func proof(of id: String) -> ProofTree?
    }

    struct DerivedBarrier: Hashable, Sendable {    // R12
        let barrierID: String
        let hypotheses: [String]; let conclusion: String
        let reductionClass: String
        struct Consequence: Hashable, Sendable { let kind: String; let target: String }
        let consequence: Consequence               // rules-out kinds only
        let strength: String; let conditionalOn: [String]
        let up: [String: [Step]]; let down: [Step]
        let circumventedBy: [String]               // reach this pair
        let circumventsOriginalOnly: [String]      // reach the barrier's own pair only
        let redundantWith: [String]                // "derived:" prefix for derived ones
    }

    enum Answer: Sendable {
        case unsupported(reason: String)           // R2
        case derived(DerivedAnswer)                // tree, depth, models, chain class,
                                                   // assumes, weakening, strongest (R6),
                                                   // barriers + qualifiers + conflicts +
                                                   // scope note (R8), recorded-on-pair,
                                                   // vacuous (R14)
        case notDerived(NoPathAnswer)              // R10, in its order, incl. questionBecomes
    }

    init(manifest: RelationsManifest, curation: DerivationCuration)
    func closure(from start: Set<String>, options: Options) -> Closure
    func answer(from start: Set<String>, to target: String, options: Options) -> Answer
    func implying(_ target: String, options: Options) -> BackwardClosure   // R11
    func derivedBarriers(from start: Set<String>, to target: String) -> [DerivedBarrier]
}
```

- **Built where the manifest is.** `AppModel.loadLibrary()` loads the manifest
  after every sync; the `Derivation` is built there with the bundled curation
  and precomputes the single-object closures for both options.
- **The proof tree's rows are already flat**, so the explorer can draw them as
  an outline without recursion in a view body (`SWIFTUI-RULES.md`).
- `PageRelations` stays the recorded view. The inspector's derived groups are
  a separate type built from a `Derivation`.

## 4. Complexity and timing

Let E = 236 directed steps, H = 263 hypothesis occurrences, V = 234 non-class
objects, and L ≤ 10 layers per phase (the maximum default depth is 9).

| Operation | Cost | Python reference, this manifest |
|---|---|---|
| Build steps | O(E) | 1 ms |
| One closure (three phases) | O(L · H) | 0.3–0.8 ms |
| All single-object closures, both options | O(V · L · H) | 151 ms for 468 |
| Answer with completions (no path) | O(V · L · H) | 135–155 ms (OWF ⇒ PKE, PKE ⇒ OT) |
| Answer, derivable (R6 and R8 rerun restricted closures) | O(L · H) per class | 2–3 ms (DDH ⇒ iPRF, DDH ⇒ OT) |
| Derived barriers, all | O(barriers · E) | 2 ms |
| Implied-by PKE | candidate pairs × closure | 122 ms cold, 1 ms warm |
| Invariants (every barrier, every derived barrier) | restricted closures | 90 ms |
| Whole golden file (72 queries, 7 patched manifests) | — | 4.7 s |

These are CPython timings on the Linux container; nothing was compiled here.
A Swift port of the same loops should be at least an order of magnitude
faster; that is an expectation, not a measurement. Precompute at load, off
the main actor. Only a no-path answer's completions cost more than a few
milliseconds.

---

## 5. Results on the real manifest

Wiki `ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157`, `relations.json` SHA-256
`b0c3fb65…c0e3ee`; the curation's SHA-256 is in the golden file.

**Eligibility.** 283 reductions → 236 directed steps (7 reverse). Excluded:
45 inclusions, 2 heuristic, 4 with a complexity-class endpoint, 3
quarantined. By model: standard 189, ROM 22, CRS 7, generic group 7, quantum
5, algebraic group 3, other 2 (both directions of DLO24), unknown 1 (the
stub). Default: 201.

**Closures.** 234 objects can start a query, and 119 derive something. Over
all single starts there are **1,022** derived (start, target) pairs: chain
class fully black-box 543, unstated 464, free 15; **45 carry an assumed
precondition**; 1 more is weakened only (BDH ⇒ ABE). Model tags: none 925,
quantum 89, CRS 6, both 2. Depth: 1→175, 2→193, 3→191, 4→177, 5→145, 6→91,
7→34, 8→10, 9→6. With the toggle there are 1,222 pairs, 200 of them
model-scoped. 36 objects gain facts with the toggle.

| Object | Default | With toggle | Max depth (default) | Note |
|---|---|---|---|---|
| GapSVP / SIVP | 33 | 36 | 6 | quantum (Reg05); no longer leveled FHE |
| DDH | 33 | 37 | 5 | MPC through DMO00's OT |
| LWE | 29 | 29 | 5 | leveled FHE assuming BGV12's modulus |
| DCR | 29 | 31 | 5 | |
| RSA | 22 | 28 | 5 | no longer NIZK (FLS90 needs a certified TDP) |
| TDP | 21 | 21 | 4 | NIZK assuming doubly enhanced, certified |
| DLOG | 19 | 24 | 4 | 16 of them assuming DLOG in Z_p^\* (BM84) |
| PKE | 19 | 19 | 4 | includes OWF (IL89) |
| OWP | 16 | 16 | 4 | |
| FAC | 16 | 17 | 5 | +RSA only (R5 stops the rest) |
| OWF | 15 | 15 | 3 | no PKE, KE, OT, CRHF |
| SIS | 3 | 19 | 2 | +16, all through the ROM signature edge |
| OT | 4 | 4 | 1 | MPC and COM assuming malicious OT; not OWF (record gap) |
| BDH | 5 (+1 weakened) | 27 | 3 | ABE only selective KP-ABE; no IBE, PRG |
| CDH | 4 | 8 | 2 | no OWF: the record has no DLOG ⇒ OWF |
| Low-noise LPN | 31 | 35 | 6 | 6 assuming quasi-polynomial hardness (AMR25) |
| ROM | 0 | 2 | — | OIHF, Merkle puzzles (depth 1) |
| GGM | 0 | 28 | — | Sho97's DDH, CDH, DLOG, KEA and their fully black-box consequences |
| AGM | 0 | 1 | — | KEA (depth 1) |

**Backward.** PKE: 27 single sources, 39 pairs (above). OT: 22 single
sources (2 with an assumption), no pairs. MPC: 17 single sources, two
settings apart.

**Invariants**, all true: no ineligible edge is ever used; default results
carry no idealised model; no derivation of any class contradicts a recorded
barrier, and none proves a believed-true proposition; no derivation
contradicts a derived barrier, and no recorded standard-model reduction does;
ROM reaches neither OT nor KE in either mode. **Sentinels**, all true.

## 6. Worked examples

All are the reference script's output (`--query`), and all are records in the
golden file.

- **DDH ⇒ OT: derived, 3 steps, unstated.** OT ⇐ cPIR (DMO00) ⇐ TDH (AMR25)
  ⇐ DDH (DGI+19). **DDH ⇒ MPC**: one more step, Kil88, whose malicious-OT
  precondition DMO00's Statement meets.
- **{OWF, KEM} ⇒ PKE: derived, 4 steps, fully black-box.** PKE ⇐ KEM ∧ SKE
  (CS03), SKE ⇐ PRF ⇐ PRG (GGM86) ⇐ OWF (HILL99).
- **{OWF, iO} ⇒ PKE: derived, 1 step, free** (SW14).
- **OWF ⇒ PKE: no derivation.** Recorded barrier
  `bar-hash-function-to-pke-gkm-00` (relativizing). Derived barrier from IR89
  through OWP ⇒ OWF and PKE ⇒ KE, redundant. Completion: iO. The question
  becomes OWF ⇒ KEM (KEM was offered before the review; PKE implies it).
- **PKE ⇒ OT: no derivation.** Recorded `bar-pke-to-ot-gkm-00`; reverse
  `bar-ot-to-pke-gkm-00`; no completions.
- **FAC ⇒ PKE.** Default: no derivation; completion iO (3 steps); the
  question becomes FAC ⇒ KEM. Toggle on: FAC ⇒ RSA is derived (DLO24,
  non-standard model), but RSA78's RSA ⇒ PKE (unstated) is refused after it.
- **ROM ⇒ OT.** Default: the model-start message. Toggle on: refused at
  `red-oihf-to-ot-bh26`, citing `bar-oihf-to-ot-bh26`. ROM ⇒ MPC is refused
  there and at Kil88.
- **DLOG ⇒ CDH.** Default: no derivation, "derivable with idealised models
  included (algebraic group model)". Toggle on: derived, 1 step, tagged AGM.
- **GapSVP ⇒ PKE: derived, 2 steps, fully black-box, tagged quantum.**
- **{SXDH, LWE, LSN, NC⁰-PRG} ⇒ iO: no derivation**; JLS21 is refused
  because LPN comes from CIMR25, not over Z_p. With all four hypotheses
  given: derived, 1 step, assuming JLS21's four regimes. {SXDH, GapSVP, LPN,
  NC⁰-PRG} ⇒ iO is refused at JLS21 too (LWE from Reg05).
- **GapSVP ⇒ leveled FHE: no derivation**, BGV12 refused (LWE from Reg05).
  LWE ⇒ leveled FHE: 1 step, assuming the exponential modulus-to-noise ratio.
- **Low-noise LPN ⇒ OT: 3 steps, unstated, assuming quasi-polynomial
  hardness.**
- **ETDP ⇒ MPC: no derivation**, Kil88 refused (EGL's OT is semi-honest).
- **BDH ⇒ ABE: derived, only selectively secure KP-ABE.** BDH ⇒ IBE: no
  derivation (ABE ⇒ IBE refused on the weakened ABE); completion DLIN (Wat09,
  assuming one group); with the toggle, BF01 in the ROM.
- **ISIS ⇒ CRHF: 2 steps, unstated, assuming ISIS's regime.** SIS ⇒ ISIS
  stays fully black-box.
- **Circular evasive LWE ⇒ PKE: derived, 3 steps, vacuous (AMYY25).**
- **KEM ⇒ PKE: no derivation, no completions; the question becomes KEM ⇒
  SKE.** CRHF ⇒ DS: the question becomes CRHF ⇒ one-time signature.
- **DDH ⇒ invertible PRF: 2 steps, unstated, no strongest line.**
- **DDH ⇒ PRG: 3 steps, fully black-box, through ElGamal, IL89 and HILL**,
  not BM84. **LWE ⇒ COM: 4 steps, through PRG**, not PKE ⇒ COM.
- **LPN ⇒ PKE: no derivation**; Low-noise and Mid-noise LPN each do.
  **LWE ⇒ Ring LWE: no derivation**; Rank-1 module LWE, a section of LWE,
  does.
- **OIHF ⇒ ETDP: no derivation**; derived barrier from BH26's through EGL,
  whose circumvention reaches OT only. **OIHF ⇒ Rabin OT: derived (free)**,
  with that derived barrier as context and BH26 as its circumvention.
- **COM ⇒ TDP: three derived barriers, one kept** (GKM+00's relativizing
  OWF ⇏ PKE covers IR89's and the fully black-box PKE ⇏ TDP).
- **{OWF, PRG} ⇒ PKE: derived barrier from GKM+00** (multi-start).
- **ZKP ⇒ constant-round ZK argument: no derivation**; the recorded barrier
  carries the *unclassified* qualifier. **CPA ⇒ CCA1** carries
  *fixed-construction*.
- **DLOG ⇒ BQP: unsupported** (R2).

---

## 7. UI wording rules

These apply in the explorer window, in the inspector's derived groups and
anywhere else a derived claim appears.

- **Label every derived claim.** Use exactly "Derived by CCwiki from N
  recorded reductions" ("1 recorded reduction"). Never write a derived claim
  as the wiki's: no bare "A implies B", and no "the wiki shows".
- **Derived rows look different** from recorded ones: a *Derived* header,
  secondary style, a depth badge ("3 steps"). Model tags appear only when the
  chain is not standard-model alone. A derived row opens the proof tree.
- **Assumptions are part of the claim.** A derivation with an assumed
  precondition reads "Derived by CCwiki … assuming low-noise LPN is
  quasi-polynomially hard". The proof row that needs it shows the same line,
  and in a list the rows are grouped under an *Assuming …* sub-header rather
  than tagged one by one.
- **A weakened conclusion says what it is**: "Derived … only selectively
  secure key-policy ABE (GPSW06)".
- **A refuted start** puts a banner above the answer: "The hypothesis is
  known to be false (AMYY25), so this implication is vacuous." Its page's
  inspector shows the same banner over its derived groups.
- **Every step of a proof tree links to its reduction page.** The step shows
  the reduction's title, class, model and sources, exactly as the inspector
  shows a recorded row. A reverse step says "⇔, used right to left".
- **Model tags** use the site's names: "random oracle model", "generic group
  model", "algebraic group model", "CRS model", "quantum setting",
  "non-standard model" (for `other`), and "stub" (R3). A model-scoped result
  reads "holds in the random oracle model", never "holds".
- **Chain class wording.**

  | Chain class | Wording |
  |---|---|
  | Fully black-box | "Fully black-box: every step is" |
  | Relativizing | "Relativizing: every step relativizes" |
  | Free | "An implication; no black-box claim" |
  | Unstated | "Class unstated: N steps do not state theirs", muted as on recorded rows |

  If a stronger chain exists (R6), add "A fully black-box derivation exists
  in K steps" with a button to show it.
- **No path.** Write "No derivation found". Never write "A does not imply B",
  "separated", "impossible" or "no reduction exists". The fixed footer (R10)
  is always shown and cannot be collapsed.
- **Barrier titles are the wiki's and must be qualified.** Print R8's
  qualifier beside an unclassified, fixed-construction or stub barrier's
  title, every time the title appears, previews included. A `believed: true`
  consequence reads "would imply P ≠ NP", never "rules out". A barrier beside
  a non-standard chain carries R8's scope note.
- **Derived barriers show their argument and their consequence.** For
  example: "A relativizing reduction from OWF to CRHF would compose with OWP ⇒
  OWF (fully black-box) into one from OWP to CRHF, which Sim98 rules out.
  Derived by CCwiki." The barrier and each side reduction are links. A
  circumvention that does not reach the pair says so (R12).
- **Refused steps** say what is missing: "Not derived: OIHF holds here only in
  the random oracle model, and OIHF ⇒ OT (BH26) is a free (non-black-box)
  step, which need not carry over into that model." For R13: "Not derived:
  BGV12 needs LWE with a modulus-to-noise ratio exponential in the depth;
  the LWE here comes from GapSVP by Reg05, which gives a polynomial modulus."
- **Refused, never caveated.** No derived claim carries "precondition not
  established" or any other caveat of that kind. A step whose precondition
  is not established is listed under *Refused steps*, with the wiki's text,
  in a no-path answer, and under *Adjustments* when it shapes a derivable
  answer ([relations-followups.md](relations-followups.md) §2.5).
- **Recorded on this pair** (R10 item 0) uses the status words of R10 and
  says why an unused one was not used.
- **Hints (R9)** say "related by the page, not by a recorded reduction".
- **Completions** read "With the wiki's recorded reductions, adding iO gives
  a derivation (1 step). It may suffice on its own; the record is
  incomplete." Never call one a *missing assumption*. A set-aside one reads
  "The target gives back KEM, so the question becomes OWF ⇒ KEM."
- **Pairs (R11)** are headed "Pairs the recorded reductions use together",
  never "minimal pairs" or "needs both".
- **The toggle** is "Include idealised models", with help text naming the
  random oracle, generic group, algebraic group and other non-standard models.
  It is off by default, per window, and not remembered across launches.
- **The backward header** is "Everything the wiki's reductions derive this
  from", with help text "Derived by CCwiki. The wiki's record is incomplete."
- **Link previews** show only recorded data: a page's title and first
  paragraph, or a reduction's or barrier's full hyperedge with its class,
  model and source. A preview never shows a derived claim. A barrier preview
  **keeps an unstated class** ("against reductions of a class the wiki does
  not state"); `RelationMeta.parts` drops it today (`RelationMeta.swift:112`)
  and must not for previews.

---

## 8. Testing

**The self-test.** `scripts/derivations_reference.py RELATIONS_JSON
--selftest` runs one check per review finding, most on the real manifest
and the rest on patched copies of it. It exits non-zero on any failure.

**The golden file.** `Tests/CCwikiTests/Fixtures/derivations-golden.json` is
written by
`scripts/derivations_reference.py RELATIONS_JSON --golden … --wiki-commit SHA`
and regenerates byte-identically. It records the wiki commit, the manifest's
and the curation's SHA-256, counts, policy constants, closure sizes (15
objects, with weakened counts), backward summaries for PKE, OT and MPC with
group tags, the invariants and sentinels by name, `curatedEdges`, a snapshot
of every reduction the curation names, **72 query records** and
**10 mutation records**. A query record holds the start, target and toggle and
the expected answer: *supported*, *derivable*, vacuous, model start, recorded
barriers with qualifiers, reverse barriers, **derived barriers in full**
(class, consequence, up and down paths, circumventions, redundancy),
recorded-on-pair statuses; and for a derivation: depth, models,
model-scoped, chain class, assumptions, weakening, sorted edge ids, reverse
steps, strongest, conflicts, scope note; for a no-path answer: top 5
completions and total, question-becomes, refused steps with reason kinds,
hints and the toggle hint.

**A mutation record** is one of the review's counterexamples as a patch: it
adds objects, reductions and barriers, sets fields on existing barriers and
reductions, or appends consequences to barriers. The Swift test applies the
patch to the decoded manifest and asserts the query, the derived-barrier
count, the invariants and the entries `curationSuperseded` lists. The seven: a stronger chain behind an unstated shortcut
conflicts; a chain contradicting a derived barrier fails its invariant; a
quantum and a ROM chain beside a barrier are context, not conflicts; a
believed-true consequence is not propagated; an unstated chain conflicts
with a `free` barrier; a stub barrier is not propagated. Three more test the
upstream fields of [relations-followups.md](relations-followups.md) §4.4: a
barrier `model` that stops R12, a `reverseClass` that overrides the
curation, and a `refutedBy` that makes an answer vacuous.

**The corpus test** (`DerivationTests`, gated on `CCWIKI_WIKI` like
`RelationsTests`) reads the golden file and the curation through
`#filePath`. `Package.swift` excludes `Fixtures/` from the test target. The
test has three outcomes:

1. **Exact.** Both SHA-256s match. The test asserts every record field by
   field, every mutation, the closure sizes and the backward summaries.
2. **Drifted, within tolerance.** A hash differs, but objects, reductions and
   barriers are each within ±10% of `counts`. The test asserts the
   invariants and sentinels recomputed on the current manifest, each
   record's `stable` fields, the Statement lint on the clone, and the
   mutations' invariants (not their exact answers). Records naming a missing
   object are skipped. This is the usual state in CI.
3. **Drifted beyond tolerance.** Skip, and print the golden commit and counts
   beside the clone's, with "regenerate with
   scripts/derivations_reference.py". Use `.enabled(if:)` so the skip is
   visible.

A failing `curationResolves`, `regimeLossCurated`, `curationQuotesFound`,
`curationEdgesUnchanged` or Statement lint means the wiki moved under the
curation: review the named edges, update the file, and regenerate the golden
file. Then run `make curation-review` against the same clone.

A unit test without a clone covers each rule on a small fixture manifest,
mirroring `RelationsTests`: a conjunction that must not fire on one
hypothesis; an equivalence with one direction unstated; an inclusion and a
heuristic edge that never fire; a `{rom} ⇒ X` edge mis-typed `standard`; a
free step after a ROM step; a requirement met by a given (tagged), by a
`metBy` producer, and refused; a weakened fact that blocks no full fact; a
quarantined edge; a barrier with a quantum side edge that R12 must not
propagate.

---

## 9. Open questions

1. **Upstream classing would unlock most R5 refusals.** The unstated steps
   R5 refuses most often are OWF ⇒ SK-PIR (BM26), ZKP ⇒ auxiliary-input OWF,
   PRF ⇒ iPRF (HPPY25), RSA ⇒ TDP/PKE/OAEP (RSA78, FOPS01), DLOG ⇒ BLS/CDH
   (FKL18), Pedersen VSS, and DDH ⇒ TDH (DGI+19).
2. **Adversary-restricted models.** R5 uses "relativizes" for GGM, AGM and
   the generic ring model too. Stay with one rule, or ask upstream for a
   per-edge "generic reduction" flag?
3. **Who owns the curation?** It is CCwiki's for now (§2a). Every entry is
   an upstream ask; should the wiki take them as fields, so CCwiki can drop
   the file?
4. **Decided 2026-10-12: refuse** (§0 item 4). The inspector refuses as
   the explorer does.
5. **Kil88's `metBy`.** Only DMO00's Statement claims completeness for MPC.
   BH26's, YZ16's, Cre87's and the SPIR edge's OT are not stated to be
   malicious-secure, so OIHF, subexponential LPN, Rabin OT, random OT and
   SPIR no longer reach MPC. Should the wiki state the security of each OT
   edge?
6. **`model: other` on DLO24.** Should the wiki name the generic ring model
   as a model?
7. **"Free" as a chain class.** The wording avoids the bare word; should the
   chain row omit the class instead?
8. **Completion types.** `bilinear-pairing` (a glossary node) would
   sometimes be a sensible thing to "add". Include settings?
9. **Derived barriers in the inspector.** Kept out of the Barriers group by
   design. A one-line "N barriers follow from recorded ones" link into the
   explorer?

## 10. Residual risks

The review found ten unsound derivation patterns and fixed each one it found.
It did not show that no others exist, and these remain:

- **Unreviewed preconditions.** R13 corrects only the edges in the curation.
  A keyword scan of the Statements and security losses of the 232 eligible
  reductions (regime words, Z_p, modulus, composite, "selective",
  "semi-honest", "certified", "one-time", "only if") flagged 82; the ones
  that needed an entry have one, but a Statement can need a stronger notion
  without using any of those words. Any derived claim through an edge whose
  hypothesis is a broad host node (`lwe`, `lpn`, `bdh`, `ot`, `abe`,
  `pke`) is only as good as that edge's fit to the node. The proof tree links
  every step's Statement so a reader can check. Refusal applies only to
  preconditions the curation records. A precondition no one has reviewed is
  still chained, so this risk is unchanged by §0 item 4.
- **Shared parameters across conjuncts.** CCwiki treats a conjunction's
  hypotheses as independent. The curation covers Wat09 (one group) and JLS21
  (one prime p) by requiring them as givens. CHKV25 (the LHE plaintext field
  must equal the sparse-LPN field) is not covered: its Statement does not say
  so.
- **Conditions only the literature states.** BDOZ11 needs a large plaintext
  field, so GM's Z₂ encryption does not feed it, but the wiki's Statement
  does not say so, and by §2a's rule CCwiki does not add it. QR ⇒ MPC with
  preprocessing is still derived.
- **Producers not stated to be weaker.** R13's weakenings cover the two
  Statements that say they prove less than their node (GPSW06, PRP ⇒ iPRF).
  An edge whose Statement is silent about selective security, semi-honest
  security or parameters is taken at its node's notion.
- **Barriers have no model field** (R12). A primitive-to-primitive barrier
  proved only in an idealised model would be propagated as if standard.
  CCwiki now reads a barrier `model` when the wiki records one
  ([wiki-asks.md](wiki-asks.md) ask 3).
- **The class labels themselves.** R6, R8 and R12 trust each edge's
  `class`. A mislabelled fully black-box edge makes a wrong chain class and,
  as a side edge, a wrong derived barrier. The invariants catch a mislabel
  only when it collides with a barrier (the reviewers' mutation test found
  BH26 is the only edge where it would today).
- **Curation drift.** The file was reviewed against one wiki commit. The
  sentinels and the Statement lint catch removed ids, new regime-loss edges,
  new equivalences and new dropped conjuncts. Every entry now quotes the
  wiki, and `curationQuotesFound` fails when a quoted passage changes; an
  edit to a Statement outside every quote still goes unnoticed.

## 11. Red-team review, 2026-10-10: dispositions

Two reviewers ran the reference engine against the real manifest. Each
finding was reproduced with the engine before it was acted on. "Accepted"
means the rule, the code, the golden data and this spec changed; the
self-test has a check for each.

| Finding | Disposition |
|---|---|
| Regimes never travel: {SXDH, LWE, LSN, NC⁰-PRG} ⇒ iO through CIMR25 | Accepted: R13 `requires` on JLS21; refused, and with given hypotheses tagged. `securityLoss` regime words are a sentinel |
| Reg05 fed into JLS21 and BGV12 | Accepted: R13 on JLS21's and BGV12's LWE |
| AMR25 needs quasi-polynomial low-noise LPN | Accepted: R13; low-noise LPN ⇒ TDH, cPIR, OT, MPC now carry the assumption |
| FE ⇒ iO applied to generic FE | Accepted in part: SW14's FE never feeds it; a given FE does, tagged with AJ15/BV15's notion, so R11 pairs with FE carry the tag rather than being dropped |
| ISIS ⇒ SIS used under the equivalence's class | Accepted: per-direction class (R1) and R13; unreviewed equivalences are unstated both ways |
| Refuted assumptions shown as ordinary sources | Accepted: R14 |
| Hyperedges that do not match their Statements (BW07, FLS90, Wee22, YZW19) | Accepted: BW07 and both Wee22 edges quarantined; FLS90 and YZW19 (and YZ16, CG24) get R13 entries; Statement lint added |
| R11 pairs and R10 completions read as joint requirements; KEM offered for OWF ⇒ PKE | Accepted: wording; set-aside completions become "the question becomes start ⇒ Z" |
| R6 "strongest" crosses iPRF notions | Accepted: R13 weakening on PRP ⇒ iPRF; R6 compares only the same notion |
| Shortcut edges outside their scope (BM84, PKE ⇒ COM, GPSW06 into ABE ⇒ IBE/BE, EGL into Kil88) | Accepted: R13 entries; the engine now finds the clean longer trees where they exist (DDH ⇒ PRG, LWE ⇒ COM) |
| … GM's Z₂ AHE into BDOZ11 | Rejected for now: the wiki's Statement does not state the field size, and §2a admits only the wiki's text. Upstream ask; listed in §10 |
| R11 pairs carry no tags | Accepted |
| R8 tests only the shown chain's class | Accepted: any derivation (restricted closures), in queries and invariants, and against derived barriers |
| R8 ignores models | Accepted: standard-model, precondition-clean chains only; others get the scope note |
| R12 propagates every consequence kind | Accepted: rules-out kinds only, consequence carried; verified with the docs' own P ≠ NP example as a patch |
| Unstated and fixed-construction barriers read as results | Accepted: qualifiers, footer wording, previews keep the unstated class |
| circumventedBy inherited blindly | Accepted: listed only when it reaches the derived pair |
| Host hint names the premise | Accepted, and the host hint is suppressed beside a barrier |
| Stub and heuristic edges on the pair unmentioned; stub hint says "idealised" | Accepted: R10 item 0; stub wording |
| Derived barriers subsumed by broader ones still shown | Accepted: redundancy against kept derived barriers, strength and consequence |
| Barriers have no model field | Accepted as a residual risk (§10) and an upstream ask |
| Stub barriers not excluded | Accepted |
| Unstated chain against a free barrier | Accepted: counts as free for R8 and R12 |
| Consequence class vs barrier class | Accepted: each consequence at its own class |
| Golden file pins misleading outputs and only ids | Accepted: regenerated, derived barriers in full, new records for each case, 7 mutations |
| Refused step could cite a barrier on the composite | Accepted: refusals cite barriers on the step's pair and on (start, its conclusion) |
| Settings modelled as primitives | Accepted: R14 settings |
| Host nodes that merge notions | Accepted where a Statement says so (R13); the rest is §10's first risk |
| Multi-start queries get no barrier | Accepted: R12 for start sets |
| Derived barriers never shown on derived pairs | Accepted: shown as context, with the conflict check |

**For [relations-explorer.md](relations-explorer.md).** Its §6 `DerivedBarrier`
needs the consequence and the split circumvention lists (§3 above); its
answers need assumptions, weakening, vacuous, recorded-on-pair,
question-becomes, barrier qualifiers, conflicts and the scope note; its §2.7
no-path sentence must not claim that no chain exists "in the standard,
quantum or CRS models" when a stub or quarantined edge is on the pair; and its
barrier previews must keep the unstated class and the qualifiers (§7).
