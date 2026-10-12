# Ingestion

**Status: built (M2); since 0.3 the agent stops before GitHub and a person
approves every pull request ([corrections.md](corrections.md) §5, §6).**
Grounded in what the wiki repo actually does today rather than in what would be
convenient — see §1, which is the finding the whole design turns on.

---

## 1. The finding that shapes everything

`axhoover/cryptology.city` **already has an ingestion prompt**:
`.github/prompts/paper-submission.md`, 238 lines, wired to a
`repository_dispatch` workflow, and it has produced five real merged `[paper]`
commits.

So CCwiki must not invent house style. `prompts/ingest.md` in this repo is an
*envelope*: it states the job, points the agent at the repo's own instructions
**read from the live worktree**, and adds the checks the server-side pipeline
cannot run. Nothing about editorial style is compiled into the Swift binary,
because the wiki's prompt will drift and a Mac app that ships a stale paraphrase
of it would teach agents the wrong thing forever.

## 2. Worktree lifecycle

**Worktrees live in `~/Library/Caches/CCwiki/worktrees`, not Application
Support**, because that path contains a space and a worktree is where
third-party tooling runs. See [PROBLEMS.md](../PROBLEMS.md) — it cost two jobs
before it was fixed properly.

```
git -C repo rev-parse --verify origin/<default>^{commit}   # the base: a commit, recorded
git -C repo worktree add <caches>/worktrees/<job-id> -b ingest/<slug> <base>
cd worktrees/<job-id>
git submodule update --init --depth 1 --recursive     # cryptobib is a submodule
claude -p "<composed prompt>"                         # sealed (§7)
# …agent works, lints, leaves its change and .ccwiki/pull-request.md…
# → Awaiting review in Jobs. Approve commits, pushes and opens the draft PR,
#   then removes the worktree (plans/corrections.md §6.5).
```

The base is a SHA, never `origin/main`: a sync during review would otherwise
move it, and the review would show upstream commits reversed.

A worktree has its own working directory and shares only the object database, so
the reader's checkout cannot be dirtied and several jobs can run at once. The
worktree is **kept** through review and after any failure, and the jobs panel
offers "reveal in Terminal" — a job you cannot inspect is a job you cannot
debug. It is pruned when the pull request opens, when the job is discarded, or
when the agent changed nothing.

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
- Does every endpoint the paper's results name already resolve to an object id
  in `relations.json`? A relation whose endpoint does not exist needs a new
  object page, and that needs human approval — so it is worth knowing *before*
  the agent spends turns on it. (Specified, not built. It replaces an older
  check for `/^#+\s*Other results/mi` on a candidate host page, which was also
  never built and which the reductions migration made wrong — see §4.)
- Does the proposed key match `^[A-Za-z][A-Za-z+]*\d{2}[a-z]?$`?
- Is `vendor/cryptobib/crypto.bib` present?
- Are `git`, `gh`, `claude` and `node` all resolvable? (`ToolLocator`.)

## 4. Post-flight: the diff ceiling

The observed **number one real failure is picking the wrong host page** — a
previous run put a secret-key PIR result on `doubly-efficient-pir` and a human
moved it to `single-server-private-information-retrieval` the next day, because
the result was not doubly efficient. The sentence was fine; the page was wrong.

So the review step shows the endpoint pages' own definitions next to the
proposed relation, and `DiffGuard` rejects or flags a diff that:

- adds more than one new page outside `content/Reductions/` and
  `content/Barriers/`, or any new page under `content/Primitives/`,
  `content/Assumptions/`, `content/Complexity/` or `content/Glossary/` —
  **creating an object page requires human approval**;
- touches more than one existing page, or changes more than ~5 lines on it;
- **adds a prose relationship bullet** to a `# Other results` or
  `# Known relationships` list, or **adds a relation field** (`hypotheses`,
  `conclusion`, `class`, …) to an object page's frontmatter;
- **touches anything between `<!-- BEGIN GENERATED participates-in … -->` and
  `<!-- END GENERATED participates-in -->`** — the region is checksummed and
  derived from the reduction pages;
- names a hypothesis or conclusion that does not already resolve to an object
  id;
