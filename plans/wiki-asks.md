# Wiki asks: what the wiki could record so CCwiki's curation can go

**Written 2026-10-12 against wiki `ab81f02`**, the commit the curation and
the golden file were reviewed against. Spec:
[relations-followups.md](relations-followups.md) §4. Every count below was
computed with `scripts/derivations_reference.py` on that commit.

CCwiki derives relations by chaining the reductions in the wiki's
`relations.json` ([derivations.md](derivations.md)). Where the manifest does
not record something a Statement says, CCwiki keeps a reviewed correction in
`Resources/derivation-curation.json`: 42 entries, each quoting the page it
rests on ([curation-review.md](curation-review.md)). Each entry is a thing
the wiki could record itself. These ten asks say how, page by page, and what
each would let CCwiki drop.

The asks prefer **variant nodes to new fields**: the wiki already has
variants, and its own review queue is moving that way
(`ffr:node-granularity-3`, `ffr:node-granularity-11`). Three asks do need new
fields (`reverse-class`, `refuted-by`, a barrier `model`); CCwiki decodes
all three now, so it is ready the day the wiki ships them.

## How to apply them

CCwiki and its agents never write to the wiki. The maintainer files the asks:

1. **The content asks** (4–10) go through the wiki's review pipeline. Copy
   [`wiki-asks.inbox.json`](wiki-asks.inbox.json) to the wiki's
   `.review/inbox/` on `main`, for example as
   `.review/inbox/ccwiki-derivations-2026-10.json`, and run
   `node scripts/review/round.mjs inbox` there. That check is the authority
   on the file's shape; CCwiki's `--selftest-units` only catches what would
   make it fail. The next monthly round verifies each item with its two
   adversarial verifiers and proposes it on the review page.
2. **The three schema asks** (1–3) change the wiki's scripts, so they are
   better as one ordinary pull request in the wiki repository. Their items
   are in the JSON too, so the round can see they exist.

The file holds one object `{"source", "items"}`. Each item has `id` (prefix
`ccw:`), `kind` (one of the wiki's `INBOX_KINDS`), `summary`, `pages` (a
page the change creates ends ` (new)`), `proposed_action`, and `rationale`,
`related`, `needs_paper` and `confidence` where they apply. Nothing else: any
other key makes the wiki reject the file. An item's `rationale` names the
curation entries it retires ("Retires CCwiki's curation entries …"), and
`--selftest-units` checks that each one exists.

## What the wiki's own queue already covers

The wiki's inbox (`final-form-2026-10-04.json`) and round 2's open paper items
already cover several of these. The CCwiki items do not repeat them; they
name them in `related`.

| Wiki item | Covers |
|---|---|
| `ffr:schema-convention-10` | a machine-readable refutation marker; ask 2 picks its option B |
| `ffr:schema-convention-9` | how a barrier between models is typed; ask 3 |
| `ffr:schema-convention-14` | honest-majority "settings" as edges from a secure-channels node; CCwiki's two `settings` entries |
| `ffr:verification-gap-8` | ISIS ⇔ SIS's unproved direction; the `equivalences` and `requires` entries on that edge |
| `ffr:node-granularity-3` | YZW+19 on a new `subexponential-lpn-above-half` variant; ask 6 |
| `ffr:node-granularity-11` | AMR25 on a quasi-polynomial low-noise LPN variant; ask 6 |
| `ffr:missing-edge-4` | a KP-ABE adaptive node; ask 5 |
| `ffr:content-error-26`, `ffr:verification-gap-29` | Kil88's OT ⇒ MPC and OT ⇒ COM Statements; ask 4 |
| `fu2:node-granularity-12`, `fu2:node-granularity-13` (round 2, paper section) | Wee22's dropped LWE conjunct; BW07's composite-order hypotheses: the 3 `quarantine` entries |

## The asks

Entry ids are the curation's (relations-followups.md §2.2), such as
`requires:red-dlog-to-prg-bm84:dlog`. "Retires" names the entries a change
makes redundant.

### Ask 1. `reverse-class` on every equivalence

