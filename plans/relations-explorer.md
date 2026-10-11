# Relations explorer, derived relations and link previews

**Spec, 2026-10-10. Nothing here is built.** Branch `claude/relations-explorer`.

This is the UI and integration half of the derivation work. The engine (what
may be chained, in which model, with which class, and how a proof is chosen)
is specified in [derivations.md](derivations.md), whose rules are cited here
as R1–R12, with an executable reference in `scripts/derivations_reference.py`.
Every number below was computed with that script or with throwaway Python
over `.reductions/relations.json` (v1: 262 nodes, 283 reductions, 32
barriers). Nothing was compiled: this machine has no Swift.

> `CLAUDE.md` asks for the **swiftui-pro**, **typography-designer** and
> **macos-design** skills before and after deciding on code. None is installed
> in this session (the same gap [design-system.md](design-system.md) records).
> This spec follows `SWIFTUI-RULES.md`, which it cites by section, and
> design-system §1 for type. Each implementation track runs whichever of the
> three skills is installed by then, before and after its code.

---

## 0. What the maintainer decided

1. **CCwiki shows derived relations**, labelled *derived by CCwiki from N
   recorded reductions*, as proof trees whose every step links to its
   reduction page. It **never claims a separation from the absence of a
   path**. Only recorded barriers are results; a derived barrier appears only
   when the engine's rule for it is sound (R12), and is labelled as derived.
2. **Default models for derivations: standard, quantum and CRS.** The
   idealised models (`rom`, `generic-group`, `algebraic-group`) and `other`
   are off by default. One toggle includes them, and every step that uses one
   is tagged.
3. **Three features:** a *Does A imply B?* explorer window; transitive
   *everything this implies* and *everything implying this* in the Relations
   inspector, visibly marked as derived; and link previews on hover.

## 1. The honesty contract

The engine decides what is derivable. The UI decides what a reader believes,
so it has rules of its own. Each is enforced in a named place, so a review can
check it.

| Rule | Why | Enforced in |
|---|---|---|
| A derived chain (two or more reductions) is drawn with **`⇒*`**, never `⇒`, and carries "derived by CCwiki from N recorded reductions". One recorded step is shown as recorded, never as derived | The wiki curates one-step results. A chain is CCwiki's composition, which the wiki does not state | Explorer verdict (§2.6), inspector rows (§3.3), Copy Statement, Copy Proof |
| **No path is never a separation.** The words are "No derivation found". Never "does not imply", `⇏`, "impossible", a red tint or an ✕ | The record is incomplete: GVW13's LWE ⇒ ABE is absent, and OT, PRF, SKE, MAC and COM derive no OWF | Explorer no-derivation layout and footer (§2.7) |
| **Only barriers are results.** Recorded ones always; derived ones only as the engine returns them, labelled, behind a disclosure | A propagated barrier is a claim the wiki does not make; its soundness rests on every side edge's class (R12) | §2.7 |
| **A conjunction is never split.** From is one conjunction (`∧` between tokens). In a proof, the premises of a multi-hypothesis step are marked `∧`. A backward pair is one row | The hyperedge rule, [relations.md](relations.md) §1 | §2.3, §2.6, §2.8 |
| **Every step outside the standard model is tagged**, by the site's name for the model | A chain is only as strong as its weakest model (R4, R5) | `ModelTag` (§5), everywhere a step or fact is shown |
| **A barrier is never shown without its `circumventedBy`** | The manifest's contract | Barrier rows reuse the inspector's anatomy (§2.7) |
| Heuristic edges, inclusions and complexity-class endpoints **never appear inside a derivation** | R1, R2 | The engine. The explorer `assert`s it in debug builds when it renders a step |

## 2. The Relations Explorer window

### 2.1 Scene

A `Window` scene, single instance, beside the Jobs window and for the same
reason ([design-system.md](design-system.md) §4a): you want the proof open
*while reading the page it is about*.

- `Window("Relations Explorer", id: CCwikiApp.explorerWindowID)`, with
  `explorerWindowID = "ccwiki.relations-explorer"`, `.environment(model)`,
  default size 820 × 640, minimum 620 × 460 (`Theme.explorer…`, §5).
- **No `.keyboardShortcut` on the scene.** The shortcut lives on the Wiki
  menu command (§2.11). The Jobs scene has both, which puts one key
  equivalent on two menu items; this one does not repeat that.
- Title "Relations Explorer". `.navigationSubtitle` restates the question:
  `OWF ∧ KEM ⇒* Public key encryption`, `DDH ⇒* …`, `… ⇒* PKE`, or nothing.
- **Pages open in the reader, and the explorer stays key.** Returning on a
  proof row renders that reduction in the main window while focus stays in
  the proof, so you can walk the steps with the arrow keys and read each one
  beside it. If no main window is open (`model.mainWindowCount == 0`), the
  explorer calls `openWindow(id: CCwikiApp.mainWindowID)` first, which is why
  Phase 0 gives the `WindowGroup` an id (§6.1).
- The window does **not** publish `focusedSceneValue(\.appModel, …)`, so
  ⌘S, ⌘O and ⌘P are disabled while it is key, as they are in Jobs. Printing
  the reader from a window that is not showing it would surprise.

### 2.2 Layout

```
┌ Relations Explorer — OWF ∧ KEM ⇒* Public key encryption ───── [⇅] [🕘] ┐
│    From ╭─────────────────────────────────────────────────────────╮    │
│         │ [Hash function § Preimage resis…] ∧ [Key encapsulation…] │    │
│         ╰─────────────────────────────────────────────────────────╯    │
│      To ╭─────────────────────────────────────────────────────────╮    │
│         │ [Public key encryption]                                   │    │
│         ╰─────────────────────────────────────────────────────────╯    │
│  Models   Standard, quantum and CRS    ☐ Include idealised models      │
├────────────────────────────────────────────────────────────────────────┤
│ ⑂ Derivable                                                            │
│   OWF ∧ KEM ⇒* Public key encryption                                   │
│   Derived by CCwiki from 4 recorded reductions · 4 steps               │
│   Fully black-box: every step is                                       │
├────────────────────────────────────────────────────────────────────────┤
│ ▾ Public key encryption                                                │
│     ⇐ KEM + SKE ⇒ PKE · CS03 · fully black-box · needs both            │
│       Key encapsulation mechanism                              given   │
│   ▾ ∧ Symmetric key encryption                                         │
│         ⇐ PRF ⇒ CPA-secure SKE · folklore · fully black-box            │
│     ▾   Pseudorandom function                                          │
│           ⇐ PRG ⇒ PRF (GGM) · GGM86 · fully black-box                  │
│       ▾   Pseudorandom generator                                       │
│             ⇐ OWF ⇒ PRG · HILL99 · fully black-box                     │
│               Hash function § Preimage resistance (one-wayness)  given │
├────────────────────────────────────────────────────────────────────────┤
│ Each step is a result the wiki records. The chain is CCwiki's          │
│ composition: the wiki does not state it.                            ⓘ  │
└────────────────────────────────────────────────────────────────────────┘
```

That tree is the reference engine's real answer for `{owf, kem} ⇒ pke`.
`owf` is a variant, so it is named by host and section, as everywhere.

Four bands, top to bottom:

1. **The question** — a `Grid` with trailing-aligned labels in the manner of
   Mail's compose header: *From*, *To*, *Models*. On `.bar` material, like the
   status bar.
2. **The verdict** — fixed above the list, so a long proof never scrolls the
   answer away.
3. **The body** — one `List(selection:)`, `.listStyle(.inset)`,
   `.scrollContentBackground(.hidden)`, rows without separators
   (`SWIFTUI-RULES` §4.2, §4.3).
4. **The footer** — `safeAreaInset(edge: .bottom)`, always present when there
   is an answer (§2.6, §2.7).

Toolbar (`.primaryAction`, no leading `Spacer`, `SWIFTUI-RULES` §6.2): **Swap** (`⇅`,
`arrow.up.arrow.down`) exchanges From and To. It is enabled when From has at
most one object; with more, its tooltip says "A conjunction cannot be a
conclusion." **Recent** (`clock.arrow.circlepath`) is a `Menu` of up to ten
earlier questions, each written as its statement.

### 2.3 From and To: the object field

**The choice: a token field built from SwiftUI, with its suggestions shown
in the results area, palette-style.** Not `NSTokenField`, and not an
add-button list.

- `NSTokenField` is the native control Mail uses, and the corpus test already
  guarantees all 262 labels are unique, so its string tokens would map back to
  ids. But its completion menu shows one line of text: no type, no "section of
  …", and no room to say *why* a complexity class is not offered. Bridging its
  delegate under Swift 6 is an isolated conformance (`SWIFTUI-RULES` §12.1)
  for a control used in one window.
- An add-button list (`+`/`−` under a table) is mouse-shaped, takes two steps
  per object, and reads as a list of separate items. A conjunction should read
  as one: `OWF ∧ KEM`.
- **Suggestions replace the results while you type.** They are not a dropdown
  floating over the list. A SwiftUI overlay drawn above an AppKit-backed
  `List` is exactly the layering a visual gate catches late. Swapping the
  pane's content is the shape ⌘S and ⇧⌘R already have (`SearchPalette`), with
  the same keys. The swap is a plain `if`, with no `.transition` and no
  `withAnimation` (`SWIFTUI-RULES` §1.1).

**Anatomy.** A bordered box (`.background(.background)`, a 6 pt rounded
`strokeBorder(.separator)`, the focus ring left to AppKit, `SWIFTUI-RULES` §7.3) holding a
wrapping `TokenFlowLayout` (a `Layout`) of tokens, then a plain `TextField`.

