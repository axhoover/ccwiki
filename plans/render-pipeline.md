# The render pipeline

Reading must work with no network, ever. That is a structural requirement, not a
best-effort one, so this document is mostly about the mechanisms that make it
impossible to accidentally violate.

---

## 1. Why JavaScript renders the markdown

KaTeX and pseudocode.js exist only in JavaScript, and there is no Swift KaTeX.
The wiki's 122 custom macros have to reach KaTeX's `macros` option, and 58
`pseudocode` blocks have to reach pseudocode.js — which itself calls
`katex.renderToString`. So a JS engine is mandatory regardless.

Given that, parsing markdown in Swift would mean the prose and the math are
parsed by two different parsers with two different escaping regimes, and the TeX
would have to survive a round trip through Swift-generated HTML. That is exactly
where double-escaped backslashes and `&amp;` inside `\begin{aligned}` come from.

Measured cost of doing it in JS, on the real corpus: the largest page
(`Assumptions/learning-with-errors.md`, 20 KB, 251 KaTeX spans) renders in about
64 ms end to end. Performance is not the constraint.

## 2. What is vendored, and why each piece

`./scripts/vendor-web.sh` fetches pinned versions into `Resources/web/vendor/`,
verifies every tarball's sha1 against the npm registry's published `dist.shasum`,
and writes a `VENDOR.txt` manifest. Run it once on a machine with network and
commit the result; the app itself never touches the network. `--check` re-verifies
an installed tree without fetching. Total payload: about 750 KiB.

| Package | Version | Why this one |
|---|---|---|
| `markdown-it` | 15.0.0 | Ships a browser UMD bundle, GFM tables built in, and — decisively — its text rule *terminates on `$`*, so a `math_inline` rule registered before `escape` is actually reached. `marked`'s extension API cannot express a delimiter-run construct. |
| `markdown-it-footnote` | 4.0.0 | 7 footnotes in the corpus. |
| `markdown-it-mark` | 4.0.0 | `==highlight==`; one use, but it is one line of vendoring. |
| `github-slugger` | 2.0.0 | Heading ids **must** match Quartz's `rehype-slug`, which uses this exact package. Vendored as a generated UMD shim, so the file stays auditable against the npm source. |
| `katex` | 0.16.47 | The last of the 0.16 line the live site is on. 0.17+ renamed internal DOM classes; nothing here depends on them, but it is a gratuitous risk for no gain. |
| `pseudocode.js` | **the wiki's fork** | See below. |

### The pseudocode.js fork is not optional

`quartz/plugins/transformers/pseudocode.ts` loads the in-repo
`quartz/static/pseudocode.js`, which is upstream 2.4.1 plus an `\algname{...}`
directive (`quartz/static/pseudocode.js:575`). Upstream `pseudocode@2.4.1` has
**zero** occurrences of `algname` — and all 58 pseudocode blocks in the corpus
use `\algname{Game}` or `\algname{Oracle}`. Using the npm build would throw a
parse error on every algorithm block in the wiki.

So the vendor script pulls `pseudocode.js` from a **pinned wiki commit** and
checks its sha256; the CSS comes from upstream npm. If the wiki ever changes its
fork, `./scripts/vendor-web.sh --check` fails loudly rather than the app
silently rendering garbage.

pseudocode.js resolves its math backend from the global `katex` symbol and calls
`renderToString` with **no options**, so macros arrive by monkey-patching —
exactly as the site's own plugin does. The patch is also where formulas are
remembered (§3, "The KaTeX memo"). Load order is therefore mandatory:
`katex.min.js` → `pseudocode.js` → markdown-it and its plugins →
`github-slugger.umd.js` → `ccwiki-markdown.js` → `ccwiki.js`.

**Two files of our own.** `ccwiki-markdown.js` is the Markdown half: the
markdown-it instance with the site's math, wikilinks, heading ids and
callouts, the source-line stamps (below), and the review's blocks. It touches
no DOM, wraps itself as `(function (global) {…})(typeof window !== "undefined"
? window : this)`, and defines `CCwikiMarkdown = { create, createPreview,
reviewEntries, reviewFrontmatter }`. That is what lets JavaScriptCore load it without a web view,
so `SourceStampTests` and `ReviewEntriesTests` run it in Swift tests, beside
the vendored bundles (with an `atob` shim, which markdown-it's entity tables
need and a bare `JSContext` may not have). `ccwiki.js` has everything that
touches the document and calls `CCwikiMarkdown.create`.

### KaTeX fonts: the directory layout is load-bearing

`katex.min.css` references fonts as `url(fonts/NAME.woff2)`, resolved relative
to **the stylesheet's own URL**. So `katex.min.css` and `fonts/` must stay
siblings. Do not flatten the directory, and do not inline the CSS into a
`<style>` block — that would re-base every `url()` against the document.

Only the 20 `.woff2` faces ship (260 KB). The vendor script strips the `.woff`
and `.ttf` entries from each `@font-face src:` list so nothing can 404; shipping
them would add ~876 KB of formats WebKit never requests.

## 3. Reproducing the site's markdown semantics

`ccwiki.js` mirrors `quartz.config.ts`'s transformer chain rather than
inventing its own dialect.

**Math** ports `micromark-extension-math@3.0.0`, which is what `remark-math@6`
uses. Inline math opens on a run of N `$`, closes on a run of *exactly* N, and
strips one space from each end when both are present. Block math needs a fence
of ≥ 2 `$`. The quirks come along: `costs $5 and $6 total` parses `$5 and $` as
math on the live site, and it does here too. Diverging from the site is worse
than the wart.