`ccw:schema-reverse-class`, kind `schema-convention`.

- **Need.** An equivalence's two directions can be different theorems
  (derivations.md R1). CCwiki keeps a table of all 7 eligible equivalences
  saying which direction the record's `class` covers. An optional field
  could not replace it: an absent field reads the same as a manifest from
  before the field existed, so the field is **required** on equivalences.
- **Change.** `reverse-class`, the class of conclusion ⇒ hypothesis, required
  on reduction pages with `kind: equivalence`.
  - `scripts/generate-relations.mjs`, in the `reductions.push` record after
    `class`:
    `...(p.fm.kind === "equivalence" ? { reverseClass: p.fm["reverse-class"] ?? "unstated" } : {})`.
  - `scripts/lint.mjs` and `scripts/lint-edges.mjs`: add `"reverse-class"`
    to `OPTIONAL_KEYS` and `EDGE_FRONTMATTER`; error
    `edge-reverse-class-missing` on an equivalence without it; error
    `edge-reverse-class` on any other kind; the value is a class or
    `unstated`; `RATIONALE_FIELDS.reduction["reverse-class"] = "reverseClass"`;
    the contradiction check reads `reverse-class` for a barrier on the
    reverse pair.
  - Docs: `docs/relations-json.md` § `reductions`, and `schema/README.md`
    § What the hyperedge asserts.
- **Pages: the 8 equivalences**, with CCwiki's reading of each:

  | Page | `class` | `reverse-class` |
  |---|---|---|
  | `cpa-security-to-cpa-security.md` | fully-black-box | fully-black-box |
  | `linear-secret-sharing-schemes-lsss-to-msp.md` | free | free |
  | `module-lwe-to-lwe-ls15.md` | fully-black-box | fully-black-box |
  | `module-lwe-to-ring-lwe-ls15.md` | fully-black-box | fully-black-box |
  | `rabin-ot-to-ot.md` | fully-black-box | fully-black-box |
  | `qip-to-pspace.md` | free | free |
  | `isis-inhomogeneous-sis-to-sis.md` | `unstated` (was fully-black-box) | fully-black-box; unless `ffr:verification-gap-8` splits the page first |
  | `rsa-to-fac-dlo24.md` | see below | |

  `rsa-to-fac-dlo24.md`'s directions differ in **model**, which no class
  field can say: RSA ⇒ FAC is trivial in the standard model, and FAC ⇒ RSA
  is DLO24's generic-ring theorem. Split it: the trivial direction is already
  recorded on its own page, `fac-to-rsa-rsa78.md` (`red-rsa-to-fac-rsa78`,
  standard, fully black-box), so `rsa-to-fac-dlo24.md` becomes the
  implication `{fac} ⇒ rsa` with `model: other` and `class: free`. It states a
  reversed theorem, so per the stability contract it retires
  `red-rsa-to-fac-dlo24` and takes `red-fac-to-rsa-dlo24`, and the page can
  be renamed `fac-to-rsa-dlo24.md`. (relations-followups.md §4.2 proposed a
  new `red-rsa-to-fac` folklore page for the trivial direction; RSA78's page
  already records it.)
- **Related.** `ffr:verification-gap-8`.
- **Retires** the 7 `equivalences:` entries: 6 by the field, DLO24's by the
  split.
- **How CCwiki takes it in.** It decodes `Relation.reverseClass` now (nil
  when absent). An equivalence with the field takes `class` forward and
  `reverseClass` backward, and CCwiki's table is ignored for it; an absent
  field keeps today's behaviour, as an older manifest needs. A stub is still
  unstated both ways. The golden sentinel `curationSuperseded` warns about
  each table entry the manifest now covers; DLO24's entry fails
  `curationResolves` once its id is retired.

### Ask 2. `refuted-by` on objects and variants

`ccw:schema-refuted-by`, kind `schema-convention`.

- **Need.** CCwiki marks circular evasive LWE, SIDH and SSDDH as false
  (derivations.md R14): an answer from one of them holds but is vacuous. The
  wiki states this in prose only (`learning-with-errors.md:113`, `:272`;
  `supersingular-isogeny-diffie-hellman.md:16`, `:62`).