- **A token** is the object's label in a capsule: `Theme.Fonts.row`,
  `.tint.opacity(0.12)` fill, `Theme.tokenCornerRadius`. A variant carries the
  `number` glyph the inspector's object rows use. It is one line, truncated in
  the middle (`Hash function § Pre…(one-wayness)`), with the full label as its
  tooltip.
- A **remove** `×` fades in on hover and is never inserted (`SWIFTUI-RULES` §4.5). A click
  selects the token, and ⌫ removes the selection.
- **`∧` between tokens in From**, `.secondary`, hidden from VoiceOver. To takes
  a single token, so typing into a filled To replaces its token on commit.
- **Placeholders.** From: "Add an assumption or primitive", then "and…" once a
  token exists. To: "Anything: show everything derivable".
- **A stale token** (its id left the manifest after a sync) stays visible,
  struck through, with the tooltip "Not in the wiki any more". It is left out
  of the question, and the verdict says "1 object ignored". Nothing is pruned
  silently.

**Matching** is a new pure `RelationObjectMatcher` (§6.3) over
`FuzzyMatcher.match`, ranking each node's label (weight 30), its aliases (24)
and its id (0). Ties go to the shorter label, then to a host over its
variants. That makes `owf`, `OWF`, `one-way` and `preimage` all find
`Hash function § Preimage resistance (one-wayness)`. Up to 8 suggestion rows,
each two lines: the label, then a detail in `.secondary` (the node's type, or
"Section of Hash functions", or the alias that matched, as ⌘O shows it).

**What can be picked** is `derivation.participants(.all)`, the endpoints of
some eligible step under either setting:

- **Complexity classes are never offered (R2).** If a query matches only
  classes, the suggestion area says "Complexity classes are related by
  containment, not derived. Their page's Relations tab lists what contains
  them."
- **Model nodes are offered** (`rom`, `ggm`, `agm`), with the detail
  "Idealised model". With the toggle off, the answer explains them (§2.7).
- Already-chosen objects are excluded from the suggestions.

### 2.4 The models row

The row reads "Standard, quantum and CRS" as plain `.secondary` text, then
`Toggle("Include idealised models", isOn:)` with `.toggleStyle(.checkbox)`,
the wording of [derivations.md](derivations.md) §7. The tooltip: "The random
oracle, generic group and algebraic group models, and the non-standard model.
A result through one of them holds only inside that model, and is tagged."

The toggle is part of the question (`ExplorerQuery.includesIdealisedModels`),
so a Recent entry restores it. It is **not remembered across launches**
(derivations.md §7): every launch starts in the default models, so nobody
returns days later to idealised results without having asked for them. The
inspector does **not** follow it (§3.1).

### 2.5 Four modes

| From | To | Mode | Engine call |
|---|---|---|---|
| empty | empty | **Empty** | none |
| set | empty | **Forward**: everything From derives | `closure(from:options:)` |
| empty | set | **Backward**: everything that derives To | `implying(_:options:)` |
| set | set | **Question**: does From imply To? | `answer(from:to:options:)` |

The brief named these `derive`, `backward` and `query`; the names here are
derivations.md §3's, which owns the type.

The answer is recomputed on every edit. There is no Go button, because there
is nothing to confirm (§2.14 has the cost).

### 2.6 A derivation

The engine returns `.derived(DerivedAnswer)`. The wording below follows
[derivations.md](derivations.md) §7 except where §6.7 says otherwise.

**The verdict band:**

- **The symbol:** `arrow.triangle.branch` (the Relations tab's) in `.tint`.
  Not a checkmark, and not green: those say *true*, and this says *chained*.
- **The title:** "Derivable", in `Theme.Fonts.verdict`. When the target holds
  only inside an idealised model (`fact.isModelScoped`), the title is "Holds
  in the random oracle model", naming the model, never a bare "holds".
- **The question**, restated with `⇒*`, in `Theme.Fonts.row`.
- **The provenance line:** "Derived by CCwiki from N recorded reductions · D
  steps", in `Theme.Fonts.meta` `.secondary`. N is `proof.relationIDs.count`
  and D is `fact.depth`.
- **The chain class, in §7's words:**
  - "Fully black-box: every step is";
  - "Relativizing: every step relativizes";
  - "An implication; no black-box claim" for `free`;
  - "Class unstated: N steps do not state theirs", muted as `unstated` is
    everywhere ([relations.md](relations.md) §8).
- **A stronger chain**, when there is one (`stronger`, R6): "A fully
  black-box derivation exists in 3 steps", with a **Show It** button that
  swaps the outline to that proof, and **Show Shortest** to swap back. DDH ⇒
  invertible PRF is the case on today's data: 2 unstated steps through
  HPPY25, or 3 fully black-box steps through NR97 and LR88.
- **Tags:** one `ModelTag` per model in `fact.models`.
- **Recorded barriers** on the pair (R8), as context, with one sentence
  relating them to the answer: "A recorded barrier rules out fully-black-box
  reductions here; this one is free. Circumvented by BH26." The rows are as in
  §2.7.

**One reduction is a recorded result, not a derivation.** When
`proof.relationIDs.count == 1`, the wiki states the answer itself. That holds
when the step's hypotheses are a subset of From, since more premises is
trivial, and when the step is an equivalence read right to left, since the
record states both directions. So the answer says:

- **"Recorded"**, not "Derivable";
- `⇒`, not `⇒*`;
- "A result the wiki records: *source*" in place of the provenance line;
- the footer "This is a result the wiki records."

Oblivious interactive hash function ⇒ OT is the example: BH26's recorded
free reduction, with the fully-black-box barrier on the same edge listed under
it. This is the one place this spec departs from derivations.md §7; see §6.7.

**Given.** A target in From comes back at depth 0 (`fact.step == nil`). The
answer is "*PKE* is one of your premises", with no proof and no footer.

**The proof** is a disclosure outline: a recursive `DisclosureGroup` in the
`List`, **expanded by default**.

- The engine's `ProofTree.rows` are flat and depth-first. Track B's
  `ExplorerResult` folds them into `ProofOutline.Node`s, which is pure and
  tested.
- The view keeps a `collapsed: Set<Node.ID>`, so expanded is the default
  (`SWIFTUI-RULES` §3.3 is the reason not to persist it).
- The `List` gives → and ← to expand and collapse, and ↑ ↓ to move.

| Node | Line 1 | Line 2 (`Theme.Fonts.meta`, `.secondary`) | Primary action |
|---|---|---|---|
| Root | label, **semibold** | `⇐ KEM + SKE ⇒ PKE · CS03 · fully black-box · needs both` | open the reduction page |
| Derived | label | `⇐ ` + the reduction's title (`RelationText.plain`) · sources · class · model if not standard; `⇔, used right to left` for a reverse step; `needs all N` for N > 1 hypotheses; the compact `StatusBadge` for a stub | open the reduction page |
| Given | label, then a `given` capsule | none | open the object (its host page plus anchor, for a variant) |
| Shown above | label | "shown above" | select the first occurrence and scroll to it (`ScrollViewReader`) |

- **The second and later hypotheses of a multi-hypothesis step** carry a
  leading `∧` in the gutter. The conjunction is drawn where it lives.
- **Rows are selectable.** `contextMenu(forSelectionType:menu:primaryAction:)`
  gives double-click and Return, and `.copyable` makes ⌘C copy the selected
  rows' statements.
- **Context menu:** Open Reduction ("CS03: KEM + SKE ⇒ PKE"), Open *object*,
  Explore From Here…, Copy Statement, Copy Proof as Text.
- **Tooltip:** the reduction's statement, then its rationale, from
  `RelationFormatting.help(for:)`. That is the inspector's tooltip, lifted
  into `Wiki/` in Phase 0, so the two cannot drift.
- **Stub steps** (toggle on only, R3) add a footnote row after the tree, in
  `.secondary`: "1 step is a stub: its class and model are not evidence."

**Copy Proof as Text** is the outline, indented two spaces per level, one step
per line with `[source; class; model]`. It is headed by the statement and
"Derived by CCwiki from N recorded reductions (relations.json at
`<headRevision prefix>`)". The commit makes a pasted proof reproducible.

**The footer:** "Each step is a result the wiki records. The chain is
CCwiki's composition: the wiki does not state it." Then an `ⓘ` button whose
popover lists, in plain words, the rules of derivations.md §2:

- Implications are used, and equivalences in both directions.
- Inclusions, heuristic candidates and steps touching a complexity class are
  never used.
- Which models are on.
- What each chain class means.
- A step that need not carry over is not applied inside an idealised model.

The popover is static text, so there is no transition to worry about.

### 2.7 No derivation

The engine returns `.notDerived(NoPathAnswer)`.

**The verdict band:**

- **The symbol:** `circle.dashed` in `.tertiary`. That is the offline state's
  vocabulary ([design-system.md](design-system.md) §4b): not a fault.
- **The title:** "No derivation found".
- **The sentence:** "CCwiki finds no chain of the wiki's recorded reductions
  from *OWF* to *PKE* in the standard, quantum or CRS models." The model list
  follows the toggle.
- **With the toggle off and a model node in From** (`modelStarts`, R4), the
  sentence is replaced by R4's own words: "The random oracle model is a model,
  not an assumption. What the wiki proves in it appears with idealised models
  included." It comes with an **Include Idealised Models** button.

**Then sections, in R10's order,** each present only when it has rows:

1. **Recorded barriers.** The pair first, then "In the other direction"
   (`reverseBarriers`).
   - Each row is the inspector's barrier anatomy with one change: after the
     `nosign` glyph comes the barrier's own **title**, where an inspector row
     puts the far end of the edge. The explorer has no "your end", and the
     title names the ruled-out class: "No relativizing reduction from OWF to
     PKE".
   - Then "against relativizing reductions · unconditional · IR89", then
     "circumvented by …" when it is. The meta line and the tooltip come from
     `RelationFormatting`.
   - The header's tooltip: "A barrier rules out reductions of a class. It
     bites a chain only if the chain's class implies it."
2. **Derived barriers** that are not redundant (R12, one start only). Each
   shows its argument, not just its conclusion, in §7's form:
   - "A relativizing reduction from OWF to CRHF would compose with OWP ⇒ OWF
     (fully black-box) into one from OWP to CRHF, which Sim98 rules out.
     Derived by CCwiki."
   - The barrier and each side reduction are links.
   - **Redundant ones** become a "Show reasoning" disclosure on the recorded
     barrier they repeat. On today's data `owf ⇒ pke` gets exactly that:
     IR89's OWP ⇏ KE (`bar-owp-to-ke-ir89`), through OWP ⇒ OWF and PKE ⇒ KE,
     repeats the recorded `bar-hash-function-to-pke-gkm-00`. It is the hand
     derivation on the wiki's own `no-owp-to-ke-ir89` page.
3. **With idealised models included** (`withIdealisedModels`, toggle off):
   "Derivable with idealised models included: 1 step, algebraic group model"
   (DLOG ⇒ CDH, FKL18). Its **Include Idealised Models** button sets the
   toggle.
4. **Refused steps** (`refused`, toggle on), in §7's words:
   - "Not derived: OIHF holds here only in the random oracle model, and OIHF ⇒
     OT (BH26) is a free (non-black-box) step, which need not carry over into
     that model."
   - For an unstated step: "…whose class the wiki does not state, so CCwiki
     cannot tell whether it carries over."
   - On today's data this is how `fac ⇒ pke` and `rom ⇒ ot` answer with the
     toggle on.
5. **Hints** (R9), headed "Related by the page, not by a recorded reduction":
   - "*LPN* derives nothing here; its sections *Low-noise LPN* and
     *Mid-noise LPN* each do";
   - "*Ring LWE* is a section of *LWE*, which is derived".
   Each row has **Use Instead**, which replaces that object in the question.