**Heading ids** use the deduplicating `GithubSlugger`, computed from the
heading's plain text with math reduced to its source — because `rehype-slug` runs
before `rehype-katex` in the site's chain. The text is read after the site's
typography (below): `ccwiki_typography` runs before `ccwiki_heading_ids`, so
`## A -> B` reads `A → B` and its id is `a--b`, as rehype-slug has it.
`WikiPage.Heading.plainText` reads a heading the same way (`educated`: the
same arrows, `--` and `...`, and LaTeX's ``` `` ``` and `''`, with an escaped
character or a character reference read as the character it stands for),
and leaves alone what the page leaves alone: math, code and a wikilink. The
text of a link markdown-it makes of a URL or an address is educated too,
as the site educates a link's text, but by itself, as the page educates
the `text` token markdown-it makes of it: `## See https://x.org/a--b` reads
`See https://x.org/a—b` and has the id `see-httpsxorgab`, as on the site,
while `<https://x.org/a->-b` keeps its `--`, which no one token holds.
Those links are markdown-it's autolinks (`<https://…>`, `<name@host>`) and
what linkify-it finds (`https://…`, `ftp://…`, `//host/…`, `mailto:…` and a
bare `name@host`; never a `www.` link, which markdown-it leaves in the
text around it). `Heading.Linkify` is the linkify-it markdown-it 15
bundles, ported, its patterns in ICU's syntax, and `plainText` applies it
where markdown-it does: at a `://` after a scheme's name while it parses,
then to each run of text between tokens of a heading it finds a link in.
So search, relation labels, the preview cards and DiffGuard name the ids
the page has, but for the rare headings listed under "Still different"
below; the outline takes its headings and ids from the render.
`FixesWikiparseTests` checks the two against each other; on the wiki at
ab81f02 all 2,769 headings of 883 pages agree.

**Options** match the site: `linkify: true` (GFM autolinks), `typographer: true`
(smartypants), `breaks: false` (`HardLineBreaks` is not configured), and
`html: true` — the corpus contains exactly one raw HTML block and the website
renders it. Passing it through is safe here because the CSP forbids inline
script (§5), so markup coming out of the wiki cannot execute.

**Typography** is the site's, not markdown-it's: its `smartquotes` stays, its
`replacements` is off, and `ccwiki_backticks` and `ccwiki_typography` do what
OFM's arrows and retext-smartypants' defaults do: `->` → →, `=>` → ⇒ and the
rest of ofm.ts's arrows, then `--` (only two) → —, three or more dots → …,
and LaTeX's ``` ``quotes'' ``` → “quotes”. `---`, `(c)`, `+-` and `..` stay
as written. A link's text is educated whatever made the link, as on the
site: every link there holds a text node by the time OFM's arrows and
smartypants run, and they edit every text node. So a wikilink's text is a
`text` token between `wikilink_open` and `wikilink_close`, and an
autolink's, a URL's or an address's text is educated where it stands,
between markdown-it's `link_open` and `link_close`: `https://x.org/a--b`
reads `https://x.org/a—b`, its href as written. Each `text` token is
educated by itself, as the site educates each text node. The preview cards
get the same rules.

**Callouts** take their title from the marker's line only (math and links
included) and the lines after it as their body, as ofm.ts does (its text
transform ends the paragraph after a `> [!type]` line, ofm.ts:187), and map
Obsidian's other names (`caution` is a warning, `summary` an abstract).

The marker is ofm.ts:147's regex as the site has it,
`^\[\!([\w-]+)\|?(.+?)?\]([+-]?)`, matched against what the site matches it
against (ofm.ts:477): the first line of the first text node of the
blockquote's first paragraph, decoded. `(.+?)?` runs on to the first `]` in
that text after the marker's own, and the text up to it is metadata: on the
site and here, `> [!note] As shown in [HLL23], …` is titled `, …`. A
`[[link]]`, math or code before any such `]` ends the text node first, and the
marker ends at its own `]`. `siteTextNode` finds the node: markdown-it's inline
parser reads the line, without the core rules and with a copy of the
footnotes, and the node ends at the first token that is not text, an escape
or an entity (a link, an image, math, a code span, emphasis, an autolink, HTML,
a wikilink, a footnote reference); then, as on the site, at the first of OFM's
own splits (ofm.ts:239: a wikilink, a `==highlight==`, an arrow, a tag that is
not all digits and slashes), and at a `www.` link or an email address, which
remark-gfm links and markdown-it's inline parse does not. It ends, too, at a
lone `~` that opens a strikethrough: remark-gfm's
(micromark-extension-gfm-strikethrough 2.0.0, `singleTilde` on by default)
takes one, and pairs it with a later one as CommonMark pairs emphasis, where
markdown-it takes only `~~`; a closing `~` is looked for in the node only. So
`> [!note] a ~b~ [x] c` is titled `a ~b~ [x] c`, and `> [!note] a ~b [x] c`,
whose `~` closes nothing, `c`. The title is the rest of the line, as written,
and with nothing left it is the type, capitalised.