- **Change.** An optional `refuted-by`, a list of reference wikilinks. This
  is option B of `ffr:schema-convention-10`, per formulation:
  - On an object page it marks the page's own object only, never its
    variants, so CSIDH on the SIDH page stays unmarked.
  - In a variant's mapping form, beside `anchor` and `formal`.
  - A family in which only some formulations are false gets no marker on its
    host. Private-coin evasive LWE, of which "Several private-coin
    formulations are false" (`learning-with-errors.md:268`), stays unmarked.
  - `scripts/generate-relations.mjs`: for the page object,
    `...(p.fm["refuted-by"] ? { refutedBy: [].concat(p.fm["refuted-by"]) } : {})`;
    for a variant,
    `...(typeof v === "object" && v?.["refuted-by"] ? { refutedBy: [].concat(v["refuted-by"]) } : {})`.
    Both are omitted when empty, as `formal` is.
  - `scripts/lint.mjs`: add `"refuted-by"` to `OPTIONAL_KEYS`, with an error
    unless the page is an object page; the variants loop (around line 536,
    which today checks only `anchor`) also checks a mapping's keys: `anchor`,
    `formal` and `refuted-by` only. No page uses the mapping form today, so
    this flags nothing. Each `refuted-by` entry must resolve to a reference
    page, by the `edge-source` check without the `folklore` token.
  - Docs: `docs/relations-json.md` § `objects`. In `schema/README.md`
    § Refutations are attacks, not barriers, add "…and the refuted object or
    variant carries `refuted-by`, so a consumer deriving consequences can
    mark implications from it vacuous."
- **Pages.**
  - `content/Assumptions/learning-with-errors.md`:
    `circular-evasive-lwe: {anchor: "#circular-evasive-lwe", refuted-by: ["[[AMYY25 - Evasive LWE Attacks, Variants & Obfustopia|AMYY25]]"]}`.
  - `content/Assumptions/supersingular-isogeny-diffie-hellman.md`:
    top-level `refuted-by: ["[[CD22 - An efficient key recovery attack on SIDH|CD22]]"]`,
    and `ssddh: {anchor: "#decisional-variant-ssddh", refuted-by: [same]}`.
- **Related.** `ffr:schema-convention-10`.
- **Retires** `refuted:circular-evasive-lwe`, `refuted:sidh` and
  `refuted:ssddh`.
- **How CCwiki takes it in.** It decodes `RelationObject.refutedBy` now
  (empty when absent). The engine merges each object with a non-empty
  `refutedBy` into its working curation, the manifest's record winning over
  CCwiki's, so every rule that reads refutations (backward-list sources,
  completions, the forward list's banner, the inspector) applies it. The
  verdict then reads "The hypothesis is known to be false (CD22), so this
  implication is vacuous. Its page records the attack." `curationSuperseded`
  lists the entries the manifest now covers.

### Ask 3. `model` on barriers

`ccw:schema-barrier-model`, kind `schema-convention`.

- **Need.** A barrier records no model, so CCwiki propagates a
  primitive-to-primitive barrier through side reductions as if it were
  proved in the standard model (derivations.md R12, §10). The lint already
  accepts `model` on a barrier page, but the producer drops it.
- **Change.**
  - `scripts/generate-relations.mjs`, in `barriers.push` after `class`:
    `model: p.fm.model ?? "standard",`. It is always emitted, as on
    reductions.
  - `scripts/lint-edges.mjs`: `RATIONALE_FIELDS.barrier.model = "model"`.
  - `schema/README.md` § Which model to record says today "On a barrier,
    which has no `model` field, the model's node is the hypothesis". It
    becomes: "`model` on a barrier is the model its theorem is proved in,
    `standard` by default. A barrier saying X fails in a model also keeps
    the model's node as its hypothesis."
