# Derivations

What CCwiki may conclude by chaining the wiki's recorded reductions, and how it
says so.

**Status: specified 2026-10-10 on `claude/relations-explorer`.** The engine is
specified here and implemented in Python as
`scripts/derivations_reference.py`, run on the real manifest (wiki
`ab81f02`, `relations.json` v1: 262 objects, 283 reductions, 32 barriers).
`Tests/CCwikiTests/Fixtures/derivations-golden.json` records its answers.
The Swift `Derivation` type (§3) is not built yet. The Swift port must give the
same answers on the same manifest, and the corpus test (§8) checks this. Read
[relations.md](relations.md) first; this assumes its hyperedge rule (§1 there)
and its class order (§5 there).

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

The wiki's own `--derive` mode is plain Horn closure, and it **ignores
`model`** (`docs/relations-json.md` § Closure). CCwiki is deliberately
stricter. On this manifest, plain closure produces four false or misleading
claims, and each one led to a rule below:

| Plain closure says | Why it is wrong | Rule |
|---|---|---|
| ROM ⇒ OIHF ⇒ OT ⇒ MPC | BH26's OIHF ⇒ OT is non-black-box, so it does not carry over into the random-oracle world; the wiki says so (`content/Reductions/rom-to-oihf-bh26.md:27`, `oihf-to-ot-bh26.md:23`) | R5 |
| CDH ≡ DLOG | DLOG ⇒ CDH is FKL18's theorem in the **algebraic group model** (`red-dlog-to-cdh-fkl18`) | R4 |
| FAC ⇒ RSA ⇒ TDP ⇒ PKE | FAC ⇒ RSA is the reverse of DLO24's equivalence, proved only against **generic ring** algorithms (`model: other`, `red-rsa-to-fac-dlo24`) | R4, R5 |
| DLOG ⇒ BQP | `dlog ⊆ bqp` is Shor's *attack*, an inclusion of a problem in a class, not an implication | R1, R2 |

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
strength explicitly: the step classes (R6) and the models used (R4).

**No derivation is never a separation.** The manifest is incomplete in ways
that matter: OT, PRF, SKE, MAC and COM do not derive OWF in it, and LWE ⇒ ABE
(GVW13) is absent. The only statements that something *cannot* be derived are
recorded barriers, and derived barriers under R12, which come from them.

---

## 2. The rules

Each rule is a named constant or function in `scripts/derivations_reference.py`,
cited as R1–R12 in its comments.

### R1. Eligible edges

| Edge | Treatment | n |
|---|---|---|
| `implication` | eligible, `hypotheses ⇒ conclusion` | 230 |
| `equivalence` | eligible in **both directions**; the backward use is marked `reverse` and named in the tree ("⇔, used right to left") | 8 |
| `inclusion` | **excluded** — containment, not implication (`IP ⊆ PSPACE`) | 45 |
| `heuristic: true` | **excluded** — "an edge of the graph, not a theorem" (`docs/relations-json.md` § Caveats) | 2 |

An equivalence has one `class` and one `model`, and both apply to each
direction. That is the only reading a single-valued field allows (open
question 3).

Of the 8 equivalences, 7 are eligible; R2 removes `qip ⇔ pspace`. After R1–R3
there are **239 directed steps**, and the default filter (R4) leaves 204.

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
  `qip ⇔ pspace`. If "CZK" became a derived *fact* next to "PKE", a class
  equality would read like a primitive. These four belong with the class
  lattice (roadmap idea 7), as conditional facts on its nodes.
- **Barriers on classes are non-containments.** Nine of the 32 barriers have
  a complexity-class endpoint (six are between two classes), and R12 must not
  mix them with primitives.

### R3. Stubs

`status: stub` means "do not treat a stub's `class` or `model` as evidence".
One reduction is a stub today: `red-noise-level-to-depir-cimr25-2`,
High-noise LPN ⇒ SK-DEPIR. A stub step is eligible **only with the toggle
on**. Its model is taken as `unknown`, which R5 treats as idealised, and its
class as `unstated`. Anything that relies on it is tagged *stub*. The default
filter needs a known model, and a stub's model is not known, so a stub cannot
pass it. With the toggle on, models stop being a filter and become tags, so
the stub can take part honestly.

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
- A model node is never offered as a completion (R10). "Add the random
  oracle model" is not an assumption a reader can add.