**The site's text transform** (ofm.ts:179) runs before the parse here too:
`%%` comments are deleted, and in a table each wikilink's pipes are escaped,
so `[[slug|Name]]` stays one cell (and `\|` in a table's math keeps its
backslash). Those escapes count on markdown-it's cell split to take one
backslash off again, so they stay only on the lines markdown-it splits into
cells (`splitRowsOnly`, from a block parse of the escaped text). Rows the
site's regex finds that make no table (a header with another number of
cells than the line under it, or rows that continue a list item's or a
quote's paragraph) are a paragraph's lines, where the site decodes each `\|`
it added; here they are put back as written, so their links resolve and
their math reads as written. A row put back that would make a table of its
own keeps its escapes, and the tables stay the site's (see "Still
different" below).

A wikilink shows its alias decoded (`IND\$-CPA` reads
`IND$-CPA`); without one, `[[page#Heading]]` shows `Heading` (in a table,
`page`, as the site's `#` escape there leaves it) and `[[page]]` the last
segment of the target. A link preview card shows a wikilink's text by the
same rule (`PreviewExcerpt`).

A table the site's regex finds inside fenced code, display math or an HTML
block is shown as written, its cells never split, so it gets the site's edit
exactly (ofm.ts:196: in each link, the first `#` and each unescaped `|`
escaped) and nothing more: `| $\|x\|$ | [[a\|b]] |` in a fence reads as
written, and `[[a|b]]` reads `[[a\|b]]`, as the site's code block shows it.
Which lines those are comes from a block parse of its own (`linesInBlocks`),
whose tokens and `env` are thrown away. An indented code block never holds
one: the regex wants a `|` at the start of the line.

**Still different from the site**, known and left so:

- A callout's `+` or `-` (folded) is not honoured: the reader has no control to
  unfold it.
- A line after the marker line that continues its paragraph without a `>`
  is the callout's body here; the site's forced break ends the blockquote
  before it. A callout the site does not break (nested in another blockquote,
  or with its `>` indented) takes only its first line as its title here; the
  site adds the paragraph's later inline markup to the title.
- The site builds a callout's title as HTML before smartypants runs, so its
  quotes and dashes stay straight there; here the title is ordinary inline
  text, and educated.
- In code, the site's text transform rewrites wikilinks too
  (`[[page#Some Heading]]` reads `[[page#some-heading|Some Heading]]` in a
  code block, `[[https://x|y]]` reads `[y](https://x)`); the reader shows
  code as written, but for a table in it (above), where the table's escapes
  stop the rewrite of every link but an external one.
- A header row the site's regex escapes into a paragraph (without the
  escape, its link's `|` ends a cell, and the row has as many cells as the
  line under it) keeps its escape here, with the rows that table would
  take: they are a paragraph's lines as on the site, but their wikilinks
  show as broken and `\|` in their math as `\\|`. No page in the wiki has
  one (2026-10).
- The site's CrawlLinks (`prettyLinks`, on by default; links.ts:136-147)
  cuts the text of every internal link that is one plain text node not
  starting with `#` to its `path.basename`: a wikilink's alias and the
  heading `[[page#Heading]]` shows, and a markdown link's text, not only a
  target without an alias. So `[[p-poly|P/poly]]` and
  `[[p-to-p-poly|P ⊆ P/poly]]` read `poly` there. The reader and the preview
  cards (`PreviewExcerpt`) keep that text whole, as written; only a target
  without an alias is cut to its last segment. The wiki at ab81f02 has 6
  such links: Reductions/p-to-p-poly.md:20, Reductions/bpp-to-p-poly.md:22,
  Complexity/polynomial-time.md:28,
  Complexity/bounded-error-probabilistic-polynomial-time.md:45 and
  Complexity/p-poly.md:44-45.
- A wikilink in a heading counts towards the id as its alias, decoded, or as
  its target, as `WikiPage.Heading.plainText` reads it; the site slugs the
  text the link shows, which for `[[page#Section]]` is `Section`, and which
  smartypants has educated. No heading in the wiki holds a wikilink
  (2026-10).
- The site strikes out text between single tildes (`a ~b~ c`), as
  remark-gfm does by default; markdown-it strikes only `~~b~~`, so `~b~`
  reads as written here. No page in the wiki has such a pair outside math
  (2026-10).
- `Heading.plainText`, and a preview card's wikilink alias
  (`PreviewExcerpt`), decode the character references
  `MarkdownLinkParser.unescape` knows (`&amp;`, `&lt;`, `&gt;`, `&quot;`,
  `&apos;`, `&nbsp;` and numeric ones); markdown-it decodes every HTML5 name,
  and makes an invalid code point U+FFFD. So `## A &mdash; B` has another id
  in search than on the page, and `[[x|a &mdash; b]]` reads
  `a &mdash; b` on a card and `a — b` on the page. No heading or alias in
  the wiki holds one.
- Other headings `Heading.plainText` reads otherwise than the page, none of
  them in the wiki: a link's text there is markdown-it's, which decodes
  percent-escapes and punycode (`## https://x.org/%41` reads
  `https://x.org/A` there); inline HTML and an image are no text on the
  page; `*` is only deleted here, so one that is not emphasis, which the
  page keeps, shows at an edge of the heading (`## a **` has the id `a-`
  there, `a` here) and before a final `Σ`, and `*emphasis*` right around
  an address does not set it apart as it does there; a `[` before a
  markdown link starts that link's text here; and after a `[` no `]`
  closes, markdown-it's backtick cache can leave a pair of backticks
  unread, so `` ## [ `a--b`c`x `` has no code span there (`a—b`, and an
  autolink in the backticks is a link) and one here.