- **Pages.**
  - `content/Barriers/no-rom-to-ke-hmo-19.md`: `model: rom`.
  - `content/Barriers/no-agm-to-ggm-kz22.md`: as `ffr:schema-convention-9`
    decides.
  - No other barrier needs one today. The oracle separations are
    `relativizing`, not idealised-model theorems.
- **Related.** `ffr:schema-convention-9`.
- **Retires** nothing. It closes the derivations.md §10 risk "Barriers have
  no model field".
- **How CCwiki takes it in.** It decodes `Barrier.model` now (`standard`
  when absent). R12 propagates only standard-model barriers; every barrier is
  still checked for conflicts, and a non-standard one says its model in the
  explorer and the inspector.

### Ask 4. Malicious OT as a node

`ccw:node-malicious-ot`, kind `node-granularity`.

- **Need.** Kil88's OT ⇒ MPC and OT ⇒ COM instantiate an ideal OT, secure
  against malicious parties, but their hypothesis is the `ot` node, whose
  definitions are semi-honest (`oblivious-transfer.md:107`). So CCwiki
  requires malicious OT of both, met only by DMO00 (cPIR ⇒ OT), whose
  Statement says single-server PIR "is therefore complete for secure two-party
  and multi-party computation". Without that, ETDP ⇒ MPC would be derived
  through EGL's semi-honest OT.
- **Change.**
  - `ot-to-mpc-kil88.md` and `ot-to-com.md`: `hypotheses: [malicious-ot-security]`.
    The variant exists on `oblivious-transfer.md#malicious-security`.
  - `cpir-to-ot-dmo00.md`: `conclusion: malicious-ot-security`. Its
    Statement already says single-server PIR is complete for secure
    computation.
  - A new folklore page `malicious-ot-security-to-ot.md`:
    `{malicious-ot-security} ⇒ ot`, `class: fully-black-box`, rationale "the
    identity map; a protocol secure against malicious parties is secure
    against semi-honest ones". The verifiers should confirm this holds for
    the OT page's definitions.
  - Ids stay: this is node refinement on the same theorem.
- **Effect,** checked by patching the manifest: every answer survives under
  the variant's name (`malicious-ot-security ⇒* MPC`, and DDH ⇒* MPC through
  DMO00), and OT ⇒ MPC and OT ⇒ COM "assuming malicious OT" become hints
  ("its section Malicious Security derives the target", derivations.md R9).
- **Related.** `ffr:content-error-26`, `ffr:verification-gap-29`.
- **Retires** `requires:red-ot-to-mpc-kil88:ot` and `requires:red-ot-to-com:ot`.
- **How CCwiki takes it in.** Nothing to decode. The entries then fail
  `curationResolves` (the hypothesis `ot` is gone from both edges), and
  `curationEdgesUnchanged` names DMO00's changed conclusion: re-review, then
  delete the entries.

### Ask 5. Weakened conclusions as nodes

`ccw:node-weakened-conclusions`, kind `node-granularity`.

- **Need.** Two Statements prove less than their conclusion node defines,
  and CCwiki keeps their facts apart: GPSW06 gives selectively secure
  KP-ABE, and PRP ⇒ iPRF gives the forward-oracle game only.
- **Change.**
  - **GPSW06.** `bdh-to-abe-gpsw06.md`: `conclusion: abe-selective-security`.
    The patched manifest gives the same pair under the variant's name: 1
    lost, 1 gained.
  - **PRP ⇒ invertible PRF.** On `pseudorandom-function.md`, a new heading
    for the forward-game notion with the variant `invertible-prf-forward`.
    `prp-to-invertible-prf.md`: `conclusion: invertible-prf-forward`. Two
    folklore pages: `{invertible-prf} ⇒ invertible-prf-forward` (the strong
    game implies the forward one) and `{invertible-prf-forward} ⇒ prf` (the
    forward game is the PRF game: `Plain iPRF security is
    $\Game^{\mathrm{prf}}$ itself`, says `invertible-prfs-to-prf.md`).
- **Related.** `ffr:missing-edge-4`.
- **Retires** `weakens:red-bdh-to-abe-gpsw06` and
  `weakens:red-prp-to-invertible-prf`.