- With the toggle off, a model node given as a start derives nothing, and the
  answer says why: "The random oracle model is a model, not an assumption.
  What the wiki proves in it appears with idealised models included."

**Clean facts first.** The closure runs in two phases. Phase 1 uses only the
default steps and yields the **clean** facts. Phase 2 runs only with the toggle
on, uses every eligible step, and adds **model-scoped** facts; it never
replaces a clean one. So turning the toggle on only *adds* facts. It never
changes how a default fact is justified, and a fact with any idealised-free
derivation shows that derivation.

### R5. Composition after an idealised step

A fact is **model-scoped** if its derivation uses a step in an idealised
model (or a stub step). A step may fire on hypotheses that include a
model-scoped fact **only if its class implies\* `relativizing`**. Under the
current order (`classes` in the manifest) only `fully-black-box` and
`relativizing` do. A step of any other class is refused there: `free`,
`unstated`, `semi-black-box`, `weakly-black-box`, the ∀∃ classes, and
`fixed-construction`. A refused step is reported in the answer as an
explanation, never as a fact.

*Why relativizing.* A relativizing reduction holds relative to every oracle Π
(RTV04; `reduction-classes.yaml`): if the hypotheses exist relative to Π, so
does the conclusion. "X holds in the random-oracle model" means X exists
relative to a random oracle, so a relativizing step carries X into Y relative
to the same oracle. A non-relativizing step need not carry it. BH26 is the
counterexample in the data. A random oracle gives an OIHF (`red-rom-to-oihf-bh26`,
`relations.json:9295`), and OIHF ⇒ OT holds by a non-black-box argument
(`red-oihf-to-ot-bh26`, class `free`, `:8096`). Yet no fully black-box
construction of OT from a random oracle exists (IR89), and the wiki's
Statement says so (`content/Reductions/oihf-to-ot-bh26.md:23`). The Notes add
that the composite "does not place OT in Minicrypt" (`rom-to-oihf-bh26.md:27`,
`oihf-to-ot-bh26.md:28`).

*Why `unstated` is refused, not caveated.* An unstated step may or may not
relativize. The alternative was to fire it with a caveat. On this manifest
that would add **45 facts from 9 single starts**, among them GGM ⇒ OT (through
DGI+19's TDH, AMR25's cPIR and DMO00, all unstated), FAC ⇒ PKE (through
RSA78), and DCR ⇒ TDP. Some of these are true. GGM ⇒ OT is believed true, and
FAC ⇒ PKE holds against generic ring adversaries. But a caveated fact
composes further, caveats pile up, and the label *derived by CCwiki* would
then rest on the reader reading a footnote. The refusal loses true facts and
never adds a false one. The answer still names the step that blocked it, so
a reader sees what would be needed. Classing a handful of unstated edges
upstream would recover most of these (open question 1).

*Checked on the data* (`invariants` in the golden file):

- With the toggle on, ROM derives exactly {OIHF, Merkle puzzles}. ROM ⇒ OT
  and ROM ⇒ MPC are refused at `red-oihf-to-ot-bh26` (`free`), and the
  answer says so.
- ROM ⇒ KE is not derived. The answer shows the recorded barrier
  `bar-rom-to-ke-hmo-19` (`relations.json:11313`).
- GGM ⇒ PKE is derived (GGM ⇒ DDH by Sho97, then ElGamal, which is
  `fully-black-box`) and tagged *generic group model*. GGM ⇒ OT is refused at
  `red-ddh-to-tdh-dgi-19` (`unstated`).
- FAC ⇒ RSA is derived with the toggle, tagged *non-standard model*. FAC ⇒
  PKE is refused at `red-rsa-to-pke-rsa78` (`unstated`).

*An approximation, stated.* For an oracle model (ROM), "relativizes" is
exactly the property needed. GGM, AGM and the generic ring model are
different: they **restrict the adversary**, and composing there needs the
step's reduction to turn a generic or algebraic adversary into a generic or
algebraic one. A fully black-box reduction that is itself generic does. The
manifest does not record that property, so CCwiki applies the same test to
every idealised model, and it says "holds in the generic group model" rather
than anything stronger (open question 2).

### R6. Chain class

The chain class of a derivation is the **first of `fully-black-box`,
`relativizing`, `free`** that every step's class implies\* (reflexively, by
the manifest's own closure). If no class qualifies, which happens exactly
when some step is `unstated`, the chain class is `unstated`.