- Which lines are headings: `WikiPage.headings()`, and the same loops in
  `PreviewExcerpt` (the preview cards), `DiffGuard.headingsByAnchor` and
  `CorrectionTarget.headingLine`, read ATX lines outside fences and `%%`
  comments. A setext heading, or a heading inside a blockquote, a callout or
  a list item, has an id on the page but none in search, relation labels,
  the preview cards or DiffGuard, and it moves the ids of later headings
  with the same text (`Security\n---\n\n## Security` is `security-1` on the
  page, `security` here). An ATX-looking line inside an HTML block or `$$`
  display math is a heading here but not on the page. The outline is not
  affected: it takes its headings from the render. None of these is in the
  wiki at ab81f02.

**Not** reproduced, deliberately: the SPA router and the graph view.

**Reproduced differently: popovers.** The site fetches the target page and
shows all of it in a scrollable box. The reader is offline and exists to avoid
a second full render, so it shows a summary card instead, computed in Swift
with the page (`LinkPreviews`, `PreviewExcerpt`) and sent as
`payload.previews`, keyed by each link's resolved href; `ccwiki.js` lays a card
out after 450 ms on an internal link and never asks Swift for anything.
Settings → Reading turns it off. See
[relations-explorer.md](relations-explorer.md) §4.

The site's clipboard buttons were left out at first in favour of a native
right-click (2026-09-27). They are back since 2026-10, because they are what
people know from the site; see "Copying LaTeX" below.

### Pseudocode after render

`renderPseudocode` puts a `.pseudocode-container` in place first, moves the
`<pre>` into it and renders there, so each box holds its own block. (Finding
the output afterwards as the i-th `.ps-root` misaligned every block after a
failed one, which leaves no `.ps-root`.) A failed block replaces its box with
a `pre.pseudocode-error`.

Per-block facts live on the box: `data-source` (the source with
`\algname{…}` removed, for copying), `data-oracle-split`, and
`data-algname` (the first `\algname{…}`, trimmed and lowercased; absent
without one). Never put a `data-*` attribute on the `<pre>`:
`pseudocode.renderElement` copies the element's `dataset` into its renderer
options.

`groupGames` then puts a block whose `\algname` is Game and the blocks
straight after it that have another `\algname` side by side, as quartz
pseudocode.ts:209 decides it (a block with none ends the group; the caption
plays no part). The game takes the width it needs and the oracle column
keeps a 12rem minimum; `% oracle-split: N` in the game's source fixes the
oracles' share at N% (quartz pseudocode.ts:245), through a `split` class and an
`--oracle-share` property so the narrow-window rules can still override it.
Anything else added inside a box must not widen it, or it moves the split;
the copy buttons (see "Copying LaTeX") are the case in point.
At 760px and below the group stacks, and every box takes its content's
height: a zero flex basis there collapsed the game box, which scrolls
sideways and so has no minimum height of its own.

`\Comment{…}` floats right with a 2em pad, as on the site (quartz
pseudocode.ts:69), in `--text-secondary` for contrast. Each `.ps-line` is
`display: flow-root`, so a comment too long to share its statement's row
drops to a row of its own under that statement instead of hanging beside the
next one, which is what the site does.

### The KaTeX memo

KaTeX is most of a render's time (62% of the corpus's, 74% of the slowest
20 pages'), and most of it is spent again on formulas it has rendered
before: a page's repeats, Back and Forward, the editor's preview 300 ms
after each pause in typing, a re-render after a pull or a preference
change, a review's refresh. So the patched `katex.renderToString` in
`ccwiki.js`, which every formula goes through (the page's, a card's and
pseudocode's), keeps what it rendered in a `Map`, one per web view:

- **The key** is every option of the call, defaults merged, but `macros`,
  each as its name, its type and its value, then the formula. The table
  is not in the key: the memo is emptied whenever `ensureMarkdown`
  installs another one, and only the current table's calls are kept.
- **What is never kept**: a call with another table; a formula that is not
  a string; an option that is an object or a function (`strict` and
  `trust` can be functions), which could answer otherwise under the same
  name; a formula with an `@`, or naming `\begin`, `\nonumber` or
  `\notag` ("KaTeX's own names", below); a call that throws.
- **What empties it, and turns it off** (the `\gdef` rule): a formula
  holding `\gdef`, `\xdef` or `\global` (as a control word: `\gdefault` is
  not one), or any call in KaTeX's `globalGroup`. Those are the only ways
  a formula's own text writes the shared table: `\def`, `\edef`, `\let`
  and `\newcommand` are local to their formula, and KaTeX undoes them when
  it ends, error or not (`Parser.parse` ends every group in a `finally`).
  The call itself is not kept, and the memo is emptied before it runs, so
  nothing rendered with the old table survives it. Then nothing is kept
  until `ensureMarkdown` installs another table: what the formula defined
  stays in the table, and can define more when a later formula uses it,
  which that formula's text does not show (`$\gdef\foo{\gdef\bar{1}}$`,
  then `$\foo$`, changes what `$\bar$` renders).
- **KaTeX's own names.** KaTeX 0.16.47 also keeps two names of its own in
  the table between formulas: `\@eqnsw`, which a numbered environment
  (`align`, `alignat`, `gather`, `equation`) sets at each row and
  `\nonumber` and `\notag` set globally, and `\df@tag`, which `\tag` sets
  and every formula deletes as it starts. KaTeX sets `\@eqnsw` before it
  reads it, so only a formula that names it sees what another left, and
  every name KaTeX keeps has an `@`: a formula with an `@` is never kept.
  Nor is a formula that could set `\@eqnsw`, so each one renders, as it
  would without the memo: a remembered `align` would not set it again,
  and a formula naming it would then read what a `\nonumber` before the
  `align` left. Those are the formulas naming `\nonumber`, `\notag` or
  `\begin`, any `\begin`, since a macro can spell an environment's name.
