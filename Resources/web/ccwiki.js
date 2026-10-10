/* CCwiki renderer — runs inside the WKWebView, offline, no network.
 *
 * Division of labour with the Swift side:
 *
 *   Swift owns *resolution*. It parses the page's wikilinks with the same
 *   grammar used here, resolves each one through the ported Quartz slug rules
 *   (QuartzSlug/WikiIndex, which are unit-tested), and hands this file a
 *   `links` map keyed by the raw matched text. JS never guesses a target.
 *
 *   JS owns *rendering*. markdown-it + KaTeX + pseudocode.js only exist in
 *   JavaScript, and splitting markdown parsing across two languages would mean
 *   round-tripping TeX through Swift-generated HTML — exactly where
 *   double-escaping bugs live.
 *
 * Everything mirrors the site's own pipeline (quartz.config.ts): remark-math's
 * delimiter semantics, remark-gfm, smartypants, rehype-slug heading ids, and
 * the patched pseudocode.js that understands `\algname{...}`.
 */
(function (global) {
  "use strict";

  var bridge = global.webkit && global.webkit.messageHandlers
    ? global.webkit.messageHandlers.ccwiki
    : null;

  function post(message) {
    if (bridge) { try { bridge.postMessage(message); } catch (e) { /* no-op */ } }
  }

  // ================================================================= math ==
  // Ports micromark-extension-math@3.0.0, which is what remark-math@6 uses.
  // The quirks are deliberate: reproducing the site beats "fixing" it.

  function mathInline(state, silent) {
    var src = state.src, start = state.pos, max = state.posMax;
    if (src.charCodeAt(start) !== 0x24 /* $ */) return false;

    // micromark's `previous` guard: the preceding character may not be an
    // unescaped `$`, which is what stops `$$` block fences being eaten here.
    if (start > 0 && src.charCodeAt(start - 1) === 0x24) {
      var backslashes = 0, k = start - 2;
      while (k >= 0 && src.charCodeAt(k) === 0x5c) { backslashes++; k--; }
      if (backslashes % 2 === 0) return false;
    }

    var pos = start;
    while (pos < max && src.charCodeAt(pos) === 0x24) pos++;
    var sizeOpen = pos - start, contentStart = pos;

    while (pos < max) {
      if (src.charCodeAt(pos) !== 0x24) { pos++; continue; }
      var runStart = pos;
      while (pos < max && src.charCodeAt(pos) === 0x24) pos++;
      if (pos - runStart !== sizeOpen) continue;  // wrong length: demote to data

      if (!silent) {
        var content = src.slice(contentStart, runStart);
        // Padding: one space/EOL comes off each end when both are present.
        if (/^[ \n]/.test(content) && /[ \n]$/.test(content) && /[^ \n]/.test(content)) {
          content = content.slice(1, -1);
        }
        var token = state.push("math_inline", "math", 0);
        token.markup = "$".repeat(sizeOpen);
        token.content = content;
      }
      state.pos = pos;
      return true;
    }
    return false;
  }

  function mathBlock(state, startLine, endLine, silent) {
    var pos = state.bMarks[startLine] + state.tShift[startLine];
    var max = state.eMarks[startLine];
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    if (pos + 1 >= max) return false;
    if (state.src.charCodeAt(pos) !== 0x24) return false;

    var open = pos;
    while (pos < max && state.src.charCodeAt(pos) === 0x24) pos++;
    var sizeOpen = pos - open;
    if (sizeOpen < 2) return false;                       // `$` alone is inline

    var meta = state.src.slice(pos, max).trim();
    if (meta.indexOf("$") >= 0) return false;
    if (silent) return true;

    var nextLine = startLine, haveEnd = false;
    while (nextLine + 1 < endLine) {
      nextLine++;
      var p = state.bMarks[nextLine] + state.tShift[nextLine];
      var m = state.eMarks[nextLine];
      if (p < m && state.sCount[nextLine] < state.blkIndent) break;
      if (state.src.charCodeAt(p) !== 0x24) continue;
      if (state.sCount[nextLine] - state.blkIndent >= 4) continue;
      var q = p;
      while (q < m && state.src.charCodeAt(q) === 0x24) q++;
      if (q - p < sizeOpen) continue;
      if (state.skipSpaces(q) < m) continue;
      haveEnd = true;
      break;
    }

    var body = state.getLines(startLine + 1, haveEnd ? nextLine : nextLine + 1,
                              state.blkIndent, false);
    var blockToken = state.push("math_block", "math", 0);
    blockToken.block = true;
    blockToken.markup = "$".repeat(sizeOpen);
    blockToken.content = body.replace(/\n$/, "");
    blockToken.map = [startLine, nextLine];
    state.line = haveEnd ? nextLine + 1 : nextLine;
    return true;
  }

  // ============================================================ wikilinks ==
  // Same grammar as quartz/plugins/transformers/ofm.ts:123.

  var WIKILINK = /^!?\[\[([^\[\]\|\#\\]+)?(#+[^\[\]\|\#\\]+)?(\\?\|[^\[\]\#]*)?\]\]/;

  function wikilink(state, silent) {
    var c = state.src.charCodeAt(state.pos);
    if (c !== 0x5b /* [ */ && c !== 0x21 /* ! */) return false;

    var match = WIKILINK.exec(state.src.slice(state.pos, state.posMax));
    if (!match) return false;

    if (!silent) {
      var token = state.push("wikilink", "", 0);
      token.content = match[0];
      token.meta = {
        raw: match[0],
        target: (match[1] || "").trim(),
        anchor: (match[2] || "").trim(),
        alias: match[3] ? match[3].replace(/^\\?\|/, "").trim() : null,
        embed: match[0].charAt(0) === "!",
      };
    }
    state.pos += match[0].length;
    return true;
  }

  // ============================================================= headings ==
  // rehype-slug assigns heading ids with a per-document *deduplicating*
  // GithubSlugger, so a second `## Syntax` becomes `syntax-1`. Wikilink
  // anchors use the non-deduplicating variant and therefore can only ever
  // address the first — a real Quartz limitation we reproduce rather than fix.

  function headingPlainText(inlineToken) {
    var out = "";
    (inlineToken.children || []).forEach(function (child) {
      if (child.type === "text" || child.type === "code_inline") {
        out += child.content;
      } else if (child.type === "math_inline") {
        // rehype-slug runs before rehype-katex, so the *source* is what feeds
        // the anchor — minus the `$` delimiters, which it strips anyway.
        out += child.content;
      } else if (child.type === "wikilink") {
        out += child.meta.alias || child.meta.target;
      }
    });
    return out;
  }

  function headingIds(md) {
    md.core.ruler.push("ccwiki_heading_ids", function (state) {
      var slugger = new global.GithubSlugger();
      var toc = [];
      var tokens = state.tokens;

      for (var i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== "heading_open") continue;
        var text = headingPlainText(tokens[i + 1]);
        var id = slugger.slug(text);
        tokens[i].attrSet("id", id);
        toc.push({ level: Number(tokens[i].tag.slice(1)), text: text, id: id });
      }
      state.env.toc = toc;
    });
  }

  // ============================================================= callouts ==
  // Obsidian callouts are blockquotes whose first line is `[!type] Title`
  // (quartz ofm.ts:147). Zero pages use them today, but the plugin is enabled
  // site-side and agent-written pages may well start.

  var CALLOUT = /^\[!([\w-]+)\]([+-]?)\s*(.*)$/;

  function callouts(md) {
    md.core.ruler.push("ccwiki_callouts", function (state) {
      var tokens = state.tokens;
      for (var i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== "blockquote_open") continue;
        // blockquote_open, paragraph_open, inline, ...
        var inline = tokens[i + 2];
        if (!inline || inline.type !== "inline") continue;
        var match = CALLOUT.exec(inline.content);
        if (!match) continue;

        var kind = match[1].toLowerCase();
        var title = match[3] || (kind.charAt(0).toUpperCase() + kind.slice(1));

        tokens[i].tag = "div";
        tokens[i].attrJoin("class", "callout callout-" + kind);
        var close = findMatching(tokens, i, "blockquote_open", "blockquote_close");
        if (close >= 0) tokens[close].tag = "div";

        // Replace the marker paragraph with the styled title.
        tokens[i + 1].tag = "div";
        tokens[i + 1].attrJoin("class", "callout-title");
        tokens[i + 3].tag = "div";
        inline.content = title;
        inline.children = [Object.assign(new state.Token("text", "", 0), { content: title })];
      }
    });
  }

  function findMatching(tokens, from, openType, closeType) {
    var depth = 0;
    for (var i = from; i < tokens.length; i++) {
      if (tokens[i].type === openType) depth++;
      else if (tokens[i].type === closeType && --depth === 0) return i;
    }
    return -1;
  }

  // ============================================================== factory ==

  function createMarkdown(macros) {
    var katexOptions = {
      macros: macros || {},
      throwOnError: false,
      strict: "ignore",
      output: "html",          // parity with quartz latex.ts:46 — no MathML
      trust: false,
      maxExpand: 1000,
    };

    var md = global.markdownit({
      // The corpus contains exactly one raw HTML block (the macros-copy anchor
      // in Glossary/latex-macros.md) and the website renders it. With
      // `script-src 'self'` and no 'unsafe-inline' in the CSP, markup coming
      // out of the wiki cannot execute, so passing it through is safe and
      // matches the site.
      html: true,
      linkify: true,           // remark-gfm autolink literals
      typographer: true,       // remark-smartypants (quartz gfm.ts:24)
      breaks: false,           // Plugin.HardLineBreaks() is not configured
    });

    if (global.markdownitFootnote) md.use(global.markdownitFootnote);
    if (global.markdownitMark) md.use(global.markdownitMark);

    // Math has to be reachable before `escape` and the emphasis scanners, or
    // `$\mathsf{st}_{\calA}$` loses its underscores to italics.
    md.inline.ruler.before("escape", "math_inline", mathInline);
    md.inline.ruler.before("escape", "wikilink", wikilink);
    md.block.ruler.before("fence", "math_block", mathBlock,
      { alt: ["paragraph", "reference", "blockquote", "list"] });

    headingIds(md);
    callouts(md);

    // Every rendered formula carries its source in `data-tex`, so ⌘C and a
    // right-click can copy its LaTeX. KaTeX's own annotation would do it,
    // but only with MathML output, which the site does not emit.
    md.renderer.rules.math_inline = function (tokens, idx) {
      try {
        return '<span class="math" data-tex="' + md.utils.escapeHtml(tokens[idx].content) + '">' +
          global.katex.renderToString(tokens[idx].content, katexOptions) + "</span>";
      } catch (e) {
        return '<code class="math-error">' + md.utils.escapeHtml(tokens[idx].content) + "</code>";
      }
    };

    md.renderer.rules.math_block = function (tokens, idx) {
      try {
        var opts = Object.assign({}, katexOptions, { displayMode: true });
        return '<div class="math-display" data-tex="' + md.utils.escapeHtml(tokens[idx].content) + '">' +
          global.katex.renderToString(tokens[idx].content, opts) + "</div>\n";
      } catch (e) {
        return '<pre class="math-error">' + md.utils.escapeHtml(tokens[idx].content) + "</pre>\n";
      }
    };

    md.renderer.rules.wikilink = function (tokens, idx, options, env) {
      var meta = tokens[idx].meta;
      var resolved = (env.links || {})[meta.raw];
      var label = displayText(meta);

      // Swift resolved every link before the markdown crossed the bridge; a
      // miss here means no page, alias or folder claims that slug. The website
      // renders those as ordinary links to nowhere. Showing them as broken is
      // the one deliberate divergence: in an app you use to *edit* the wiki,
      // a dead link is information.
      if (!resolved || !resolved.href) {
        return '<a class="broken" title="Nothing resolves to \u201c' +
          md.utils.escapeHtml(meta.target || meta.anchor) + '\u201d">' +
          md.utils.escapeHtml(label) + "</a>";
      }
      if (meta.embed && resolved.isImage) {
        return '<img src="' + md.utils.escapeHtml(resolved.href) + '" alt="' +
          md.utils.escapeHtml(label) + '" loading="lazy">';
      }
      if (resolved.external) {
        return '<a class="external" href="' + md.utils.escapeHtml(resolved.href) +
          '">' + md.utils.escapeHtml(label) + "</a>";
      }
      return '<a class="internal' + (resolved.kind === "folder" ? " folder" : "") +
        '" href="' + md.utils.escapeHtml(resolved.href) + '">' +
        md.utils.escapeHtml(label) + "</a>";
    };

    // Pseudocode fences are handed to pseudocode.js verbatim after render.
    var defaultFence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, idx, options, env, self) {
      if ((tokens[idx].info || "").trim() === "pseudocode") {
        return '<pre class="pseudocode">' + md.utils.escapeHtml(tokens[idx].content) + "</pre>\n";
      }
      return defaultFence(tokens, idx, options, env, self);
    };

    // Wide tables scroll in their own box instead of widening the measure.
    md.renderer.rules.table_open = function () { return '<div class="table-scroll"><table>\n'; };
    md.renderer.rules.table_close = function () { return "</table></div>\n"; };

    return md;
  }

  function noticeHTML(notices) {
    if (!notices || !notices.length) return "";
    var md = ensureMarkdown();
    return notices.map(function (n) {
      return '<div class="notice notice-' + (n.level === "warning" ? "warning" : "info") +
        '">' + md.utils.escapeHtml(n.text) + "</div>";
    }).join("");
  }

  function displayText(meta) {
    if (meta.alias) return meta.alias;
    if (!meta.target && meta.anchor) return meta.anchor.replace(/^#+/, "");
    // Quartz's prettyLinks default shows the last path segment.
    var base = meta.target.split("/").pop();
    return meta.anchor ? base + " › " + meta.anchor.replace(/^#+/, "") : base;
  }

  // ========================================================== post-render ==

  /** pseudocode.js resolves its math backend from the global `katex` symbol
   *  and calls `renderToString` with no options, so macros have to arrive by
   *  patching — which is exactly what quartz/plugins/.../pseudocode.ts does. */
  function installKatexMacros() {
    if (global.katex.__cityDeskPatched) return;
    var original = global.katex.renderToString.bind(global.katex);
    global.katex.renderToString = function (expr, options) {
      // Read at call time, not captured: the table can change between renders.
      return original(expr, Object.assign(
        { macros: currentMacros || {}, throwOnError: false, strict: "ignore" }, options || {}));
    };
    global.katex.__cityDeskPatched = true;
  }

  function renderPseudocode(root) {
    var blocks = Array.prototype.slice.call(root.querySelectorAll("pre.pseudocode"));
    var errors = 0;

    blocks.forEach(function (el, i) {
      var source = el.textContent;
      // The box goes in first and the block renders inside it, so each box
      // holds its own block. Finding the output afterwards by its position
      // among the `.ps-root`s went wrong after a failed block, which leaves
      // none, and misaligned every later block.
      var box = document.createElement("div");
      box.className = "pseudocode-container";
      el.parentNode.insertBefore(box, el);
      box.appendChild(el);
      try {
        // `Renderer.captionCount` is a module-level counter that never resets;
        // in a long-lived web view "Algorithm N" would drift across pages.
        global.pseudocode.renderElement(el, {
          lineNumber: true,
          noEnd: false,
          commentDelimiter: "▸",
          captionCount: i === 0 ? 0 : undefined,
        });
      } catch (e) {
        errors++;
        var pre = document.createElement("pre");
        pre.className = "pseudocode-error";
        pre.textContent = "pseudocode error: " + e.message + "\n\n" + source;
        box.replaceWith(pre);
        return;
      }
      // On the box, never as a data-* attribute of the <pre>: renderElement
      // copies the <pre>'s dataset into its own options.
      var latex = stripAlgname(source);
      box.setAttribute("data-source", latex);
      var split = /^\s*%\s*oracle-split:\s*(\d+)/m.exec(source);
      if (split) box.setAttribute("data-oracle-split", split[1]);
      addCopyRow(box, latex);
    });
    return { count: blocks.length, errors: errors };
  }

  /** `\algname{…}` is the wiki fork's own directive, which LaTeX's
   *  algorithmicx does not know, so copied source leaves it out, as the
   *  site's copy buttons do (quartz pseudocode.ts:155). */
  function stripAlgname(source) {
    return source.replace(/\\algname\{[^}]*\}/g, "");
  }

  /** `source` with the wiki's macros written out, for a LaTeX document that
   *  does not have the preamble. The site makes one pass over the table in
   *  the order of macros.ts (quartz pseudocode.ts:159). Here the order is
   *  whatever the Swift dictionary gave this launch, so passes repeat until
   *  nothing changes: the result does not depend on the order, and a macro
   *  whose body uses another would come out fully written. Today no body
   *  does, so the first pass is the last and the result is the site's. The
   *  cap stops a self-referring macro, which KaTeX would reject anyway. A
   *  name matches only as a whole control word, so `\st` leaves `\stA`
   *  alone. */
  function expandMacros(source, macros) {
    var patterns = Object.keys(macros).map(function (name) {
      return {
        pattern: new RegExp(
          name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(?![a-zA-Z@*])", "g"),
        body: macros[name],
      };
    });
    var result = stripAlgname(source);
    for (var pass = 0; pass < 10; pass++) {
      var before = result;
      patterns.forEach(function (macro) {
        // A function, so a `$` in the body is never read as a replacement
        // pattern.
        result = result.replace(macro.pattern, function () { return macro.body; });
      });
      if (result === before) break;
    }
    return result;
  }

  /** A small button that puts `text()` on the pasteboard through the app,
   *  and says so for two seconds, as the site's buttons do. The text is
   *  worked out on click, from the page as rendered.
   *
   *  The label is generated content (`.copy-button::before` in app.css),
   *  not text in the DOM: the buttons sit faded out on every algorithm, and
   *  find in page would otherwise match "LaTeX" or "macros" in them and
   *  could jump to one above the real hit. `aria-label` names the button
   *  for VoiceOver. */
  function copyButton(label, text) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-button";
    setButtonLabel(button, label);
    var timer = null;
    button.addEventListener("click", function () {
      post({ type: "copy", text: text() });
      // Hold the width, so the row does not shift while the label is short.
      button.style.minWidth = button.getBoundingClientRect().width + "px";
      setButtonLabel(button, "Copied!");
      button.classList.add("copied");
      clearTimeout(timer);
      timer = setTimeout(function () {
        setButtonLabel(button, label);
        button.classList.remove("copied");
        button.style.minWidth = "";
      }, 2000);
    });
    return button;
  }

  function setButtonLabel(button, label) {
    button.setAttribute("data-label", label);
    button.setAttribute("aria-label", label);
  }

  /** The site's pair of buttons under an algorithm (quartz pseudocode.ts:182):
   *  its source as written, and the same with the macros written out. */
  function addCopyRow(box, latex) {
    var row = document.createElement("div");
    row.className = "copy-row";
    row.appendChild(copyButton("Copy LaTeX (macros)", function () { return latex; }));
    row.appendChild(copyButton("Copy LaTeX (no macros)", function () {
      return expandMacros(latex, currentMacros || {});
    }));
    box.appendChild(row);
  }

  /** Glossary/latex-macros has an empty `#macros-copy-area` for the site's
   *  script to fill (quartz pseudocode.ts:253). Fill it the same way, from
   *  the table this page was rendered with. The names are sorted: the table
   *  crosses from Swift as a dictionary, so the order of macros.ts is gone. */
  function fillMacrosCopyArea(root) {
    var area = root.querySelector("#macros-copy-area");
    var macros = currentMacros || {};
    var names = Object.keys(macros).sort();
    if (!area || !names.length) return;

    var sorted = {};
    names.forEach(function (name) { sorted[name] = macros[name]; });
    var preamble = names.map(function (name) {
      return "\\newcommand{" + name + "}{" + macros[name] + "}";
    }).join("\n");
    var json = JSON.stringify(sorted, null, 2);

    var row = document.createElement("div");
    row.className = "copy-row";
    row.appendChild(copyButton("Copy LaTeX preamble", function () { return preamble; }));
    row.appendChild(copyButton("Copy KaTeX/MathJax JSON", function () { return json; }));
    area.textContent = "";
    area.appendChild(row);
  }

  /** Groups a `\algname{Game}` block with the non-Game blocks that immediately
   *  follow it, so the game and its oracles sit side by side the way they do
   *  on the site. */
  function groupGames(root) {
    var boxes = Array.prototype.slice.call(root.querySelectorAll(".pseudocode-container"));
    var i = 0;
    while (i < boxes.length) {
      if (!isGame(boxes[i])) { i++; continue; }
      var followers = [];
      var j = i + 1;
      while (j < boxes.length && !isGame(boxes[j]) && boxes[j].previousElementSibling === boxes[j - 1]) {
        followers.push(boxes[j]);
        j++;
      }
      if (followers.length) {
        var group = document.createElement("div");
        group.className = "game-group";
        boxes[i].parentElement.insertBefore(group, boxes[i]);
        group.appendChild(boxes[i]);
        var column = document.createElement("div");
        column.className = "oracle-column";
        followers.forEach(function (box) { column.appendChild(box); });
        group.appendChild(column);
        // `% oracle-split: N` in the game's source gives the oracles N% of
        // the width (quartz pseudocode.ts:245). A class and a custom property
        // rather than the site's inline `flex`, which the narrow-window
        // rules could not override.
        var share = parseInt(boxes[i].getAttribute("data-oracle-split"), 10);
        if (share > 0 && share < 100) {
          group.classList.add("split");
          group.style.setProperty("--oracle-share", share + "%");
        }
      }
      i = j;
    }
  }

  function isGame(box) {
    var caption = box.querySelector(".ps-algorithm > .ps-line");
    return !!caption && /^\s*Game\b/.test(caption.textContent || "");
  }

  /** The `**Authors:** … | **Venue:** … | [Source](…)` line under a reference
   *  H1 is metadata, not prose — give it its own type treatment. */
  function markByline(root) {
    var h1 = root.querySelector("h1");
    if (!h1) return;
    var next = h1.nextElementSibling;
    if (next && next.tagName === "P" && /^\s*Authors:/.test(next.textContent)) {
      next.classList.add("byline");
    }
  }

  // ================================================================= API ===

  var currentMacros = null;
  var currentMacrosKey = null;
  var md = null;

  /** A canonical string for a macro table, so two tables compare by content
   *  whatever order their keys arrived in. */
  function macrosKey(macros) {
    return Object.keys(macros).sort().map(function (k) {
      return k + "=" + macros[k];
    }).join("\u0001");
  }

  /**
   * The markdown-it instance for a macro table.
   *
   * The table comes with every render payload rather than once at startup:
   * on a fresh install the clone — and so `macros.ts` — does not exist until
   * after the first sync, and a pull can change it. Rebuilding markdown-it
   * is cheap; rendering a page with a stale table is every `\calA` in red.
   */
  function ensureMarkdown(macros) {
    if (macros === undefined || macros === null) {
      macros = ((global.__CCWIKI__ || {}).macros) || {};
    }
    var key = macrosKey(macros);
    if (md && key === currentMacrosKey) return md;
    currentMacros = macros;
    currentMacrosKey = key;
    installKatexMacros();
    md = createMarkdown(macros);
    return md;
  }

  /**
   * Render one page. Called by Swift via evaluateJavaScript.
   *
   * payload = {
   *   markdown : string,           body with frontmatter already stripped
   *   links    : { "[[raw]]": {href, kind, external} },
   *   macros   : { "\\calA": "\\mathcal{A}" },   KaTeX macros, current as of
   *                                this render
   *   html     : string            (optional) pre-built HTML, used for
   *                                synthetic folder pages
   * }
   */
  // Where each page was left, so Back and Forward return to the same place,
  // as in a browser. Lives as long as this document does: a relaunch starts
  // every page at the top again.
  var scrollPositions = {};
  var shownPath = null;

  function render(payload) {
    var started = Date.now();
    var page = document.getElementById("page");
    var env = { links: payload.links || {} };
    var toc = [];
    if (shownPath !== null) scrollPositions[shownPath] = window.scrollY;
    var keepY = payload.preserveScroll ? window.scrollY : null;
    var restoreY = payload.restoreScroll &&
      Object.prototype.hasOwnProperty.call(scrollPositions, payload.path)
      ? scrollPositions[payload.path] : null;
    shownPath = payload.path;
    lastReportedHeading = undefined;

    try {
      var markdown = ensureMarkdown(payload.macros);
      var prefix = noticeHTML(payload.notices);
      if (payload.html !== undefined && payload.html !== null) {
        page.innerHTML = prefix + payload.html;
      } else {
        page.innerHTML = prefix + markdown.render(payload.markdown || "", env);
        toc = env.toc || [];
      }
    } catch (e) {
      page.innerHTML = '<div class="notice notice-warning">Render failed: ' +
        String(e && e.message ? e.message : e) + "</div>";
      post({ type: "rendered", ok: false, error: String(e), toc: [] });
      return;
    }

    fillMacrosCopyArea(page);
    var pseudo = { count: 0, errors: 0 };
    if (global.pseudocode) {
      pseudo = renderPseudocode(page);
      groupGames(page);
    }
    markByline(page);

    if (keepY !== null) {
      window.scrollTo(0, keepY);
    } else if (restoreY !== null) {
      window.scrollTo(0, restoreY);
    } else if (payload.anchor) {
      if (!scrollToAnchor(payload.anchor)) window.scrollTo(0, 0);
    } else {
      window.scrollTo(0, 0);
    }
    post({
      type: "rendered",
      ok: true,
      toc: toc,
      pseudocodeBlocks: pseudo.count,
      pseudocodeErrors: pseudo.errors,
      ms: Date.now() - started,
    });
    reportScroll();
  }

  function scrollToAnchor(anchor) {
    if (!anchor) { window.scrollTo(0, 0); return true; }
    var el = document.getElementById(anchor);
    if (!el) return false;
    el.scrollIntoView({ block: "start", behavior: "auto" });
    return true;
  }

  /** The visible heading nearest the top of the viewport, so the outline can
   *  track the reader's position. */
  function currentHeading() {
    var headings = document.querySelectorAll("h1[id],h2[id],h3[id],h4[id]");
    var best = null;
    for (var i = 0; i < headings.length; i++) {
      if (headings[i].getBoundingClientRect().top <= 80) best = headings[i].id;
      else break;
    }
    return best;
  }

  // ============================================================= copying ==
  // A formula on the page is glyphs: copied as it stands, a fraction reads
  // as "21" and every macro is lost. ⌘C and the context menu put its LaTeX
  // on the pasteboard instead, and the buttons under each algorithm copy
  // the whole block.

  /** The formula `node` is part of, if any. Markdown math carries its source
   *  in `data-tex`; pseudocode.js renders with KaTeX's default output, whose
   *  MathML annotation carries it instead. */
  function mathHost(node) {
    var el = node && (node.nodeType === 1 ? node : node.parentElement);
    if (!el || !el.closest) return null;
    return el.closest("[data-tex]") || el.closest(".katex");
  }

  function texOf(host) {
    if (host.hasAttribute("data-tex")) return host.getAttribute("data-tex");
    var annotation = host.querySelector('annotation[encoding="application/x-tex"]');
    return annotation ? annotation.textContent : null;
  }

  /** Replaces every formula under `root` with its LaTeX: `$…$` inline, and
   *  display math as `$$`, the source and `$$` on lines of their own, which
   *  is how the wiki writes it (a one-line `$$x$$` is inline math). */
  function texify(root) {
    root.querySelectorAll("[data-tex]").forEach(function (host) {
      var display = host.classList.contains("math-display");
      host.replaceWith(texNode(host.getAttribute("data-tex"), display));
    });
    root.querySelectorAll(".katex").forEach(function (katex) {
      var tex = texOf(katex);
      if (tex !== null) katex.replaceWith(texNode(tex, false));
    });
  }

  function texNode(tex, display) {
    var node = document.createElement(display ? "div" : "span");
    node.textContent = display ? "$$\n" + tex + "\n$$" : "$" + tex + "$";
    // As typed: innerText would otherwise fold the line breaks into spaces.
    node.style.whiteSpace = "pre-wrap";
    return node;
  }

  // ⌘C, Edit › Copy and the menu's own Copy all reach here. A selection with
  // math in it is copied with each formula as its LaTeX, as plain text and
  // as HTML, so Notes and Mail paste the LaTeX too. Anything else is left to
  // WebKit.
  document.addEventListener("copy", function (event) {
    var selection = window.getSelection();
    if (!event.clipboardData || !selection || selection.isCollapsed || !selection.rangeCount) return;

    // A clone, widened to whole formulas: half a formula has no LaTeX, and
    // moving the real selection would show.
    var range = selection.getRangeAt(0).cloneRange();
    var start = mathHost(range.startContainer);
    if (start) range.setStartBefore(start);
    var end = mathHost(range.endContainer);
    if (end) range.setEndAfter(end);

    var scratch = document.createElement("div");
    scratch.className = "copy-scratch";
    scratch.setAttribute("aria-hidden", "true");
    scratch.appendChild(range.cloneContents());
    // The copy buttons are not page text. Their labels are generated content,
    // but the buttons themselves, whatever WebKit makes of their
    // user-select: none, could still reach the copied HTML, so a selection
    // across them is copied here, without them.
    if (!scratch.querySelector("[data-tex], .katex, .copy-row")) return;
    scratch.querySelectorAll(".copy-row").forEach(function (row) { row.remove(); });
    texify(scratch);
    // One line per algorithm line: to innerText a <p> is a paragraph, with
    // a blank line after it.
    scratch.querySelectorAll("p.ps-line").forEach(function (line) {
      var div = document.createElement("div");
      div.className = line.className;
      while (line.firstChild) div.appendChild(line.firstChild);
      line.replaceWith(div);
    });

    // Attached, because only a laid-out box has an innerText with the
    // paragraph and line breaks the reader sees; textContent runs them
    // together.
    document.body.appendChild(scratch);
    var text = scratch.innerText || scratch.textContent;
    scratch.remove();

    event.clipboardData.setData("text/plain", text);
    event.clipboardData.setData("text/html", scratch.innerHTML);
    event.preventDefault();
  }, true);

  // Before WebKit builds the context menu, tell Swift what is under the
  // pointer: a formula's LaTeX, and an algorithm's, as written and with the
  // macros written out. The message is sent on the same connection as, and
  // ahead of, the menu request, so it arrives first.
  document.addEventListener("contextmenu", function (event) {
    var target = event.target;
    var host = mathHost(target);
    var box = target && target.closest ? target.closest(".pseudocode-container") : null;
    var source = box ? box.getAttribute("data-source") : null;
    post({
      type: "contextTarget",
      tex: host ? texOf(host) : null,
      algorithm: source,
      algorithmExpanded: source === null ? null : expandMacros(source, currentMacros || {}),
    });
  }, true);

  // Internal links are navigations for the *app*, not the web view: the Swift
  // side owns history, the sidebar selection and the inspector.
  document.addEventListener("click", function (event) {
    var anchor = event.target.closest ? event.target.closest("a") : null;
    if (!anchor) return;

    if (anchor.classList.contains("broken")) { event.preventDefault(); return; }

    var href = anchor.getAttribute("href") || "";
    if (!href) return;

    if (/^https?:|^mailto:/.test(href)) {
      event.preventDefault();
      post({ type: "openExternal", url: href });
      return;
    }
    if (href.charAt(0) === "#") {
      event.preventDefault();
      scrollToAnchor(href.slice(1));
      return;
    }
    event.preventDefault();
    post({ type: "navigate", href: href, modified: event.metaKey || event.shiftKey });
  }, true);

  // One report per frame, and only when the answer changed: a scroll event
  // fires many times per frame, and every message crosses the bridge and
  // re-evaluates the Outline pane on the Swift side.
  var lastReportedHeading;
  var scrollReportScheduled = false;

  function reportScroll() {
    var heading = currentHeading();
    if (heading === lastReportedHeading) return;
    lastReportedHeading = heading;
    post({ type: "scrolled", heading: heading });
  }

  document.addEventListener("scroll", function () {
    if (scrollReportScheduled) return;
    scrollReportScheduled = true;
    window.requestAnimationFrame(function () {
      scrollReportScheduled = false;
      reportScroll();
    });
  }, { passive: true });

  global.CCwiki = {
    render: render,
    scrollToAnchor: scrollToAnchor,
    currentHeading: currentHeading,
    // Exposed for the unit-test harness in scripts/.
    createMarkdown: createMarkdown,
  };

  post({ type: "ready" });
})(window);