| Chain class | Claimed when | Why composition preserves it |
|---|---|---|
| Fully black-box | every step is fully black-box | Composing two such reductions nests the fixed constructions (`G₁` calls `G₂`, which calls the base primitive only as an oracle) and the fixed reductions (`S₂` runs `S₁`, which runs the adversary only as an oracle). The result is again one fixed construction and one fixed reduction, both oracle-only: RTV04's definition. With a conjunction, the reduction breaks one of the hypotheses, which is still black-box in each. |
| Relativizing | every step implies relativizing | ∀Π (A^Π ⇒ B^Π) and ∀Π (B^Π ⇒ C^Π) give ∀Π (A^Π ⇒ C^Π). |
| Free | every step has a class (none `unstated`) | Every class implies `free`; composing implications is an implication. |
| Unstated | some step is `unstated` | The chain is still an implication, since every non-heuristic edge is a proved theorem. CCwiki makes no class claim about it. |

CCwiki **never claims** semi-black-box, weakly-black-box or a ∀∃ class for a
chain. Whether those notions compose depends on details the manifest does not
record (the reduction may depend on the adversary's code), and BBF13 discuss
these classes' fine structure. A chain made of such steps is reported as
`free`, which only says an implication was proved. (No reduction in today's
corpus uses them: implications are 127 fully black-box, 76 unstated, 27
free.)

**The shown derivation has minimal depth, and that is not always the
strongest one.** In 55 derived pairs, a longer derivation has a stronger class.
For example, DDH ⇒ invertible PRF takes 2 steps through HPPY25 (`unstated`),
but 3 fully black-box steps through LR88. The answer then also reports the
strongest chain class over all derivations, with its depth: "A fully black-box
derivation exists in 3 steps." It is computed by rerunning the closure over
only the steps whose class implies each composable class in turn.

### R7. Forward chaining, depth and proof trees

```
closure(S, toggle):
  known := { s ↦ given | s ∈ S }
  phase 1 over default steps;  phase 2 (toggle only) over all eligible steps
  each phase, layer k = 1, 2, …:
    a step fires at layer k iff every hypothesis is known with depth < k,
      its conclusion is not known, R5 allows it,
      and (phase 2 only) it would not be clean
    each new conclusion takes the PREFERRED firing step at its first layer
    stop when a layer adds nothing and k exceeds every known depth
```

- **Depth** is the height of the tree: `1 + max(depth of hypotheses)`. A
  conjunction is as deep as its deepest branch.
- **Preferred** means the least, in order, of: the number of non-standard
  models; the chain-class rank (fully black-box, relativizing, free,
  unstated); the reduction id, compared by UTF-8 bytes; and forward before
  reverse. Every fact is fixed once assigned, so trees are consistent, and the
  answer is deterministic. The Swift port must use this exact order for the
  golden file to match.
- **Proof trees** are DAGs. Each fact appears once with its subtree. A later
  occurrence is a reference ("shown above"), never a copy. Today a non-given
  subtree is never shared from a single start; the case appears with
  conjunctive starts, such as `{sxdh, lwe, lpn, prg-in-nc0} ⇒
  deniable-encryption`, where LWE feeds both JLS21 and the OWF branch.
- **N recorded reductions** is the number of distinct reduction ids in the
  tree. An equivalence used both ways counts once.

### R8. Recorded barriers in an answer

Every answer lists the recorded barriers on the **exact hyperedge** (the
start set equals the barrier's `hypotheses`, and the target is its
`conclusion`). With a single start, it also lists those on the reverse pair.
Each shows its class, strength, `conditionalOn`, consequences and
`circumventedBy`, exactly as the inspector does (relations.md §3a).

When the target *is* derived, a barrier on the pair is context, not a
contradiction, unless the chain class implies\* the barrier's class. That
would mean the record is inconsistent, so CCwiki would show it as a conflict.
The corpus test asserts it never happens, and on this manifest it does not.
OIHF ⇒ OT is derived (`free`, BH26) beside `bar-oihf-to-ot-bh26`
(`fully-black-box`), which the barrier itself lists as circumvented.

### R9. Hosts and variants

CCwiki never infers host ⇔ variant edges. A variant is a section of a page,
and the manifest has no edge between `lpn` and its noise regimes, or between
`pke` and `pke-cca2-security`. Recorded edges between them (`rabin-ot ⇔ ot`)
are used like any other. A no-path answer adds four hints, each labelled
*related by the page, not by a recorded reduction*:

| Hint | Example on this manifest |
|---|---|
| Sections of the **target** that are derived | anything ⇒ Hash function: no derivation, but its section *Preimage resistance (one-wayness)* (`owf`) is. Over single starts the hint applies to 229 (start, section) pairs |
| The **target's host** is derived | LWE ⇒ Ring LWE: no derivation; Ring LWE is a section of the LWE page |
| Sections of a **start** that derive the target | LPN ⇒ PKE: no derivation; *Low-noise LPN* and *Mid-noise LPN* each do |
| The **host of a start** derives the target | (none in the golden set; computed the same way) |

### R10. The no-path answer

In this order:

1. **Recorded barriers** on the pair and its reverse (R8).
2. **Derived barriers** (R12), not covered by a recorded one. Redundant
   ones appear only under *Show reasoning*.
3. **With idealised models included**: when the toggle is off and turning it
   on would derive the target, say so with the model tags. FAC ⇒ RSA:
   "derivable in a non-standard model (DLO24)".
4. **Refused steps** (R5, toggle on): the steps the composition rule
   refused on the derivation that plain closure would have used.
5. **Host and variant hints** (R9).
6. **Completions**: *becomes derivable if you also assume Z*, for a single
   object `Z`:
   - `Z` is a `primitive` or `assumption`, not a model node, and not already
     derived from the start;
   - `Z` alone does **not** derive the target (that belongs in *implied by*,
     R11), and `start ∪ {Z}` does;
   - only the weakest are kept: drop `Z` when another completion `Z′`
     follows from `Z` and `Z` does not follow from `Z′`;
   - sorted by depth, then number of non-standard models, then chain class,
     then tree size, then id; at most 8, with the total.
7. **The footer**, fixed text:

   > CCwiki found no derivation from the reductions the wiki records. This is
   > not a separation: the record is incomplete, and only the barriers listed
   > here are results.

### R11. Everything implying X (backward closure)

- **Single objects**: every `A` (not a class, not a model node) whose closure
  contains `X`, with depth and model tags. This is exact, read from the
  single-object closures.
- **Minimal pairs** `{A, B}` that derive `X` when neither does alone. A pair
  derives more than its halves only if some conjunctive step has all its
  hypotheses in `cl(A) ∪ cl(B)` and in neither alone. So the candidates come
  from the conjunctive steps, and each is verified with a real closure. This
  is exact for pairs under the default filter. With the toggle on, a pair
  whose only gain is turning a model-scoped fact into a clean one can be
  missed; it is labelled so.
- **Grouped by the conjunctive edge where the two halves meet**: the
  conjunctive step nearest the root whose hypotheses neither half derives
  alone. A group is shown as the edge's hypotheses with each side's sources,
  not as a flat list. Larger conjunctions (JLS21 has four hypotheses) are
  shown as the edge itself, not enumerated.
- Caps: 40 single rows and 12 pairs per group, with totals.

PKE, default filter: **29 single objects; 43 minimal pairs in 5 groups**. SW14
`{owf, io}` has 24 pairs, CS03 `{kem, ske}` 16, and WEE22 and GHJS25 (two
edges) 1 each. NIZK has 10 single objects and 120 pairs: 90 through SW14 and
30 through KMY20. This is why the list is grouped.

### R12. Derived barriers

A barrier says `(∃ a class-C reduction {X} ⇒ Y) ⇒ Q`. If `X ⇒* A′` and
`B′ ⇒* Y` by reductions of class C, then a class-C reduction `A′ ⇒ B′` would
compose into a class-C reduction `X ⇒ Y`. So the same consequence `Q`
follows: **`(∃ class-C A′ ⇒ B′) ⇒ Q`**.

This is sound only when every condition below holds, and CCwiki emits a
derived barrier only then:

- **The barrier has one hypothesis**, and **each consequence is propagated
  at its own class** `C ∈ {fully-black-box, relativizing, free}`, the classes
  closed under composition (R6). Semi- and weakly-black-box, ∀∃,
  `fixed-construction` (it names one construction; composing changes the
  construction) and `unstated` are never propagated.
- **Side edges** are single-hypothesis, non-heuristic, not stubs, have a
  class that implies\* C, and are **standard-model only**. This is stricter
  than the brief's "default models", and it has to be. A barrier is a
  statement about plain-model reductions. Composing it with a quantum
  reduction (Reg05) or a CRS-model one gives a quantum or CRS-model reduction
  `X ⇒ Y`, which the barrier does not rule out. The contradiction would be
  lost.
- **Every node on the side chains**, both endpoints included, is a
  `primitive`. Without this rule the procedure emits category errors such as
  "no relativizing reduction from OWF to LWE". A black-box reduction *to* a
  fixed hardness assumption is not what the barrier quantifies over.
- The derived barrier inherits `strength`, `conditionalOn` and
  `circumventedBy` from its barrier. A circumventing reduction is shown with
  its own hyperedge.
- It is **redundant** when a recorded barrier on the same pair has a class
  that the derived class implies\*, because that barrier already rules out at
  least as much.

Soundness rests on the side edges' class labels: IL89's PKE ⇒ OWF must
really be fully black-box. That is why every derived barrier names its
barrier and each side reduction, and why none appears as a row in the
inspector's Barriers group. They appear only inside a no-path answer, labelled
*derived by CCwiki*.

On this manifest: **451 derived records, 297 primitive pairs, 295 of them not
recorded, from 9 barriers.** IR89 (OWP ⇏ KE) accounts for 164, GKM+00
OWF ⇏ PKE for 111, and GKM+00 PKE ⇏ OT for 89. Corpus check: no derived
barrier is contradicted by a recorded reduction on its pair.

---

## 3. Data structures and API (Swift sketch)

A pure value type in `Sources/CCwiki/Wiki/Derivation.swift`, built once from a
`RelationsManifest`, `Sendable`, with no UI and no I/O, like `PageRelations`.
It has no API that returns an object pair. A step carries its whole
hypothesis list.

```swift
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
        let reductionClass: String                 // effective (R3)
        let isStub: Bool
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
    }

    struct Closure: Sendable {
        let start: Set<String>
        let options: Options
        let facts: [String: Fact]
        let refused: [Step]                        // R5, for explanations
        func proof(of id: String) -> ProofTree?
    }

    struct ProofTree: Sendable {
        struct Row: Sendable, Identifiable { let id: Int; let objectID: String;
            let level: Int; let step: Step?; let isReference: Bool }
        let rows: [Row]                            // depth-first, R7
        var relationIDs: [String]                  // the "N recorded reductions"
    }

    enum Answer: Sendable {
        case unsupported(reason: String)           // R2
        case derived(DerivedAnswer)                // tree, depth, models,
                                                   // chain class, strongest (R6),
                                                   // barriers on the pair (R8)
        case notDerived(NoPathAnswer)              // R10, in its order
    }

    init(manifest: RelationsManifest)
    func closure(from start: Set<String>, options: Options) -> Closure
    func answer(from start: Set<String>, to target: String, options: Options) -> Answer
    func implying(_ target: String, options: Options) -> BackwardClosure   // R11
    let derivedBarriers: [DerivedBarrier]                                  // R12
}
```

- **Built where the manifest is.** `AppModel.loadLibrary()` loads the manifest
  after every sync, and the `Derivation` is built in the same place and
  precomputes the single-object closures for both options. The inspector's
  transitive groups and R11's single rows are then lookups.
- **The proof tree's rows are already flat**, so the explorer can draw them as
  an outline without recursion in a view body (`SWIFTUI-RULES.md`).
- `PageRelations` stays the recorded view. The inspector's derived groups are
  a separate type built from a `Derivation`, so recorded and derived rows can
  never mix.

## 4. Complexity and timing

Let E = 239 directed steps, H = 267 hypothesis occurrences, V = 234
non-class objects, and L ≤ 10 layers (the maximum default depth is 9).

| Operation | Cost | Python reference, this manifest |
|---|---|---|
| Build steps | O(E) | 0.7 ms |
| One closure (layered) | O(L · H) | 0.4 ms |
| All single-object closures, both options | O(V · L · H) | 211 ms for 468 |
| Answer with completions (no path) | O(V · L · H) | 75–130 ms (OWF ⇒ PKE, PKE ⇒ OT) |
| Answer, derivable | O(L · H) per class tried (R6) | 1–4 ms (DDH ⇒ iPRF, DDH ⇒ OT) |
| Derived barriers, all | O(barriers · E) | 2 ms |
| Implied-by PKE | candidate pairs × closure | 125 ms cold, 77 ms warm |
| Whole golden file | — | 3.1 s |

These are CPython timings on the Linux container; nothing was compiled here.
A Swift port of the same loops should be at least an order of magnitude
faster. That is an expectation, not a measurement. Precompute at load, off the
main actor. A query runs on demand, and only a no-path answer's completions
cost more than a millisecond or so. A counter-based Horn closure
(Dowling–Gallier) would make one closure linear, but the layering that defines
depth would have to be rebuilt on top of it. It is not worth it at this size.

---

## 5. Results on the real manifest

Wiki `ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157`, `relations.json` SHA-256
`b0c3fb65…c0e3ee`.

**Eligibility.** 283 reductions → 239 directed steps (7 reverse). Excluded:
45 inclusions, 2 heuristic, 4 with a complexity-class endpoint. By model, the
eligible steps are standard 192, ROM 22, CRS 7, generic group 7, quantum 5,
algebraic group 3, other 2 (both directions of DLO24), and unknown 1 (the
stub). Default: 204.

**Closures.** 234 objects can start a query, and 120 derive something. Over
all single starts there are 1,084 derived (start, target) pairs: chain class
fully black-box 593, unstated 473, free 18. Model tags: none 983, quantum
91, CRS 8, both 2. Depth: 1→180, 2→225, 3→205, 4→189, 5→148, 6→89, 7→33,
8→9, 9→6. With the toggle there are 1,286 pairs, 202 of them model-scoped. 36
objects gain facts with the toggle.

| Object | Default | With toggle | Max depth (default) | Note |
|---|---|---|---|---|
| GapSVP / SIVP | 34 | 37 | 6 | quantum (Reg05) |
| DDH | 33 | 37 | 5 | +Schnorr, PCS, vector commitment (ROM), BLS (AGM) |
| LWE | 29 | 29 | 5 | OT at depth 3; not Ring LWE, not ABE |
| DCR | 29 | 31 | 5 | |
| RSA | 23 | 29 | 5 | +6, all ROM (FOPS01 and the CCA KEM) |
| TDP | 21 | 21 | 4 | |
| DLOG | 19 | 24 | 4 | +CDH, BLS (AGM); Schnorr, PCS, vector commitment (ROM) |
| PKE | 19 | 19 | 4 | includes OWF (IL89) |
| OWP | 16 | 16 | 4 | |
| FAC | 16 | 17 | 5 | +RSA only (R5 stops the rest) |
| OWF | 15 | 15 | 3 | no PKE, KE, OT, CRHF |
| SIS | 3 | 20 | 2 | +17, all through the ROM signature edge (depth 6 with the toggle) |
| OT | 4 | 4 | 1 | COM, MPC, Rabin OT, OIHF; not OWF (record gap) |
| ROM | 0 | 2 | — | OIHF, Merkle puzzles (depth 1) |
| GGM | 0 | 29 | — | Sho97's DDH, CDH, DLOG, KEA and their fully black-box consequences (depth 4) |
| AGM | 0 | 1 | — | KEA (depth 1) |

**Backward.** PKE: 29 single sources, 43 minimal pairs (above). OT: 22 single
sources, no pairs. No conjunctive edge reaches OT.

**Invariants**, all true: no ineligible edge is ever used; default results
carry no idealised model; no chain contradicts a recorded barrier on its
pair; ROM reaches neither OT nor KE in either mode; no derived barrier is
contradicted by a recorded reduction.

## 6. Worked examples

All are the reference script's output (`--query`); all but two (LWE ⇒ OT and
OWF ⇒ PKE with the toggle) are records in the golden file.