- **Off**, for as long as a table stands, when any macro body holds a
  global definition, an `@`, `\begin`, `\nonumber` or `\notag`: every
  formula using that macro could change the table, or read what another
  formula left. Off too when a macro's name is `\color` or has an `@`:
  after every formula KaTeX deletes `\color` and `\current@color` from
  the table, which `\color` and `\right` read, so a table naming either
  changes at the first formula, and every name of KaTeX's own has an
  `@`. And from a global definition on, as above.
- **Size**: 1,000 formulas, the least recently used going first: a hit
  moves its entry to the end of the map, and a miss at the limit deletes
  the first.

None of the 126 macros and none of the wiki's 7,320 formulas has a global
definition, an `@`, a `\begin`, a `\nonumber` or a `\notag`, and no macro
is named `\color` (wiki at ab81f02). With every exception in place the
output is unchanged byte for byte: in jsdom, with the real `ccwiki.js`
before and after, all 883 files rendered twice in one web view, in path
order, each page twice in a row, and path order then a shuffled order,
gave 1,766 of 1,766 identical pages each time (16.6 MB), with the limit at
1,000 and at 50.

**The limit, from the corpus.** A render of every page calls KaTeX 7,320
times (6,605 in prose, 92 of them display math, and 715 in pseudocode),
on 3,299 distinct formulas and options, 4.39 M characters of HTML. The
most on one page is 166 (`Assumptions/learning-with-errors.md`). The share
of calls the memo answers, for each limit, simulated on that call
sequence and checked against the real memo (`RenderMemoTests` prints all
but the Back columns on every corpus run); "back k" is a page rendered
again after k others, as Back does:

| Limit | First pass | Second pass | Each page twice | Back 10 | Back 50 | Back 100 | Most kept |
|---|---|---|---|---|---|---|---|
| 500 | 46.5% | 46.9% | 100% | 100% | 78.6% | 53.7% | 0.8 M |
| **1,000** | 50.5% | 51.7% | 100% | 100% | 100% | 82.1% | 1.6 M |
| 2,000 | 53.5% | 57.3% | 100% | 100% | 100% | 100% | 3.1 M |
| 3,300 | 54.9% | 100% | 100% | 100% | 100% | 100% | 4.9 M |
| 1,000, first in first out | 48.5% | 49.2% | 99.9% | 99.0% | 95.8% | 77.2% | 1.6 M |

The passes are in path order, which keeps a folder's pages together; in
three shuffled orders 1,000 kept 100% of Back 100 too. "Most kept" is
characters of HTML and keys at the most the memo held.

1,000 holds any page, and the last hundred or so read, at about 1.6 M
characters a web view (one per reader tab, editor preview and review). The
app never renders the whole wiki in one web view, so the second pass,
which only 3,300 or more covers, is no reason to keep three times as
much. A hit rate is not time saved: the hits are mostly the short
formulas every page repeats, so at 1,000 a second pass answers half the
calls and saves none of the time (below), while a page rendered again
saves most of it. Least recently used and not first in, first out,
because first in, first out drops the formulas a page just used from
among the oldest, and so misses on the page rendered again.

