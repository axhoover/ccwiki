# Correction — CCwiki job prompt

<!--
This file is a TEMPLATE. CCwiki fills the `{{...}}` placeholders and pipes the
result to `claude -p` inside the job's git worktree (plans/corrections.md §5.4).

The rule from ingest.md holds here too: **this file does not contain house
style, and must never start containing it.** It points the agent at the
worktree's own `CLAUDE.md`, which the wiki's maintainers keep current, and
restates none of it.

The agent is small and cheap, and has only the file tools: Read, Edit, Write,
Glob and Grep. No shell, no git, no web. It edits one page, writes the pull
request's text to `.ccwiki/pull-request.md`, and stops. CCwiki computes the
diff, shows it to a maintainer, and opens a draft pull request only once they
approve it.

Placeholders CCwiki substitutes:

  {{WORKTREE}}     absolute path of the job's git worktree
  {{PAGE_PATH}}    the page, repository-relative: content/Primitives/….md
  {{PAGE_TITLE}}   the page's title
  {{PAGE_URL}}     the page on cryptology.city, with the section as its anchor
  {{LINES}}        "lines 42–44", "line 42", or "the whole page"
  {{SECTION}}      ", in “Security”", ", near “Security”", or nothing
  {{QUOTE}}        the passage as the reader saw it, formulas as $…$
  {{FENCE}}        backticks, one more than the longest run in the excerpt
  {{EXCERPT}}      the file's lines, verbatim
  {{REQUEST}}      what the reader says is wrong

`{{#NAME}}…{{/NAME}}` keeps what it wraps only when NAME has a value: a
correction of the whole page has no quote and no excerpt. The quote and the
request are prefixed with `> ` line by line.
-->

You are correcting one page of the cryptology.city wiki, in a git worktree
that belongs to you alone: `{{WORKTREE}}`.

Page: `{{PAGE_PATH}}`{{#PAGE_URL}} ({{PAGE_URL}}){{/PAGE_URL}}, {{LINES}}{{SECTION}}.

{{#QUOTE}}
The reader quoted, as rendered:

> {{QUOTE}}

{{/QUOTE}}
{{#EXCERPT}}
The source of those lines:

{{FENCE}}
{{EXCERPT}}
{{FENCE}}

{{/EXCERPT}}
What the reader says is wrong:

> {{REQUEST}}

1. Read `CLAUDE.md` § Writing Style, § Content Conventions and § Citations,
   and `macros.ts` if you will touch math. They are the rules; this prompt
   restates none of them. On a page under `content/Reductions/` or
   `content/Barriers/`, read `schema/README.md` too.
2. Read the page. Decide whether the reader is right. If the page is right,
   or the fix needs a source you cannot check from the repository, abort.
3. Make the smallest edit that does what was asked, in `{{PAGE_PATH}}` only.
   Never edit between `<!-- BEGIN GENERATED participates-in` and
   `<!-- END GENERATED participates-in -->`. Never rename a file. Never add
   relation fields to an object page.
4. Do not commit, push, or open anything. CCwiki shows your edit to a
   maintainer, who approves it. Write nothing except the page and the file
   in step 5.
5. Write `.ccwiki/pull-request.md`: the first line
   `# [fix] {{PAGE_TITLE}}: <what changed>`, then two or three sentences
   saying what you changed and why. No recap, no adjectives, and no local
   paths: it is published as written.

To abort, change nothing and print a block that starts `ABORTED:` with the
reason and what a human would need to check. An abort is a good outcome.
