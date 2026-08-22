# Ingestion

**Status: designed, not yet built.** M1 (the reader) is complete; this document
is the plan M2 implements, and it is grounded in what the wiki repo actually
does today rather than in what would be convenient.

---

## 1. The finding that shapes everything

`axhoover/cryptology.city` **already has an ingestion prompt**:
`.github/prompts/paper-submission.md`, 238 lines, wired to a
`repository_dispatch` workflow, and it has produced five real merged `[paper]`
commits.

So CityDesk must not invent house style. `prompts/ingest.md` in this repo is an
*envelope*: it states the job, points the agent at the repo's own instructions
**read from the live worktree**, and adds the checks the server-side pipeline
cannot run. Nothing about editorial style is compiled into the Swift binary,
because the wiki's prompt will drift and a Mac app that ships a stale paraphrase
of it would teach agents the wrong thing forever.

## 2. Worktree lifecycle

```
git -C repo worktree add ../worktrees/<job-id> -b ingest/<slug> origin/<default>
cd worktrees/<job-id>
git submodule update --init --depth 1 --recursive     # cryptobib is a submodule
claude -p "<composed prompt>"
# …agent works, lints, pushes, opens a draft PR…
git -C repo worktree remove ../worktrees/<job-id>
```

A worktree has its own working directory and shares only the object database, so
the reader's checkout cannot be dirtied and several jobs can run at once. On
failure the worktree is **kept**, and the jobs panel offers "reveal in Terminal"
— a job you cannot inspect is a job you cannot debug.

On relaunch, `GitService.listWorktrees` reconciles what git knows about against
the jobs the app knows about, and offers to prune orphans. A worktree whose
directory is gone needs `git worktree prune`, not `remove`.

The two submodules (`vendor/cryptobib`, `vendor/microcrypt-zoo`) are **not**
populated in a fresh worktree, and the lint greps `vendor/cryptobib/crypto.bib`
for citation keys, so initializing them is part of setup rather than an
afterthought.

## 3. Pre-flight, before the agent starts

Computed in Swift from the clone, shown in the launch sheet, and passed into the
prompt so the agent does not repeat the work:

- Does `content/References/<KEY> - *.md` already exist, or does any page's alias
  already claim `slugify(KEY)`? (Alias collisions are a hard lint error and
  they are attributed to the *pre-existing* page, which makes them confusing.)
- Does the candidate host page contain `/^#+\s*Other results/mi`?
- Does the proposed key match `^[A-Za-z][A-Za-z+]*\d{2}[a-z]?$`?
- Is `vendor/cryptobib/crypto.bib` present?
- Are `git`, `gh`, `claude` and `node` all resolvable? (`ToolLocator`.)

## 4. Post-flight: the diff ceiling

The observed **number one real failure is picking the wrong host page** — a
previous run put a secret-key PIR result on `doubly-efficient-pir` and a human
moved it to `single-server-private-information-retrieval` the next day, because
the result was not doubly efficient. The sentence was fine; the page was wrong.

So the review step shows the target page's own definition next to the proposed
bullet, and `DiffGuard` rejects or flags a diff that:

- adds more than one new page, or a new page outside `content/References/`;
- touches more than one existing page, or changes more than ~5 lines on it;
- inserts a bullet mid-list rather than appending, or reorders/rewords an
  existing one;
- uses anything but ` — ` (em dash, U+2014) as the claim/citation separator, or
  ends the bullet with a period;
- puts the citation wikilink anywhere but last on its line —
  `scripts/microcrypt-sync.mjs` treats earlier wikilinks as *endpoints*, so this
  corrupts its index;
- puts a `$` inside a wikilink's display text — Quartz's link renderer does not
  process math there and the link breaks (learned from commit `1e98dc6`, and
  documented nowhere in the repo's prose);
- edits `macros.ts`, `quartz/`, `public/`, `.orchestrator/`, `.fact-check/` or
  any `TODO_*` file;
- renames anything under `content/References/` — **filenames are live URLs**.

## 5. Local validation the server pipeline does not do

CI runs `npm run lint` and `npx quartz build`. The prompt additionally requires
`npm run sync-cryptobib`, which is the only thing that catches an invented
`cryptobib_key` — and CI does not run it.

Two traps worth restating because they cost real time:

- **Run the full lint, never `node scripts/lint.mjs <one-file>`.** Per-file mode
  filters the *output*, not the analysis, so an alias collision your new page
  causes is reported against the pre-existing page and is therefore invisible.
- **Never run `npm run format`.** Prettier rewrites more than twenty unrelated
  tracked files, and `npm run check` already fails on a clean checkout.

`sync-cryptobib` prints about a hundred pre-existing drift warnings. That is the
accepted steady state; the agent is told explicitly not to "fix" them.

## 6. Two key namespaces

Conflating these is the most likely metadata error:

- the **wiki citation key** (`AGGM06`, `BFL+24`) — invented by the agent from
  author initials plus year; it is the frontmatter `title`, the `[KEY]` in the
  H1, and the filename prefix;
- **`cryptobib_key`** (`STOC:AGGM06`, `EPRINT:AbrMalRoy25c`) — must be *found*
  by grepping `vendor/cryptobib/crypto.bib`, never invented. If it is not there,
  omit it and supply a verified inline `bibtex` block instead. The lint enforces
  exactly one of the two.

## 7. What CityDesk never does

`gh pr create --draft`, always. Never ready-for-review, never merged, never
approved. The app's role ends at "draft PR opened, here is the diff" — it
captures the PR URL from `gh`'s output for the jobs panel and stops.

Aborting is a good outcome and the prompt says so: no branch pushed, no PR, no
issue, no commit, and a structured `ABORTED:` block explaining what a human
would need to decide. A wrong page in the wiki costs a maintainer more than a
submission that did not land.

## 8. PDFs

Dropped PDFs are copied to `~/Library/Application Support/CityDesk/library/`,
which is deliberately outside the clone, and passed to the agent as an input
path only. They never enter the repo; the References page points at
eprint/arXiv/DOI.