- **DDH ⇒ OT: derived, 3 steps, unstated, standard model.** OT ⇐ cPIR (DMO00)
  ⇐ TDH (AMR25) ⇐ DDH (DGI+19). Every step is `unstated`, so the chain is.
  LWE takes the same route through `red-lwe-to-tdh-dgi-19`.
- **{OWF, KEM} ⇒ PKE: derived, 4 steps, fully black-box.** PKE ⇐ KEM ∧ SKE
  (CS03), SKE ⇐ PRF (folklore) ⇐ PRG (GGM86) ⇐ OWF (HILL99). The tree shows the
  conjunction node with KEM as given and SKE's branch below it.
- **{OWF, iO} ⇒ PKE: derived, 1 step, free.** SW14 obfuscates a circuit
  containing the code of a PRF built from the OWF, so it is not black-box in
  the OWF (its `rationale.class`).
- **OWF ⇒ PKE: no derivation.**
  - Recorded barrier: `bar-hash-function-to-pke-gkm-00` (relativizing,
    unconditional).
  - Derived barrier: IR89's OWP ⇏ KE through OWP ⇒ OWF and PKE ⇒ KE, the
    wiki's own hand derivation (`content/Barriers/no-owp-to-ke-ir89.md:34`).
    It is redundant with the recorded barrier, so it appears only under *Show
    reasoning*.
  - Completions (2): **iO** (1 step, SW14, free) and **KEM** (4 steps, CS03,
    fully black-box).
  - The same answer with the toggle on.