6. **Becomes derivable if you also assume** (completions, up to 8, then "and
   N more"). Each row reads "iO", then "1 step · SW14 · free". Its **Add**
   button appends the object to From. For `owf ⇒ pke` the rows are iO
   (1 step) and KEM (4 steps). Never "a missing assumption".

**The footer**, fixed and never collapsible, in R10's words: "CCwiki found no
derivation from the reductions the wiki records. This is not a separation:
the record is incomplete, and only the barriers listed here are results."

**Unsupported** (`.unsupported`, R2). A complexity class in the question,
seeded from a class's page say, gets
`ContentUnavailableView("Complexity Classes Are Not Derived", systemImage:
"chart.bar")` with the containment sentence from §2.3.

### 2.8 Everything from, everything to

**Forward** (`DDH ⇒* …`), from `closure(from:options:)`:

- The verdict reads "Derivable from DDH", then "33 objects · 1-step rows are
  recorded results; the rest are derived by CCwiki."
- One `Section` per depth, headed "Recorded (1 step)", "2 steps", "3 steps"
  and so on.
- Each row is the target's label, its `ModelTag`s, and a `DisclosureGroup`,
  collapsed, whose content is the proof from `closure.proof(of:)`. That is at
  most a few dozen rows, folded on expansion on the main actor.
- Context menu: **Ask About This** (sets To), Explore From Here…, Open, Copy
  Statement.

**Backward** (`… ⇒* PKE`), from `implying(_:options:)`:

- The verdict reads "Everything the wiki's reductions derive this from"
  (§7's header), then "29 objects alone · 43 pairs". Its tooltip: "Derived by
  CCwiki. The wiki's record is incomplete."
- **"On its own"**: the singles by depth, the 11 at depth 1 marked "recorded".
  Each is disclosable to its proof, from `answer(from: [single], to:)` on first
  expansion, synchronously; one closure is well under a millisecond.
- **"Together with one other"**: one group per joining conjunctive edge,
  headed by that edge and its source, "Through OWF + iO ⇒ PKE · SW14 · 24
  pairs". The rows are the pairs, `CDH ∧ Differing-inputs obfuscation`, each
  one row and one claim. At most 12 rows per group (R11), then "and N more" as
  plain text.

**The footer** for both: "Derived by CCwiki from the reductions the wiki
records. Something missing here is not evidence that it does not follow."

### 2.9 Keyboard

| Keys | Where | Does |
|---|---|---|
| ⇧⌘E | anywhere | shows the explorer, focus in From |
| ⌥⇧⌘E | main window | Explore From This Page (§2.11) |
| typing | From, To | suggestions replace the results |
| ↓ ↑ | a field with suggestions | move the highlight (`onKeyPress`, as `SearchPalette`) |
| Return, Tab or `,` | a field with suggestions | commit the highlighted object as a token (`,` as in Mail) |
| Tab / ⇧Tab | an empty field | From → To → results, and back |
| ⌫ | an empty field | selects the last token; a second ⌫ removes it |
| Esc | a field | hides the suggestions; a second Esc clears the typed text. Never closes the window |
| ↑ ↓ → ← | results | move; expand and collapse (native outline) |
| Return, double-click | results | the row's primary action (§2.6) |
| ⌘C | results | Copy Statement of the selected rows |

The footer of the suggestion area shows the keycaps, as both palettes do
(`SWIFTUI-RULES` §8.6): "↩ add · ⇥ next field · esc dismiss".

### 2.10 Empty and resting states

Each is a `ContentUnavailableView` (`SWIFTUI-RULES` §7.1).

| State | Title, symbol | Description, action |
|---|---|---|
| Library not loaded yet (`libraryGeneration == 0`) | "Loading the Wiki", `ProgressView` | none |
| Manifest unavailable | "Relationships Unavailable", `arrow.triangle.branch` | the diagnostic's message; **Sync Now** when the file is missing (the inspector's wording) |
| Empty question | "Ask What Follows From What", `arrow.triangle.branch` | "Add objects to From to see everything they derive together, or an object to To to see what derives it." **Explore From This Page** when the reader's page has one |
| Forward, nothing derived | "Nothing Derived", `circle.dashed` | "The wiki records no reduction that starts from *X* in these models." Plus **Include Idealised Models** when the toggle is off |
| Backward, nothing found | "No Recorded Sources", `circle.dashed` | the same, mirrored |
| No suggestion matches | `ContentUnavailableView.search(text:)` | the complexity-class sentence when only classes matched |

### 2.11 Entry points and shortcuts

**Shortcuts already taken** (`CCwikiApp.swift`; `RootView.swift` declares
none, and its toolbar buttons only name them in tooltips):

| Shortcut | Command | Line |
|---|---|---|
| ⌘O | Quick Switcher | 148 |
| ⇧⌘N | Ingest a Paper (File and Jobs menus) | 152, 272 |
| ⌘F, ⌘G, ⇧⌘G | Find on Page, Next, Previous | 158–166 |
| ⇧⌘F | Find in All Pages | 171 |
| ⌘S | Search the Wiki | 179 |
| ⇧⌘R | Search References | 184 |
| ⌘P | Print | 194 |
| ⌘R | Sync with GitHub | 220 |
| ⇧⌘H | Go Home | 225 |
| ⇧⌘J | Show Jobs (menu and Window scene) | 276, 35 |
| ⌘+, ⌘−, ⌘0 | Text size | 108–116 |
| ⌥⌘I | Toggle Inspector | 122 |
| ⌥⌘1, ⌥⌘2, ⌥⌘3 | Outline, Backlinks, Relations | 126–132 |
| ⌘[, ⌘] | Back, Forward | 138, 142 |
| Esc, ⌘Return, Return | sheets: dismiss, submit ingest, Sync Log default | sheet views |

**Owned by the system** and avoided: ⌘, ⌘Q ⌘H ⌥⌘H ⌘W ⌘M ⌘\` ⌃⌘S (Show
Sidebar) ⌃⌘F, the Edit set, and, by AppKit convention, ⌘E (Use Selection for
Find) and ⌘J (Jump to Selection).

**Proposed:**

- **⇧⌘E — Show Relations Explorer.** The shape of ⇧⌘J for the other
  secondary window; E for *explore*; free in the app and in the system set.
  It calls `openWindow(id:)` directly, as Show Jobs does, so it works from any
  window.
- **⌥⇧⌘E — Explore From This Page.** The Option form is the "this page"
  variant, as Option variants are on the Mac. It needs the reader's page, so
  it is disabled unless the main window is focused and the page has a
  participant.

Both go in the **Wiki** menu after Random Page, behind a divider. SwiftUI
adds the scene to the Window menu by itself.

**Other entry points:**

- **Relations inspector rows**, as a context-menu item **Explore From Here…**.
  The objects are the ones the row names:
  - an object row (an endpoint on a reduction or barrier page): From = that
    object;
  - a Builds on, Contained in or Equivalent to row: From = the far end;
  - a Produces or Contains row: From = the whole conjunction it shows;
  - a barrier row: From = its hypotheses, **To = its conclusion**. That opens
    the answer for the ruled-out edge with the barrier in it: usually no
    derivation, and for BH26's OIHF ⇒ OT a recorded free reduction beside the
    fully-black-box barrier it circumvents;
  - the derived rows of §3: Show Proof, and Explore From Here… on the target.
- **The reader's context menu.** `ReaderWebView.willOpenMenu` adds "Explore
  From This Page…" after "Copy Link to Page", when
  `model.currentPageExplorerQuery` is non-nil.
- **The explorer's own rows** (§2.6, §2.8).

**What "this page" seeds** is the pure
`ExplorerQuery.seed(for:activeAnchor:manifest:derivation:)`:

- **An object page:** the variant whose anchor is the heading being read
  (`webController.activeHeadingID`), so scrolling to *Collision resistance*
  and pressing ⌥⇧⌘E asks about CRHF. Otherwise the host object. Otherwise the
  page's first participant.
- **A reduction page:** From = its hypotheses, To = empty, so you see what
  the hypotheses give together.
- **A barrier page:** From = its hypotheses, To = its conclusion.
- **A complexity class, or a page the manifest does not know:** `nil`, and
  the commands are disabled.

**Every entry point goes through `model.explore(_:)`.** It pushes the current
question onto Recent when it differs, sets the new one with the models toggle
kept, and bumps `explorerWindowRequests`. `RootView` answers with
`.onChange { openWindow(id:) }`, exactly as it does for Jobs. That is the one
path that works from AppKit (the reader's `NSMenu`) as well as from SwiftUI.

### 2.12 State

| What | Where | Lifetime |
|---|---|---|
| The question (From, To) | `AppModel.explorerQuery`, persisted as JSON under `ccwiki.explorer.query` | Across launches; restored with the window |
| The models toggle | in the same JSON | **Reset to off at every launch** (§2.4); kept inside Recent entries |
| Recent questions | `ccwiki.explorer.recents`, at most 10 | Pushed when `explore(_:)` replaces a question, and when the window closes (`onDisappear`). Two clear moments, no debouncing |
| Window frame | SwiftUI scene restoration | Automatic |
| Collapsed proof nodes, selection | view `@State` | Ephemeral, by design: `SWIFTUI-RULES` §3.3 is the reason not to persist them |
| The answer | view `@State`, keyed on `(explorerQuery, libraryGeneration)` | Recomputed after every sync |

Ids are persisted, never labels, so a renamed title still matches.

### 2.13 Accessibility

- **The From field** is one container, "From, all of:", whose tokens are
  buttons labelled "Hash function § Preimage resistance, premise 1 of 2", each
  with an accessibility action **Remove**. The `∧` separators are hidden; the
  container's label carries the conjunction.
- **Suggestion rows** are buttons. The highlighted one has `.isSelected`. On
  each new list, `AccessibilityNotification.Announcement("8 suggestions")`.
- **A proof row** is `accessibilityElement(children: .combine)` with a
  sentence label: "Public key encryption, derived by CS03 from Key
  encapsulation mechanism and Symmetric key encryption, fully black-box."
  A premise reads "…, given"; a repeat reads "…, shown above".
- **When the outcome changes** (not on every keystroke), the verdict is
  announced: "Derivable in 4 steps", "No derivation found".
- **Colour never carries meaning alone.** Model tags are words, and a stub
  keeps its `StatusBadge`, which names itself.
- Semantic fonts only, and the focus ring is AppKit's (`SWIFTUI-RULES` §5.1, §7.3).

### 2.14 Threading and cost

The reference engine in Python takes:

- `ddh`'s closure: 0.7 ms;
- `{owf} ⇒ pke` with its completions: 186 ms, the worst query (it runs about
  a hundred closures);
- `implying("ot")`: 400 ms, the worst backward call.

derivations.md §4 measures the same order: 75–130 ms for a no-path answer,
and 77–125 ms for PKE's backward closure.

Swift will be one to two orders faster, and that is still not main-actor
work. So:

```swift
.task(id: ExplorerTaskKey(query: model.explorerQuery, generation: model.libraryGeneration)) {
    let derivation = model.derivation          // a Sendable value
    let query = model.explorerQuery
    let result = await Task.detached(priority: .userInitiated) {
        ExplorerResult.compute(query, derivation)
    }.value
    guard !Task.isCancelled else { return }
    self.result = result
}
```

- The previous answer stays up until the new one lands, so there is no flash
  between keystrokes.
- After 150 ms a small `ProgressView` appears in the verdict band.
- A superseded detached task runs to completion and is discarded. That is
  cheaper than threading cancellation through the engine.

## 3. Inspector: derived sections

### 3.1 Where, and which models

- **Placement.** Below every recorded group in the Relations tab, on **object
  pages only** (`PageRelations.Subject.objects`). A reduction or barrier page
  is one edge, and what its endpoints derive is on their own pages.
- **One pair of sections per page**, not one per object: **"Derived:
  implies"** and **"Derived: implied by"**. A page hosting several objects
  (the hash function page hosts OWF, CRHF and more) gets an object caption row
  before each object's rows, the inspector's existing secondary name style.
  Two headers per page, however many variants.
- Above them, one caption row in `Theme.Fonts.meta` `.tertiary`: "Derived by
  CCwiki from the recorded reductions above." It sits where the eye passes
  from what the wiki says to what CCwiki computes.
- **Always the default models.** The inspector is the most-viewed surface and
  a glance surface, so it is the last place for a tagged idealised chain. The
  headers' tooltips say so, and point to the explorer for the rest.

### 3.2 What a row is

- **Derived means depth ≥ 2.** A depth-1 fact is a recorded single-premise
  step (or an equivalence read backwards), and the recorded groups above
  already show it.
- A target that is reached recorded-in-ROM *and* derived-in-standard appears
  in both places, correctly: the recorded row says ROM, the derived row says
  how to do without it.
- **Implies** is `derivation.derivedImplications(of: id, options: .standard)`;
  **implied by** is `derivation.derivedSources(of: id, options: .standard)`.
  Both are lookups into the single-object closures that `Derivation.init`
  precomputes (derivations.md §3), sorted by depth and then by label.
- **On today's data:**
  - DDH has 33 facts in its closure; 6 are recorded steps, so it gets 27
    derived rows, among them OT at 3 steps and MPC at 4.
  - GapSVP, SIVP and succinct LWE reach 34 facts each; GapSVP gets 32
    derived rows.
  - PKE has 29 single sources, 11 of them recorded, so 18 derived rows under
    "implied by". OT has 22, so 15.

### 3.3 Row anatomy and distinction

The GapSVP page, from the reference engine:

```
Derived by CCwiki from the recorded reductions above.
▾ Derived: implies                                         32
    ⇒* Hash function § Collision resistance           2 steps
    ⇒* Public key encryption                          2 steps
       quantum setting
    ⇒* Non-interactive zero-knowledge                 2 steps
       CRS model · quantum setting
    ⇒* Key exchange                                   3 steps
       quantum setting
    …
```

GapSVP has no derived sources, so its page has no "Derived: implied by"
section at all.

- **`⇒*` / `⇐*`** in `.secondary`: the transitive-closure star, which a
  cryptographer reads as *derivable*, never as a recorded `⇒`.
- **The label in `.secondary`.** Recorded rows are `.primary`. De-emphasis is
  colour, never weight (design-system §1). There is no status dot: a derived
  row is not a page.
- **A trailing step badge**, "3 steps", in the badge metrics with `.secondary`
  text on a `.quaternary` fill. It is `fixedSize` (`SWIFTUI-RULES` §2.2). **A step is a layer
  of the shortest proof:** the depth, which is the distance the engine
  minimises. The tooltip gives the reduction count.
- **A second line only for models other than standard** that are on by
  default: "quantum setting", "CRS model", in `Theme.Fonts.meta`. Reg05's
  quantum GapSVP ⇒ LWE is the common case.
- **The headers** are `Theme.Fonts.sectionHeader`, carry the dotted-path
  symbol `point.3.connected.trianglepath.dotted`, and show a trailing count in
  `.tertiary`.
- **The headers' tooltips:**
  - **implies:** "What this implies through two or more recorded reductions
    chained together. Derived by CCwiki; the wiki does not state these
    chains. Standard, quantum and CRS models only; the Relations Explorer can
    include the others. Click a row for its proof."
  - **implied by:** "Objects that each imply this through two or more
    recorded reductions chained together, derived by CCwiki from what the wiki
    records, which is not everything known. Combinations of several objects
    are in the Relations Explorer."
- **A row's tooltip:** "DDH ⇒* Oblivious transfer", then "Derived by CCwiki
  from 3 recorded reductions; 3 steps.", then the chain class in §2.6's words
  ("Class unstated: 3 steps do not state theirs"), then "Click to see the
  proof."
- **The last row of each "implied by" block** is a link-styled "Combinations
  of several objects…", which opens backward mode on that object. No count is
  shown, because counting pairs means the backward search the inspector must
  not run at load.

### 3.4 Behaviour

- **Click (the whole row is a `Button`, as the recorded rows are):**
  `model.explore(ExplorerQuery(from: [id], to: target))` for *implies*, and
  `from: [source], to: id` for *implied by*. That shows the proof. The
  explorer keeps its models toggle; under R4's two-phase closure a fact
  derivable in the default models keeps its default-model proof either way.
- **Context menu:** Show Proof, Explore From Here… (From = the row's object),
  Open *label*, and Copy Statement ("DDH ⇒* Oblivious transfer (derived by
  CCwiki from 3 recorded reductions)").
- **Collapsed by default.** `Section(isExpanded:content:header:)` is
  macOS 14. `make shots` must confirm that the inset list style draws its
  disclosure. If it does not, the header becomes a `Button` with a rotating
  chevron that flips the bound `Bool`, with no `withAnimation` (`SWIFTUI-RULES` §1.2).
- **The expanded state persists per role** (`ccwiki.derivedSectionsExpanded`,
  a set of `implies` / `impliedBy`), not per page. That is how an Xcode
  inspector section behaves: open it once and it stays open as you move
  around.
- **VoiceOver:** "Oblivious transfer, derived in 3 steps, quantum setting".
  Hint: "Shows the proof in the Relations Explorer."

### 3.5 Cost

- **`Derivation` is built once per manifest load**, inside the detached task
  in `AppModel.loadLibrary()` that already builds `RelationsManifest` and
  `RelationLabels`.
- It is assigned in the same main-actor block as the manifest, so the
  inspector never sees a manifest and closures from different commits
  (`SWIFTUI-RULES` §3.1: rebuilt from source, never patched).
- **The build** is 468 single-object closures, both settings, plus the
  inverted index for `derivedSources`. That is 211 ms in Python
  (derivations.md §4), so a few milliseconds in Swift.
- **The view does dictionary lookups.** A pure `PageDerivations(path:manifest:
  derivation:labels:)` sorts at most 34 rows per object. It is computed per
  read, like `currentRelations` and for the same reason (AppModel's comment
  on it).

## 4. Link previews

### 4.1 What shows, and when not

The site's Quartz popover (`enablePopovers: true`) fetches the target page and
shows all of it in a 30 rem scrollable box you can hover into. CCwiki shows a
**summary card** instead: the reader is offline, there is no page to fetch,
and a second full render of the target (KaTeX, pseudocode) on every hover is
what the reader exists to avoid. The card is computed in Swift with the page,
and **JS never asks Swift for anything**.

| Target | Kind line | Title | Meta | Excerpt |
|---|---|---|---|---|
| Object page | "Primitive", "Assumption", "Complexity class", "Glossary", "Folklore", "Note" (+ " · stub") | page title | none | first paragraph |
| A section, including a variant (`page#anchor`) | "Section of *Host title*" | variant label, else the heading text | none | first paragraph of that section |
| Reduction page | "Reduction" (or "Equivalence", "Inclusion") | **the hyperedge from the manifest**, `RelationLabels.statement`: every hypothesis, `⇢` if heuristic, never truncated | `RelationMeta.parts` (the page's own line: class, model, "heuristic candidate", via, sources, loss) | first paragraph (the Statement section's) |
| Barrier page | "Barrier" | the page title ("No relativizing reduction from OWP to KE"), **not** the bare edge, which alone would read as an implication | `RelationMeta.parts` (strength, against-class, assuming, sources), **plus "circumvented by BH26"** when it is: the contract applies to previews too | first paragraph |
| Reference | "Reference" | the paper's title (`displayTitle`) | authors (four or fewer, else "First et al."), venue, year | the abstract's first paragraph, unless it is a `TODO` placeholder |
| External, asset, folder, same-page anchor, broken | **no card** | | | |

- **Folder listings get no previews.** Their rows already carry the title and
  status, and 545 entries on the References listing is payload with no
  reader.
- **Unlisted pages do get previews.** A link reaches them, and that is what
  `unlisted` permits.

### 4.2 Swift: computing the payload

- **`LinkPreviews`** (Track D; interface in §6.6) is built in the same detached
  `loadLibrary` task as `RelationLabels`, holding every page-level card. The
  corpus is 883 files with one paragraph scan each, a few tens of
  milliseconds. Section cards (`page#anchor`) are computed at render time for
  the anchored links on the page being shown, typically under ten.
- **`PageRenderer`** gains `var linkPreviews = LinkPreviews.empty` and
  `var buildsPreviews = true`, the latter cleared when the Settings toggle is
  off (§4.6). For every link that resolves to `.page(path, anchor)`, it sets
  `request.previews[href] = linkPreviews.preview(path:anchor:)`.
- **Keyed by the resolved `href`**, not by the raw link text. Several raw
  links share a target, and `href` is exactly the string `ccwiki.js` reads back
  with `getAttribute("href")`.

**The first paragraph, `PreviewExcerpt.firstParagraph(in:anchor:)`**, is pure
and tested:

- **Scope:** the body after the first ATX H1, or the whole body if there is
  none. With an anchor, the section whose heading id matches, using the same
  deduplicating `GithubSlugger` as `WikiPage.headings()`, so the first match
  wins as Quartz anchors do, up to the next heading of the same or a higher
  level.
- **Walk blocks** with the fence rule `RelationMeta.insertUnderH1` uses (` ``` `
  or `~~~` runs, the closing run at least as long).
- **Skip:**
  - headings;
  - fenced blocks, `pseudocode` included;
  - `$$` display blocks;
  - HTML blocks and comments;
  - blockquotes and callouts;
  - tables, list items, embeds (`![[`);
  - **the relation-meta paragraph**, any paragraph ending in
    `RelationMeta.marker`. Previews read `page.body`, which does not carry the
    splice today, and this check keeps it so if they ever read the rendered
    markdown;
  - **the reference byline** (`**Authors:**…`);
  - **placeholders** (a paragraph starting `TODO`). 236 of the 430 reference
    pages have no abstract yet, and "TODO — abstract." is not a preview.
- **Join** the paragraph's lines with single spaces. The wiki hard-wraps
  prose.
- **Reduce to inline markdown without links:**
  - `[[target|alias]]` → its display text, by the same rule as `displayText`
    in `ccwiki.js` (alias, else the last path segment, plus ` › anchor`);
  - `[text](dest)` → its text;
  - footnote markers, images and inline HTML tags dropped.
  - **`$…$`, `**`, `_` and backticks are kept**, so JS renders math and
    emphasis.
- **Truncate:**
  - at the last sentence end at or before 280 characters, or else at the last
    space before 420, followed by `…`;
  - **never inside a `$…$` or a code span**, by the pairing rule
    `RelationMeta.escapeOutsideMath` uses;
  - an emphasis marker left unclosed by the cut is removed.
- **Caps:** an object page's title at 160; a statement never; each meta part
  at 120 (security losses run long); `label` at 700. **A card is at most about
  1.2 KB.** The busiest page, LWE, has 55 distinct link targets, so about
  70 KB of payload at worst; the median page has a handful.

**The payload** is one top-level key in `RenderRequest.jsonPayload()`:

```json
"previews": {
  "ccwiki://wiki/page/Reductions%2Fprg-to-prf-ggm86.md": {
    "kind": "Reduction",
    "title": "Pseudorandom generator ⇒ Pseudorandom function",
    "meta": ["Fully-black-box reduction", "standard model", "GGM86"],
    "excerpt": "If $G : \\bits^n \\to \\bits^{2n}$ is a length-doubling PRG, …",
    "label": "Reduction. Pseudorandom generator ⇒ Pseudorandom function. Fully-black-box reduction, standard model, GGM86. If G …"
  }
}
```

Every word on the card is chosen in Swift; JS only lays it out.

### 4.3 JavaScript: `ccwiki.js`

- **One card element**, created once and appended to `body`, outside
  `#page`: `<div class="link-preview" role="tooltip" id="ccwiki-link-preview"
  hidden>` with four children (`-kind`, `-title`, `-meta`, `-excerpt`).
  - **Hidden means `hidden`**, never `opacity: 0`, so find in page cannot
    match a card's text. That is the copy buttons' lesson
    ([render-pipeline.md](render-pipeline.md) §3).
  - It sits outside `#page`, so a selection in the page never includes it,
    and `pointer-events: none`, so it never takes a click.
- **`render(payload)`** stores `payload.previews || {}`, clears a per-render
  cache of rendered cards, and hides any visible card.
- **Delegated listeners on `document`:**
  - **Open:** `mouseover` on `a.internal` whose `href` has an entry, after
    **450 ms**. That sits between the site's 200 ms and a macOS tooltip's
    roughly one second: long enough that a pointer crossing a dense paragraph
    does not flash cards.
  - **Warm switching:** a card shown within 400 ms of the last one opens with
    no delay.
  - **Close:** `mouseout` whose `relatedTarget` is outside the same anchor,
    after 100 ms. A link that wraps across two lines fires `mouseout` between
    its line boxes.
  - **Close at once** on `mousedown`, `contextmenu`, `scroll` (passive),
    `keydown` Escape, window `blur`, and any `render`.
  - **No card while a mouse button is down.** A text selection drag passes
    over links.
  - **Keyboard:** `focusin` on a link opens after the same delay; `focusout`
    closes.
  - **External links never open a card,** twice over: they have class
    `external` rather than `internal`, and Swift builds no entry for them.
- **Position:** `position: fixed`.
  - Below the client rect under the pointer, as floating-ui's `inline`
    middleware does on the site: `getClientRects()`, the rect containing the
    pointer's y, or the first rect for keyboard focus. 8 px gap.
  - Flipped above when it would cross the bottom of the viewport; clamped
    12 px inside the left and right edges.
- **Rendering.** `ensureMarkdown(macros)` also builds a second instance,
  `previewMarkdown`: `markdownit({ html: false, linkify: false,
  typographer: true })`, with only the `math_inline` rule and its KaTeX
  renderer, keyed on the same macro table, so the site's macros render in
  cards.
  - Title, each meta part and the excerpt go through
    `previewMarkdown.renderInline`. Meta parts are joined with
    `RelationMeta.separator`'s glyph.
  - `html: false` means anything Swift missed is escaped, not injected.
  - A KaTeX failure falls back to the escaped source in `<code>`, as the
    page's own math does.
- **For the visual gate:** `CCwiki.showPreview(href)` (opens the card on the
  first matching link) and `CCwiki.hidePreview()`, beside `createMarkdown`,
  which is exposed for the same reason.

### 4.4 CSS: `app.css`

Document type, because a card is a piece of the document. The hierarchy
follows design-system §1: emphasis is weight, de-emphasis is colour.

| Part | Face | Size / line | Weight | Colour |
|---|---|---|---|---|
| kind | system sans, `letter-spacing: 0.06em`, uppercase | 0.72rem | 600 | `--text-tertiary` |
| title | system sans | 0.92rem / 1.3 | 600 | `--text` |
| meta | system sans | 0.78rem / 1.45 | 400 | `--text-secondary` (the `.relation-meta` vocabulary) |
| excerpt | the document serif | 0.86rem / 1.5 | 400 | `--text` |

- **The box:** `--bg-raised` background, a 1 px `--rule-strong` border,
  8 px radius, padding 0.65rem 0.8rem, and
  `max-width: min(23rem, calc(100vw - 24px))`.
- **A backstop** `max-height: 16rem`, with a bottom fade from `--bg-raised`;
  the Swift caps make it rare.
- **Shadow:** `0 6px 24px rgba(0,0,0,.14), 0 1px 3px rgba(0,0,0,.08)` in
  light, and the alpha raised to .45 under `prefers-color-scheme: dark`. The
  tokens already flip, which is design-system §2's point.
- `.link-preview .katex { font-size: 1em; }`, as in the meta line.
- `z-index: 10`, above the folder listing's sticky letters.
- **Motion:** a 120 ms opacity fade in, and none under
  `prefers-reduced-motion: reduce`.
- **Print:** in the existing `@media print` block, add
  `.link-preview { display: none !important; }` beside `.notice, .copy-row`.

### 4.5 Keyboard and VoiceOver

- WebKit only Tab-focuses links when the user has turned on *Press Tab to
  highlight each item* (Safari) or Keyboard Navigation (System Settings). With
  it on, focus opens the card as hover does.
- While a card is shown, its link gets `aria-describedby` pointing at it, and
  the card's `aria-label` is Swift's `label`, the whole card as plain text.
  This matters because KaTeX's HTML output, which the site uses, is not
  readable by VoiceOver.
- The relation facts in a card are a convenience, never the only place they
  live: the Relations inspector carries all of them for keyboard and VoiceOver
  users.

### 4.6 The setting

Settings → Reading → **Show link previews on hover**, persisted as
`ccwiki.showsLinkPreviews`, on by default. Its footer: "A card with the
target's title and first paragraph, or a reduction's statement and how it
holds. Hover over a link for half a second."

Off, `PageRenderer.buildsPreviews` is false, the payload carries no
`previews`, and JS has nothing to show: no JS flag needed. The toggle
invalidates and re-renders, as `showsMaintenanceNotices` does.

## 5. Type and visual vocabulary

Phase 0 adds the following to `Theme`. Each is a named metric, per
`SWIFTUI-RULES` §2.4:

```swift
// MARK: Relations explorer
static let explorerMinWidth: CGFloat = 620
static let explorerMinHeight: CGFloat = 460
static let explorerDefaultWidth: CGFloat = 820
static let explorerDefaultHeight: CGFloat = 640
static let tokenCornerRadius: CGFloat = 5
static let explorerSuggestionLimit = 8

// in Theme.Fonts
/// The explorer's answer: "Derivable", "No derivation found".
static let verdict = Font.title3.weight(.semibold)
```

**One chip vocabulary** (`SWIFTUI-RULES` §5.4). Phase 0 adds
`UI/ModelTag.swift`, used by the explorer and the inspector alike:

```swift
struct ModelTag: View { let model: String }
```

It shows `RelationVocabulary.modelName(model)` in `Theme.Fonts.badge` with the
badge metrics, on a `.quaternary` fill. It is neutral, because a model is a
caveat and not an error (not orange). Its VoiceOver label is "uses the random
oracle model". `"unknown"` (a stub's effective model, R3) reads "stub", as
derivations.md §7 has it.

**Glyphs:**

| Glyph | Meaning | Where |
|---|---|---|
| `⇒` | recorded implication | as today |
| `⇒*` `⇐*` | derived by CCwiki | the explorer and the inspector. `RelationVocabulary.derivedArrow = "⇒*"` |
| `⇐` | "by this step", on a proof row | the explorer |
| `∧` | conjunction | From, proof premises, pairs |

## 6. Parallel tracks: who owns which file

Four tracks, after one small Phase 0 that lands every seam they share. After
Phase 0, **no two tracks edit the same file**.

### 6.1 Phase 0: the seams

One PR. It compiles, it changes no behaviour visible to a reader, and it
lands first. The owner is whoever merges; it is mechanical.

| File | Change |
|---|---|
| `Wiki/Derivation.swift` (new) | every declaration in §6.6 under "Engine", with bodies that return empty values: `Derivation.empty`, empty closures, `.notDerived` with every list empty. Track A replaces the bodies |
| `Wiki/ExplorerQuery.swift` (new) | `ExplorerQuery` (Codable), `seed(…)` returning `nil` |
| `Wiki/LinkPreview.swift` (new) | `LinkPreview`, `LinkPreviews` with `.empty` and `preview(path:anchor:)` returning `nil` |
| `Wiki/RelationFormatting.swift` (new) | **a pure move, no behaviour change**: `metaParts(for:)`, `help(for:)` (for both `Relation` and `Barrier`), `citations`, `classLabel`, `modelLabel`, `circumvention(of:)`, out of `RelationsView` into a struct taking `RelationsManifest` and `RelationLabels`. `RelationsView` calls it |
| `UI/ModelTag.swift` (new) | §5 |
| `UI/RelationsExplorerView.swift` (new) | a placeholder: `ContentUnavailableView("Relations Explorer", …)` |
| `App/Theme.swift` | §5's metrics |
| `App/Settings.swift` | `explorerQuery`, `explorerRecents`, `derivedSectionsExpanded`, `showsLinkPreviews` (default `true`) |
| `App/AppModel.swift` | the stored properties and methods in §6.6 under "AppModel". `loadLibrary` builds `Derivation` and `LinkPreviews` in its detached task, now returning a small `LoadedLibrary` struct instead of a five-tuple, and bumps `libraryGeneration`. `renderCurrent` passes `linkPreviews` and `buildsPreviews` to `PageRenderer`. `init` wires `webController.exploreHere`. `showsLinkPreviews` re-renders on change |
| `App/CCwikiApp.swift` | `WindowGroup(id: mainWindowID)`; the explorer `Window` scene; the two Wiki-menu commands; `explorerWindowID`, `mainWindowID` |
| `UI/RootView.swift` | `.onChange(of: model.explorerWindowRequests) { openWindow(id: explorerWindowID) }`; `mainWindowCount` incremented in `onAppear`, decremented in `onDisappear` |
| `Reader/RenderRequest.swift` | `var previews: [String: LinkPreview] = [:]` and its key in `jsonPayload()`; `PageRenderer.linkPreviews` and `.buildsPreviews` (unused until Track D) |
| `Reader/WebController.swift` | `var exploreHere: (() -> ExplorerQuery?)?`, `var onExplore: ((ExplorerQuery) -> Void)?`, and `showPreviewForTesting(href:)`, which evaluates `window.CCwiki.showPreview && CCwiki.showPreview(href)` and is harmless before Track D |
| `App/ScreenshotRunner.swift` | steps `explorer:<from,…>[><to>][,all]`, `derived`, `preview:<page path>><href>` (§7) |
| `PLAN.md` | index entries for this file and `derivations.md` |

Giving the `WindowGroup` an id may reset its saved frame once, a one-off cost
noted in the release notes. If a live run shows anything worse, Phase 0 drops
the id and the explorer falls back to leaving `model.openPage` unshown when no
reader is open, which is what Jobs does today.

### 6.2 Track A: the engine

- **Owns:** `Wiki/Derivation.swift`,
  `Tests/CCwikiTests/DerivationTests.swift`, the golden fixture
  `Tests/CCwikiTests/Fixtures/derivations-golden.json`, `derivations.md`,
  `scripts/derivations_reference.py`.
- **Edits nothing else.** The specification and rules are in
  [derivations.md](derivations.md).
- **Interface obligations beyond derivations.md §3's sketch** (all listed in
  §6.7):
  - `participants(_:)` and `isModelNode(_:)`;
  - `derivedImplications(of:options:)` and `derivedSources(of:options:)`,
    with `relationCount` per link;
  - the fields of `DerivedAnswer`, `NoPathAnswer`, `BackwardClosure` and
    `DerivedBarrier` spelled out in §6.6;
  - a typed `Unsupported` and a `RefusedStep` naming its scoped hypotheses;
  - the four R9 hint kinds.

### 6.3 Track B: the explorer window

- **Owns:** `UI/RelationsExplorerView.swift`, `UI/ObjectTokenField.swift`
  (including `TokenFlowLayout`), `UI/ProofOutline.swift`,
  `Wiki/RelationObjectMatcher.swift`, `Wiki/ExplorerQuery.swift` (filling
  `seed`), `Wiki/ExplorerResult.swift` (the pure "query → what to show" step,
  so the view only lays out), and the tests `RelationObjectMatcherTests.swift`,
  `ExplorerQueryTests.swift` and `ExplorerResultTests.swift`.
- **One shared-file edit**, in `Reader/WebController.swift`: the "Explore
  From This Page…" item in `ReaderWebView.willOpenMenu`, calling Phase 0's
  `exploreHere` and `onExplore`.
- **Consumes:** the Engine interface, `AppModel.explore(_:)` and
  `explorerQuery`, `RelationFormatting`, `ModelTag`.
- **Interface it publishes:**

```swift
struct RelationObjectMatcher: Sendable {
    struct Item: Identifiable, Sendable, Hashable {
        let id: String                   // a manifest object or variant id
        let label: String
        /// "Assumption", "Section of Hash functions", "Idealised model", or the alias matched.
        let detail: String?
        let score: Int
    }
    init(manifest: RelationsManifest, labels: RelationLabels, participants: Set<String>)
    /// Best first, at most `limit`, never an id in `excluding`. Empty for an empty query.
    func matches(_ query: String, excluding: Set<String>, limit: Int) -> [Item]
}
```

### 6.4 Track C: the inspector sections

- **Owns:** `Wiki/PageDerivations.swift`, `UI/DerivedRelationsSections.swift`,
  `Tests/CCwikiTests/PageDerivationsTests.swift`.
- **One shared-file edit**, in `UI/RelationsView.swift`:
  - append `DerivedRelationsSections(page:)` after the recorded groups in
    `list(_:)`;
  - add "Explore From Here…" to the context menus of relation, barrier and
    object rows (§2.11), through `model.explore(_:)`.
- **Consumes:** `Derivation.derivedImplications(of:options:)` and
  `derivedSources(of:options:)`, `AppModel.explore(_:)`,
  `CCwikiSettings.derivedSectionsExpanded`, `ModelTag`.
- **Interface it publishes** (pure, Sendable, tested without a view):

```swift
struct PageDerivations: Sendable {
    enum Role: String, Sendable, CaseIterable { case implies, impliedBy }
    struct Block: Sendable, Identifiable {
        let objectID: String             // the page's object this block is about
        let role: Role
        let rows: [Derivation.Link]      // depth ≥ 2, sorted by depth then label
        var id: String { "\(objectID)/\(role.rawValue)" }
    }
    let blocks: [Block]                  // object order as PageRelations; empty blocks omitted
    func count(_ role: Role) -> Int
    init(path: String, manifest: RelationsManifest, derivation: Derivation,
         labels: RelationLabels)          // always Derivation.Options.standard (§3.1)
}
```

### 6.5 Track D: link previews

- **Owns:** `Wiki/LinkPreview.swift` (`LinkPreviews`, `PreviewExcerpt`),
  `Resources/web/ccwiki.js`, `Resources/web/app.css`,
  `Tests/CCwikiTests/LinkPreviewTests.swift`.
- **Shared-file edits:**
  - `Reader/RenderRequest.swift`: filling `previews` in
    `PageRenderer.request`;
  - `UI/SettingsView.swift`: the toggle;
  - `plans/render-pipeline.md` §3: "popovers" moves from *not reproduced* to
    *reproduced differently*.
- **Consumes:** `WikiIndex`, `RelationsManifest`, `RelationLabels`,
  `RelationMeta.parts`.

### 6.6 The interfaces, exactly

**Engine** (Track A implements; Tracks B and C consume). This is
derivations.md §3's sketch, nesting and names kept, with the fields the UI
reads spelled out. Ids are `String`, as everywhere in `RelationsManifest`.
`closure`, `answer` and `implying` are the brief's `derive`, `query` and
`backward`. Bodies and stored properties are elided; this is the surface the
other tracks compile against.

```swift
struct Derivation: Sendable {

    struct Options: Hashable, Sendable {
        /// R4's toggle: also `rom`, `generic-group`, `algebraic-group`,
        /// `other`, and stub steps. What they add is model-scoped (R5).
        var includesIdealisedModels = false
        static let standard = Options()
        static let all = Options(includesIdealisedModels: true)
    }

    /// One directed use of a reduction (R1); an equivalence yields two.
    /// `hypotheses` is the whole conjunction, in the edge's order — never
    /// one hypothesis of it.
    struct Step: Hashable, Sendable, Identifiable {
        let relationID: String
        let hypotheses: [String]
        let conclusion: String
        let isReverse: Bool
        let model: String                    // effective (R3, R4); "unknown" for a stub
        let reductionClass: String           // effective (R3)
        let isStub: Bool
        var id: String { isReverse ? relationID + "~reverse" : relationID }
    }

    /// R6, strongest first. A raw-value enum gets no synthesized
    /// `Comparable`, so `<` is written out, by declaration order.
    enum ChainClass: String, Sendable, Comparable {
        case fullyBlackBox = "fully-black-box", relativizing, free, unstated
    }

    struct Fact: Hashable, Sendable {
        let objectID: String
        let depth: Int                       // 0 = given
        let step: Step?                      // nil = given
        let models: Set<String>              // non-standard models used
        let isModelScoped: Bool              // R5
        let chainClass: ChainClass           // R6
    }

    /// A step R5 refused: an explanation, never a fact.
    struct RefusedStep: Hashable, Sendable {
        let step: Step
        let scopedHypotheses: [String]       // the hypotheses that hold only inside a model
    }

    struct ProofTree: Hashable, Sendable {
        /// Depth-first, hypotheses in the edge's order (R7).
        struct Row: Hashable, Sendable, Identifiable {
            let id: Int                      // position in `rows`
            let objectID: String
            let level: Int                   // 0 = the target
            let step: Step?                  // nil for a given or a reference
            let isReference: Bool            // "shown above"
        }
        let rows: [Row]
        let relationIDs: [String]            // distinct, sorted: the N of "from N"
    }

    struct Closure: Sendable {
        let start: Set<String>
        let options: Options
        let facts: [String: Fact]            // the start included, at depth 0
        let refused: [RefusedStep]
        func proof(of id: String) -> ProofTree?
    }

    struct StrongerChain: Hashable, Sendable {   // R6
        let chainClass: ChainClass
        let depth: Int
        let proof: ProofTree
    }

    struct DerivedAnswer: Sendable {
        let fact: Fact                       // the target's
        let proof: ProofTree
        let stronger: StrongerChain?         // only when it differs
        let recordedBarriers: [Barrier]      // R8: the exact pair
        let reverseBarriers: [Barrier]       // R8: one start only
    }

    struct DerivedBarrier: Hashable, Sendable {  // R12
        let barrier: Barrier                 // the recorded one it follows from
        let hypothesis: String               // A′
        let conclusion: String               // B′
        let reductionClass: ChainClass       // the class it rules out
        let up: [Step]                       // barrier.hypotheses[0] ⇒* A′
        let down: [Step]                     // B′ ⇒* barrier.conclusion
        let redundantWith: [String]          // recorded barrier ids that already say it
    }

    struct Hint: Hashable, Sendable {            // R9
        enum Kind: Hashable, Sendable { case targetSection, targetHost, startSection, startHost }
        let kind: Kind
        let objectID: String                 // the section or host
        let standsFor: String                // the start or target it is related to
        let depth: Int
    }

    struct Completion: Hashable, Sendable {      // R10.6
        let objectID: String
        let fact: Fact                       // the target, from start ∪ {objectID}
        let relationIDs: [String]
    }

    struct NoPathAnswer: Sendable {              // R10, in its order
        let recordedBarriers: [Barrier]
        let reverseBarriers: [Barrier]
        let derivedBarriers: [DerivedBarrier]    // redundant ones included, flagged
        let withIdealisedModels: Fact?           // toggle off, and on would derive it
        let modelStarts: [String]                // R4: model nodes given with the toggle off
        let refused: [RefusedStep]
        let hints: [Hint]
        let completions: [Completion]            // at most 8
        let completionCount: Int
    }

    enum Unsupported: Hashable, Sendable {
        case unknownObject(String)
        case complexityClass(String)             // R2
    }

    enum Answer: Sendable {
        case unsupported(Unsupported)
        case derived(DerivedAnswer)              // a target in the start: depth 0
        case notDerived(NoPathAnswer)
    }

    struct BackwardClosure: Sendable {           // R11
        struct Single: Hashable, Sendable { let objectID: String; let fact: Fact }
        struct Group: Hashable, Sendable {
            let relationID: String               // where the two halves meet
            let pairs: [[String]]                // each sorted; at most 12
            let pairCount: Int
        }
        let target: String
        let singles: [Single]                    // at most 40
        let singleCount: Int
        let groups: [Group]                      // most pairs first
        let pairCount: Int
    }

    /// One derived row for the inspector.
    struct Link: Hashable, Sendable, Identifiable {
        let objectID: String                     // the far end
        let fact: Fact                           // the derived end's
        let relationCount: Int
        var id: String { objectID }
    }

    static let empty: Derivation
    init(manifest: RelationsManifest)            // precomputes both settings' single closures
    let derivedBarriers: [DerivedBarrier]        // R12, all of them

    func closure(from start: Set<String>, options: Options) -> Closure
    func answer(from start: Set<String>, to target: String, options: Options) -> Answer
    func implying(_ target: String, options: Options) -> BackwardClosure

    /// Endpoints of an eligible step under `options`; never a complexity class.
    func participants(_ options: Options) -> Set<String>
    /// rom, ggm, agm and their variants (R4).
    func isModelNode(_ id: String) -> Bool
    /// What `id` alone derives at depth ≥ 2, sorted by (depth, id). A lookup.
    func derivedImplications(of id: String, options: Options) -> [Link]
    /// What alone derives `id` at depth ≥ 2, sorted by (depth, id). A lookup.
    func derivedSources(of id: String, options: Options) -> [Link]
}
```

**The question** (Phase 0 declares; Track B implements `seed`):

```swift
struct ExplorerQuery: Codable, Hashable, Sendable {
    var from: [String] = []            // entry order; a conjunction, so a set in meaning
    var to: String? = nil
    /// Persisted inside Recent entries; reset to false at launch (§2.4).
    var includesIdealisedModels = false
    var options: Derivation.Options { .init(includesIdealisedModels: includesIdealisedModels) }
    enum Mode: Sendable { case empty, forward, backward, question }
    var mode: Mode { get }
    /// The same question with the toggle off: what a launch restores (§2.4).
    func launching() -> ExplorerQuery
    static func seed(for subject: PageRelations.Subject, activeAnchor: String?,
                     manifest: RelationsManifest, derivation: Derivation) -> ExplorerQuery?
}
```

**AppModel** (Phase 0):

```swift
// MARK: Derivations
private(set) var derivation = Derivation.empty
private(set) var linkPreviews = LinkPreviews.empty
/// Bumped at the end of every `loadLibrary`, so views keyed on it recompute.
private(set) var libraryGeneration = 0

// MARK: Relations explorer
/// didSet: persisted. Read at launch through `launching()`.
var explorerQuery: ExplorerQuery
private(set) var explorerRecents: [ExplorerQuery]
private(set) var explorerWindowRequests = 0
/// RootView instances on screen; 0 means no reader window to show a page in.
var mainWindowCount = 0
/// Push the current question to Recent (when it differs), set `query` (its
/// toggle as given), and ask RootView to open the window.
func explore(_ query: ExplorerQuery)
func rememberExplorerQuery()
/// What "Explore From This Page" would ask; nil disables it (§2.11).
var currentPageExplorerQuery: ExplorerQuery? { get }

// MARK: Reading
var showsLinkPreviews: Bool               // didSet: persisted, invalidate, re-render
```

Seeding from the inspector or a context menu passes the explorer's current
toggle through, so a click never turns it on or off. Under R4's two phases a
fact derivable in the default models keeps its default proof either way.

**Previews** (Phase 0 declares; Track D implements):

```swift
struct LinkPreview: Hashable, Sendable {
    let kind: String          // display text: "Reduction", "Section of Hash functions"
    let title: String         // inline markdown; math kept, links removed
    let meta: [String]        // inline markdown parts, joined with " · "
    let excerpt: String?      // inline markdown, ≤ 420 source characters
    let label: String         // the whole card as plain text, for VoiceOver
    var jsonObject: [String: Any] { get }
}

struct LinkPreviews: Sendable {
    static let empty: LinkPreviews
    init(index: WikiIndex, manifest: RelationsManifest, labels: RelationLabels)
    /// The card for a resolved page link: precomputed for a page,
    /// computed on demand for `page#anchor`. nil when there is nothing to say.
    func preview(path: String, anchor: String?) -> LinkPreview?
}

enum PreviewExcerpt {
    static func firstParagraph(in body: String, anchor: String?) -> String?
    static func inlineWithoutLinks(_ markdown: String) -> String
    static func truncated(_ inline: String, soft: Int = 280, hard: Int = 420) -> String
}
```

**JS ↔ Swift:** `payload.previews` as §4.2. No message goes the other way.

### 6.7 Where this differs from derivations.md

The two specs were written side by side. Where they meet, this one follows
derivations.md, except here:

| Point | derivations.md | This spec | Why |
|---|---|---|---|
| A one-reduction answer | §7: "Derived by CCwiki from 1 recorded reduction" | **"Recorded"**, `⇒`, "a result the wiki records" (§2.6) | The wiki states that result. Calling it derived understates it, and teaches readers that "derived" can mean "recorded" |
| `Answer.unsupported` | `reason: String` | `Unsupported`, typed | The UI picks its title and symbol by case; wording stays in the UI |
| `Closure.refused` | `[Step]` | `[RefusedStep]`, with `scopedHypotheses` | §7's refused-step sentence names the scoped hypothesis; the reference script already reports it |
| `DerivedAnswer`, `NoPathAnswer`, `BackwardClosure` | named, fields in prose | fields spelled out (§6.6) | Tracks B and C build against them before Track A lands |
| Inspector lookups | "lookups" into precomputed closures | `derivedImplications(of:options:)`, `derivedSources(of:options:)`, `Link` | Track C's whole interface |
| `participants`, `isModelNode` | not named | added | The picker (§2.3) |
| Proof rows | flat rows, "no recursion in a view body" | kept flat; Track B folds them into `DisclosureGroup` nodes in a pure step | A native outline needs a tree; the fold is tested, the view stays declarative |
| Quantum tag | R4: "uses a quantum reduction" | §7's "quantum setting" | §7 is the later, site-aligned rule; R4's phrase reads as a different claim |

Anything else in derivations.md §7 (the toggle's name and lifetime, the
chain-class phrases, refused steps, hints, completions, the backward header,
the footer) is used as written.

### 6.8 Merge order and gates

1. **Phase 0.** `make check`; `make shots` must be identical to before,
   except the new placeholder window.
2. **Tracks A and D in parallel.** Neither depends on the other. D is
   testable on its own, and A against the golden file.
3. **Tracks B and C in parallel** once A's types are real. Both can build
   their views against Phase 0's empty engine and fixtures in the meantime:
   `ExplorerResultTests` and `PageDerivationsTests` use a hand-made
   `Derivation` over a fixture manifest, as `RelationsTests` does.
4. The integrator writes the `PROGRESS.md` entry and refreshes this file's
   numbers. Tracks do not edit `PROGRESS.md`, because four parallel edits to
   its head conflict every time.

Every track runs `make check` after every change and `make shots` before
trusting a UI change. Every PR is a draft, and **no one merges to `main`**.

## 7. Tests and the visual gate

**Unit, pure:**

- **`RelationObjectMatcherTests`:**
  - `owf`, `OWF`, `preimage` → the OWF variant first;
  - `ot` → oblivious transfer;
  - `lwe` → LWE before its variants;
  - no complexity class ever suggested;
  - excluded ids never returned.
- **`ExplorerQueryTests`:**
  - Codable round trip;
  - `launching()` turns the toggle off and keeps From and To; a Recent entry
    keeps its toggle;
  - `mode` for the four combinations;
  - `seed` on an object page with an active variant anchor, on the host, on a
    reduction page (hypotheses, no To), on a barrier page (hypotheses and
    conclusion), and `nil` on a complexity class.
- **`ExplorerResultTests`:**
  - the derivable verdict says "derived by CCwiki from N recorded reductions"
    with N = `relationIDs.count`, for N ≥ 2;
  - a one-reduction answer says "Recorded" with `⇒`, and never "derived";
  - the no-derivation text never contains "does not imply", `⇏` or
    "separat";
  - a three-premise step's second and third premises carry `∧`;
  - the footer is present in every outcome but `given`.
- **`PageDerivationsTests`:**
  - no row has depth < 2;
  - rows are sorted;
  - a multi-object page gives one block per object per role;
  - a reduction page gives none.
- **`LinkPreviewTests`:**
  - the first paragraph skips the H1, `## Statement`, a relation-meta marker
    paragraph, the byline, a `TODO`, fences, `$$` blocks and lists;
  - it keeps `$…$`;
  - truncation never splits `$…$`;
  - an anchor scopes to its section;
  - a multi-hypothesis reduction's title has every hypothesis;
  - a circumvented barrier's meta says so;
  - external, asset, folder and same-page links get no entry;
  - the LWE page's payload stays under 80 KB.
- **Corpus** (`make test-corpus`): every page-level card is non-empty except
  the 236 reference pages with no abstract and the known stubs. That number
  is pinned, so a change shows up.

**The visual gate.** New `make shots` steps, all added in Phase 0:

| Step | Shows |
|---|---|
| `explorer:owf,kem>pke` | a derivation with a conjunctive step |
| `explorer:owf>pke` | no derivation: barrier, derived barrier under it, completions |
| `explorer:fac>pke,all` | refused composition with the toggle on |
| `explorer:ddh` | forward, by depth |
| `explorer:>pke` | backward, singles and pair groups |
| `page:Assumptions/decisional-diffie-hellman.md,relations,derived` | the inspector's derived sections expanded |
| `preview:Primitives/public-key-encryption.md>ccwiki://wiki/page/Reductions%2Fkem-and-ske-to-pke.md` | a reduction card |
| each of the above, then `dark` | dark mode |

Things to check by eye, because no test can:

- the inset list draws `Section(isExpanded:)`'s disclosure;
- long variant tokens truncate in the middle without reflowing the field;
- the card flips above a link near the bottom of the window;
- the card never covers the link it describes.

## 8. Deliberately not in this spec

- **A compare mode** ("PKE vs OT"). The incompleteness trap is at its worst
  there: the data would print "only PKE implies OWF". If it is ever built, its
  columns read "recorded for A, not for B", never "only A".
- **A graph canvas.** [roadmap.md](roadmap.md) §4a still stands. The explorer
  answers the question a canvas was meant to, as a list.
- **Previews inside the explorer or the inspector.** Their rows already carry
  their facts, and every row has a tooltip.
- **Badges from `suspected-errors.json`**, which is too stale to drive them:
  the claim text has changed for 55 of its 80 entries.

**Open, and not blocking:**

- Whether a heuristic candidate that would close a gap
  (`mmap ∧ leveled FHE ⇢ iO`) deserves a line in a no-derivation answer, as
  "a heuristic candidate exists, and is not used". The engine does not report
  one today.
- Whether ⇧⌘E should also be added to Jobs' pattern of a scene-level shortcut,
  once a live run shows which of the two duplicate key equivalents AppKit
  honours.
