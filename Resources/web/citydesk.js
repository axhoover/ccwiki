/* CityDesk renderer — runs inside the WKWebView, offline, no network.
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
    ? global.webkit.messageHandlers.citydesk
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
    md.core.ruler.push("citydesk_heading_ids", function (state) {
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
    md.core.ruler.push("citydesk_callouts", function (state) {
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

    md.renderer.rules.math_inline = function (tokens, idx) {
      try {
        return global.katex.renderToString(tokens[idx].content, katexOptions);
      } catch (e) {
        return '<code class="math-error">' + md.utils.escapeHtml(tokens[idx].content) + "</code>";
      }
    };

    md.renderer.rules.math_block = function (tokens, idx) {
      try {
        var opts = Object.assign({}, katexOptions, { displayMode: true });
        return '<div class="math-display">' +
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
  function installKatexMacros(macros) {
    if (global.katex.__cityDeskPatched) return;
    var original = global.katex.renderToString.bind(global.katex);
    global.katex.renderToString = function (expr, options) {
      return original(expr, Object.assign(
        { macros: macros, throwOnError: false, strict: "ignore" }, options || {}));
    };
    global.katex.__cityDeskPatched = true;
  }

  function renderPseudocode(root) {
    var blocks = Array.prototype.slice.call(root.querySelectorAll("pre.pseudocode"));
    var errors = 0;

    blocks.forEach(function (el, i) {
      var source = el.textContent;
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
        el.replaceWith(pre);
        return;
      }
      // renderElement replaces the <pre> in place; wrap whatever landed there.
      var rendered = root.querySelectorAll(".ps-root");
      var node = rendered[i];
      if (node && !node.parentElement.classList.contains("pseudocode-container")) {
        var box = document.createElement("div");
        box.className = "pseudocode-container";
        node.parentElement.insertBefore(box, node);
        box.appendChild(node);
      }
    });
    return { count: blocks.length, errors: errors };
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
  var md = null;

  function ensureMarkdown() {
    if (md) return md;
    var boot = global.__CITYDESK__ || {};
    currentMacros = boot.macros || {};
    installKatexMacros(currentMacros);
    md = createMarkdown(currentMacros);
    return md;
  }

  /**
   * Render one page. Called by Swift via evaluateJavaScript.
   *
   * payload = {
   *   markdown : string,           body with frontmatter already stripped
   *   links    : { "[[raw]]": {href, kind, external} },
   *   html     : string            (optional) pre-built HTML, used for
   *                                synthetic folder pages
   * }
   */
  function render(payload) {
    var started = Date.now();
    var page = document.getElementById("page");
    var env = { links: payload.links || {} };
    var toc = [];

    try {
      var prefix = noticeHTML(payload.notices);
      if (payload.html !== undefined && payload.html !== null) {
        page.innerHTML = prefix + payload.html;
      } else {
        page.innerHTML = prefix + ensureMarkdown().render(payload.markdown || "", env);
        toc = env.toc || [];
      }
    } catch (e) {
      page.innerHTML = '<div class="notice notice-warning">Render failed: ' +
        String(e && e.message ? e.message : e) + "</div>";
      post({ type: "rendered", ok: false, error: String(e), toc: [] });
      return;
    }

    var pseudo = { count: 0, errors: 0 };
    if (global.pseudocode) {
      pseudo = renderPseudocode(page);
      groupGames(page);
    }
    markByline(page);

    if (payload.anchor) {
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

  document.addEventListener("scroll", function () {
    post({ type: "scrolled", heading: currentHeading() });
  }, { passive: true });

  global.CityDesk = {
    render: render,
    scrollToAnchor: scrollToAnchor,
    currentHeading: currentHeading,
    // Exposed for the unit-test harness in scripts/.
    createMarkdown: createMarkdown,
  };

  post({ type: "ready" });
})(window);