- **How CCwiki takes it in.** Nothing to decode. `curationEdgesUnchanged`
  fails on the changed conclusions under kept ids: re-review, then delete
  the entries.

### Ask 6. Hypotheses on regime and notion variants

`ccw:node-hypothesis-regimes`, kind `node-granularity`, `needs_paper` for
the rows marked so.

- **Need.** A Statement often needs more of its hypothesis than the node
  defines: a hardness regime, a group, a field. CCwiki keeps 23 `requires`
  entries for it, and refuses a chain that does not establish the stronger
  notion (derivations.md R13; BM84's alone stops 32 default derived pairs).
  Each row below re-points one hypothesis at a variant that states the
  notion; the ids stay.

| Edge page | Hypothesis now | Proposed node | Exists? | Retires |
|---|---|---|---|---|
| `dlog-to-prg-bm84.md` | `dlog` | `dlog-zp-star`, `DLOG in $\ZZ_p^*$`, a heading on `discrete-logarithm.md` | new | `requires:red-dlog-to-prg-bm84:dlog` |
| `tdp-to-nizk-bfm88.md` (FLS90) | `tdp` | `doubly-enhanced-certified-tdp` on `trapdoor-permutation.md`, beside `enhanced-trapdoor-permutation` (related `ffc:verification-gap-1`) | new | `requires:red-tdp-to-nizk-bfm88:tdp` |
| `pke-to-com.md` | `pke` | a variant for perfectly correct CPA-secure PKE with certifiable keys, on `public-key-encryption.md` | new | `requires:red-pke-to-com:pke` |
| `abe-to-be.md` | `abe` | `cp-abe-adaptive-security`; KW19's (`k-linear-assumption-to-abe-rw13.md`) and Wee25's (`succinct-lwe-to-abe-wee25.md`) conclusions likewise if their Statements are adaptive CP-ABE (`needs_paper`) | exists | `requires:red-abe-to-be:abe` |
| `subexponential-lpn-to-crhf-yzw-19.md` | `subexponential-lpn` | as `ffr:node-granularity-3` | proposed there | `requires:red-subexponential-lpn-to-crhf-yzw-19:subexponential-lpn` |
| `subexponential-lpn-to-ot-yz16.md`, `subexponential-lpn-to-pke-yz16.md`, `subexponential-lpn-to-prc-cg24.md`, `lwe-to-zero-bit-prc-cg24.md` | `subexponential-lpn` | one variant for constant-noise LPN that is 2^ω(√n)-hard, if YZ16's and CG24's regimes agree (`needs_paper`), plus a folklore edge from the above-half variant | new | the 4 YZ16 and CG24 entries |
| `noise-level-to-tdh-amr25.md` | `lpn-low-noise` | as `ffr:node-granularity-11` | proposed there | `requires:red-noise-level-to-tdh-amr25:lpn-low-noise` |
| `lwe-to-leveled-fully-homomorphic-encryption-bgv12.md` | `lwe` | an LWE variant with modulus-to-noise ratio exponential in the depth, which Pei09 concludes (ask 9) | new | `requires:red-lwe-to-leveled-fully-homomorphic-encryption-bgv12:lwe` |
| `fe-to-io.md` | `functional-encryption` | a variant for single-key, sub-exponentially secure, weakly compact public-key FE, on `functional-encryption.md` | new | `requires:red-fe-to-io:functional-encryption` |
| `ddh-and-lpn-and-lwe-and-nc1-prg-to-io-jls21.md` | `sxdh`, `lwe`, `lpn`, `prg-in-nc0` | sub-exponential variants of each, with LPN over ℤ_p. The shared prime p stays in the Statement | new | 3 of the 4 entries |

- The 4 YZ16 and CG24 entries are
  `requires:red-subexponential-lpn-to-ot-yz16:subexponential-lpn`,
  `requires:red-subexponential-lpn-to-pke-yz16:subexponential-lpn`,
  `requires:red-subexponential-lpn-to-prc-cg24:subexponential-lpn` and
  `requires:red-lwe-to-zero-bit-prc-cg24:subexponential-lpn`.
- JLS21's: the variants retire
  `requires:red-ddh-and-lpn-and-lwe-and-nc1-prg-to-io-jls21:sxdh`,
  `…:lpn` and `…:prg-in-nc0`. CCwiki keeps one entry, re-keyed to the new
  LWE hypothesis, for the prime p that SXDH's group, LWE and LPN share: no
  node can say that.
- **Not asked:** Wat09's IBE and HIBE need DBDH and DLIN in **one** group.
  No node can say that either, so CCwiki keeps its four entries.
- **Related.** `ffr:node-granularity-3`, `ffr:node-granularity-11`,
  `ffc:verification-gap-1`.
- **Retires** 15 `requires` entries, as the table says.
- **How CCwiki takes it in.** Nothing to decode. Each re-pointed entry
  fails `curationResolves` (its hypothesis is gone from its edge):
  re-review, then delete it.

### Ask 7. CS03's DEM

`ccw:node-cs03-one-time-dem`, kind `node-granularity`.

- **Need.** The KEM + SKE ⇒ PKE Statement says "a one-time-secure SKE (the
  DEM)", but the hypothesis is the whole `ske` node. So KEM alone never
  gives PKE: the 15 pairs under CS03 in the backward list are a record gap
  (derivations.md R11).
