# The wiki model

`Sources/CCwiki/Wiki/` is pure, nonisolated, dependency-free Swift, and it is
where almost all of the app's correctness risk lives. Everything here is a port
of behaviour that already exists in the wiki repo, so "what does Quartz do?" is
always the right question, and "what would be nicer?" is almost always the wrong
one — a divergence means CCwiki shows links the website does not, or hides
ones it does, and nobody notices until they click.

---

## 1. Two slugifiers that must never be mixed

The single most important fact in this file. The wiki uses two completely
different slug algorithms and they disagree about almost everything.

| | `QuartzSlug.sluggify` | `GithubSlugger.slug` |
|---|---|---|
| Applies to | file paths | heading anchors |
| Case | **preserved** | lowercased |
| Spaces | → `-` | → `-` |
| `&` | → `-and-` | deleted |
| `%` | → `-percent` | deleted |
| `?` `#` | deleted | deleted |
| `.` `,` `!` `(` `)` `'` `+` `=` | **survive** | deleted |
| Everything else | survives | deleted unless a letter, mark or digit |

So `AMYY25 - Evasive LWE Attacks, Variants & Obfustopia.md` becomes the slug
`References/AMYY25---Evasive-LWE-Attacks,-Variants--and--Obfustopia`, while the
heading `Ring LWE` becomes the anchor `ring-lwe`. Sharing code between them
would be a subtle disaster.

`QuartzSlug` is a line-by-line port of `quartz/util/path.ts`; `GithubSlugger` is
a port of `github-slugger@2.0.0`. Both carry the upstream quirks deliberately:

- `splitAnchor("a#x#y")` returns `("a", "#x")` — everything after a second `#`
  is silently dropped, because JavaScript's `split(sep, limit)` splits fully and
  *then* truncates.
- `.pdf` targets keep their fragment verbatim, so `doc.pdf#page=3` works.
- `github-slugger` does no trimming and no run-collapsing, so `"  spaced  out  "`
  really does become `"--spaced--out--"`.
- Heading **ids** come from a per-document *deduplicating* slugger (a second
  `## Syntax` is `syntax-1`), but wikilink **anchors** come from the
  non-deduplicating one — so `[[page#Syntax]]` can only ever address the first
  one. That is a real Quartz limitation. We reproduce it rather than "fix" it,
  because a link that works in CCwiki and not on the website is worse than one
  that works nowhere.

## 2. The resolution table

`WikiIndex.build` mirrors `quartz/build.ts:75-91`:

1. Glob `**/*.*` under `content/` — note the pattern requires a dot in the
   *filename*, so an extensionless file is invisible to the site and must be
   invisible here.
2. Drop anything under `ignorePatterns` (`private`, `Templates`, `.obsidian`,
   `vendor`), which is why the four files in `content/Templates/` are not pages.
3. `slugifyFilePath` each survivor into `allSlugs`.
4. Then, walking markdown paths in **sorted** order, append one slug per
   frontmatter alias — computed as `slugifyFilePath(alias + ".md")`, i.e.
   **root-relative**, not relative to the page's own directory. This is why the
   alias `PRF` on `Primitives/pseudorandom-function.md` produces the top-level
   slug `PRF`, and why the alias `#P` on `Complexity/sharp-p.md` produces the
   slug `P` and collides with `Complexity/polynomial-time.md`'s alias `P`.

Real numbers for this corpus: 296 files → 774 slugs, 478 of them from aliases.

## 3. Resolving one `[[wikilink]]`

The site is configured `markdownLinkResolution: "shortest"`
(`quartz.config.ts:72`), which means: read the target as a bare basename, and
take the match **only if it is unique**. Zero matches and two-plus matches
behave identically — both fall through to treating the target as an absolute
path from the vault root.

```
1. target matches ^https?://          → external link, stop
2. splitAnchor(target + rawAnchor)    → (fp, anchor); the anchor is already
                                        github-sluggered by this point
3. fp is empty                        → same-page anchor, stop
4. transformInternalLink(fp + anchor) → a RelativeURL rooted at "."
5. strip the leading "." and split off the anchor again → targetCanonical
6. matches = allSlugs where lastSegment == targetCanonical  (exact, CASE-SENSITIVE)
   exactly one → that slug;  otherwise → targetCanonical itself
7. slug → file, in order:
     a. a file with that slug            → page
     b. an alias owner                   → that page (first in sorted order)
     c. a file with slug + "/index"      → that page
     d. a known folder                   → a synthetic folder listing
     e. otherwise                        → unresolved, and we say so
```