- **PKE ⇒ OT: no derivation.** Recorded `bar-pke-to-ot-gkm-00`; reverse
  `bar-ot-to-pke-gkm-00`; no completions (no conjunctive edge reaches OT).
- **FAC ⇒ PKE.**
  - Default: no derivation. Completions are iO (3 steps) and KEM (6 steps),
    both through FAC ⇒ DS (GMR88) ⇒ OWF.
  - Toggle on: still no derivation. FAC ⇒ RSA is derived (reverse of DLO24,
    tagged non-standard model), but RSA ⇒ PKE (RSA78, `unstated`) is refused
    after it. The answer names that step.
- **ROM ⇒ OT.**
  - Default: the model-start message.
  - Toggle on: no derivation, with `red-oihf-to-ot-bh26` named as the refused
    step: "OIHF holds here only in the random oracle model, and BH26's OIHF ⇒
    OT is non-black-box." ROM ⇒ MPC gives the same answer.
- **DLOG ⇒ CDH.** Default: no derivation, "derivable with idealised models
  included (algebraic group model)". Toggle on: derived, 1 step, tagged AGM.
  CDH ⇒ DLOG is derived in the standard model.
- **GapSVP ⇒ PKE: derived, 2 steps, fully black-box, tagged quantum.**
- **LPN ⇒ PKE: no derivation; Low-noise and Mid-noise LPN (sections of LPN)
  each do.**