- **Change.**
  - Add the heading "One-time security" on `symmetric-key-encryption.md`,
    with the variant `ske-one-time`.
  - `kem-and-ske-to-pke.md`: `hypotheses: [kem, ske-one-time]` (refinement;
    the id stays).
  - Two folklore pages: `{ske} ⇒ ske-one-time` and `{prg} ⇒ ske-one-time`
    (a pseudorandom pad; encrypt-then-MAC with a one-time MAC for the CCA
    notion).
- **Effect.** With ask 8's KEM ⇒ OWF, KEM derives PKE.
- **Retires** no entry; it adds answers.
- **How CCwiki takes it in.** Nothing to decode or retire; new derived pairs
  show as golden drift, which the corpus test's drifted mode handles.

### Ask 8. Missing X ⇒ OWF edges

`ccw:missing-edge-owf`, kind `missing-edge`, `needs_paper` where noted.

- **Need.** derivations.md §1 lists folklore and textbook X ⇒ OWF results
  the wiki does not record. Each is measured by adding it alone, as an
  unstated, standard-model, folklore implication, and counting the new
  default derived pairs (1,022 today). All 11 together add **432**; the
  counts overlap (SIS also reaches OWF through Ajt96's CRHF once CRHF ⇒ OWF
  exists).

  | Edge | Proposed source | New pairs |
  |---|---|---|
  | `{ot} ⇒ owf` | IL89 (`needs_paper`: which theorem) | 170 |
  | `{ske} ⇒ owf` | IL89 (`needs_paper`) | 104 |
  | `{com} ⇒ owf` | IL89 (`needs_paper`) | 90 |
  | `{crhf} ⇒ owf` | folklore, for a compressing family | 63 |
  | `{mac} ⇒ owf` | IL89 (`needs_paper`) | 59 |
  | `{prf} ⇒ owf` | folklore | 44 |
  | `{sis} ⇒ owf` | Ajt96 (`needs_paper`) | 32 |
  | `{dlog} ⇒ owf` | folklore: x ↦ g^x | 32 |
  | `{lpn} ⇒ owf` | folklore, or BFKL93 (`needs_paper`) | 31 |
  | `{kem} ⇒ owf` | `needs_paper`: IL89 does not treat KEMs; the verifiers find the source | 17 |
  | `{one-time-signature} ⇒ owf` | Rom90 (`needs_paper`) | 15 |

- **Pages.** Eleven new reduction pages in `content/Reductions/`. The
  reference pages for IL89, Ajt96 and Rom90 exist; BFKL93's is new.
- **Retires** no entry; it adds answers.
- **How CCwiki takes it in.** As ask 7: golden drift, nothing else.

### Ask 9. Pei09 and BLPRS13 as edges