Measured in V8 on the same machine (node 22, the test's DOM-free shell,
`CCwiki.render` and the page's pseudocode, best of 5), before and after:

| Case | Before | After |
|---|---|---|
| Every page, first render | 856 ms | 811 ms (−5%) |
| Each page rendered again right after itself | 842 ms | 339 ms (−60%) |
| The whole wiki a second time, in order | 732 ms | 732 ms |
| `learning-with-errors`, rendered again | 38.4 ms | 8.5 ms (−78%) |

`RenderMemoTests` checks the rules on a KaTeX that numbers its answers,
checks a `\gdef` and `\@eqnsw` against the vendored KaTeX, and on the
corpus renders every page twice through the memo and compares each with
the vendored KaTeX behind the patch as it was before the memo.

**The numbers in WebKit.** The page times each render, pseudocode and the
passes after it included, and sends it as `ms` in its `rendered` message,
with the page's path. `WebController` logs both at debug level under
category `render` (a review as "a review"), so
`log stream --level debug --predicate 'subsystem BEGINSWITH "com.axhoover.ccwiki" AND category == "render"'`
gives the app's own before and after for a change to the renderer, which
the V8 numbers above only stand in for.

### Copying LaTeX

The page shows glyphs: copied as they stand, `\frac{1}{2}` reads "21",
zero-width spaces turn up, and every macro is lost. So the reader puts LaTeX
on the pasteboard in four ways.

**Where the source comes from.** Markdown math carries it in `data-tex`.
Prose math is rendered with `output: "html"`, like the site, so it has no
MathML. pseudocode.js calls `katex.renderToString` with no options, so its
math gets KaTeX's default `htmlAndMathml`, and the source is in the MathML
`<annotation encoding="application/x-tex">`. Keep both as they are: prose
MathML would double the math DOM and differ from the site, and the
annotation is pseudocode math's only copy of its source.

**⌘C.** A capturing `copy` listener in `ccwiki.js` clones the selection,
widens it to whole formulas, and replaces each formula with its LaTeX:
`$…$` inline, and display math as `$$`, the source and `$$` on lines of
their own (a one-line `$$x$$` is inline math to remark-math). It drops the
copy buttons, turns each `p.ps-line` into a `div` (`innerText` gives a `<p>`
a blank line after it), lays the result out in an attached off-screen
`.copy-scratch` box and reads its `innerText`, falling back to
`textContent`. Both `text/plain` and `text/html` get the LaTeX, so Notes and
Mail paste it too; KaTeX's own copy-tex keeps the original HTML instead.
The handler steps in only when the selection holds math or the app's
buttons; otherwise WebKit's copy runs untouched. ⌘C, Edit › Copy and the
context menu's Copy all reach it, because the app does not replace the
pasteboard command group.

copy-tex itself is not vendored: it only reads `.katex-mathml` and does
nothing on HTML-only math. That is also why, on the site, ⌘C gives LaTeX
inside pseudocode blocks only.

**Right-click.** A capturing `contextmenu` listener posts `contextTarget`
with `tex` (the formula under the pointer), `algorithm` (its block's
`data-source`), `algorithmExpanded` (the same with the macros written
out) and `link` (the app's link under the pointer, for the link items of
§4). `ReaderContextTarget` turns that into the menu's copy items, which
`ReaderWebView.willOpenMenu` puts at the top: **Copy LaTeX** for the
formula, then **Copy Algorithm as LaTeX** with **Copy Algorithm as LaTeX (No
Macros)** as its Option-key alternate. Each item captures its text by value,
so `didCloseMenu` clearing the target cannot break a copy. The report
travels on the same WebKit connection as, and ahead of, the menu request,
which is why it is there in time; if that ordering ever changes, the items
simply do not appear.

**Buttons.** Under each algorithm, as on the site (quartz
pseudocode.ts:182): **Copy LaTeX (macros)** and **Copy LaTeX (no macros)**,
faded in on hover or keyboard focus, never selectable, not printed, and
reading "Copied!" for two seconds after a click. The faded row is still
laid out, so it is `width: 0; min-width: 100%` and wraps its buttons: as
plain flow content its two buttons (about 310px) became the oracle column's
flex basis and pulled most game groups back to an even split. The labels
are generated content (`::before { content: attr(data-label) }`, with an
`aria-label` for VoiceOver), so find in page never matches a hidden button.
Glossary/latex-macros has
an empty `<div id="macros-copy-area">` that the site's script fills;
`fillMacrosCopyArea` fills it the same way, with **Copy LaTeX preamble**
(one `\newcommand` per macro) and **Copy KaTeX/MathJax JSON**. Both are
sorted by name: the table crosses from Swift as a dictionary, so the order
of `macros.ts` is gone.

Every button's text goes over the bridge, `post({type: "copy", text})`, to
`WebController.handle`, which writes it to `NSPasteboard`. Not
`navigator.clipboard`: whether a page on `ccwiki://` counts as a secure
context in `WKWebView` is not something to depend on. (⌘C needs no bridge:
it fills the copy event's own `clipboardData`.)

**Macro expansion** ports the site's helpers (quartz pseudocode.ts:155-167).
`stripAlgname` removes `\algname{…}`, which only the wiki's fork of
pseudocode.js understands. `expandMacros` replaces each name in the table
being rendered with, only as a whole control word (`\st` leaves `\stA`
alone). The site makes a single pass in `macros.ts` order. The app gets the
table as a Swift dictionary, serialised without sorted keys, so its order
can change from one launch to the next; it therefore repeats the pass until
the text stops changing, at most 10 times, and the result does not depend
on the order. No macro's body uses another and none takes arguments (all
126 in `macros.ts` as of 2026-10), so today the first pass is the last and
the app's output is the site's. If a body ever uses another macro, the app
still writes it out in full, where the site's single pass may not; a macro
with arguments would be expanded wrongly on both sides.

### Source lines

A correction carries the lines of the file a passage came from
([corrections.md](corrections.md) §3). markdown-it gives every block token a
`map`, `[first, end)`, 0-based in the markdown it was handed: the
`RenderRequest`'s, which is the page body with, on a reduction or barrier
page, the relation-meta line spliced under the H1. A core rule,
`ccwiki_source_lines`, pushed after `ccwiki_callouts`, stamps each block
(every token with a `map` that is a block and not a closing tag) as
`data-source-lines="first-end"`.

- Display math and tables build their own markup, so their renderers write
  the attribute: on `div.math-display` and on `div.table-scroll`.
- `mathBlock`'s map is set from `state.line`, so a block's lines end on its
  closing `$$`. An unclosed block runs to the end of its container, and
  consumes its last line: it used to parse that line again, and, as the last
  line of a page, to throw "block rule didn't increment state.line".
- Pseudocode takes the range as `ccwiki-lines`, never a `data-` attribute,
  which `pseudocode.renderElement` would copy into its options;
  `renderPseudocode` moves it onto the `.pseudocode-container` (or the
  `pre.pseudocode-error`) as `data-source-lines`.
- An `html_block` carries its map, but raw HTML has nowhere to show it.
- `%%` comments are deleted before the parse, so a comment over several
  lines moves the lines after it; `ccwiki_comment_lines`, just before
  `ccwiki_source_lines`, maps every token back to the lines it was handed.

`SourceLineMap` (Swift) maps a rendered range to the file: past the
frontmatter, and around the spliced lines, which map to the frontmatter they
are made from. `SourceStampTests` checks every kind of block against it.
markdown-it counts the blank line after a list into the list and its last
item, so `CorrectionTarget` drops blank lines at either end of a range before
it quotes the file or opens the editor there.

**Reading a selection.** `CCwiki.selectionSource()` returns a JSON string,
`"null"` when nothing on the page is selected: the union of the lines of the
blocks the selection's first and last selected text sit in, its text through
the same `selectionText(range)` as ⌘C (each formula as `$…$` or `$$…$$`), the
last heading at or before it, and the page's `path` and `revision`, which
arrived with the render payload. A triple-click ends its range at the start
of the next block; that block is not part of the passage.

**The right-click.** On a secondary click, WebKit selects the word under the
pointer before it dispatches `contextmenu`. A capture-phase `mousedown`
listener of its own, for `button === 2` or `ctrlKey`, records the passage
first, if the pointer is inside one of the selection's client rects. The
`contextmenu` listener sends it as `contextTarget`'s `selection`, or else the
block under the pointer with `text: null`: a pointer, which the menu calls
the Page. The message's keys are `type, tex, algorithm, algorithmExpanded,
link, selection`.

**The editor's preview** follows the cursor with
`CCwiki.revealSourceLines(start, end, mark)`: the innermost block that
overlaps the range scrolls to the middle, and with `mark` it is outlined for
1.2 s (`.source-reveal`).

### The review

`CCwiki.renderReview(payload)` shows a change the way pages are shown
(corrections §6.3). `CCwikiMarkdown.reviewEntries(md, file)`, DOM-free,
parses each file's old and new body and takes the top-level blocks from
their maps: the old blocks a hunk overlaps are `removed`, the new ones
`added`, one unchanged block either side is `context`, and every other run
of unchanged blocks one `gap`. `ccwiki.js` lays them out, one `section` per
file, each entry a `div.review-entry.<kind>` with a `data-entry-id`, the
frontmatter as signed source lines (`CCwikiMarkdown.reviewFrontmatter`; a
`gap` row, unchanged lines left out, is a caption with no sign), and
DiffGuard's flags as captions above the entries they meet. Added and removed entries carry Before and After in
the gutter and `role="insertion"`/`"deletion"`, so they differ by more than
colour. A link to a page the change adds (`kind: "new"`) is `a.new`: styled
as a link, titled "Added by this change", going nowhere.
`CCwiki.scrollToReviewEntry(id)` takes an entry's id, a file's id or path, or
a finding's id, `<rule>:<path>:<line>`, whose line finds its entry.
`WebController` keeps the last review's JSON and sends it whenever the shell
says `ready`.

**Blocks render when shown.** A block's HTML is rendered the first time
an entry reads it, and kept (`renderedWhenRead`, a getter): a `gap` shows
no HTML, so the blocks it stands for never render, and most blocks of a
changed file are in one. The review renders when it opens and at every
save while it is open. A one-line edit to each page of the wiki renders
3,512 blocks instead of 12,748 (about 1.5 s → 0.9 s for all of them in
V8, with the check for KaTeX's table below); an edit to its first and
last lines 5,240 instead of 12,814; a page added or deleted renders
every block, as before.

That puts every render after both parses, in the order the entries
come, not each text's, and without the blocks in gaps. Two things a
render reads can change between renders. One is a Markdown link's
destination: `link_open` finds the one Swift keyed it by from its href,
in what `normalizeLink` last saw for that href (markdown-it keeps only
the href; `create` in `ccwiki-markdown.js`), and `[a](<x y>)` and
`[a](x%20y)` make one href. So `parseWithDestinations` records the
destinations each text's parse asks `normalizeLink` about, and a block's
first read asks again for its text's before it renders: what it last saw
is what it saw when that text was parsed, as when every block rendered
as its text was parsed. Without that, a review of such an edit called
the removed link's missing target by the added one's spelling.

The other is KaTeX's macro table, which a formula can change for every
formula after it ("The KaTeX memo"): a `\gdef` in a gap defined nothing
for the block shown below it, and an old block shown after a new one
read what the new text defined. So when a block's formula could change
the table (`\gdef`, `\xdef`, `\global`, `\nonumber`, `\notag`, or any
`\begin`, as the memo has them), or any formula could through the table
(a macro whose body could, one a formula defined, which KaTeX keeps as
tokens, or a name KaTeX changes: `\color`, or one with an `@`),
`reviewEntries` reads every block of both texts once both are parsed,
the old text's first, which is the order they rendered in when each
rendered as its text was parsed: parsing never calls KaTeX. That holds
across files and reviews too: a file whose blocks render when shown
leaves nothing in the table that a later formula reads. A formula that
only reads what another left (`$\@eqnsw$`) does not count: while no
formula writes, the table holds still. No wiki page has such a formula;
only an edit that breaks a page's `$$`, so that pseudocode's `\begin`
lands in a formula, renders every block (6 pages of the every-7th-line
edit below).

The entries are byte for byte the same: in node, with the vendored KaTeX
and the wiki's macros, 7,064 reviews of every page (a middle line edited,
the first and last, a line inserted, removed or followed by a blank one,
every 7th line, the page added and deleted) and 15 hazards the wiki lacks
(the two-way link, CR LF, a lone CR, a combining mark at a line's start,
fences, `%%` comments, repeated headings, a footnote, a reference
definition, math, pseudocode, a table, a callout) gave the same JSON
before and after, 41 MB of it; without the second ask, 3 of the hazards
did not. 300 runs of random reviews (565 reviews, 1,096 files, one to
three a review) whose formulas write, read and delete KaTeX's names,
some in gaps and some across files, gave the same JSON in bare contexts
and the same review in jsdom through the shell; the first version, which
rendered lazily whatever the formulas, differed within the first runs.
`RenderMemoTests` compares the two on the hazards, on seven reviews in
which a formula changes the table, and on one in which a formula only
reads it, which must still render only the blocks it shows, on every
run; and on four of those edits to every page on a corpus run, against a
copy of the file as it was (`Tests/CCwikiTests/Fixtures/legacy`).

## 4. Serving content: a custom scheme, not `file://`

`CCwikiSchemeHandler` serves `ccwiki://wiki/…` from two roots:

```
/_/…       → CCwiki.app/Contents/Resources/web/…      the shell and vendored libs
/asset/…   → …/CCwiki/repo/content/…                  images and other files
/page/…    → never served; the click handler intercepts these
/folder/…  → never served; likewise
```

Three loading strategies were measured; only one works:

| Strategy | External JS loads? |
|---|---|
| `loadHTMLString(html, baseURL: file://…)` | **no** — this kills the naive "render to a string" approach the moment KaTeX is involved |
| `loadFileURL(_:allowingReadAccessTo:)` | yes, but grants exactly one directory per load |
| **custom `WKURLSchemeHandler`** | **yes**, and it can do the other two things below |

The two things only a scheme handler can do:

1. **Send a `Content-Security-Policy` response header.** With a file URL the
   best available is a `<meta http-equiv>` tag, which only takes effect from the
   point it is parsed and cannot express `frame-ancestors`.
2. **Serve two roots.** The vendored pipeline is inside the `.app`; the wiki is
   in Application Support. Those have no useful common ancestor.

It also means a wikilink click is a real navigation to a URL we can intercept,
which is where back/forward come from. Where the page opens is Swift's call.
`ccwiki.js` posts `navigate` with the keys held (`command`, `shift`,
`option`) and `middleButton`, and `LinkDisposition.forClick` reads them as
Safari does: ⌘-click or a middle click opens a tab behind the current one
(in front until `WindowTabbing.joinsInBackground` is turned on after the
by-eye check, reader-comforts §1.4), ⇧⌘-click a tab in front, ⌥⌘-click a new
window, and a plain click, or ⇧ or ⌥ alone, opens it where you are.
WebKit may not dispatch `auxclick`, so the middle button is read from
`mousedown` and `mouseup`, and a middle `click` or `auxclick` is only
stopped. A link WebKit follows itself, the page's listener having missed it,
gets the same table from `WKNavigationAction`'s `buttonNumber` and
`modifierFlags`. The page on cryptology.city has an item of its own, **Open
Link on cryptology.city**, in the link's context menu, after **Open Link in
New Tab** and **Open Link in New Window**; a link to a folder gets those two
alone. `contextTarget` carries the link's `href` for them. They
follow WebKit's **Open Link**, which is the app's own for every link the app
opens, a page, a folder or a file of the wiki, and a web or mail link
(`externalLink`): WebKit's loads the link with no click behind it, a
navigation of type `.other` that the delegate cancels. A place on the page
keeps WebKit's, which scrolls there. The review and an editor's preview
offer Open Link on cryptology.city but no tab or window, since their links
open in the active reader (corrections §17).

## 5. Three layers that keep reading offline

1. **The CSP header**, on every HTML response:
   `default-src 'none'; script-src 'self'; connect-src 'none'; img-src 'self' data:; …`
2. **The navigation delegate** cancels every navigation that is not the shell,
   and hands `http`/`https`/`mailto` to `NSWorkspace` so external links open in
   the default browser. The shell itself loads only when the controller loads
   it, before the page says `ready`; after that only a place on it may load
   (`CCwikiURL.allowsShellNavigation`), so a refresh in a page's raw HTML can
   neither replace the shell nor reload it for ever.
3. **`WKUIDelegate` returns `nil`** for `createWebViewWith`, so `target="_blank"`
   can never spawn a window.

### The CSP detail that will bite you

`style-src` **must** keep `'unsafe-inline'`. KaTeX emits hundreds of inline
`style="height:1.19em"` attributes per page, CSP3 governs those, and without the
exception every strut computes to zero height and the math collapses into
overlapping soup. `script-src` stays strict — no `'unsafe-inline'`, no
`'unsafe-eval'` — which is the half that actually matters: an inline `<script>`
in wiki markdown cannot run.

The corresponding win: a `WKUserScript` at `.atDocumentStart` **does** run under
`script-src 'self'`. The macro table no longer needs one: it comes with every
render payload, and `ensureMarkdown` called without a table keeps the current
one.

**Honesty note.** The app is not sandboxed and does make network calls — `git`,
`gh` and `claude` all need it. The guarantee here is about the *reader*: the web
view makes zero requests. Do not over-claim it as a process-level property.

## 6. Dark mode

The web view follows `NSAppearance`, so `prefers-color-scheme` in `app.css`
tracks the system automatically — no theme bridge, no `postMessage`. The one
line that matters is `webView.underPageBackgroundColor = .textBackgroundColor`
(macOS 12+): without it WebKit paints its own backdrop before the first frame
and every navigation flashes white in dark mode.