- **DDH ⇒ invertible PRF: 2 steps, unstated**; "a fully black-box derivation
  exists in 3 steps" (NR97, LR88, PRP ⇒ iPRF).
- **DLOG ⇒ BQP: unsupported** (R2).

---

## 7. UI wording rules

These apply in the explorer window, in the inspector's derived groups and
anywhere else a derived claim appears.

- **Label every derived claim.** Use exactly "Derived by CCwiki from N
  recorded reductions" ("1 recorded reduction"). Never write a derived claim
  as the wiki's: no bare "A implies B", and no "the wiki shows".
- **Derived rows look different** from recorded ones. They sit under a
  *Derived* header, in secondary style, with a depth badge ("3 steps"). Model
  tags appear only when the chain is not standard-model alone. A derived row
  opens the proof tree, not a reduction page.
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

  If a stronger chain exists, add "A fully black-box derivation exists in K
  steps" with a button to show it.
- **No path.** Write "No derivation found". Never write "A does not imply B",
  "separated", "impossible" or "no reduction exists". The fixed footer (R10)
  is always shown and cannot be collapsed.
- **Derived barriers show their argument, not just their conclusion.** For
  example: "A relativizing reduction from OWF to CRHF would compose with OWP ⇒
  OWF (fully black-box) into one from OWP to CRHF, which Sim98 rules out.
  Derived by CCwiki." The barrier and each side reduction are links.