`ccw:missing-edge-lwe-classical`, kind `missing-edge`, `needs_paper` for the
regimes.

- **Need.** Both are cited in the Notes of `gapsvp-to-lwe-reg05.md` (lines
  32–33) and recorded as no edge, so every GapSVP chain is quantum (Reg05).
- **Change.**
  - `{gapsvp} ⇒ <the LWE variant of ask 6 for large moduli>` (Pei09,
    classical, q ≥ 2^(n/2)).
  - `{gapsvp} ⇒ lwe` (BLPRS13, classical, with the dimension loss in
    `security-loss`).
  - Both `model: standard`.
- **Effect.** GapSVP ⇒ PKE loses its quantum tag. Through BGV12 re-pointed
  at the same variant (ask 6), GapSVP ⇒ leveled FHE comes back: the one R13
  refusal in derivations.md §6 that the literature resolves.
- **Related.** ask 6's BGV12 row.
- **Retires** no entry by itself; with ask 6 it is what lets BGV12's
  hypothesis be met.
- **How CCwiki takes it in.** Golden drift, as asks 7 and 8.

### Ask 10. BDOZ11's field size

`ccw:verification-gap-bdoz11-field`, kind `verification-gap`, `needs_paper`.

- **Need.** The Statement of
  `additively-homomorphic-encryption-to-mpc-with-preprocessing-bdoz11.md`
  does not say BDOZ11 needs a large plaintext field. So QR ⇒ MPC with
  preprocessing is still derived through GM84's ℤ₂ encryption
  (derivations.md §10). CCwiki does not add a condition the wiki does not
  state.
- **Change.** State the requirement in the Statement, cited. Then either
  re-point the hypothesis at a large-field variant, or let CCwiki add a
  `requires` entry that cites the new sentence.
- **Retires** no entry; it would let CCwiki add one, or make one unneeded.

## What the asks would buy

- **Asks 1–7, with the wiki's own items, retire 35 of the 42 entries and
  add 1:**
  - the 7 `equivalences` and 3 `refuted` entries (asks 1 and 2);
  - the 3 `quarantine` entries, through the wiki's own `fu2:node-granularity-12`
    and `fu2:node-granularity-13`;
  - the 2 `weakens` entries (ask 5);
  - 18 of the 23 `requires` entries: 2 by ask 4, 15 by ask 6, and ISIS's
    (`requires:red-isis-inhomogeneous-sis-to-sis:inhomogeneous-sis`) through
    `ffr:verification-gap-8`;
  - the 2 `settings` entries, through `ffr:schema-convention-14` (option
    A). The honest-majority variants then become conclusions of a new
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
- **What remains** is 8 entries: 5 `requires` entries (JLS21's shared prime
  and Wat09's four), the 2 `statementLint` entries, which are CCwiki's own
  review notes and stay CCwiki's, and `settings:secure-channels-model`.

## How CCwiki notices each change

| Ask | Decoded now | Entries then superseded | Detected by |
|---|---|---|---|
| 1 | `Relation.reverseClass` | `equivalences:<id>` | `curationSuperseded` (a warning); DLO24's by `curationResolves` once its id retires |
| 2 | `RelationObject.refutedBy` | `refuted:<id>` | `curationSuperseded` |
| 3 | `Barrier.model` | none | n/a |
| 4–7, 9 | nothing | the re-pointed edges' `requires` and `weakens` entries | `curationResolves` fails (the hypothesis is gone), or `curationEdgesUnchanged` fails (the conclusion changed under a kept id) |
| `fu2:` items | nothing | `quarantine:<id>` | `curationEdgesUnchanged` |
| `ffr:schema-convention-14` | nothing | `settings:<id>` | `curationSuperseded`: a setting that is no longer the sole hypothesis of any eligible step |
| 8, 9 | nothing | none | golden drift: new derived pairs, which the corpus test's drifted mode handles |

When a check fires, follow derivations.md §8: review the named entries, edit
the curation, regenerate the golden file, then run
`make curation-review WIKI=…` against the same clone.
