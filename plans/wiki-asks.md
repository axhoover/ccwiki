# Wiki asks: what the wiki could record so CCwiki's curation can go

**Written 2026-10-12 against wiki `ab81f02`**, the commit the curation and
the golden file were reviewed against; **asks 11–21 added 2026-10-15** from
the maintainer's mathematical audit of the curation on PR #9
([relations-followups.md](relations-followups.md) §13). Spec:
[relations-followups.md](relations-followups.md) §4. Every count below was
computed with `scripts/derivations_reference.py` on that commit, with the
curation as it stands after the audit.

CCwiki derives relations by chaining the reductions in the wiki's
`relations.json` ([derivations.md](derivations.md)). Where the manifest does
not record something a Statement says, CCwiki keeps a reviewed correction in
`Resources/derivation-curation.json`: 47 entries, each quoting the page it
rests on ([curation-review.md](curation-review.md)). Each entry is a thing
the wiki could record itself. These asks say how, page by page, and what
each would let CCwiki drop. Asks 1–10 came from the curation's first
review; asks 11–21 from the audit: five new nodes and reductions (11–15),
which CCwiki does not add itself, since every step it chains is the wiki's
claim, and six corrections to the wiki's text (16–21).

The asks prefer **variant nodes to new fields**: the wiki already has
variants, and its own review queue is moving that way
(`ffr:node-granularity-3`, `ffr:node-granularity-11`). Three asks do need new
fields (`reverse-class`, `refuted-by`, a barrier `model`); CCwiki decodes
all three now, so it is ready the day the wiki ships them.

## How to apply them

CCwiki and its agents never write to the wiki. The maintainer files the asks:

1. **The content asks** (4–21) go through the wiki's review pipeline. Copy
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
| `ffr:verification-gap-8` | ISIS ⇔ SIS's unproved direction; the `equivalences` and `quarantine` entries on that edge, with ask 21 |
| `ffr:node-granularity-3` | YZW+19 on a new `subexponential-lpn-above-half` variant; ask 6 |
| `ffr:node-granularity-11` | AMR25 on a quasi-polynomial low-noise LPN variant; ask 6 |
| `ffr:missing-edge-4` | a KP-ABE adaptive node; ask 5 |
| `ffr:content-error-26`, `ffr:verification-gap-29` | Kil88's OT ⇒ MPC and OT ⇒ COM Statements; ask 4 |
| `fu2:node-granularity-12`, `fu2:node-granularity-13` (round 2, paper section) | Wee22's dropped LWE conjunct; BW07's composite-order hypotheses: 3 of the 4 `quarantine` entries, BW07's with ask 18 |

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
  | `isis-inhomogeneous-sis-to-sis.md` | `unstated` (was fully-black-box) | fully-black-box; unless `ffr:verification-gap-8` or ask 21 splits the page first (CCwiki quarantines the forward direction meanwhile) |
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
- **Related.** `ffr:content-error-26`, `ffr:verification-gap-29`;
  `ccw:missing-edge-ot-semi-honest-to-malicious` (ask 14) adds the compiler
  that lets semi-honest OT reach the re-pointed steps.
- **Retires** `requires:red-ot-to-mpc-kil88:ot` and `requires:red-ot-to-com:ot`.
- **How CCwiki takes it in.** Nothing to decode. The entries then fail
  `curationResolves` (the hypothesis `ot` is gone from both edges), and
  `curationEdgesUnchanged` names DMO00's changed conclusion: re-review, then
  delete the entries.

### Ask 5. Weakened conclusions as nodes

`ccw:node-weakened-conclusions`, kind `node-granularity`.