- **Refused steps (R5)** say what is missing. For example: "Not derived: OIHF
  holds here only in the random oracle model, and OIHF ⇒ OT (BH26) is a free
  (non-black-box) step, which need not carry over into that model." For an
  unstated step: "…whose class the wiki does not state, so CCwiki cannot tell
  whether it carries over."
- **Hints (R9)** say "related by the page, not by a recorded reduction".
- **Completions** read "Becomes derivable if you also assume: iO (1 step) ·
  KEM (4 steps)". Never call one a *missing assumption*.
- **The toggle** is "Include idealised models", with help text naming the
  random oracle, generic group, algebraic group and other non-standard models.
  It is off by default, per window, and not remembered across launches.
- **The backward header** is "Everything the wiki's reductions derive this
  from", with help text "Derived by CCwiki. The wiki's record is incomplete."
- **Link previews** show only recorded data: a page's title and first
  paragraph, or a reduction's or barrier's full hyperedge with its class,
  model and source. A preview never shows a derived claim.

---

## 8. Testing

**The golden file.** `Tests/CCwikiTests/Fixtures/derivations-golden.json` is
written by
`scripts/derivations_reference.py RELATIONS_JSON --golden … --wiki-commit SHA`.
It records the wiki commit, the manifest's SHA-256, its counts, the policy
constants, closure sizes for 12 objects, backward summaries for PKE and OT,
the invariants by name, and **40 query records** that pin every rule. Each
record holds the start, target and toggle, and the expected answer:
*supported*, *derivable*, depth, models, model-scoped, chain class, the sorted
edge ids of the tree, reverse steps, the strongest class when it differs,
recorded and reverse barrier ids, non-redundant derived barrier ids, the top 5
completions with their total, refused steps, host/variant hints, and the
toggle hint.

