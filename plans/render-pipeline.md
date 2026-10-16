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
exactly as the site's own plugin does. Load order is therefore mandatory:
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
before `rehype-katex` in the site's chain.

**Options** match the site: `linkify: true` (GFM autolinks), `typographer: true`
(smartypants), `breaks: false` (`HardLineBreaks` is not configured), and
`html: true` — the corpus contains exactly one raw HTML block and the website
renders it. Passing it through is safe here because the CSP forbids inline
script (§5), so markup coming out of the wiki cannot execute.

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
`\algname{…}` removed, for copying) and `data-oracle-split`. Never put a
`data-*` attribute on the `<pre>`: `pseudocode.renderElement` copies the
element's `dataset` into its renderer options.

`groupGames` then puts a Game block and the blocks straight after it side by
side. The game takes the width it needs and the oracle column keeps a 12rem
minimum; `% oracle-split: N` in the game's source fixes the oracles' share at
N% (quartz pseudocode.ts:245), through a `split` class and an
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
follow WebKit's **Open Link**, which for these links is the app's own:
WebKit's loads the link with no click behind it, a navigation of type
`.other` that the delegate cancels.

## 5. Three layers that keep reading offline

1. **The CSP header**, on every HTML response:
   `default-src 'none'; script-src 'self'; connect-src 'none'; img-src 'self' data:; …`
2. **The navigation delegate** cancels every navigation that is not the shell,
   and hands `http`/`https`/`mailto` to `NSWorkspace` so external links open in
   the default browser.
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
`script-src 'self'`, which is how the macro table is injected as
`window.__CCWIKI__.macros` before any script sees it.

**Honesty note.** The app is not sandboxed and does make network calls — `git`,
`gh` and `claude` all need it. The guarantee here is about the *reader*: the web
view makes zero requests. Do not over-claim it as a process-level property.

## 6. Dark mode

The web view follows `NSAppearance`, so `prefers-color-scheme` in `app.css`
tracks the system automatically — no theme bridge, no `postMessage`. The one
line that matters is `webView.underPageBackgroundColor = .textBackgroundColor`
(macOS 12+): without it WebKit paints its own backdrop before the first frame
and every navigation flashes white in dark mode.
