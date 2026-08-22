# Paper ingestion — CCwiki job prompt

<!--
This file is a TEMPLATE. CCwiki fills the `{{...}}` placeholders and pipes the
result to `claude -p` inside the job's git worktree.

The most important design rule here: **this file does not contain house style,
and must never start containing it.**

`axhoover/cryptology.city` already carries its own editorial contract, in
`.github/prompts/paper-submission.md`, and it has produced real merged PRs. It
is maintained by the people who maintain the wiki, and it will drift. Baking a
paraphrase of it into a Mac app would guarantee the app teaches agents an
out-of-date style the moment the wiki's own prompt changes.

So this template does three things and nothing else:

  1. states the job (this paper, this worktree, this branch);
  2. hands the agent the repo's OWN instructions, read from the live worktree;
  3. adds the checks the server-side pipeline cannot run — the local lint, the
     local build, and the diff ceiling CCwiki enforces before it will let a
     PR open.

Placeholders CCwiki substitutes:

  {{WORKTREE}}       absolute path of the job's git worktree
  {{BRANCH}}         the branch created for this job, off origin/<default>
  {{BASE_BRANCH}}    the default branch this job forked from
  {{SUBMISSION}}     a JSON object: {type, url, source_url, notes, submitted_at}
  {{PAPER_LOCATION}} either a local PDF path or the URL plus canonicalization hints
  {{PREFLIGHT}}      what CCwiki already checked (key collisions, host page, tooling)
  {{SKILL_NOTE}}     whether .claude/skills/city-style is present in the worktree
-->

You are opening a **draft** pull request that adds one paper to the
cryptology.city wiki. You are working inside a git worktree that belongs to you
alone; nothing else is reading it.

## Submission

```json
{{SUBMISSION}}
```

{{PAPER_LOCATION}}

## Repository context

- Worktree: `{{WORKTREE}}` — this is your working directory. Do not touch any
  other checkout on this machine.
- **Your shell already starts in that directory. Do not `cd`.** Tool permissions
  match on a command's first word, so `cd X && git status` is denied while
  `git status` is allowed — a previous run lost seven turns to exactly this.
- **Do not redirect output to anywhere outside the worktree.** `npm ci >
  /tmp/log` is refused as a write outside the working directory, which took a
  previous run's `npm ci` down with it. Redirect inside the worktree, or just
  let the output come back to you.
- **To read a PDF, use the `Read` tool.** It handles PDFs directly. Do not shell
  out to `pdftotext`.
- Branch: `{{BRANCH}}`, already created for you off `origin/{{BASE_BRANCH}}`.
- {{SKILL_NOTE}}

CCwiki already ran these checks; the results are below, and you should trust
them rather than repeating the work:

{{PREFLIGHT}}

## Step 1 — Read the repository's own instructions

Read these files from the worktree, in this order, **before** you write
anything. They are the contract; this prompt is only the envelope.

1. `.github/prompts/paper-submission.md` — the paper-ingestion contract:
   scope limits, what requires human approval, abort semantics, and the PR body
   template. **Follow it exactly.** Where it and this prompt disagree, it wins,
   except for the mechanical limits in Step 4, which CCwiki enforces on the
   diff whatever the prompt says.
2. `CONTRIBUTING.md` — the frontmatter schema and the worked example per page
   type. This is what `scripts/lint.mjs` enforces.
3. `CLAUDE.md` — the full style guide: voice, the anti-pattern list, section
   order, citation conventions.
4. `content/Templates/Reference.md` — the reference page skeleton, comments
   included.
5. `macros.ts` — the **only** legal source of LaTeX macros. `CLAUDE.md` lists a
   subset; the file is authoritative. Do not define macros inline, and do not
   add one — adding a macro requires human approval.

Then read one recent reference page and the primitive page that cites it, so
you have a concrete model of what a finished edit looks like. `git log
--oneline | grep '\[paper\]'` finds real examples of exactly this job.

## Step 2 — Establish the paper's metadata

Fetch the paper and its metadata from the canonical source. Prefer, in order,
`https://eprint.iacr.org/<year>/<number>`, `https://arxiv.org/abs/<id>`, then
`https://doi.org/<doi>`; that is also the preference order the lint documents
for the `source` frontmatter key.

Two distinct keys, never to be conflated:

- The **wiki citation key** (`AGGM06`, `BFL+24`, `vAH04`) — you invent this from
  author initials plus a two-digit year, following `CLAUDE.md`. It is the
  frontmatter `title`, the `[KEY]` in the H1, and the filename prefix.
- **`cryptobib_key`** (`EPRINT:AbrMalRoy25c`, `STOC:AGGM06`) — you must **find**
  this by grepping `vendor/cryptobib/crypto.bib` for the author surnames and
  year. **Never invent one.** If it is not there, omit `cryptobib_key` and
  supply an inline `bibtex` block instead, containing only fields you have
  verified from the paper itself.

If the submodule is empty, `git submodule update --init --depth 1 --recursive`
first — a fresh worktree does not inherit populated submodules.

## Step 3 — Write the reference page

`content/References/<KEY> - <Full Title>.md`, per the template. The separator is
a space, a hyphen and a space. Strip `:` `?` `/` and other path-hostile
characters from the title part rather than substituting for them. **The filename
is a live URL: never rename an existing one.**

`## Abstract` holds the paper's **verbatim** abstract. Any observation of your
own goes under a separate `# Notes` heading, never inside the abstract.

## Step 4 — Link the result into the wiki

This is the part that gets reverted when it goes wrong, so keep it small.