**The corpus test** (`DerivationTests`, gated on `CCWIKI_WIKI` like
`RelationsTests`) reads the golden file through `#filePath`, as
`ChangelogTests` reads `CHANGELOG.md`. `Package.swift` excludes
`Fixtures/` from the test target so SwiftPM does not warn about an unhandled
file. The test has three outcomes:

1. **Exact.** The SHA-256 of the clone's `relations.json` equals
   `manifestSHA256`. The test asserts every record field by field, plus the
   closure sizes and backward summaries. The manifest has no timestamp, so an
   unchanged wiki gives the same bytes. The hash is therefore a more precise
   key than the commit, which moves on any content edit.
2. **Drifted, within tolerance.** The hash differs, but objects, reductions and
   barriers are each within ±10% of `counts`. The test asserts the invariants,
   recomputed on the current manifest, and each record's `stable` fields, such
   as ROM ⇒ OT being refused or OWF ⇒ PKE not being derived. Records naming an
   object that no longer exists are skipped. This is the usual state in CI,
   which clones the wiki at HEAD.
3. **Drifted beyond tolerance.** Skip, and print the golden commit and counts
   beside the clone's, with "regenerate with
   scripts/derivations_reference.py". Use `.enabled(if:)` so the skip is
   visible rather than a silent pass.

A unit test without a clone covers each rule on a small fixture manifest,
mirroring `RelationsTests`. Fixtures to include: a conjunction that must not
fire on one hypothesis; an equivalence used in reverse; an inclusion and a
heuristic edge that never fire; a `{rom} ⇒ X` edge mis-typed `standard`; a
free step after a ROM step; and a barrier with a quantum side edge that R12
must not propagate.

---

## 9. Open questions

1. **Upstream classing would unlock most refused facts.** The unstated
   steps R5 refuses most often are OWF ⇒ SK-PIR (BM26), ZKP ⇒ auxiliary-input
   OWF, PRF ⇒ iPRF (HPPY25), RSA ⇒ TDP/PKE/OAEP (RSA78, FOPS01), DLOG ⇒
   BLS/CDH (FKL18), Pedersen VSS, and DDH ⇒ TDH (DGI+19). Recording a class for those, or a
   `rationale.class` saying why it stays unstated, would turn refusals into
   derivations or into settled answers. That is worth asking upstream.
2. **Adversary-restricted models.** R5 uses "relativizes" for GGM, AGM and
   the generic ring model too, where the precise condition is that the
   reduction maps generic or algebraic adversaries to generic or algebraic
   ones. Should CCwiki stay with one rule (simple, and conservative for the
   ROM), or ask upstream for a per-edge "generic reduction" flag?
3. **Equivalence classes.** One `class` covers both directions of an
   equivalence. For DLO24 the hard direction is FAC ⇒ RSA and the easy one is
   RSA78's. Is that the wiki's intent?
4. **`model: other` on DLO24.** CCwiki treats `other` as idealised for R5.
   Should the wiki name the generic ring model as a model (with its own
   `MODEL_PAGES` entry)?
5. **"Free" as a chain class.** It is sound, but readers may read "free" as
   something stronger than "an implication". The wording in §7 avoids the bare
   word. Should the chain row omit the class instead?
6. **Completion types.** Completions are limited to primitives and
   assumptions. `bilinear-pairing` (a glossary node, the algebraic setting)
   would sometimes be a sensible thing to "add". Include settings?
7. **Derived barriers in the inspector.** They are kept out of the
   Barriers group by design (R12). The OWF page could carry a one-line
   "N barriers follow from recorded ones" link into the explorer. Wanted?
