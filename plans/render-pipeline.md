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
`katex.min.js` → `pseudocode.js` → `ccwiki.js`.

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

**Not** reproduced, deliberately: popovers, the SPA router, the graph view, and
the site's clipboard buttons. The last of those is replaced by a native
right-click, which is strictly better — CCwiki has the markdown source and can
copy the original TeX without a DOM round trip.

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
which is where back/forward and ⌘-click come from.

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