Append **at most one to three bullets** to the `# Other results` section of
**one** existing primitive or assumption page. Locate the section with
`/^#+\s*Other results/mi` and append to the end of that list; if the paper's
result is about a named variant that has its own narrower `### Known results`
list, prefer that list. Do not renumber, reorder, reword or reflow anything that
is already there.

Each bullet is one sentence, in the wiki's voice, and must correspond to a
single concrete result you can point at in the paper:

```
- <claim> — [[CITATIONKEY - Full Title|CITATIONKEY]]
```

Mechanical rules CCwiki checks on the diff and will reject:

- The separator is an **em dash** (U+2014) with a single space either side.
  Not `--`, not an en dash.
- **No trailing period.**
- The citation wikilink is the **last** wikilink on the line.
  `scripts/microcrypt-sync.mjs` treats every earlier wikilink on a result bullet
  as an *endpoint* (the primitives and assumptions the result relates), so a
  citation that is not last corrupts its index.
- **No `$` anywhere inside a wikilink's display text.** Quartz's link renderer
  does not process math there and the link breaks. Write
  `[[k-lin|k-LIN]]`, never `[[k-lin|$k$-LIN]]`.
- Wikilink the objects the claim names: `[[decisional-diffie-hellman|DDH]]`,
  `[[public-key-encryption|PKE]]`.
- Use the macros: `\secpar`, `\poly`, `\negl`, `\calA`, `\bits`. Not `\lambda`,
  not `\mathrm{poly}`, not a raw `\mathsf{...}` where a macro exists.

**Choosing the right host page is the failure mode that actually happens.** A
previous run put a secret-key PIR result on `doubly-efficient-pir` and a human
moved it to `single-server-private-information-retrieval` the next day, because
the result was not doubly efficient. Before you write the bullet, read the host
page's own definition and justify the choice against it in one sentence in the
PR body. If two pages are plausible, say so under "Things a human should
verify".

New pages you create are `status: stub` or `status: draft`. **Never
`status: complete`** — that is a human judgement and it makes the lint demand a
full section contract.

## Step 5 — Validate locally

CI runs `npm run lint` and `npx quartz build`. Run both, plus the one CI does
not, before you push. All three must exit 0.

```sh
# You are already in the worktree — no `cd`.
npm ci                         # only if node_modules is absent
git submodule update --init --depth 1 --recursive
node scripts/lint.mjs          # the FULL lint — see below
npx quartz build
# Only if your page sets `cryptobib_key`:
npm run sync-cryptobib         # CI does not run this; it is what catches a bad key
```

**Run `sync-cryptobib` only when your new page actually sets a
`cryptobib_key`.** Its whole job is to catch an invented one. If you used an
inline `bibtex` block instead — which is the right answer for a paper too recent
to be in CryptoBib — it has nothing of yours to check, and chasing it is a waste
of a turn budget you may need for the lint.

- Run the **whole** lint, never `node scripts/lint.mjs <one-file>`. Per-file mode
  filters the *output*, not the analysis: an alias collision your new page causes
  is reported against the *pre-existing* page, so a per-file run hides the very
  error you introduced.
- The worktree path deliberately contains no spaces, so the repo's scripts —
  several of which read `import.meta.url.pathname` without percent-decoding it —
  work directly. You should not need a symlink or `--preserve-symlinks`; if you
  find yourself reaching for one, say so in the PR body, because something has
  changed.
- `npm run sync-cryptobib` prints roughly a hundred pre-existing drift warnings.
  That is the accepted steady state. **Do not fix them**; you are only checking
  that it does not fail on *your* key.
- **Never run `npm run format`.** Prettier rewrites more than twenty unrelated
  tracked files, and `npm run check` already fails on a clean checkout.

If the lint reports a problem with your work, fix it and re-run. If it reports a
pre-existing problem elsewhere, leave it alone and mention it in the PR body.

## Step 6 — Commit, push, open a draft PR

```sh
git add <only the files you meant to change>
git commit -m "[paper] <KEY>: <short description>"
git push -u origin {{BRANCH}}
gh pr create --draft --base {{BASE_BRANCH}} \
  --title "[paper] <KEY>: <Title>" --body-file <(...)
```

`--draft` is not optional. **Never** mark a PR ready for review, never merge,
never approve. Your job ends when the draft PR exists.

Use the PR body template from `.github/prompts/paper-submission.md` verbatim —
Summary; Main claims, with locations; Changes in this PR; Things a human should
verify before merge; Would also do, requires approval; Confidence and
limitations; Submitter notes. Name the exact theorem or section number behind
every claim you assert, and say which pages you touched and why each one.

The style rules in `CLAUDE.md` apply to the **PR description** as well as to the
wiki content: no marketing adjectives, no throat-clearing, no closing recap.

Print the PR URL on its own line as the last thing you do. CCwiki reads it
from your output.

## Step 7 — Aborting

If you cannot do the job honestly — the paper is not retrievable, the metadata
cannot be verified, the result does not belong on any existing page, the key
collides with an existing paper that is not this one — then **abort**. Follow
the abort semantics in `.github/prompts/paper-submission.md`: no branch pushed,
no PR, no issue, no commit. Write a structured block to stdout beginning
`ABORTED:` that names the reason and what a human would need to decide.

An abort is a good outcome. A wrong page in the wiki costs a maintainer more
than a submission that did not land.

## Out of scope without human approval

Do not, under any circumstances:

- add or change a macro in `macros.ts`;
- touch `quartz/`, `quartz.config.ts`, `package.json`, `public/`,
  `.orchestrator/`, `.fact-check/`, or any `TODO_*` file;
- rename or move any file under `content/References/`;
- edit a page marked `human_verified`;
- create more than one new reference page, or touch more than one existing page;
- rewrite existing prose rather than appending to it. **Linking beats
  rewriting.** Surgical edits only.