- puts a `$` inside a wikilink's display text — Quartz's link renderer does not
  process math there and the link breaks (learned from commit `1e98dc6`, and
  documented nowhere in the repo's prose);
- edits `macros.ts`, `schema/`, `.reductions/`, `quartz/`, `public/`,
  `.orchestrator/`, `.fact-check/` or any `TODO_*` file;
- renames anything under `content/References/` — **filenames are live URLs**.

> **Rewritten 2026-08-24.** The first four bullets used to describe appending a
> prose result bullet to a `# Other results` list, with rules about em-dash
> separators and putting the citation wikilink last (for
> `scripts/microcrypt-sync.mjs`, which treated earlier wikilinks as endpoints).
> The wiki's reductions migration moved relationship data out of prose into
> reduction and barrier pages, and now forbids the prose form outright. See
> [relations.md](relations.md) and `PROGRESS.md` 2026-08-24. Anything the repo
> still enforces about bullet formatting lives in
> `.github/prompts/paper-submission.md`, which is where the prompt now sends the
> agent rather than restating it.

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

## 7. What CCwiki never does

**Nothing reaches GitHub without a person's approval**
([corrections.md](corrections.md) §5). The agent never commits, pushes or opens
anything. It leaves its change in the worktree and the pull request's text in
`.ccwiki/pull-request.md` (first line `# <title>`, then the body, from the
contract's template), prints `READY FOR REVIEW`, and the job waits in Jobs,
"Awaiting review". Only Approve commits, pushes and opens the pull request:
`gh pr create --draft`, always. Never ready-for-review, never merged, never
approved. Nothing in `.ccwiki/` is ever staged.

`prompts/ingest.md` says so in one sentence that overrides the contract on one
topic: **the contract decides what the change is; this envelope decides how it
leaves the machine.** The contract was written for a GitHub Action whose own
step opens the PR.

**Every agent runs sealed** (`AgentInvocation`). git is read-only in its
allow-list; `git push`, `commit`, `remote`, `config` and all of `gh` are denied;
and its environment has no GitHub token, no SSH agent, no credential helper, an
empty `gh` configuration and an `origin` push URL that goes nowhere. That stops
an accident, not a determined agent: ingestion keeps `node`, which can run
anything. So the **tripwire** (`Tripwire`) lists GitHub's branches before the
agent starts and again after it exits, and asks `gh` for pull requests opened
meanwhile; anything CCwiki did not make is named in an orange notice, and a pull
request the agent opened itself makes the job `opened`. The review is the gate.

Aborting is a good outcome and the prompt says so: no branch pushed, no PR, no
issue, no commit, no hand-over file, and a structured `ABORTED:` block
explaining what a human would need to decide. A wrong page in the wiki costs a
maintainer more than a submission that did not land.

## 8. PDFs

Dropped PDFs are copied to `~/Library/Application Support/CCwiki/library/`,
which is deliberately outside the clone, and passed to the agent as an input
path only. They never enter the repo; the References page points at
eprint/arXiv/DOI.

---

## 9. How it is built

```
Sources/CCwiki/Jobs/
├── IngestSubmission.swift   the input: a recognized URL or a staged PDF
├── Preflight.swift          what CCwiki checks before the agent starts; GitHubAccess
├── PromptComposer.swift     fills prompts/ingest.md and prompts/correct.md — and nothing else
├── AgentInvocation.swift    claude's arguments and the sealed environment; the hand-over file
├── Tripwire.swift           a push or a PR CCwiki did not make, looked for afterwards
├── ClaudeStream.swift       stream-json → a readable transcript + the outcome
├── Job.swift                @Observable state machine, transcript, log file, record
└── IngestJobRunner.swift    base → worktree → submodules → claude (sealed) → tripwire → review
```

### Driving `claude`

```
claude -p "<prompt>"
  --output-format stream-json --verbose
  --permission-mode acceptEdits
  --allowedTools Read,Write,Edit,Glob,Grep,TodoWrite,Bash(git status:*),Bash(git diff:*),
                 Bash(git log:*),…,Bash(git submodule update:*),Bash(npm:*),Bash(npx:*),Bash(node:*),…
  --disallowedTools Bash(git push:*),Bash(git commit:*),Bash(git remote:*),Bash(git config:*),Bash(gh:*)
  --max-turns 200                     # CCWIKI_MAX_TURNS overrides
```

with the environment `AgentInvocation.sealed` builds (§7). A correction's agent
gets the file tools only, and `--model` (corrections.md §5.4).

`stream-json` is what makes the jobs panel a *log* rather than a wall of text:
each event is a structured step, so the transcript shows `Bash  npm run lint`
with its result underneath, and the terminal `result` event carries the turn
count, the cost, and any `permission_denials`.

`acceptEdits` plus a **scoped** tool allow-list, not `bypassPermissions`. Edits
inside a throwaway worktree are safe to auto-accept; shell commands are not.
The allow-list mirrors the one the wiki's own GitHub workflow grants, plus the
`npm`/`npx`/`node` the *local* lint needs. A job that wanders outside it fails
visibly, with the denied call named in the transcript, which is much better than
one that quietly did something nobody asked for.

### Outcomes

When the agent exits, the runner first runs the tripwire (unless the job was
cancelled), then reads the outcome. The states, and they are not all failures:

| State | Meaning | Worktree |
|---|---|---|
| `awaitingReview` | The agent changed something and did not abort. Nothing has been pushed; the job waits for Approve or Discard (corrections.md §6). | kept |
| `opened(url)` | After Approve, the draft PR CCwiki opened. Or the tripwire found a pull request the agent opened itself, with an orange notice. GitHub is believed, never the agent's prose. | pruned after Approve; kept, for inspection, after the tripwire |
| `aborted(reason)` | The agent declined on purpose. **A good outcome.** | kept |
| `failed(message)` | Something broke, or the agent ran out of turns. | kept |
| `failed("The agent finished without changing anything.")` | Nothing to review. | pruned |
| `cancelled` | The user stopped it. | kept |

The worktree is kept whenever there is something in it to look at, and the
panel offers "Reveal Worktree in Terminal" — a job you cannot inspect is a job
you cannot debug. On launch, `orphanedWorktrees` reconciles what git knows
against the jobs the app knows about and offers to prune the residue of a
crash; a job awaiting review owns its worktree and is never offered.

### Two dev affordances worth keeping

- `CCWIKI_INGEST_DRY_RUN=1` stops after composing the prompt and writes it
  into the transcript. Every mechanical step still runs — worktree, submodules,
  pre-flight, composition — so iterating on `prompts/ingest.md` costs nothing.
- `make shots PLAN='ingest:<url>'` submits a real job and blocks until it
  awaits review or reaches a terminal state, reporting progress to stderr. The
  same harness that gates the reader gates this.