Three consequences worth stating explicitly:

- **Case matters on the slug side.** `[[Oblivious transfer]]` slugifies to
  `Oblivious-transfer`, which nothing claims, so it is broken — on the website
  too. Matching case-insensitively would invent a link. (It does not matter on
  the anchor side, because github-slugger lowercases.)
- **A target containing `/` can never equal a single segment**, so the shortest
  search never fires for it and it goes straight to the absolute branch. That is
  correct, not a bug.
- **An unresolved link is rendered as broken**, not dropped. The website shows
  these as ordinary links to nowhere; in a tool you use to *edit* the wiki, a
  dead link is information. Three of the corpus's 673 links are dead today.

### What the corpus actually contains

Measured by `CorpusTests`, and a good regression assertion:

```
673 wikilinks total
  660 resolve to a page (651 by filename, 10 by alias, 3 same-page anchors… )
    1 asset embed (![[Minicrypt.png]])
    6 folder links (all in index.md)
    3 unresolved — the known dead ones
  653 use the |alias form; 0 contain a "/"; 13 carry an anchor; 0 are block refs
```

### Code is not linked

Quartz replaces wikilinks on the mdast, where `findAndReplace` does not descend
into `code` / `inlineCode` nodes. A naive regex sweep would manufacture links
the site does not render — and this wiki is full of fenced `pseudocode` blocks
containing `[` and `]`. `CodeMask.inertRanges` finds fenced blocks, inline code
spans and `%%obsidian comments%%`, and the parser skips any match overlapping
one. It returns *ranges* rather than a blanked copy of the string, so character
offsets never have to line up between two representations — which they would not,
for any string containing an emoji.

## 4. Frontmatter

`Frontmatter.parse` is a hand-written parser for the subset of YAML the corpus
and the repo's lint actually permit. It is not a YAML implementation and does
not try to be. Measured against all 297 files, it must handle:

- `key: scalar`, splitting on the **first** colon — 345 lines carry a colon
  inside the value (every `source:` URL, every `cryptobib_key`). Splitting on
  the last, or refusing colons, breaks all of them.
- block sequences (`aliases:` then `  - item`) and the inline empty `[]`.
- literal block scalars (`bibtex: |`) on 43 pages, newlines preserved.
- double- and single-quoted scalars, unquoted only when both ends match — so
  `title: "#P"`, `title: P/poly` and `title: Impagliazzo's Five Worlds` all
  survive intact.
- full-line `#` comments, which `content/Templates/Reference.md` teaches agents
  to write.

It deliberately **ignores nested mappings**: an indented block under a key is
skipped, so a nested `status:` can never overwrite the top-level one. It also
never strips a trailing `# comment` from a value, because doing so would mangle
`"#P"` and every URL with a fragment.

Two schema notes that matter for the UI:

- `type` is a perfect function of the directory and the lint enforces that, so
  **the directory wins** and a disagreement is a warning, not a crash.
- For a reference page the frontmatter `title` is the **citation key**, not the
  paper title. The paper title lives in the filename. `WikiPage.displayTitle`
  handles this; the sidebar shows both.

## 5. The LaTeX macro table

**`content/Glossary/latex-macros.md` does not contain the macros.** It is a
documentation page: tables of macro *names*, each rendered as an example. The
definitions live in `macros.ts` at the repo root, as a TypeScript
`Record<string, string>` literal, and `quartz.config.ts` feeds that same object
to both `Plugin.Latex` and `Plugin.Pseudocode`. The repo's own lint reads it too
(`scripts/lint.mjs:405`) and treats it as the only legal place to define a
macro, so it is a stable contract rather than an implementation detail.

`MacroTable.parse` is a small tokenizer, not a line regex: it finds the object
literal by brace-matching (skipping strings and comments), then reads
`"key": "value"` pairs, unescaping JavaScript string escapes. A regex over lines
would work today and break the moment someone writes a value containing `}` or a
comment containing a quote. 122 macros parse out of the live file.

Every failure degrades to an empty table plus a `Diagnostic`, never a throw:
missing file, unreadable file, no object literal, or an empty result. The app
then shows a warning banner above the page and renders the math anyway — `\calA`
appears as a KaTeX error rather than 𝒜, which is ugly but readable, and far
better than a blank page.
