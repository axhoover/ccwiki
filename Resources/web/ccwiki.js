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
 *
 * The Markdown half, which touches no DOM, is `ccwiki-markdown.js`, loaded
 * just before this file. This one has everything that touches the document:
 * rendering into it, pseudocode, copying, the context menu, link previews,
 * the selection a correction starts from, and the review of a change.
 */
(function (global) {
  "use strict";

  var bridge = global.webkit && global.webkit.messageHandlers
    ? global.webkit.messageHandlers.ccwiki
    : null;

  function post(message) {
    if (bridge) { try { bridge.postMessage(message); } catch (e) { /* no-op */ } }
  }

  // The Markdown itself (the math, wikilinks, heading ids, callouts and
  // the source line of every block) is `ccwiki-markdown.js`, which touches
  // no DOM, so it can be tested without a web view. This file keeps
  // everything that touches the document.
  var markdownLibrary = global.CCwikiMarkdown;

  /** Where a block came from in the Markdown: `first-end`, 0-based and
   *  half-open, on every block `ccwiki-markdown.js` renders. Pseudocode's
   *  arrives as `ccwiki-lines` and moves onto its box. */
  var SOURCE_LINES = "data-source-lines";
  var PSEUDOCODE_LINES = "ccwiki-lines";

  /** The notices above a page: Swift's words, as plain text. */
  function noticeHTML(notices) {
    if (!notices || !notices.length) return "";
    return notices.map(function (n) {
      return '<div class="notice notice-' + (n.level === "warning" ? "warning" : "info") +
        '">' + escapeText(n.text) + "</div>";
    }).join("");
  }

  // ========================================================== post-render ==

  /** pseudocode.js resolves its math backend from the global `katex` symbol
   *  and calls `renderToString` with no options, so macros have to arrive by
   *  patching — which is exactly what quartz/plugins/.../pseudocode.ts does.
   *  Every formula goes through the patch, the page's, a card's and
   *  pseudocode's alike, so the memo below lives in it. */
  function installKatexMacros() {
    if (global.katex.__cityDeskPatched) return;
    var original = global.katex.renderToString.bind(global.katex);
    global.katex.renderToString = function (expr, options) {
      // Read at call time, not captured: the table can change between renders.
      var merged = Object.assign(
        { macros: currentMacros || {}, throwOnError: false, strict: "ignore" }, options || {});
      if (writesMacros(expr, merged)) {
        // What the memo holds was rendered with the table as it was. And
        // what this defines can define more when a later formula uses it,
        // which no formula's text shows, so nothing is kept until
        // `ensureMarkdown` installs another table.
        katexMemo.clear();
        katexMemoOn = false;
        return original(expr, merged);
      }
      var key = katexMemoKey(expr, merged);
      if (key === null) return original(expr, merged);
      var html = katexMemo.get(key);
      if (html !== undefined) {
        // The map's last entry is the one used last.
        katexMemo.delete(key);
        katexMemo.set(key, html);
        return html;
      }
      html = original(expr, merged);
      if (katexMemo.size >= KATEX_MEMO_LIMIT) katexMemo.delete(katexMemo.keys().next().value);
      katexMemo.set(key, html);
      return html;
    };
    global.katex.__cityDeskPatched = true;
  }

  // ========================================================== KaTeX memo ==
  // A formula's HTML depends on its source, its options and the macro
  // table. KaTeX keeps nothing else between calls, and a formula that
  // changes the table, or reads what another left in it, never reaches the
  // memo. So each formula renders once while the table stands, and a
  // page's repeats, Back and Forward, the editor's preview as it is typed
  // in, a review's refresh and the cards read it back
  // (plans/render-pipeline.md, "The KaTeX memo").

  /** How many formulas are kept, the least recently used going first: any
   *  one page (the most on one is 166) and the last hundred or so read, in
   *  about 1.6 M characters. render-pipeline.md has the hit rates. */
  var KATEX_MEMO_LIMIT = 1000;
  var katexMemo = new Map();
  /** Off while a macro of the table could change what a formula reads, and
   *  after a formula has defined one. */
  var katexMemoOn = true;
  /** What writes KaTeX's shared macro table from inside a formula: `\gdef`,
   *  `\xdef`, and `\global` before a `\def`, `\edef`, `\let` or
   *  `\futurelet`. `\def` and `\newcommand` are local to their formula. */
  var GLOBAL_DEFINITION = /\\(?:gdef|xdef|global)(?![A-Za-z@])/;
  /** What sets KaTeX's own `\@eqnsw`, which a formula naming it reads: a
   *  numbered environment (`align`, `alignat`, `gather`, `equation`) at
   *  each row, `\nonumber` and `\notag`. Any `\begin`, since a macro can
   *  spell an environment's name. */
  var SETS_EQUATION_SWITCH = /\\(?:begin|nonumber|notag)(?![A-Za-z@])/;

  /** Whether a call can change the table every later formula reads: a
   *  global definition, or in KaTeX's global group any definition. KaTeX
   *  takes a `String` object too, which `test` reads as its text. */
  function writesMacros(expr, options) {
    return !!options.globalGroup || GLOBAL_DEFINITION.test(expr);
  }

  /** Whether a formula naming the macro whose body this is could read or
   *  change what another formula left in the table. */
  function sharesMacroState(body) {
    return GLOBAL_DEFINITION.test(body) || SETS_EQUATION_SWITCH.test(body) || body.indexOf("@") >= 0;
  }

  /** The memo's key for a call, or null for a call that must reach KaTeX:
   *  while the memo is off, for a formula that is not a string, for
   *  another table than the current one, and for an option that is an
   *  object or a function (`strict`, `trust`), which can answer otherwise
   *  under the same name. */
  function katexMemoKey(expr, options) {
    if (!katexMemoOn || typeof expr !== "string" || options.macros !== currentMacros) return null;
    // KaTeX's own `\@eqnsw` stays in the table from one formula to the
    // next, and a formula that names it reads what the last one to set it
    // left. So neither kind is kept, and every one that sets it renders,
    // as without the memo. KaTeX's own names all have an `@`; no formula
    // or macro in the wiki has one, or a `\begin`.
    if (expr.indexOf("@") >= 0 || SETS_EQUATION_SWITCH.test(expr)) return null;
    var parts = [];
    for (var name in options) {
      if (name === "macros") continue;
      var value = options[name];
      if (typeof value === "function" || (typeof value === "object" && value !== null)) return null;
      parts.push(name, typeof value, String(value));
    }
    // JSON never holds a raw U+0000, so the options end at the first one.
    return JSON.stringify(parts) + "\u0000" + expr;
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
      // The block's source lines come as `ccwiki-lines`, not a data-*
      // attribute, which renderElement would copy into its options; the box
      // carries them as every other block does (corrections §3.2).
      var lines = el.getAttribute(PSEUDOCODE_LINES);
      if (lines) {
        box.setAttribute(SOURCE_LINES, lines);
        el.removeAttribute(PSEUDOCODE_LINES);
      }
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
        if (lines) pre.setAttribute(SOURCE_LINES, lines);
        box.replaceWith(pre);
        return;
      }
      // On the box, never as a data-* attribute of the <pre>: renderElement
      // copies the <pre>'s dataset into its own options.
      var latex = stripAlgname(source);
      box.setAttribute("data-source", latex);
      var split = /^\s*%\s*oracle-split:\s*(\d+)/m.exec(source);
      if (split) box.setAttribute("data-oracle-split", split[1]);
      // The first `\algname{…}`, which `groupGames` reads; none at all is
      // not the same as an empty one.
      var name = /\\algname\{([^}]*)\}/.exec(source);
      if (name) box.setAttribute("data-algname", name[1].trim().toLowerCase());
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

  /** Groups a `\algname{Game}` block with the named, non-Game blocks that
   *  immediately follow it, so the game and its oracles sit side by side the
   *  way they do on the site. Decided as the site decides (quartz
   *  pseudocode.ts:209), by each block's first `\algname`, trimmed and in
   *  any case, never by its caption: a block with no `\algname` ends the
   *  group. */
  function groupGames(root) {
    var boxes = Array.prototype.slice.call(root.querySelectorAll(".pseudocode-container"));
    var i = 0;
    while (i < boxes.length) {
      if (algname(boxes[i]) !== "game") { i++; continue; }
      var followers = [];
      var j = i + 1;
      while (j < boxes.length && boxes[j].previousElementSibling === boxes[j - 1] &&
             algname(boxes[j]) !== null && algname(boxes[j]) !== "game") {
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

  /** A block's `\algname`, as `renderPseudocode` noted it, or null. */
  function algname(box) {
    return box.hasAttribute("data-algname") ? box.getAttribute("data-algname") : null;
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

  /** The line of relation fields Swift splices under a reduction or barrier
   *  H1 (RelationMeta.swift) ends in a marker comment, as on the site: the
   *  comment goes, and its paragraph takes the `relation-meta` class. */
  function markRelationMeta(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    var markers = [];
    while (walker.nextNode()) {
      if (walker.currentNode.data.trim() === "relation-meta") markers.push(walker.currentNode);
    }
    markers.forEach(function (marker) {
      var paragraph = marker.parentNode;
      if (!paragraph || paragraph.tagName !== "P" || paragraph.lastChild !== marker) return;
      var before = marker.previousSibling;
      paragraph.removeChild(marker);
      if (before && before.nodeType === Node.TEXT_NODE) before.data = before.data.replace(/\s+$/, "");
      paragraph.classList.add("relation-meta");
    });
  }

  // ================================================================= API ===

  var currentMacros = null;
  var currentMacrosKey = null;
  var md = null;
  var previewMarkdown = null;

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
   * With no table, the current one stays: a caller that only wants an
   * instance must never empty the table pseudocode and copying read.
   */
  function ensureMarkdown(macros) {
    if (macros === undefined || macros === null) {
      macros = currentMacros || {};
    }
    var key = macrosKey(macros);
    if (md && key === currentMacrosKey) return md;
    currentMacros = macros;
    currentMacrosKey = key;
    // Formulas rendered with another table are of no use, and none is kept
    // while a macro could reach what one formula leaves for the next, or
    // is one KaTeX changes: it deletes `\color` and `\current@color` from
    // the table after every formula, and every name of its own has an `@`.
    katexMemo.clear();
    katexMemoOn = !Object.keys(macros).some(function (name) {
      return name === "\\color" || name.indexOf("@") >= 0 || sharesMacroState(String(macros[name]));
    });
    installKatexMacros();
    md = markdownLibrary.create(macros);
    previewMarkdown = markdownLibrary.createPreview(macros);
    return md;
  }

  /**
   * Render one page. Called by Swift via evaluateJavaScript.
   *
   * payload = {
   *   markdown : string,           body with frontmatter already stripped
   *   links    : { "[[raw]]": {href, kind, external} }, plus a markdown
   *                link's destination ("slug#anchor") for each of those
   *   macros   : { "\\calA": "\\mathcal{A}" },   KaTeX macros, current as of
   *                                this render
   *   html     : string            (optional) pre-built HTML, used for
   *                                synthetic folder pages
   *   previews : { href: {kind, title, meta, note, excerpt, label} }
   *                                (optional) a card per internal link
   *                                target, keyed by the href the link carries
   *   revision : string            (optional) the commit the page was read
   *                                from, returned with a selection
   * }
   */
  // Where each page was left, so Back and Forward return to the same place,
  // as in a browser. Lives as long as this document does: a relaunch starts
  // every page at the top again.
  var scrollPositions = {};
  var shownPath = null;
  // What a selection reports with its lines (corrections §3.3): the commit
  // the page was read from, and its headings' plain text by id, math as
  // its source, as the outline has them.
  var shownRevision = null;
  var shownHeadings = {};

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
    shownRevision = payload.revision || null;
    shownHeadings = {};
    shownReview = null;
    lastReportedHeading = undefined;
    dismissPreview();
    previews = payload.previews || {};
    renderedPreviews = {};

    try {
      var markdown = ensureMarkdown(payload.macros);
      var prefix = noticeHTML(payload.notices);
      if (payload.html !== undefined && payload.html !== null) {
        page.innerHTML = prefix + payload.html;
      } else {
        page.innerHTML = prefix + markdown.render(payload.markdown || "", env);
        toc = env.toc || [];
        toc.forEach(function (heading) { shownHeadings[heading.id] = heading; });
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
    markRelationMeta(page);

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
      // The page this is about, for the render log: another render may
      // have been asked for since.
      path: payload.path,
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

  /** What `range` holds, as a detached box: a clone widened to whole
   *  formulas, since half a formula has no LaTeX, and moving the real
   *  selection would show. */
  function selectionScratch(range) {
    var widened = range.cloneRange();
    var start = mathHost(widened.startContainer);
    if (start) widened.setStartBefore(start);
    var end = mathHost(widened.endContainer);
    if (end) widened.setEndAfter(end);

    var scratch = document.createElement("div");
    scratch.className = "copy-scratch";
    scratch.setAttribute("aria-hidden", "true");
    scratch.appendChild(widened.cloneContents());
    return scratch;
  }

  /** The box as text is read from it: without the copy buttons, which are
   *  not page text (their labels are generated content, but the buttons
   *  themselves, whatever WebKit makes of their user-select: none, could
   *  still reach copied HTML), with each formula as its LaTeX, and one line
   *  per algorithm line: to innerText a <p> is a paragraph, with a blank
   *  line after it. */
  function prepareScratch(scratch) {
    scratch.querySelectorAll(".copy-row").forEach(function (row) { row.remove(); });
    texify(scratch);
    scratch.querySelectorAll("p.ps-line").forEach(function (line) {
      var div = document.createElement("div");
      div.className = line.className;
      while (line.firstChild) div.appendChild(line.firstChild);
      line.replaceWith(div);
    });
  }

  /** The box's text as the reader sees it. Attached while it is read,
   *  because only a laid-out box has an innerText with the paragraph and
   *  line breaks the reader sees; textContent runs them together. */
  function scratchText(scratch) {
    document.body.appendChild(scratch);
    var text = scratch.innerText || scratch.textContent;
    scratch.remove();
    return text;
  }

  /** The selection as the reader shows it, each formula written as `$…$`
   *  or `$$…$$`: what ⌘C copies when there is math, and what a correction
   *  quotes, so copying and quoting cannot drift apart (corrections §3.3). */
  function selectionText(range) {
    var scratch = selectionScratch(range);
    prepareScratch(scratch);
    return scratchText(scratch);
  }

  // ⌘C, Edit › Copy and the menu's own Copy all reach here. A selection with
  // math in it is copied with each formula as its LaTeX, as plain text and
  // as HTML, so Notes and Mail paste the LaTeX too. Anything else is left to
  // WebKit; a selection across the copy buttons is copied here, without
  // them.
  document.addEventListener("copy", function (event) {
    var selection = window.getSelection();
    if (!event.clipboardData || !selection || selection.isCollapsed || !selection.rangeCount) return;

    var scratch = selectionScratch(selection.getRangeAt(0));
    if (!scratch.querySelector("[data-tex], .katex, .copy-row")) return;
    prepareScratch(scratch);
    var text = scratchText(scratch);

    event.clipboardData.setData("text/plain", text);
    event.clipboardData.setData("text/html", scratch.innerHTML);
    event.preventDefault();
  }, true);

  // ========================================================== selection ==
  // A correction starts from the page, or from a passage on it, and carries
  // the passage's source lines, its section and its text (corrections §3).

  /** The nearest block under `node` that says where it came from, inside
   *  the page. */
  function stampedBlock(node) {
    var el = node && (node.nodeType === 1 ? node : node.parentElement);
    var block = el && el.closest ? el.closest("[" + SOURCE_LINES + "]") : null;
    var page = document.getElementById("page");
    return block && page && page.contains(block) ? block : null;
  }

  /** A block's lines, `{start, end}`, 0-based and half-open. */
  function blockLines(block) {
    var match = /^(\d+)-(\d+)$/.exec(block.getAttribute(SOURCE_LINES) || "");
    if (!match) return null;
    var lines = { start: Number(match[1]), end: Number(match[2]) };
    return lines.end > lines.start ? lines : null;
  }

  /** The section `node` is in: the last heading with an id at or before it
   *  in document order, `{id, text, level}`, its text as the outline has
   *  it. Null above the first. */
  function headingBefore(node) {
    var page = document.getElementById("page");
    if (!page || !node) return null;
    var headings = page.querySelectorAll("h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]");
    var found = null;
    for (var i = 0; i < headings.length; i++) {
      var heading = headings[i];
      var position = heading.compareDocumentPosition(node);
      if (heading !== node && !(position & Node.DOCUMENT_POSITION_FOLLOWING)) break;
      found = heading;
    }
    if (!found) return null;
    var known = shownHeadings[found.id];
    return {
      id: found.id,
      text: known ? known.text : (found.textContent || "").trim(),
      level: Number(found.tagName.slice(1)),
    };
  }

  /** The text nodes the range really selects some of, in order. A
   *  triple-click ends the range at the start of the next block, which
   *  selects none of it, so that block is not part of the passage. */
  function selectedTextNodes(range) {
    var root = range.commonAncestorContainer;
    if (root.nodeType === Node.TEXT_NODE) return [root];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var nodes = [];
    while (walker.nextNode()) {
      var node = walker.currentNode;
      if (!range.intersectsNode(node)) continue;
      var from = node === range.startContainer ? range.startOffset : 0;
      var to = node === range.endContainer ? range.endOffset : node.data.length;
      if (/\S/.test(node.data.slice(from, to))) nodes.push(node);
    }
    return nodes;
  }

  /** What `range` selects on the page, for a correction: the union of the
   *  lines of the blocks it starts and ends in, its text, its section, and
   *  the page and revision it was shown at. Null outside the page, or when
   *  neither end is in a block with lines: raw HTML, or a notice alone. */
  function passage(range) {
    var page = document.getElementById("page");
    if (!page || shownPath === null || !page.contains(range.commonAncestorContainer)) return null;
    var nodes = selectedTextNodes(range);
    var first = nodes.length ? nodes[0] : range.startContainer;
    var last = nodes.length ? nodes[nodes.length - 1] : range.endContainer;
    var startBlock = stampedBlock(first);
    var endBlock = stampedBlock(last);
    // A selection that starts in a notice has lines only at its end.
    var a = startBlock ? blockLines(startBlock) : null;
    var b = endBlock ? blockLines(endBlock) : null;
    if (!a && !b) return null;
    a = a || b;
    b = b || a;
    var text = selectionText(range).trim();
    if (!text) return null;
    return {
      start: Math.min(a.start, b.start),
      end: Math.max(a.end, b.end),
      text: text,
      heading: headingBefore(startBlock ? first : last),
      path: shownPath,
      revision: shownRevision,
    };
  }

  /** The block under the pointer at a right-click with nothing selected:
   *  its lines and section, and no text. A pointer, not a passage: the
   *  correction is about the whole page, opened at this block. */
  function pointer(target) {
    var block = stampedBlock(target);
    var lines = block ? blockLines(block) : null;
    if (!lines || shownPath === null) return null;
    return {
      start: lines.start,
      end: lines.end,
      text: null,
      heading: headingBefore(block),
      path: shownPath,
      revision: shownRevision,
    };
  }

  /** The live selection, for the menu bar's and the toolbar's correction
   *  commands, as a JSON string: Swift's `ReaderSelection(json:)` reads it.
   *  The string "null" when nothing on the page is selected, never
   *  undefined, which `evaluateJavaScript` cannot return. */
  function selectionSource() {
    var selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return "null";
    var found = null;
    try { found = passage(selection.getRangeAt(0)); } catch (e) { found = null; }
    return JSON.stringify(found);
  }

  // A right-click must not invent a selection. On a secondary click, WebKit
  // selects the word under the pointer before it dispatches `contextmenu`,
  // which is what makes Look Up "word" appear, so read there, nearly every
  // right-click would report a one-word passage. This listener reads the
  // selection as it was, as the button goes down: a passage only if there
  // is one and the pointer is on it. It is a listener of its own: it returns
  // at once for any other button, and never calls preventDefault.
  var rightClickPassage;      // undefined: no right-click since the last menu

  document.addEventListener("mousedown", function (event) {
    if (event.button !== 2 && !event.ctrlKey) return;
    rightClickPassage = null;
    var selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;
    var range = selection.getRangeAt(0);
    var rects = range.getClientRects();
    for (var i = 0; i < rects.length; i++) {
      var rect = rects[i];
      if (event.clientX >= rect.left && event.clientX <= rect.right &&
          event.clientY >= rect.top && event.clientY <= rect.bottom) {
        try { rightClickPassage = passage(range); } catch (e) { rightClickPassage = null; }
        return;
      }
    }
  }, true);

  // Before WebKit builds the context menu, tell Swift what is under the
  // pointer: a formula's LaTeX, and an algorithm's, as written and with the
  // macros written out; the link, for the menu's Open Link in New Tab, in
  // New Window and on cryptology.city, and a web or mail link's, for its
  // Open Link; and the selection, for the corrections group: the passage
  // the right-click was on, or else the block under the pointer, with no
  // text. The message is sent on the same connection as, and ahead of, the
  // menu request, so it arrives first.
  document.addEventListener("contextmenu", function (event) {
    var target = event.target;
    var host = mathHost(target);
    var box = target && target.closest ? target.closest(".pseudocode-container") : null;
    var source = box ? box.getAttribute("data-source") : null;
    var selection = rightClickPassage || null;
    rightClickPassage = undefined;
    if (!selection) {
      try { selection = pointer(target); } catch (e) { selection = null; }
    }
    post({
      type: "contextTarget",
      tex: host ? texOf(host) : null,
      algorithm: source,
      algorithmExpanded: source === null ? null : expandMacros(source, currentMacros || {}),
      link: appLink(linkAt(target)),
      externalLink: webLink(linkAt(target)),
      selection: selection,
    });
  }, true);

  // ===================================================== source reveal ==
  // The editor's preview follows the line being edited (corrections §7.4).

  var revealTimer = null;

  /** Scrolls the first block that overlaps rendered lines `[start, end)` to
   *  the middle of the window: the innermost, so a list item rather than
   *  its list. With `mark`, outlines the blocks briefly. */
  function revealSourceLines(start, end, mark) {
    var page = document.getElementById("page");
    if (!page) return false;
    end = Math.max(end, start + 1);
    var overlapping = Array.prototype.filter.call(
      page.querySelectorAll("[" + SOURCE_LINES + "]"), function (block) {
        var lines = blockLines(block);
        return lines && lines.start < end && start < lines.end;
      });
    if (!overlapping.length) return false;
    var first = overlapping[0];
    for (var i = 1; i < overlapping.length && first.contains(overlapping[i]); i++) {
      first = overlapping[i];
    }
    first.scrollIntoView({ block: "center", behavior: "auto" });
    if (mark) {
      clearTimeout(revealTimer);
      page.querySelectorAll(".source-reveal").forEach(function (block) {
        block.classList.remove("source-reveal");
      });
      // The innermost blocks only: outlining a list and its item both
      // draws two boxes around one line.
      var marked = overlapping.filter(function (block) {
        return !overlapping.some(function (other) {
          return other !== block && block.contains(other);
        });
      });
      marked.forEach(function (block) { block.classList.add("source-reveal"); });
      revealTimer = setTimeout(function () {
        marked.forEach(function (block) { block.classList.remove("source-reveal"); });
      }, 1200);
    }
    return true;
  }

  /** The link `node` is in, if any. */
  function linkAt(node) {
    return node && node.closest ? node.closest("a") : null;
  }

  /** The href of a link the app follows itself, to a page, a folder or a
   *  file of the wiki. Null for no link, a dead one, one to the web, or a
   *  place on this page. Swift decides which of these a tab can show. */
  function appLink(anchor) {
    if (!anchor || anchor.classList.contains("broken")) return null;
    var href = anchor.getAttribute("href") || "";
    if (!href || href.charAt(0) === "#" || /^https?:|^mailto:/.test(href)) return null;
    return href;
  }

  /** The href of a link to the web or to mail, for the menu's Open Link,
   *  which the app opens itself. Null for no link, a dead one, or any
   *  other. */
  function webLink(anchor) {
    if (!anchor || anchor.classList.contains("broken")) return null;
    var href = anchor.getAttribute("href") || "";
    return /^https?:|^mailto:/.test(href) ? href : null;
  }

  /** Follows a link off the page: the web in the browser, anything else in
   *  the app, with the keys held and whether it was the middle button.
   *  Where it opens is Swift's call (LinkDisposition.forClick), made as
   *  Safari makes it. */
  function follow(href, event, middleButton) {
    if (/^https?:|^mailto:/.test(href)) {
      post({ type: "openExternal", url: href });
      return;
    }
    post({
      type: "navigate",
      href: href,
      command: event.metaKey,
      shift: event.shiftKey,
      option: event.altKey,
      middleButton: middleButton,
    });
  }

  // Internal links are navigations for the *app*, not the web view: the Swift
  // side owns history, the sidebar selection, the inspector, and the tab or
  // window a link opens in.
  //
  // Only the primary button follows a link here. WebKit may also give a
  // middle click a `click`, or an `auxclick`, so both are listened for and
  // only stopped: the middle button is the `mouseup` listener's, below, and
  // a link opens once, never in the web view itself.
  function onLinkClick(event) {
    var anchor = linkAt(event.target);
    if (!anchor) return;

    if (anchor.classList.contains("broken")) { event.preventDefault(); return; }

    var href = anchor.getAttribute("href") || "";
    if (!href) return;

    event.preventDefault();
    if (event.button !== 0) return;
    if (href.charAt(0) === "#") {
      scrollToAnchor(href.slice(1));
      return;
    }
    follow(href, event, false);
  }
  document.addEventListener("click", onLinkClick, true);
  document.addEventListener("auxclick", onLinkClick, true);

  // The middle button opens a link in a tab behind this one, as in Safari.
  // WebKit may not dispatch `auxclick`, so the press and the release are read
  // instead: a release on the link that was pressed is a middle click. These
  // two listeners are their own, apart from every other `mousedown` (the
  // preview card's, or one for the right button): they return at once for
  // any other button and never call preventDefault. A place on this page is
  // a scroll, not a page to open, so a middle click leaves it alone.
  var middlePressedLink = null;

  document.addEventListener("mousedown", function (event) {
    if (event.button !== 1) return;
    middlePressedLink = linkAt(event.target);
  }, true);

  document.addEventListener("mouseup", function (event) {
    if (event.button !== 1) return;
    var pressed = middlePressedLink;
    middlePressedLink = null;
    if (!pressed || linkAt(event.target) !== pressed) return;
    if (pressed.classList.contains("broken")) return;
    var href = pressed.getAttribute("href") || "";
    if (!href || href.charAt(0) === "#") return;
    follow(href, event, true);
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

  // ======================================================= link previews ==
  // A summary card for an internal link once the pointer has rested on it
  // (relations-explorer.md §4). Swift computes every card with the page and
  // sends them as `payload.previews`, keyed by the href each link carries;
  // this file only lays a card out. JS never asks Swift for anything, and a
  // link with no entry (external, asset, folder, same page) gets no card.

  // Between the site's 200 ms and a macOS tooltip's second or so: long enough
  // that a pointer crossing a dense paragraph does not flash cards.
  var PREVIEW_DELAY = 450;
  // A card asked for this soon after the last one closed opens at once, so
  // reading along a row of links does not wait each time.
  var PREVIEW_WARM = 400;
  // A link that wraps onto a second line fires `mouseout` between its line
  // boxes; the close waits long enough for the `mouseover` that follows.
  var PREVIEW_CLOSE_DELAY = 100;
  var PREVIEW_GAP = 8;
  var PREVIEW_INSET = 12;
  // RelationMeta.separator: a no-break space keeps the dot with the part
  // before it, so a wrapped line never starts with one.
  var PREVIEW_SEPARATOR = "\u00A0\u00B7 ";

  var previews = {};
  var renderedPreviews = {};
  var previewCard = null;
  var previewAnchor = null;     // the link whose card is showing
  var pendingAnchor = null;     // the link waiting out the delay
  var previewOpenTimer = null;
  var previewCloseTimer = null;
  var lastPreviewClosed = 0;
  var lastPointerY = null;
  // The test hook scrolls its link into view; that scroll must not close
  // the card it is about to open.
  var ignoreScrollUntil = 0;

  function hasPreview(href) {
    return Object.prototype.hasOwnProperty.call(previews, href);
  }

  /** The internal link `node` is part of, when it has a card. */
  function previewLink(node) {
    var el = node && (node.nodeType === 1 ? node : node.parentElement);
    var anchor = el && el.closest ? el.closest("a.internal") : null;
    return anchor && hasPreview(anchor.getAttribute("href") || "") ? anchor : null;
  }

  /** One card element for the document, outside `#page`: a selection in the
   *  page never includes it, `render` never replaces it, and with
   *  `pointer-events: none` it never takes a click. Hidden means `hidden`,
   *  never a zero opacity, so find in page cannot match a card's text. */
  function ensurePreviewCard() {
    if (previewCard) return previewCard;
    var card = document.createElement("div");
    card.className = "link-preview";
    card.id = "ccwiki-link-preview";
    card.setAttribute("role", "tooltip");
    card.hidden = true;
    // The note is R8's qualifier, which goes beside the title it qualifies
    // (derivations.md §7), so it comes before a meta line that may wrap.
    ["kind", "title", "note", "meta", "excerpt"].forEach(function (part) {
      var el = document.createElement("div");
      el.className = "link-preview-" + part;
      card.appendChild(el);
    });
    document.body.appendChild(card);
    previewCard = card;
    return card;
  }

  /** A card's parts as HTML, rendered once per page. Every word is Swift's;
   *  the kind and the note are plain text, the rest inline markdown. */
  function renderedPreview(href) {
    if (Object.prototype.hasOwnProperty.call(renderedPreviews, href)) {
      return renderedPreviews[href];
    }
    if (!previewMarkdown) ensureMarkdown();
    var data = previews[href] || {};
    function inline(text) {
      if (!text) return "";
      try {
        return previewMarkdown.renderInline(String(text));
      } catch (e) {
        return previewMarkdown.utils.escapeHtml(String(text));
      }
    }
    var rendered = {
      kind: data.kind || "",
      title: inline(data.title),
      meta: (data.meta || []).map(inline).filter(Boolean).join(PREVIEW_SEPARATOR),
      note: data.note || "",
      excerpt: inline(data.excerpt),
      label: data.label || "",
    };
    renderedPreviews[href] = rendered;
    return rendered;
  }

  function setPreviewPart(card, part, content, isHTML) {
    var el = card.querySelector(".link-preview-" + part);
    if (isHTML) el.innerHTML = content; else el.textContent = content;
    el.hidden = !content;
  }

  /** Show `anchor`'s card under the line box the pointer is on, or under the
   *  link's first line box when it came by keyboard. */
  function showPreview(anchor, pointerY) {
    var href = anchor.getAttribute("href") || "";
    if (!hasPreview(href)) return false;
    clearTimeout(previewOpenTimer);
    clearTimeout(previewCloseTimer);
    previewOpenTimer = previewCloseTimer = null;
    pendingAnchor = null;

    var card = ensurePreviewCard();
    var data = renderedPreview(href);
    setPreviewPart(card, "kind", data.kind, false);
    setPreviewPart(card, "title", data.title, true);
    setPreviewPart(card, "note", data.note, false);
    setPreviewPart(card, "meta", data.meta, true);
    setPreviewPart(card, "excerpt", data.excerpt, true);
    // KaTeX's HTML is not readable by VoiceOver, so the card is described by
    // Swift's plain-text label, and the link points at the card.
    card.setAttribute("aria-label", data.label);
    if (previewAnchor && previewAnchor !== anchor) previewAnchor.removeAttribute("aria-describedby");
    previewAnchor = anchor;
    anchor.setAttribute("aria-describedby", card.id);

    card.hidden = false;
    positionPreview(card, anchor, pointerY);
    return true;
  }

  /** Under the line box the pointer is on (the first, by keyboard), lined up
   *  with its start, as floating-ui's `inline` middleware places the site's
   *  popover; but 8 px clear of the whole link, so a link that wraps onto
   *  the next line is not covered. Above the link when it would cross the
   *  bottom of the window; 12 px inside the left and right edges. When
   *  neither side has room it takes the larger and shortens, so it never
   *  covers the link it describes. */
  function positionPreview(card, anchor, pointerY) {
    var rects = anchor.getClientRects();
    if (!rects.length) { hidePreview(); return; }
    var rect = rects[0];
    if (pointerY !== null && pointerY !== undefined) {
      for (var i = 0; i < rects.length; i++) {
        if (pointerY >= rects[i].top && pointerY <= rects[i].bottom) { rect = rects[i]; break; }
      }
    }
    var link = anchor.getBoundingClientRect();
    var viewWidth = document.documentElement.clientWidth;
    var viewHeight = document.documentElement.clientHeight;

    card.style.maxHeight = "";
    card.style.left = "0px";
    card.style.top = "0px";
    var width = card.offsetWidth;
    var height = card.offsetHeight;
    var below = viewHeight - link.bottom - PREVIEW_GAP - PREVIEW_INSET;
    var above = link.top - PREVIEW_GAP - PREVIEW_INSET;

    var top;
    if (height <= below || below >= above) {
      if (height > below) card.style.maxHeight = Math.max(below, 0) + "px";
      top = link.bottom + PREVIEW_GAP;
    } else {
      if (height > above) card.style.maxHeight = Math.max(above, 0) + "px";
      top = link.top - PREVIEW_GAP - card.offsetHeight;
    }
    var left = Math.max(PREVIEW_INSET, Math.min(rect.left, viewWidth - PREVIEW_INSET - width));
    card.style.left = left + "px";
    card.style.top = top + "px";
    // The fade at the bottom is for a card cut short, which the caps in
    // Swift make rare.
    card.classList.toggle("is-clipped", card.scrollHeight > card.clientHeight + 1);
  }

  function hidePreview() {
    clearTimeout(previewOpenTimer);
    clearTimeout(previewCloseTimer);
    previewOpenTimer = previewCloseTimer = null;
    pendingAnchor = null;
    if (!previewCard || previewCard.hidden) return;
    previewCard.hidden = true;
    previewCard.style.maxHeight = "";
    if (previewAnchor) previewAnchor.removeAttribute("aria-describedby");
    previewAnchor = null;
    lastPreviewClosed = Date.now();
  }

  /** Close at once and forget the last card, so the next one waits out the
   *  delay: what follows a scroll, a click or Escape is not reading along a
   *  row of links. Without this, links passing under a still pointer while
   *  the page scrolls would each flash a card. */
  function dismissPreview() {
    hidePreview();
    lastPreviewClosed = 0;
  }

  function schedulePreview(anchor, pointerY) {
    clearTimeout(previewCloseTimer);
    previewCloseTimer = null;
    // Back on the link showing, from another of its line boxes; or still
    // waiting on this one.
    if (anchor === previewAnchor || anchor === pendingAnchor) return;
    clearTimeout(previewOpenTimer);
    var warm = (previewCard && !previewCard.hidden) ||
      Date.now() - lastPreviewClosed < PREVIEW_WARM;
    if (warm) {
      showPreview(anchor, pointerY);
      return;
    }
    pendingAnchor = anchor;
    previewOpenTimer = setTimeout(function () {
      previewOpenTimer = null;
      pendingAnchor = null;
      if (anchor.isConnected) showPreview(anchor, pointerY === null ? null : lastPointerY);
    }, PREVIEW_DELAY);
  }

  function scheduleClose() {
    clearTimeout(previewOpenTimer);
    previewOpenTimer = null;
    pendingAnchor = null;
    clearTimeout(previewCloseTimer);
    previewCloseTimer = setTimeout(hidePreview, PREVIEW_CLOSE_DELAY);
  }

  document.addEventListener("mouseover", function (event) {
    lastPointerY = event.clientY;
    var anchor = previewLink(event.target);
    if (!anchor) return;
    // A selection drag passes over links; no card while a button is down.
    if (event.buttons) return;
    schedulePreview(anchor, event.clientY);
  });

  document.addEventListener("mousemove", function (event) {
    lastPointerY = event.clientY;
  }, { passive: true });

  document.addEventListener("mouseout", function (event) {
    var anchor = previewLink(event.target);
    if (!anchor) return;
    if (event.relatedTarget && anchor.contains(event.relatedTarget)) return;
    scheduleClose();
  });

  // Keyboard focus opens a card as hover does, once WebKit Tab-focuses
  // links at all (Safari's "Press Tab to highlight each item", or Keyboard
  // Navigation). A click that focuses a link is not keyboard focus.
  document.addEventListener("focusin", function (event) {
    var anchor = previewLink(event.target);
    if (!anchor) return;
    var byKeyboard = true;
    try { byKeyboard = anchor.matches(":focus-visible"); } catch (e) { /* older WebKit */ }
    if (byKeyboard) schedulePreview(anchor, null);
  });

  document.addEventListener("focusout", function (event) {
    if (previewLink(event.target)) hidePreview();
  });

  // Anything that means the reader has moved on closes the card at once.
  document.addEventListener("mousedown", dismissPreview, true);
  document.addEventListener("contextmenu", dismissPreview, true);
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") dismissPreview();
  }, true);
  document.addEventListener("scroll", function () {
    if (Date.now() >= ignoreScrollUntil) dismissPreview();
  }, { passive: true, capture: true });
  window.addEventListener("blur", dismissPreview);
  window.addEventListener("beforeprint", dismissPreview);
  // The card is placed once, when it opens. Resizing the window, or the
  // inspector or sidebar opening beside the page, reflows the text under it,
  // and a card left where it was could cover its link or point at the wrong
  // line.
  window.addEventListener("resize", dismissPreview);

  /** For the visual gate (`make shots`): open the card on the first link in
   *  the page whose href is `href`, scrolling it into view if it is not.
   *  True when a card opened. */
  function showPreviewFor(href) {
    var links = document.querySelectorAll("#page a.internal");
    for (var i = 0; i < links.length; i++) {
      if (links[i].getAttribute("href") !== href) continue;
      dismissPreview();
      var rect = links[i].getBoundingClientRect();
      if (rect.top < 0 || rect.bottom > document.documentElement.clientHeight) {
        ignoreScrollUntil = Date.now() + 250;
        links[i].scrollIntoView({ block: "center", behavior: "auto" });
      }
      return showPreview(links[i], null);
    }
    return false;
  }

  // =============================================================== review ==
  // A change shown the way the reader renders pages: the blocks it changed,
  // and nothing else (corrections §6.3). The blocks are
  // `CCwikiMarkdown.reviewEntries`'s; this lays them out, one section per
  // file, each entry a `div.review-entry.<kind>`.
  //
  // payload = {
  //   macros : { "\\calA": "\\mathcal{A}" },
  //   files  : [{ id, path, title, status, summary, isMarkdown, header,
  //               frontmatter: [{kind, text}], old, new,
  //               bodyLine: {old, new}, hunks: [{old: [a, b], new: [c, d]}],
  //               flags: [{lines: [a, b], severity, text}], links }]
  // }
  //
  // Hunk and flag lines are 0-based and half-open, in the body; `bodyLine`
  // is the file line, 1-based, of each side's body line 0.

  /** The paths of the review on screen, so a review of the same files,
   *  shown again after a save, keeps the reader's place. */
  var shownReview = null;

  var REVIEW_STATUS = {
    added: "New file",
    deleted: "Deleted",
    renamed: "Renamed",
    modified: "Modified",
  };
  // Text presentation, so each takes its severity's colour.
  var FLAG_GLYPH = { blocking: "⛔︎", warning: "⚠︎", note: "ⓘ" };
  var FLAG_LABEL = { blocking: "Blocks the pull request", warning: "Warning", note: "Note" };

  function renderReview(payload) {
    var started = Date.now();
    var page = document.getElementById("page");
    payload = payload || {};
    var files = payload.files || [];
    var key = files.map(function (file) { return file.path; }).join("\n");
    var keepY = shownReview === key ? window.scrollY : null;
    if (shownPath !== null) scrollPositions[shownPath] = window.scrollY;
    // Not a page: nothing here is a passage to correct.
    shownPath = null;
    shownRevision = null;
    shownHeadings = {};
    shownReview = key;
    lastReportedHeading = undefined;
    dismissPreview();
    previews = {};
    renderedPreviews = {};

    try {
      var markdown = ensureMarkdown(payload.macros);
      page.innerHTML = files.length
        ? files.map(function (file) { return reviewFileHTML(markdown, file); }).join("")
        : '<p class="review-empty">No changes.</p>';
    } catch (e) {
      var message = String(e && e.message ? e.message : e);
      page.innerHTML = '<div class="notice notice-warning">The review could not be shown: ' +
        escapeText(message) + "</div>";
      post({ type: "rendered", ok: false, error: message, toc: [] });
      return;
    }

    var pseudo = { count: 0, errors: 0 };
    if (global.pseudocode) {
      pseudo = renderPseudocode(page);
      groupGames(page);
    }
    markRelationMeta(page);
    window.scrollTo(0, keepY !== null ? keepY : 0);
    post({
      type: "rendered",
      ok: true,
      toc: [],
      pseudocodeBlocks: pseudo.count,
      pseudocodeErrors: pseudo.errors,
      ms: Date.now() - started,
    });
  }

  function escapeText(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /** Inline markdown and math, never HTML: a title, a flag's message. */
  function inlineText(text) {
    if (!text) return "";
    try {
      return previewMarkdown.renderInline(String(text));
    } catch (e) {
      return escapeText(text);
    }
  }

  function reviewFileHTML(markdown, file) {
    var flags = file.flags || [];
    var bodyLine = file.bodyLine || {};
    var out = ['<section class="review-file" data-file-id="' + escapeText(file.id || "") +
      '" data-path="' + escapeText(file.path || "") + '"' +
      (typeof bodyLine.new === "number" ? ' data-body-line="' + bodyLine.new + '"' : "") + ">"];

    // relations.json and anything else that is not a page: one line, and
    // its lines in Source.
    if (file.isMarkdown === false) {
      out.push('<div class="review-nonmarkdown"><code>' + escapeText(file.path || "") + "</code>" +
        separator() + escapeText(file.summary || "") + separator() + "Shown in Source</div>");
      out.push(flags.map(flagHTML).join(""));
      out.push("</section>");
      return out.join("");
    }

    out.push('<header class="review-file-header">');
    out.push('<div class="review-file-title">' + inlineText(file.title || file.path || "") + "</div>");
    out.push('<div class="review-file-meta"><code>' + escapeText(file.path || "") + "</code>" +
      separator() + escapeText(REVIEW_STATUS[file.status] || REVIEW_STATUS.modified) +
      (file.summary ? separator() + escapeText(file.summary) : "") + "</div>");
    // A reduction's or barrier's endpoints, each a link to its page.
    if (file.header) {
      out.push('<div class="review-endpoints">' +
        markdown.renderInline(file.header, { links: file.links || {} }) + "</div>");
    }
    out.push("</header>");

    var entries = markdownLibrary.reviewEntries(markdown, file);
    var attached = [];
    entries.forEach(function (entry) { attached = attached.concat(entry.flags); });
    // A flag on no entry (one on the frontmatter, or on the file as a
    // whole) heads the file.
    out.push(flags.filter(function (flag) { return attached.indexOf(flag) < 0; })
      .map(flagHTML).join(""));
    out.push(frontmatterHTML(file.frontmatter || []));
    out.push(entries.map(entryHTML).join(""));
    out.push("</section>");
    return out.join("");
  }

  function separator() {
    return '<span class="review-separator" aria-hidden="true"> · </span>';
  }

  /** The frontmatter is YAML, not Markdown: its changed lines as source,
   *  with a line of context, in a box at the top of the file. A gap, a run
   *  of unchanged lines left out, is a caption, not a line of the file. */
  function frontmatterHTML(lines) {
    var rows = markdownLibrary.reviewFrontmatter(lines);
    if (!rows.length) return "";
    return '<div class="review-frontmatter">' + rows.map(function (row) {
      if (row.kind === "gap") {
        return '<div class="review-frontmatter-line gap">' + escapeText(row.text) + "</div>";
      }
      var role = row.kind === "added" ? ' role="insertion" aria-label="Added"'
        : row.kind === "removed" ? ' role="deletion" aria-label="Removed"' : "";
      return '<div class="review-frontmatter-line ' + row.kind + '"' + role + ">" +
        '<span class="review-frontmatter-sign" aria-hidden="true">' + row.sign + "</span>" +
        escapeText(row.text) + "</div>";
    }).join("") + "</div>";
  }

  function flagHTML(flag) {
    var severity = FLAG_GLYPH[flag.severity] ? flag.severity : "note";
    return '<div class="review-flag ' + severity + '">' +
      '<span class="review-flag-glyph" role="img" aria-label="' + FLAG_LABEL[severity] + '">' +
      FLAG_GLYPH[severity] + "</span>" + inlineText(flag.text || "") + "</div>";
  }

  /** One entry, with the flags on its lines as captions above it. Added and
   *  removed entries say so in their gutter label (app.css), so they differ
   *  by more than colour, and to VoiceOver by their role. */
  function entryHTML(entry) {
    var attributes = ' class="review-entry ' + entry.kind + '" data-entry-id="' +
      escapeText(entry.id) + '" data-side="' + entry.side + '"';
    if (entry.fileLines) {
      attributes += ' data-file-lines="' + entry.fileLines[0] + "-" + entry.fileLines[1] + '"';
    }
    if (entry.kind === "added") attributes += ' role="insertion" aria-label="Added"';
    if (entry.kind === "removed") attributes += ' role="deletion" aria-label="Removed"';
    var flags = entry.flags.map(flagHTML).join("");
    if (entry.kind === "gap") {
      return flags + "<div" + attributes + ">" + escapeText(entry.text || "") + "</div>";
    }
    return flags + "<div" + attributes + '><div class="review-entry-body">' + entry.html + "</div>" +
      (entry.note ? '<div class="review-note">' + escapeText(entry.note) + "</div>" : "") +
      "</div>";
  }

  /** Scrolls the review to `id` and outlines it briefly. `id` is an
   *  entry's `data-entry-id`; a file's id or path; or `<rule>:<path>:<line>`,
   *  a DiffGuard finding's id, whose 1-based line (in the new text; the old
   *  for a deleted file) finds the entry that holds it, the frontmatter
   *  when it is above the body, and the file when it is 0. */
  function scrollToReviewEntry(id) {
    var page = document.getElementById("page");
    if (!page || id === undefined || id === null) return false;
    var target = reviewTarget(page, String(id));
    if (!target) return false;
    target.scrollIntoView({ block: "center", behavior: "auto" });
    clearTimeout(revealTimer);
    page.querySelectorAll(".source-reveal").forEach(function (el) {
      el.classList.remove("source-reveal");
    });
    target.classList.add("source-reveal");
    revealTimer = setTimeout(function () { target.classList.remove("source-reveal"); }, 1200);
    return true;
  }

  function reviewTarget(page, id) {
    var entries = page.querySelectorAll(".review-entry");
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].getAttribute("data-entry-id") === id) return entries[i];
    }
    var sections = page.querySelectorAll("section.review-file");
    for (var j = 0; j < sections.length; j++) {
      if (sections[j].getAttribute("data-file-id") === id ||
          sections[j].getAttribute("data-path") === id) return sections[j];
    }
    var match = /^(.*):(\d+)$/.exec(id);
    if (!match) return null;
    var rest = match[1];
    var line = Number(match[2]);
    for (var k = 0; k < sections.length; k++) {
      var path = sections[k].getAttribute("data-path") || "";
      var fileID = sections[k].getAttribute("data-file-id") || "";
      if (rest === path || rest === fileID ||
          (path && rest.slice(-(path.length + 1)) === ":" + path)) {
        return line > 0 ? (entryAtLine(sections[k], line) || sections[k]) : sections[k];
      }
    }
    return null;
  }

  /** The entry holding file line `line` on the side a finding's lines are
   *  on, else the nearest; the frontmatter above the body. */
  function entryAtLine(section, line) {
    var bodyLine = Number(section.getAttribute("data-body-line"));
    if (bodyLine && line < bodyLine) {
      return section.querySelector(".review-frontmatter");
    }
    var entries = Array.prototype.slice.call(section.querySelectorAll(".review-entry"));
    var newSide = entries.filter(function (el) { return el.getAttribute("data-side") === "new"; });
    var candidates = newSide.length ? newSide : entries;
    var nearest = null, distance = Infinity;
    for (var i = 0; i < candidates.length; i++) {
      var match = /^(\d+)-(\d+)$/.exec(candidates[i].getAttribute("data-file-lines") || "");
      if (!match) continue;
      var first = Number(match[1]), last = Number(match[2]);
      if (line >= first && line <= last) return candidates[i];
      var gap = line < first ? first - line : line - last;
      if (gap < distance) { distance = gap; nearest = candidates[i]; }
    }
    return nearest;
  }

  global.CCwiki = {
    render: render,
    scrollToAnchor: scrollToAnchor,
    currentHeading: currentHeading,
    // The Markdown half's, under the names they have always had here: for
    // a test harness, and the visual gate. Guarded, so a shell missing that
    // file still says "ready", and each render says what failed.
    createMarkdown: markdownLibrary && markdownLibrary.create,
    createPreviewMarkdown: markdownLibrary && markdownLibrary.createPreview,
    showPreview: showPreviewFor,
    hidePreview: dismissPreview,
    // Corrections (plans/corrections.md §3.3, §6.3).
    selectionSource: selectionSource,
    revealSourceLines: revealSourceLines,
    renderReview: renderReview,
    scrollToReviewEntry: scrollToReviewEntry,
  };

  post({ type: "ready" });
})(window);
