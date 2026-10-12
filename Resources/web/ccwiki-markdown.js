/* CCwiki's Markdown: markdown-it with the site's math, wikilinks, heading
 * ids and callouts, the source line of every block, and the blocks of a
 * change for the review.
 *
 * This half of the renderer touches no DOM. JavaScriptCore loads it without a
 * web view, so what it stamps and what the review shows are unit-tested in
 * Swift (SourceStampTests, ReviewEntriesTests). Everything that touches the
 * document is in `ccwiki.js`, which loads after this file and calls
 * `CCwikiMarkdown.create`.
 *
 * Load order: markdown-it, its footnote and mark plugins, and GithubSlugger
 * first; this file; then `ccwiki.js`. KaTeX is read when a formula renders,
 * not when this file loads.
 *
 * Everything mirrors the site's own pipeline (quartz.config.ts): remark-math's
 * delimiter semantics, remark-gfm, smartypants, rehype-slug heading ids.
 */
(function (global) {
  "use strict";

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

    // `line` ends on the closing fence, or on the first line after a block
    // that has none: the end of its container, or of the text. An unclosed
    // block runs to there, as micromark's does, and consumes every line it
    // shows. (It used to leave its last line to be parsed again, and, as
    // the last line of a page, to throw "block rule didn't increment
    // state.line": typing `$$` at the end of a page in the editor blanked
    // the preview.)
    var line = startLine + 1, haveEnd = false;
    for (; line < endLine; line++) {
      var p = state.bMarks[line] + state.tShift[line];
      var m = state.eMarks[line];
      if (p < m && state.sCount[line] < state.blkIndent) break;
      if (state.src.charCodeAt(p) !== 0x24) continue;
      if (state.sCount[line] - state.blkIndent >= 4) continue;
      var q = p;
      while (q < m && state.src.charCodeAt(q) === 0x24) q++;
      if (q - p < sizeOpen) continue;
      if (state.skipSpaces(q) < m) continue;
      haveEnd = true;
      break;
    }

    var body = state.getLines(startLine + 1, line, state.blkIndent, false);
    var blockToken = state.push("math_block", "math", 0);
    blockToken.block = true;
    blockToken.markup = "$".repeat(sizeOpen);
    blockToken.content = body.replace(/\n$/, "");
    state.line = haveEnd ? line + 1 : line;
    // Set from `state.line`, so the block's lines end on its closing `$$`:
    // the range a selection reports, the excerpt a correction quotes and
    // the lines the editor selects all include it (corrections §3.2).
    blockToken.map = [startLine, state.line];
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

  // ========================================================= source lines ==
  // Every block says which lines of the Markdown it came from, so a
  // selection in the reader can name its source lines (corrections §3.2).
  // markdown-it gives each block token a `map`, `[first, end)`, 0-based in
  // the string it was handed; that is the RenderRequest's markdown, and
  // `SourceLineMap` (Swift) maps it to the file, past the frontmatter and
  // around the relation-meta line.
  //
  // Three kinds of block write the range themselves: display math and
  // tables, whose renderers build their own markup, and pseudocode, which
  // takes it as `ccwiki-lines`, never as a `data-` attribute, because
  // pseudocode.js copies the <pre>'s dataset into its options. `ccwiki.js`
  // moves it onto the block's box as `data-source-lines`.

  var SOURCE_LINES = "data-source-lines";
  var PSEUDOCODE_LINES = "ccwiki-lines";

  function lineRange(map) {
    return map[0] + "-" + map[1];
  }

  function sourceLines(md) {
    md.core.ruler.push("ccwiki_source_lines", function (state) {
      state.tokens.forEach(function (token) {
        // An opening tag or a block of its own; an `inline` token is the
        // text of the block that holds it, and is never rendered as a tag.
        if (!token.map || !token.block || token.nesting === -1 || token.type === "inline") return;
        token.attrSet(SOURCE_LINES, lineRange(token.map));
      });
    });
  }

  /** ` data-source-lines="a-b"` for a renderer that builds its own markup. */
  function sourceAttribute(token, name) {
    var range = token.attrGet(SOURCE_LINES) || (token.map ? lineRange(token.map) : null);
    return range ? " " + (name || SOURCE_LINES) + '="' + range + '"' : "";
  }

  // ============================================================== factory ==

  function katexOptionsFor(macros) {
    return {
      macros: macros || {},
      throwOnError: false,
      strict: "ignore",
      output: "html",          // parity with quartz latex.ts:46 — no MathML
      trust: false,
      maxExpand: 1000,
    };
  }

  /** A link the change being reviewed adds a page for: it looks like a link
   *  and says so, and goes nowhere, since the page is not in the reader's
   *  wiki yet (corrections §6.3). */
  var NEW_PAGE_TITLE = "Added by this change";

  function isNewPage(resolved) {
    return !!resolved && resolved.kind === "new";
  }

  function create(macros) {
    var katexOptions = katexOptionsFor(macros);

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
    sourceLines(md);

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
      var lines = sourceAttribute(tokens[idx]);
      try {
        var opts = Object.assign({}, katexOptions, { displayMode: true });
        return '<div class="math-display"' + lines + ' data-tex="' +
          md.utils.escapeHtml(tokens[idx].content) + '">' +
          global.katex.renderToString(tokens[idx].content, opts) + "</div>\n";
      } catch (e) {
        return '<pre class="math-error"' + lines + ">" +
          md.utils.escapeHtml(tokens[idx].content) + "</pre>\n";
      }
    };

    md.renderer.rules.wikilink = function (tokens, idx, options, env) {
      var meta = tokens[idx].meta;
      var resolved = (env.links || {})[meta.raw];
      var label = displayText(meta);

      if (isNewPage(resolved)) {
        return '<a class="new" title="' + NEW_PAGE_TITLE + '">' +
          md.utils.escapeHtml(label) + "</a>";
      }
      // Swift resolved every link before the markdown crossed the bridge; a
      // miss here means no page, alias or folder claims that slug. The website
      // renders those as ordinary links to nowhere. Showing them as broken is
      // the one deliberate divergence: in an app you use to *edit* the wiki,
      // a dead link is information.
      if (!resolved || !resolved.href) {
        return '<a class="broken" title="Nothing resolves to “' +
          md.utils.escapeHtml(meta.target || meta.anchor) + '”">' +
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

    // Markdown links. The wiki writes `[text](slug#anchor)` wherever the text
    // holds math, because a wikilink's alias cannot (remark-math splits it
    // first). Swift resolved each destination like a wikilink and keyed it by
    // the destination as parsed; markdown-it keeps only the normalized href,
    // so normalizeLink remembers which destination each href came from.
    var linkDestinations = Object.create(null);
    var normalizeLink = md.normalizeLink;
    md.normalizeLink = function (url) {
      var href = normalizeLink.call(md, url);
      linkDestinations[href] = url;
      return href;
    };

    var defaultLinkOpen = md.renderer.rules.link_open || function (tokens, idx, options, env, self) {
      return self.renderToken(tokens, idx, options);
    };
    md.renderer.rules.link_open = function (tokens, idx, options, env, self) {
      var token = tokens[idx];
      var href = token.attrGet("href") || "";
      // URLs and same-page anchors are the click handler's; a reference-style
      // link names no destination Swift has seen.
      if (!href || href.charAt(0) === "#" || /^[A-Za-z][A-Za-z0-9+.\-]*:/.test(href) ||
          (token.meta && token.meta.label)) {
        return defaultLinkOpen(tokens, idx, options, env, self);
      }
      var destination = linkDestinations[href] !== undefined ? linkDestinations[href] : href;
      var links = env.links || {};
      var resolved = Object.prototype.hasOwnProperty.call(links, destination) ? links[destination] : null;
      if (isNewPage(resolved)) {
        token.attrs = [["class", "new"], ["title", NEW_PAGE_TITLE]];
      } else if (!resolved || !resolved.href) {
        // A miss is a dead link, shown as a dead wikilink is.
        token.attrs = [["class", "broken"],
          ["title", "Nothing resolves to “" + destination + "”"]];
      } else {
        token.attrSet("href", resolved.href);
        token.attrJoin("class", resolved.external ? "external"
          : "internal" + (resolved.kind === "folder" ? " folder" : ""));
      }
      return defaultLinkOpen(tokens, idx, options, env, self);
    };

    // Pseudocode fences are handed to pseudocode.js verbatim after render.
    var defaultFence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, idx, options, env, self) {
      if ((tokens[idx].info || "").trim() === "pseudocode") {
        return '<pre class="pseudocode"' + sourceAttribute(tokens[idx], PSEUDOCODE_LINES) + ">" +
          md.utils.escapeHtml(tokens[idx].content) + "</pre>\n";
      }
      return defaultFence(tokens, idx, options, env, self);
    };

    // Wide tables scroll in their own box instead of widening the measure.
    md.renderer.rules.table_open = function (tokens, idx) {
      return '<div class="table-scroll"' + sourceAttribute(tokens[idx]) + "><table>\n";
    };
    md.renderer.rules.table_close = function () { return "</table></div>\n"; };

    return md;
  }

  /** The renderer for link-preview cards: inline markdown and its math only.
   *  Swift has already reduced each part to text, emphasis, code and `$…$`,
   *  so this instance knows nothing else. `html: false` escapes anything
   *  Swift missed rather than injecting it, and links and images are off, so
   *  a stray `[text](url)` stays text: a card is never clicked. Same macro
   *  table as the page, so the site's macros render in cards. */
  function createPreview(macros) {
    var katexOptions = katexOptionsFor(macros);
    var pm = global.markdownit({ html: false, linkify: false, typographer: true });
    pm.disable(["link", "image", "autolink"], true);
    pm.inline.ruler.before("escape", "math_inline", mathInline);
    pm.renderer.rules.math_inline = function (tokens, idx) {
      try {
        return global.katex.renderToString(tokens[idx].content, katexOptions);
      } catch (e) {
        return '<code class="math-error">' + pm.utils.escapeHtml(tokens[idx].content) + "</code>";
      }
    };
    return pm;
  }

  function displayText(meta) {
    if (meta.alias) return meta.alias;
    if (!meta.target && meta.anchor) return meta.anchor.replace(/^#+/, "");
    // Quartz's prettyLinks default shows the last path segment.
    var base = meta.target.split("/").pop();
    return meta.anchor ? base + " › " + meta.anchor.replace(/^#+/, "") : base;
  }

  // =============================================================== review ==
  // The Rendered view of a change shows the blocks it changed and nothing
  // else (corrections §6.3). Swift sends each file's old and new body and
  // the line hunks between them; this parses both texts and takes the
  // top-level blocks from `token.map`. JavaScript owns the blocks as it owns
  // all parsing: Swift never guesses where markdown-it's blocks begin.
  //
  // For each hunk, the old blocks it overlaps are `removed` and the new ones
  // `added`. One unchanged block either side is `context`, and every other
  // run of unchanged blocks one `gap`. A hunk that overlaps no block on
  // either side changed only blank lines, and is a `gap` that says so.

  var BLANK_LINES_ONLY = "Only blank lines changed here. See Source.";
  var WHITESPACE_ONLY = "Whitespace only";

  /** The top-level blocks of `source`: their lines, `[start, end)` and
   *  0-based, their source text, and their HTML, rendered from the tokens
   *  of one parse, so a footnote or a reference definition elsewhere in the
   *  text still resolves. */
  function topLevelBlocks(md, source, env) {
    var tokens = md.parse(source, env);
    var lines = source.split("\n");
    var blocks = [];
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i];
      if (token.level !== 0 || token.nesting === -1) continue;
      var end = i;
      if (token.nesting === 1) {
        end = closingIndex(tokens, i);
        if (end < 0) continue;
      }
      if (token.map) {
        var html = "";
        try {
          html = md.renderer.render(tokens.slice(i, end + 1), md.options, env);
        } catch (e) {
          html = "<pre>" + md.utils.escapeHtml(lines.slice(token.map[0], token.map[1]).join("\n")) +
            "</pre>";
        }
        blocks.push({
          start: token.map[0],
          end: token.map[1],
          text: lines.slice(token.map[0], token.map[1]).join("\n"),
          html: html,
        });
      }
      i = end;
    }
    return blocks;
  }

  /** The token that closes `tokens[from]`: the next one at its level with
   *  nesting -1. */
  function closingIndex(tokens, from) {
    var level = tokens[from].level;
    for (var i = from + 1; i < tokens.length; i++) {
      if (tokens[i].level === level && tokens[i].nesting === -1) return i;
    }
    return -1;
  }

  /** Whether a block's lines `[start, end)` meet a hunk's `[a, b)`. An
   *  empty hunk side is an insertion point, which changes a block only from
   *  inside it. */
  function meets(block, range) {
    var a = range[0], b = range[1];
    if (b <= a) return block.start < a && a < block.end;
    return a < block.end && block.start < b;
  }

  function collapsed(text) {
    return text.replace(/\s+/g, " ").trim();
  }

  function pairs(range) {
    return Array.isArray(range) && range.length === 2 &&
      typeof range[0] === "number" && typeof range[1] === "number";
  }

  /**
   * The review's entries for one file of the payload (§6.3), in order:
   * `{ id, kind, side, lines: [start, end), fileLines: [first, last] | null,
   *    html, text, note, flags }`.
   *
   * `kind` is `added`, `removed`, `context` or `gap`. `side` says which text
   * `lines` are in: `old` for removed, `new` for the rest. `text` is a gap's
   * one line; `note` is "Whitespace only" on a pair that differs only in
   * whitespace. `flags` are the file's flags whose lines meet the entry,
   * each on the first entry it meets; a flag that meets none, or has no
   * lines, is on no entry, and `renderReview` shows it with the file.
   *
   * A file that is not Markdown has no entries: the review shows it as one
   * line, and its lines in Source.
   */
  function reviewEntries(md, file) {
    if (!file || file.isMarkdown === false) return [];
    var status = file.status || "modified";
    var oldBlocks = status === "added" ? [] : topLevelBlocks(md, file.old || "", { links: file.links || {} });
    var newBlocks = status === "deleted" ? [] : topLevelBlocks(md, file.new || "", { links: file.links || {} });
    var bodyLine = file.bodyLine || {};
    var entries = [];

    function push(kind, side, block, extra) {
      var startLine = side === "old" ? bodyLine.old : bodyLine.new;
      var entry = {
        id: (file.id || "f") + "-" + entries.length,
        kind: kind,
        side: side,
        lines: [block.start, block.end],
        fileLines: typeof startLine === "number" && block.end > block.start
          ? [startLine + block.start, startLine + block.end - 1] : null,
        html: block.html || "",
        text: (extra && extra.text) || null,
        note: (extra && extra.note) || null,
        flags: [],
      };
      entries.push(entry);
      return entry;
    }

    if (status === "added") {
      newBlocks.forEach(function (block) { push("added", "new", block); });
    } else if (status === "deleted") {
      oldBlocks.forEach(function (block) { push("removed", "old", block); });
    } else {
      buildModified(file.hunks || [], oldBlocks, newBlocks, push);
    }

    attachFlags(entries, file.flags || [], status === "deleted" ? "old" : "new");
    return entries;
  }

  /** Groups the hunks by the blocks they change, then walks the new text:
   *  unchanged runs between the groups, each group's removed then added
   *  blocks. */
  function buildModified(hunks, oldBlocks, newBlocks, push) {
    var groups = [];
    hunks.forEach(function (hunk) {
      if (!hunk || !pairs(hunk.old) || !pairs(hunk.new)) return;
      var removed = indicesMeeting(oldBlocks, hunk.old);
      var added = indicesMeeting(newBlocks, hunk.new);
      var last = groups[groups.length - 1];
      // A block two hunks both touch is one change, shown once.
      if (last && (shares(last.removed, removed) || shares(last.added, added))) {
        last.removed = union(last.removed, removed);
        last.added = union(last.added, added);
        return;
      }
      groups.push({ removed: removed, added: added, at: hunk.new[0], hunk: hunk });
    });

    var next = 0;           // the first new block not yet shown
    groups.forEach(function (group, index) {
      var start = group.added.length ? group.added[0] : firstStartingAtOrAfter(newBlocks, group.at);
      start = Math.max(start, next);
      unchanged(newBlocks.slice(next, start), index > 0, true, push);

      var removed = group.removed.map(function (i) { return push("removed", "old", oldBlocks[i]); });
      var added = group.added.map(function (i) { return push("added", "new", newBlocks[i]); });
      for (var k = 0; k < Math.min(group.removed.length, group.added.length); k++) {
        if (collapsed(oldBlocks[group.removed[k]].text) === collapsed(newBlocks[group.added[k]].text)) {
          removed[k].note = WHITESPACE_ONLY;
          added[k].note = WHITESPACE_ONLY;
        }
      }
      if (!removed.length && !added.length) {
        push("gap", "new", { start: group.hunk.new[0], end: group.hunk.new[1], html: "" },
          { text: BLANK_LINES_ONLY });
      }
      next = group.added.length ? Math.max(next, group.added[group.added.length - 1] + 1) : start;
    });
    unchanged(newBlocks.slice(next), groups.length > 0, false, push);
  }

  /** A run of unchanged blocks: one of context beside each change it
   *  touches, and the rest as one gap. With no change in the file at all,
   *  the whole run is a gap. */
  function unchanged(run, afterChange, beforeChange, push) {
    if (!run.length) return;
    var lead = afterChange ? 1 : 0;
    var tail = beforeChange ? 1 : 0;
    if (!afterChange && !beforeChange) { lead = 0; tail = 0; }
    if (run.length <= lead + tail) {
      run.forEach(function (block) { push("context", "new", block); });
      return;
    }
    run.slice(0, lead).forEach(function (block) { push("context", "new", block); });
    var hidden = run.slice(lead, run.length - tail);
    push("gap", "new", { start: hidden[0].start, end: hidden[hidden.length - 1].end, html: "" },
      { text: hidden.length + (hidden.length === 1 ? " unchanged block" : " unchanged blocks") });
    run.slice(run.length - tail).forEach(function (block) { push("context", "new", block); });
  }

  function indicesMeeting(blocks, range) {
    var found = [];
    blocks.forEach(function (block, i) { if (meets(block, range)) found.push(i); });
    return found;
  }

  function firstStartingAtOrAfter(blocks, line) {
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].start >= line) return i;
    }
    return blocks.length;
  }

  function shares(a, b) {
    return a.some(function (i) { return b.indexOf(i) >= 0; });
  }

  function union(a, b) {
    var all = a.slice();
    b.forEach(function (i) { if (all.indexOf(i) < 0) all.push(i); });
    return all.sort(function (x, y) { return x - y; });
  }

  /** Each flag on the first entry, on its side, whose lines it meets. A
   *  flag on an empty range marks the line it starts on. */
  function attachFlags(entries, flags, side) {
    flags.forEach(function (flag) {
      if (!flag || !pairs(flag.lines)) return;
      var a = flag.lines[0];
      var b = Math.max(flag.lines[1], a + 1);
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (entry.side !== side) continue;
        if (a < entry.lines[1] && entry.lines[0] < b) {
          entry.flags.push(flag);
          return;
        }
      }
    });
  }

  global.CCwikiMarkdown = {
    create: create,
    createPreview: createPreview,
    reviewEntries: reviewEntries,
  };
})(typeof window !== "undefined" ? window : this);