- **Need.** Three Statements prove less than their conclusion node
  defines, and CCwiki keeps their facts apart: GPSW06 gives selectively
  secure KP-ABE, PRP ⇒ iPRF gives the forward-oracle game only, and Kil88
  with GMW87 gives MPC secure with abort against a static malicious
  adversary (the third added after the PR #9 audit).
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
  - **Kil88 ⇒ MPC.** On `secure-multi-party-computation.md`, a heading for
    security with abort against a static malicious adversary corrupting any
    number of parties, stand-alone, with the variant
    `mpc-security-with-abort`. `ot-to-mpc-kil88.md`:
    `conclusion: mpc-security-with-abort`; its Statement already says
    "security with abort against a malicious dishonest majority". The MPC
    page's malicious notion is "typically with guaranteed output delivery
    or fairness conditions", and the page also covers UC security; Kil88
    and GMW87 give no fairness or guaranteed output delivery (unachievable
    in general with a dishonest majority), and no adaptive or UC security.
    Nothing in the record consumes MPC, so no pair is lost.
- **Related.** `ffr:missing-edge-4`, `ccw:missing-edge-ot-semi-honest-to-malicious`.
- **Retires** `weakens:red-bdh-to-abe-gpsw06`,
  `weakens:red-prp-to-invertible-prf` and `weakens:red-ot-to-mpc-kil88`.
- **How CCwiki takes it in.** Nothing to decode. `curationEdgesUnchanged`
  fails on the changed conclusions under kept ids: re-review, then delete
  the entries.

### Ask 6. Hypotheses on regime and notion variants

`ccw:node-hypothesis-regimes`, kind `node-granularity`, `needs_paper` for
the rows marked so.

- **Need.** A Statement often needs more of its hypothesis than the node
  defines: a hardness regime, a group, a field, a domain size. CCwiki keeps
  26 `requires` entries for it, and refuses a chain that does not establish the stronger
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
| `prp-to-prf.md`, `prp-to-invertible-prf.md` (added after the PR #9 audit) | `prp` | `prp-large-domain`, a PRP over a domain with $\|\calD\| = \secpar^{\omega(1)}$, a heading on `pseudorandom-permutation.md`; `prf-to-prp-lr88.md` concludes it (its PRP is on $\bits^{2n}$, and its bound is negligible only when $2^n$ is superpolynomial); `strong-security-to-prp.md` keeps the plain node; a folklore `{prp-large-domain} ⇒ prp` (the identity) keeps every other use | new | `requires:red-prp-to-prf:prp`, `requires:red-prp-to-invertible-prf:prp` |

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
- The PRP rows: both Statements say "over a domain $\calD$ with $|\calD|$
  superpolynomial in $\secpar$", but the PRP page's syntax puts no bound on
  $\calD$. On $\calD = \{0,1\}$, $P_k(x) = x \oplus k$ for a uniform bit $k$
  is exactly a random permutation, so a perfect PRP, and not a PRF: two
  queries never collide, while a random function's collide with probability
  1/2. The switching gap is at most $q(q-1)/(2|\calD|)$. Both conversions
  need the row: with only one re-pointed, the other bypasses it.
- **Not asked:** Wat09's IBE and HIBE need DBDH and DLIN in **one** group.
  No node can say that either, so CCwiki keeps its four entries. GPSW06's
  DBDH is ask 11.
- **Related.** `ffr:node-granularity-3`, `ffr:node-granularity-11`,
  `ffc:verification-gap-1`.
- **Retires** 17 `requires` entries, as the table says.
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
  default derived pairs (998 today, after the PR #9 audit; the counts were
  1,022 and 432 before it). All 10 together add **373**; the counts overlap
  (SIS also reaches OWF through Ajt96's CRHF once CRHF ⇒ OWF exists).
  DLOG ⇒ OWF, measured here before the audit, is now ask 13, with the
  audit's exact formulation; with it, all 11 add 405.

  | Edge | Proposed source | New pairs |
  |---|---|---|
  | `{ot} ⇒ owf` | semi-honest OT gives OWFs: Hai08, Theorem 4 (p. 425), per the PR #9 audit; or IL89 (`needs_paper`: which theorem) | 170 |
  | `{ske} ⇒ owf` | IL89 (`needs_paper`) | 93 |
  | `{com} ⇒ owf` | IL89 (`needs_paper`) | 90 |
  | `{crhf} ⇒ owf` | folklore, for a compressing family | 47 |
  | `{mac} ⇒ owf` | IL89 (`needs_paper`) | 48 |
  | `{prf} ⇒ owf` | folklore | 33 |
  | `{sis} ⇒ owf` | Ajt96 (`needs_paper`) | 16 |
  | `{lpn} ⇒ owf` | folklore, or BFKL93 (`needs_paper`) | 31 |
  | `{kem} ⇒ owf` | `needs_paper`: IL89 does not treat KEMs; the verifiers find the source | 17 |
  | `{one-time-signature} ⇒ owf` | Rom90 (`needs_paper`) | 15 |

  The audit's curation changes lowered four counts: the starts that lost
  their answers (a strong PRP, whose domain may be small, no longer reaches
  PRF; ISIS no longer reaches SIS) gain less from an OWF edge.
- **Pages.** Ten new reduction pages in `content/Reductions/`. The
  reference pages for IL89, Ajt96 and Rom90 exist; BFKL93's and Hai08's are
  new.
- **Related.** `ccw:missing-edge-dlog-to-owf`,
  `ccw:missing-edge-ot-semi-honest-to-malicious`.
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
- **Pages.**
  `content/Reductions/additively-homomorphic-encryption-to-mpc-with-preprocessing-bdoz11.md`,
  and a large-field variant on `homomorphic-encryption.md` if the
  hypothesis is re-pointed.
- **Retires** no entry; it would let CCwiki add one, or make one unneeded.
- **How CCwiki takes it in.** Nothing to decode. If the Statement states
  the field size, CCwiki adds a `requires` entry that cites the new
  sentence and regenerates the review. If the hypothesis is re-pointed,
  QR ⇒ MPC with preprocessing stops being derived, which shows as golden
  drift.

### Ask 11. DBDH as its own node

`ccw:node-dbdh`, kind `node-granularity`. From the PR #9 audit, like asks
12–21.

- **Need.** The `bdh` node's page defines computational BDH and DBDH
  together (`bilinear-map-assumptions.md` § Assumption), so a bare `bdh`
  fact may be computational BDH only. GPSW06's Statement assumes
  **decisional** BDH, and its selective reduction embeds a DBDH challenge
  $(g^a, g^b, g^c, Z)$ and decides whether $Z = e(g,g)^{abc}$. DBDH
  hardness implies computational BDH hardness (computing $e(g,g)^{abc}$
  decides the challenge); GPSW06 supplies nothing in the other direction.
  CCwiki keeps `requires:red-bdh-to-abe-gpsw06:bdh`, so computational BDH
  alone never invokes GPSW06 unqualified: every answer through it says it
  assumes DBDH.
- **Change.**
  - `bilinear-map-assumptions.md`: the **Decisional BDH** paragraph becomes
    a heading with the variant `dbdh`, for the symmetric prime-order pairing
    groups the pages use (GPSW06, §2: a bilinear group of prime order).
  - `bdh-to-abe-gpsw06.md`: `hypotheses: [dbdh]` (node refinement; the id
    stays).
  - A folklore page `dbdh-to-bdh.md`: `{dbdh} ⇒ bdh`, `class:
    fully-black-box`, `model: standard`: a BDH solver's output decides the
    DBDH challenge with one comparison, so DBDH hardness implies
    computational BDH hardness in the same group.
  - Wat09's IBE and HIBE (`bdh-to-ibe-wat09.md`, `bdh-to-hibe-wat09.md`)
    say DBDH too: re-point them at `dbdh` as well. CCwiki keeps their four
    entries, which say DBDH and DLIN live in **one** group, re-keyed to the
    new hypothesis.
- **Pages.** `content/Assumptions/bilinear-map-assumptions.md`,
  `content/Reductions/bdh-to-abe-gpsw06.md`,
  `content/Reductions/bdh-to-ibe-wat09.md`,
  `content/Reductions/bdh-to-hibe-wat09.md`,
  `content/Reductions/dbdh-to-bdh.md` (new).
- **Sources.** GPSW06, §2 and §4.3, Theorem 1.
- **Related.** ask 5 (GPSW06's conclusion), ask 12.
- **Retires** `requires:red-bdh-to-abe-gpsw06:bdh`.
- **How CCwiki takes it in.** Nothing to decode. The entry fails
  `curationResolves` once `bdh` is gone from GPSW06's hypotheses:
  re-review, then delete it. BDH then no longer reaches ABE through GPSW06,
  and DBDH does, with no assumption.

### Ask 12. Selective KP-ABE ⇒ CPA-secure PKE

`ccw:missing-edge-selective-kp-abe-to-pke`, kind `missing-edge`.

- **Need.** GPSW06 gives selectively secure KP-ABE, and CCwiki keeps that
  fact apart (`weakens:red-bdh-to-abe-gpsw06`): no recorded step accepts
  it, and rightly so for ABE ⇒ IBE and ABE ⇒ BE (below). Ordinary PKE does
  follow from selective KP-ABE, but the record has no such edge, so BDH ⇒
  PKE is not derived.
- **Change.** A new page `abe-selective-security-to-pke.md`:
  `hypotheses: [abe-selective-security]` (which GPSW06 concludes with
  ask 5), `conclusion: pke` (IND-CPA), `class: fully-black-box`,
  `model: standard`, source folklore. It is a direct argument against the
  selective game, not a theorem attributed to GPSW06:
  - *Construction.* Fix an attribute set $x_0$ and a policy $f_0$ with
    $f_0(x_0) = 1$. Key generation runs the ABE's $\Setup$, publishes its
    public parameters as the public key, and keeps $\KeyGen(\msk, f_0)$ as
    the secret key. Every message is encrypted under $x_0$, and decrypted
    with the key for $f_0$. Correctness is the ABE's.
  - *Reduction.* A PKE adversary becomes a selective KP-ABE adversary that
    commits to $x_0$ before $\Setup$, makes no key query, and forwards the
    PKE challenge messages as its own. The distinguishing advantage is
    preserved.
  - *Not covered.* The analogous identity encoding of a selective KP-ABE
    gives **selective** IBE, not adaptive IBE, so ABE ⇒ IBE stays refused on
    it; BE from KP-ABE is ask 15.
- **Pages.** `content/Reductions/abe-selective-security-to-pke.md` (new);
  `content/Primitives/attribute-based-encryption.md` (link it from
  § Selective Security).
- **Effect,** measured with ask 5's GPSW06 conclusion in place and its
  weakening dropped: +41 default derived pairs (998 → 1,039). BDH ⇒ PKE is
  derived through GPSW06, assuming DBDH (from a DBDH start with ask 11, with
  no assumption); BDH ⇒ IBE and BDH ⇒ BE stay underived.
- **Sources.** GPSW06, §2 and §4.3, Theorem 1, for the selective KP-ABE
  game the argument runs against.
- **Related.** ask 5, ask 11, `ffr:missing-edge-4`.
- **Retires** no entry; it adds answers.
- **How CCwiki takes it in.** Golden drift. Recorded instead from the
  plain `abe` node, the edge would be one CCwiki adds to the `acceptedBy`
  of `weakens:red-bdh-to-abe-gpsw06`, citing its Statement, since the
  argument holds for the selective game.

### Ask 13. DLOG ⇒ OWF on the same group family

`ccw:missing-edge-dlog-to-owf`, kind `missing-edge`.

- **Need.** BM84 needs DLOG in $\ZZ_p^*$ with residues read as integers
  (ask 16), so CCwiki refuses it on DLOG derived from CDH, DDH or BDH
  (`requires:red-dlog-to-prg-bm84:dlog`). The general existence
  implication does not need BM84: DLOG hardness gives a one-way function on
  the same group family, and OWF ⇒ PRG (HILL99) is recorded. The record
  has no DLOG ⇒ OWF edge, so CDH ⇒ PRG is not derived. (DDH ⇒ PRG already
  is, through ElGamal, IL89 and HILL99.)
- **Change.** A new page `dlog-to-owf.md`: `hypotheses: [dlog]`,
  `conclusion: owf`, `class: fully-black-box`, `model: standard`,
  folklore. Statement: for an efficiently generated and efficiently
  represented cyclic group family of known order $q$ with generator $g$ on
  which DLOG is hard, $x \mapsto g^x$ on $\ZZ_q$ is one-way; any inverter
  given $g^x$ returns some $x'$ with $g^{x'} = g^x$, so
  $x' \equiv x \pmod q$, the discrete logarithm. State it in the
  public-parameter formulation: the function's index is the group
  description $(\GG, q, g)$ the group generator samples, the domain sample
  is a uniform $x \in \ZZ_q$, and one-wayness is over both. It uses no
  integer reading of group elements, and is not BM84's.
- **Pages.** `content/Reductions/dlog-to-owf.md` (new);
  `content/Assumptions/discrete-logarithm.md` (Known Results).
- **Effect.** +32 default derived pairs (998 → 1,030), among them CDH ⇒
  PRG (CDH ⇒ DLOG ⇒ OWF ⇒ PRG, fully black-box) and BDH ⇒ PRG.
- **Sources.** BM84, §§3–4, Theorem 4 (pp. 861–862), for what BM84 proves
  and needs; HILL99, Theorem 6.2.2 (manuscript p. 33), for OWF ⇒ PRG.
- **Related.** ask 8 (this was its DLOG row), ask 16.
- **Retires** no entry: BM84's requirement stays, since BM84 itself still
  needs $\ZZ_p^*$. It adds answers.
- **How CCwiki takes it in.** Golden drift.

### Ask 14. Semi-honest OT ⇒ malicious OT (Haitner's compiler)

`ccw:missing-edge-ot-semi-honest-to-malicious`, kind `missing-edge`.

- **Need.** Kil88's OT ⇒ MPC and OT ⇒ COM substitute a real OT for an
  ideal one, which needs OT secure against malicious parties; the `ot`
  node's definitions are semi-honest. CCwiki therefore refuses both on
  semi-honest OT (`requires:red-ot-to-mpc-kil88:ot`,
  `requires:red-ot-to-com:ot`), and ETDP ⇒ MPC and ETDP ⇒ COM are not
  derived. A known fully black-box compiler turns semi-honest OT into
  malicious OT, and the record lacks it. The one producer CCwiki accepts,
  DMO00, is accepted on its Statement's completeness claim, and its page
  does not say how its OT reaches malicious security.
- **Change.**
  - A new page `ot-to-malicious-ot-security-hai08.md`: `hypotheses: [ot]`,
    `conclusion: malicious-ot-security` (the variant exists on
    `oblivious-transfer.md#malicious-security`), `class: fully-black-box`,
    `model: standard`, source Hai08: Haitner's fully black-box
    construction of OT secure against malicious parties from semi-honest OT
    (Theorem 2 and Corollary 2, p. 415). It needs no separate OWF
    assumption: semi-honest OT gives OWFs (Theorem 4, p. 425), which is
    also ask 8's OT row. A reference page for Hai08 (Haitner, TCC 2008) is
    new.
  - With ask 4, Kil88's two pages take `malicious-ot-security` as their
    hypothesis, and the chain is the compiler, then the direct Kil88 step.
    Without ask 4, extend the two Statements and their citations to include
    the compiler; CCwiki relaxes its requirements only once the wiki states
    it.
  - `ot-to-mpc-kil88.md`: conclude explicitly static malicious MPC with
    abort (ask 5's `mpc-security-with-abort`); no fairness, guaranteed
    output delivery, adaptive or UC security is inherited from the
    undifferentiated MPC node.
  - `cpir-to-ot-dmo00.md`: record the malicious upgrade its completeness
    claim rests on (the OT its PIR gives, made secure against malicious
    parties by a semi-honest-to-malicious compiler), so that CCwiki's
    `metBy` acceptance of DMO00 rests on a theorem the wiki states.
  - `ot-to-com.md`: say that the commitment is statistically hiding and
    statistically binding **in the OT-hybrid model** only. With a real OT
    its hiding and binding rest on that OT's security, and no plain-model
    commitment is both statistically hiding and statistically binding.
    Ordinary computational commitments also follow from semi-honest OT
    through OT ⇒ OWF ⇒ PRG ⇒ COM (ask 8).
- **Pages.** `content/Reductions/ot-to-malicious-ot-security-hai08.md`
  (new), a reference page for Hai08 (new),
  `content/Reductions/ot-to-mpc-kil88.md`, `content/Reductions/ot-to-com.md`,
  `content/Reductions/cpir-to-ot-dmo00.md`.
- **Effect,** measured with ask 4's re-pointing and its two requirements
  dropped: +33 default derived pairs (998 → 1,031). ETDP ⇒ MPC is derived
  (EGL, the compiler, Kil88), as static malicious MPC with abort only, and
  so is ETDP ⇒ COM. Ask 4 alone adds 21 and leaves ETDP ⇒ MPC underived.
- **Sources.** Haitner, TCC 2008: Theorem 2 and Corollary 2 (p. 415),
  Theorem 4 (p. 425).
- **Related.** ask 4, ask 5, ask 8, `ffr:content-error-26`,
  `ffr:verification-gap-29`.
- **Retires** nothing by itself; with ask 4 it is what lets semi-honest OT
  reach Kil88.
- **How CCwiki takes it in.** Golden drift, and ask 4's.

### Ask 15. Adaptive KP-ABE ⇒ BE with membership policies

`ccw:missing-edge-kp-abe-to-be`, kind `missing-edge`.

- **Need.** `abe-to-be.md` records the ciphertext-policy construction only,
  so CCwiki requires CP-ABE of it (`requires:red-abe-to-be:abe`). A
  key-policy construction exists too, and the record does not have it.
- **Change.** A new page `kp-abe-to-be.md`, or a second construction on
  `abe-to-be.md` with its own edge: from an adaptively KP-IND-CPA-secure
  KP-ABE over attribute universe $[n]$ whose policy class contains the
  membership predicates $f_i(x) = [i \in x]$, to `be`; `class:
  fully-black-box`, `model: standard`, folklore.
  - *Construction.* User $i$ gets the KP-ABE key for $f_i$; a broadcast to
    $S \subseteq [n]$ encrypts under the attribute set $S$, so user $i$
    decrypts exactly when $i \in S$.
  - *Reduction.* The forbidden BE key queries, users $i \in S^*$, are
    exactly the policies $f_i$ that accept $S^*$, so every BE adversary is
    a KP-ABE adversary with the same advantage, and the security game is
    preserved.
  - *Scope.* Adaptive KP-ABE gives adaptive BE; selective KP-ABE gives only
    selective BE. Neither gives short ciphertexts: the ciphertext is a
    KP-ABE ciphertext for an attribute set of size $|S|$.
  - Keep the existing CP construction as it is.
- **Pages.** `content/Reductions/kp-abe-to-be.md` (new), or
  `content/Reductions/abe-to-be.md`.
- **Effect.** One new default derived pair (circular evasive LWE ⇒ BE,
  vacuous), and ABE ⇒ BE no longer assumes CP-ABE. GPSW06's selective
  KP-ABE still reaches no BE: the record has no selective-BE node for it.
- **Related.** ask 6's ABE ⇒ BE row, ask 12, `ffr:missing-edge-4`.
- **Retires** no entry: CCwiki keeps `requires:red-abe-to-be:abe` for the
  CP construction. It adds answers.
- **How CCwiki takes it in.** Golden drift.

### Ask 16. BM84's rationale

`ccw:content-bm84-rationale`, kind `content-error`.

- **Need.** `dlog-to-prg-bm84.md`'s `rationale.class` says "The
  construction uses only the group operation". It does not: the
  recurrence $x_{i+1} = g^{x_i} \bmod p$ feeds each residue back as the
  next integer exponent, and the output bit $[x_i \ge (p-1)/2]$ compares
  residues by their integer order. That is an interface of the prime field
  $\ZZ_p$, which an arbitrary cyclic group's encoding does not supply, and
  it is why BM84 needs DLOG in $\ZZ_p^*$; CCwiki keeps
  `requires:red-dlog-to-prg-bm84:dlog` for it.
- **Change.** Rewrite `rationale.class`: the construction uses the group
  operation of $\ZZ_p^*$ and the integer reading of residues, as exponents
  and in the half-interval predicate; the reduction runs the distinguisher
  only as an oracle, turning it into a next-bit predictor and the predictor
  into a DLOG solver.
- **Pages.** `content/Reductions/dlog-to-prg-bm84.md`.
- **Sources.** BM84, §§3–4, Theorem 4 (pp. 861–862).
- **Related.** ask 6 (`dlog-zp-star`), ask 13.
- **Retires** nothing: ask 6's `dlog-zp-star` row retires the requirement.
- **How CCwiki takes it in.** Nothing: the curation does not quote the
  rationale.

### Ask 17. DLO24's preprocessing experiment

`ccw:content-dlo24-preprocessing`, kind `content-error`, `needs_paper`.

- **Need.** `rsa-to-fac-dlo24.md`'s Statement lets the adversary receive
  "an advice string from unbounded preprocessing on $n$". In DLO24's
  Definition 28 the preprocessing depends only on the security parameter
  and the random encoding, and happens **before** the modulus and the
  challenge are sampled. Preprocessing that saw $N = pq$ could put $p$ in
  its polynomial-length advice and make online factoring trivial, so the
  Statement as written cannot be the theorem. The model also permits a
  non-generic intermediate computation on the encoded challenge, so it is
  not "only through ring operations and equality tests". CCwiki keeps the
  reverse direction conditional on the corrected experiment
  (`requires:red-rsa-to-fac-dlo24~reverse:fac`).
- **Change.**
  - Restate the experiment from DLO24's Definitions 15–16 (p. 8:18) and
    Definition 28 (p. 8:23), and the theorem from Theorem 12 (p. 8:15):
    a generic-RSA adversary with preprocessing, whose advice is computed
    from $\secpar$ and the random encoding before $N$ is sampled, converts
    into a factoring adversary with preprocessing of the same kind, with
    polynomially related online complexity and polynomially longer advice.
  - Keep the ordinary direction separate: RSA hardness implies factoring
    hardness on the same modulus distribution, fully black-box in the
    standard model, which `fac-to-rsa-rsa78.md` (`red-rsa-to-fac-rsa78`)
    already records. With ask 1's split, `rsa-to-fac-dlo24.md` becomes the
    implication FAC ⇒ RSA with `model: other`; give its hypothesis a
    variant on `factoring.md` for factoring hardness against adversaries
    with preprocessing advice fixed before $N$ is sampled, since the `fac`
    node's adversary $\calA(1^\secpar, N)$ gets no advice. Its `free` class
    holds inside the generic-RSA experiment only.
- **Pages.** `content/Reductions/rsa-to-fac-dlo24.md`,
  `content/Assumptions/factoring.md`.
- **Sources.** DLO24 (ITC 2024, LIPIcs 304, paper 8): Definitions 15–16,
  Definition 28, Theorem 12.
- **Related.** ask 1.
- **Retires** `requires:red-rsa-to-fac-dlo24~reverse:fac`, with ask 1's
  split, which retires the id.
- **How CCwiki takes it in.** `curationResolves` fails once the id is
  retired: re-review, then delete the entry.

### Ask 18. BW07's assumptions and title

`ccw:content-bw07-assumptions`, kind `content-error`.

- **Need.** `bdh-to-hve-bw07.md`'s Statement lists "three assumptions
  jointly": DBDH, the bilinear subgroup decision assumption and C3DH.
  BW07 needs two, on the **same** composite-order group family:
  composite-order cBDH and C3DH (Definitions 4.1–4.2; Lemmas 5.3–5.6,
  pp. 11–12). Subgroup decision follows from C3DH (Appendix B.2 and
  footnote 2, p. 21: relabel the subgroups and apply the pairing), so it
  is not a third independent assumption. The reference page's file name
  also gives the wrong title.
- **Change.**
  - Restate the Statement: in a composite-order bilinear group family,
    HVE with selective payload- and attribute-hiding security exists under
    cBDH and C3DH on that family; subgroup decision is implied by C3DH.
  - Rename
    `content/References/BW07 - Conjunctive Normal Form Encryption and Attribute Based Encryption.md`
    to `BW07 - Conjunctive, Subset, and Range Queries on Encrypted Data.md`
    (its heading already has this title), and update the links in
    `bdh-to-hve-bw07.md` and `hve-to-subset-and-range-queries.md`.
  - Record the two hypotheses as nodes on that one family, as
    `fu2:node-granularity-13` proposes, rather than the prime-order `bdh`.
- **Pages.** `content/Reductions/bdh-to-hve-bw07.md`,
  `content/Reductions/hve-to-subset-and-range-queries.md`,
  `content/References/BW07 - Conjunctive Normal Form Encryption and Attribute Based Encryption.md`
  (renamed).
- **Sources.** BW07: Definitions 4.1–4.2, Lemmas 5.3–5.6 (pp. 11–12),
  Appendix B.2 and footnote 2 (p. 21).
- **Related.** `fu2:node-granularity-13`.
- **Retires** `quarantine:red-bdh-to-hve-bw07`, with
  `fu2:node-granularity-13`: CCwiki lifts the quarantine only once both
  hypotheses are recorded on the same group family.
- **How CCwiki takes it in.** `curationEdgesUnchanged` fails on the
  changed hypotheses: re-review, then delete the entry.

### Ask 19. TDP ⇒ NIZK: the certification FLS90 needs

`ccw:content-tdp-nizk-double-enhancement`, kind `content-error`,
`needs_paper` for CL18's proof.

- **Need.** `tdp-to-nizk-bfm88.md`'s Statement ends "The hidden-bits
  compilation uses the double enhancement, and double enhancement suffices
  for it" (GR13). Goldreich and Rothblum's 2017 erratum withdraws that
  unqualified sufficiency claim. The page's own Notes say why: doubly
  enhanced families still leave the FLS90 instantiation unsound for
  adversarially chosen indices whose domain is not recognizable, and
  certifiable injectivity closes the gap (CL18). CCwiki requires
  certification that holds for adversarially chosen indices
  (`requires:red-tdp-to-nizk-bfm88:tdp`).
- **Change.** Replace the sentence: the compilation uses the double
  enhancement, and soundness needs certification that holds for
  adversarially chosen indices; CL18's certifiably injective doubly
  enhanced trapdoor functions suffice. Cite the erratum beside GR13.
- **Pages.** `content/Reductions/tdp-to-nizk-bfm88.md`,
  `content/References/GR13 - Enhancements of Trapdoor Permutations.md`.
- **Sources.** Goldreich–Rothblum, 2017 erratum
  (https://www.wisdom.weizmann.ac.il/~/oded/p_tdp.html); Canetti–Lichtenberg,
  ePrint 2017/631 (CL18). The audit checked the erratum and CL18's
  abstract, not CL18's full proof.
- **Related.** ask 6's TDP row, `ffc:verification-gap-1`.
- **Retires** nothing by itself: ask 6's `doubly-enhanced-certified-tdp`
  row, stated with this certification, retires the requirement.
- **How CCwiki takes it in.** `curationQuotesFound` names the quoted
  Statement or Notes sentence if it changes: re-quote and re-review.

### Ask 20. Circular evasive LWE: what AMYY25 refutes

`ccw:content-circular-evasive-lwe-scope`, kind `content-error`,
`needs_paper`.

- **Need.** `learning-with-errors.md` says public-coin circular evasive LWE
  "is false" (§ Evasive LWE counterexamples, § Circular evasive LWE)
  without pinning down the attacked formulation or the premise. AMYY25
  (§4.1, Assumption 4.1; Theorem 4.6, p. 29; Claim 4.7, p. 30) give a
  public-coin sampler that meets the pre-condition of the circular evasive
  LWE formulation HLL23 assume and breaks its post-condition, under the
  base hardness the theorem assumes for the pre-condition. That refutes
  this formulation only: not every evasive LWE variant, and it is no
  impossibility result for ABE for unbounded-depth circuits.
- **Change.** On both lines, and in a formal definition for § Circular
  evasive LWE (a TODO today), state the attacked formulation (AMYY25's
  Assumption 4.1, HLL23's), the sampler class (public-coin), the theorem
  (Theorem 4.6, Claim 4.7), and the base-hardness premise under which the
  pre-condition holds.
- **Pages.** `content/Assumptions/learning-with-errors.md`.
- **Sources.** AMYY25: §4.1, Assumption 4.1, Theorem 4.6 (p. 29), Claim 4.7
  (p. 30).
- **Related.** ask 2.
- **Retires** nothing: ask 2 retires `refuted:circular-evasive-lwe`, and
  this ask says what its `refuted-by` marker refers to.
- **How CCwiki takes it in.** `curationQuotesFound` names the quoted
  sentences if they change: re-quote, and narrow the entry's sentence to
  what the page then says.

### Ask 21. ISIS ⇒ SIS: parameters, distributions and a proof

`ccw:verification-gap-isis-sis-parameters`, kind `verification-gap`,
`needs_paper`.

- **Need.** `isis-inhomogeneous-sis-to-sis.md` proves one direction: SIS
  hard for $(n, m, q, \sqrt{\beta^2+1})$ implies ISIS hard for
  $(n, m-1, q, \beta)$ (write $\mathbf{A} = [\mathbf{A}' \mid \mathbf{a}]$
  and turn $\mathbf{A}'\mathbf{z}' = \mathbf{a}$ into the nonzero kernel
  vector $(\mathbf{z}', -1)$). Of the other it says only that it "holds only
  under conditions on the column count and norm bound", which is circular.
  Read at fixed parameters it is false: with $q = 2$, $m = 1$,
  $n = \secpar$ and $\beta = 2$, SIS is solved by $z = 2$, while a uniform
  ISIS target lies in the span of the single column with probability at
  most $2^{1-n}$. That is a counterexample to an unrestricted
  fixed-parameter claim, not to a correctly parameterized equivalence.
  CCwiki quarantines that direction
  (`quarantine:red-isis-inhomogeneous-sis-to-sis`, forward) and keeps the
  proved one.
- **Change.** Either state ISIS ⇒ SIS with explicit parameter
  inequalities, the instance distributions and a proof or reference, or
  split the page: the implication SIS ⇒ ISIS with the Sketch's fully
  black-box reduction, and the other direction only once it is stated.
- **Pages.** `content/Reductions/isis-inhomogeneous-sis-to-sis.md`.
- **Related.** `ffr:verification-gap-8`, ask 1.
- **Retires** `quarantine:red-isis-inhomogeneous-sis-to-sis`; with ask 1,
  or the split, also `equivalences:red-isis-inhomogeneous-sis-to-sis`.
- **How CCwiki takes it in.** A split retires the id or changes its kind,
  and `curationResolves` fails. A restated Statement changes no record:
  `curationQuotesFound` names the changed sentence; re-review then.

## What the asks would buy

- **Asks 1–7, 11, 17, 18 and 21, with the wiki's own items, retire 40 of
  the 47 entries and add 1:**
  - the 7 `equivalences` and 3 `refuted` entries (asks 1 and 2);
  - the 4 `quarantine` entries: Wee22's two through the wiki's own
    `fu2:node-granularity-12`, BW07's through `fu2:node-granularity-13`
    with ask 18, and ISIS's through ask 21 (or `ffr:verification-gap-8`);
  - the 3 `weakens` entries (ask 5);
  - 21 of the 26 `requires` entries: 2 by ask 4, 17 by ask 6, GPSW06's
    DBDH by ask 11, and DLO24's reverse direction by ask 17 with ask 1's
    split;
  - the 2 `settings` entries, through `ffr:schema-convention-14` (option
    A). The honest-majority variants then become conclusions of a new
    `secure-channels-model` node, so CCwiki adds one entry,
    `settings:secure-channels-model`, which keeps that node listed apart
    and out of completions as R14 treats settings today. Treating it as a
    model node instead would scope every result through it, which the
    record does not ask for.
- **What changes in the answers.** The re-pointing patches keep every pair,
  renamed to the variant, with two exceptions: MPC's backward list loses
  its two setting rows, because the honest-majority variants no longer
  imply MPC (each variant instead lists `secure-channels-model` as its
  setting); and with ask 11, BDH no longer reaches ABE through GPSW06,
  which DBDH then does with no assumption.
- **Asks 8, 9 and 12–15 add answers:** 373 default pairs from ask 8's ten
  OWF edges (405 with ask 13's DLOG ⇒ OWF, which alone adds 32, CDH ⇒ PRG
  among them); 41 from selective KP-ABE ⇒ PKE with ask 5 (ask 12), BDH ⇒
  PKE among them; 33 from Haitner's compiler with ask 4 (ask 14), ETDP ⇒
  MPC among them, as static malicious MPC with abort; 1 from KP-ABE ⇒ BE
  (ask 15); and classical lattice chains (ask 9).
- **Asks 16, 19 and 20 correct text** the curation relies on; they retire
  nothing by themselves.
- **What remains** is 8 entries: 5 `requires` entries (JLS21's shared prime
  and Wat09's four), the 2 `statementLint` entries, which are CCwiki's own
  review notes and stay CCwiki's, and `settings:secure-channels-model`.

## How CCwiki notices each change

| Ask | Decoded now | Entries then superseded | Detected by |
|---|---|---|---|
| 1 | `Relation.reverseClass` | `equivalences:<id>` | `curationSuperseded` (a warning); DLO24's by `curationResolves` once its id retires |
| 2 | `RelationObject.refutedBy` | `refuted:<id>` | `curationSuperseded` |
| 3 | `Barrier.model` | none | n/a |
| 4–7, 9, 11 | nothing | the re-pointed edges' `requires` and `weakens` entries | `curationResolves` fails (the hypothesis is gone), or `curationEdgesUnchanged` fails (the conclusion changed under a kept id) |
| 17 | nothing | `requires:red-rsa-to-fac-dlo24~reverse:fac` | `curationResolves`, once ask 1's split retires the id |
| 18, 21, `fu2:` items | nothing | `quarantine:<id>` | `curationEdgesUnchanged` (changed hypotheses), or `curationResolves` (a split page's retired id) |
| `ffr:schema-convention-14` | nothing | `settings:<id>` | `curationSuperseded`: a setting that is no longer the sole hypothesis of any eligible step |
| 8, 9, 12–15 | nothing | none | golden drift: new derived pairs, which the corpus test's drifted mode handles |
| 16, 19, 20 | nothing | none | `curationQuotesFound` names a quoted sentence that changed |

When a check fires, follow derivations.md §8: review the named entries, edit
the curation, regenerate the golden file, then run
`make curation-review WIKI=…` against the same clone.
