# Roadmap

Things deliberately deferred, with enough detail that picking one up does not
mean re-deciding it. Nothing here is started.

Ordered by how much they change the app's shape, not by priority.

> **2026-09-26.** The fixes that come *before* any of this, and the plan for
> shipping a download, are in [audit-2026-09.md](audit-2026-09.md) §6 and
> [distribution.md](distribution.md). Several "smaller things" below (job
> history across launches, `DiffGuard`) reappear there with line references.

---

## 1. A human step between the agent and GitHub

**Requested 2026-08-22.**

Today a job runs to completion and the first time you see its work is in a PR on
github.com. The asked-for shape is:

> The user uploads something, the AI suggests a summary of changes, and the user
> can refine it locally before shoving to GitHub.

So the job's terminal state gains a stage **before** `git push`:

```
… agent finishes → REVIEW → (edit) → push + gh pr create
```

What the review pane needs, in rough order of value:

1. **The diff**, rendered the way the reader renders a page — this app already
   has a markdown renderer that agrees with the website, so a proposed bullet
   should be shown as it will *look*, not as `+- foo — [[Bar|Bar]]`.
2. **The host page's own definition beside the proposed bullet.** Picking the
   wrong host page is the observed number-one real failure
   ([ingestion.md](ingestion.md) §4), and it is obvious the moment you see the
   page's `## Syntax` next to the claim.
3. **An editable PR body**, since the agent's draft is usually right in
   substance and occasionally wrong in emphasis.
4. **Editable content**, at least for the bullet text. This is where it stops
   being a review pane and starts being an editor — see §3.

Design notes already settled by the current build:

- The worktree is still there at that point (the runner only prunes on success),
  so "edit locally" means editing files in the worktree — no staging area to
  invent.
- `DiffGuard` (specified in [ingestion.md](ingestion.md) §4, not yet built) is
  the machine half of this review; the human half is the pane. Build the guard
  first: it turns "read this whole diff" into "read these two flagged lines".

## 2. A better ingestion pipeline

**Requested 2026-08-22:** *"optimize/refine the paper ingestion into a better
pipeline that more often gives the types of PRs that we want."*

The first real run ([PR #36](https://github.com/axhoover/cryptology.city/pull/36))
produced a good PR in 59 turns and $5.46. Both numbers are higher than they need
to be, and "the types of PRs we want" is a judgement that currently lives only
in one person's head. Two things to do, in this order:

**a. Write down what a good PR is, as examples rather than rules.** The wiki has
five merged `[paper]` commits and one instructive correction (`96d885c`, which
moved a bullet to the right page a day later). That is a small but real
evaluation set. A `prompts/examples/` directory of before/after diffs, fed to
the agent as few-shot material, will move output quality more than another
paragraph of prose in `prompts/ingest.md` — and it can be regenerated from the
repo's own history as it grows.

**b. Split the job into phases with a cheaper model on the cheap ones.**
Roughly: *extract metadata* (mechanical, small model), *choose the host page*
(the hard judgement, needs the good model plus the page's definition in
context), *write the bullet*, *validate and fix*. Today it is one 59-turn
conversation that re-reads the contract, the templates and a worked example
before it can start. Phases also make each step separately measurable, which is
what "more often gives the PRs we want" actually requires.

Cheap wins available now, before any restructuring:

- Cache `node_modules` between jobs. `npm ci` in a fresh worktree costs a minute
  or two every single time; a shared, gitignored install linked into the
  worktree would remove it.
- Skip `sync-cryptobib` when the page carries no `cryptobib_key` (**done**).
- Feed the agent each candidate endpoint's own definition directly in the
  prompt, instead of making it go and find the file. (This used to say "the host
  page's `# Other results` section"; the reductions migration removed that form
  — see [relations.md](relations.md).)

## 3. Correcting a page

**Requested 2026-08-22:** *"allow a user to edit/correct a page either by
themselves or with the help of an LLM to point out errors. Just having an error
button that allows for quick correction PRs (or issue opening)."*

This is the feature that turns CCwiki from a reader into a tool you use while
reading, and it is probably the highest-value item here: noticing an error is
something that happens *during* reading, and the cost of acting on it right now
is opening a browser, finding the repo, finding the file, and editing markdown
in a textarea.

Sketch:

- **A "Report a problem" affordance on every page**, and on a text selection.
  Selecting a sentence and hitting the button should carry that sentence, its
  line number and its section into whatever comes next.
- **Two outcomes, both cheap:** open a GitHub **issue** (no branch, no diff —
  the right answer when you are sure something is wrong but not what it should
  say), or open a **correction PR** (a one- or two-line edit).
- **A correction PR is a much smaller job than an ingestion job**: no paper to
  fetch, no metadata, no new page, usually one file and one line. It should run
  in seconds and cost cents, which argues for its own prompt and its own
  (smaller) model rather than reusing `prompts/ingest.md`.
- **The LLM-assisted variant** — "check this page for errors" — is a different
  thing again: a read-only pass that produces a *list* of suspected problems for
  the reader to triage, not an edit. The wiki already has a `.fact-check/`
  directory and a skeptical-checker prompt in `.orchestrator/`; read those
  before designing anything, the same way `prompts/ingest.md` defers to the
  repo's own contract.

The mechanics are all built: worktrees, the job runner, the streaming
transcript, the outcome states, `gh`. What is missing is a second job *kind* and
the UI to start one from a page.

## 4. Search ranking

Deferred with a concrete plan; see [search.md](search.md) §6. Short version:
weight the fields harder, and multiply the bm25 score by a per-kind factor so a
`primitive` or `assumption` page outranks a `reference` — except when the query
looks like a citation key, which is exactly when a reference should win.

## 4a. A graph view of the relationship hypergraph

**Deferred 2026-08-24**, deliberately and with the data already in hand.
[relations.md](relations.md) built the model and the Relations inspector; a
canvas was considered at the same time and judged not worth it yet.

The list answers the question people actually have — *what does this imply, and
what implies it* — from the page they are already reading. A canvas answers
"what does the neighbourhood look like", which is a rarer question, and the
wiki's own site already renders one.

If it is ever built, the constraint is not negotiable and is the reason this
note exists: **the graph is bipartite.** Nodes are objects *and* reductions;
edges run object → reduction → object. Drawing an object-to-object edge would
turn each of the 42 multi-hypothesis reductions into several independent
implications the wiki does not claim. Barriers attach to the reduction node,
never to an edge between two objects. `RelationsManifest` is already shaped so
this is the path of least resistance: nothing it returns is a pair.

Worth having first, whoever picks this up: a reason to believe a canvas beats
the list for a real reading task. "The data is a graph" is not one.

## 5. Smaller things

- **`DiffGuard`** — the mechanical half of §1, specified in
  [ingestion.md](ingestion.md) §4 and not yet built.
- **Job history across launches.** **Done 2026-09-26:** a `JobRecord` is
  written beside each transcript on every state change and the list is
  rebuilt from them at launch. The transcript itself is not re-parsed into
  the log pane; that is the remaining half.
- **A second job kind needs a job *type*.** `IngestJob` is currently named for
  the only kind there is. §3 is the moment to generalize it.
- **Reference PDFs.** The library holds what you drop; it could also cache the
  PDF for any reference page you open, and show it in a tab beside the page.
