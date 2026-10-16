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
        // The site reads the alias from text micromark has decoded, so
        // `IND\$-CPA` shows `IND$-CPA` and `AT&amp;T` shows `AT&T`. `raw`,
        // as written, stays the key Swift resolved the link by.
        alias: match[3] ? state.md.utils.unescapeAll(match[3].replace(/^\\?\|/, "")).trim() : null,
        embed: match[0].charAt(0) === "!",
      };
    }
    state.pos += match[0].length;
    return true;
  }

  /** Each wikilink's text as a `text` token between `wikilink_open` and
   *  `wikilink_close`. The site makes a wikilink a link with a text child
   *  (ofm.ts:336) before its arrows and smartypants run, so they reach the
   *  link's text as they reach the words around it:
   *  `[[merkle-puzzles|Merkle's puzzles]]` gets its curly apostrophe.
   *  After `linkify`, which would make a URL in the text a second link,
   *  and before `smartquotes`. An embed stays one
   *  `wikilink` token: the site shows an image or a transclusion for it,
   *  never text.
   *
   *  A link in a table cell is marked `inTable`: the site escapes the `#`
   *  of a wikilink in a table (ofm.ts:196), so there `[[page#Heading]]`
   *  keeps the page as its text instead of taking the heading's. */
  function wikilinkText(md) {
    md.core.ruler.after("linkify", "ccwiki_wikilink_text", function (state) {
      var cells = 0;
      state.tokens.forEach(function (block) {
        if (block.type === "th_open" || block.type === "td_open") cells++;
        else if (block.type === "th_close" || block.type === "td_close") cells--;
        if (block.type !== "inline" || !block.children) return;

        var children = [];
        block.children.forEach(function (token) {
          if (token.type !== "wikilink") { children.push(token); return; }
          token.meta.inTable = cells > 0;
          if (token.meta.embed) { children.push(token); return; }

          var open = new state.Token("wikilink_open", "a", 1);
          open.meta = token.meta;
          open.level = token.level;
          var text = new state.Token("text", "", 0);
          text.content = displayText(token.meta);
          text.level = token.level + 1;
          var close = new state.Token("wikilink_close", "a", -1);
          close.level = token.level;
          children.push(open, text, close);
        });
        block.children = children;
      });
    });
  }

  // ============================================================= headings ==
  // rehype-slug assigns heading ids with a per-document *deduplicating*
  // GithubSlugger, so a second `## Syntax` becomes `syntax-1`. Wikilink
  // anchors use the non-deduplicating variant and therefore can only ever
  // address the first — a real Quartz limitation we reproduce rather than fix.

  function headingPlainText(inlineToken) {
    var out = "";
    var children = inlineToken.children || [];
    for (var i = 0; i < children.length; i++) {
      var child = children[i];
      if (child.type === "text" || child.type === "code_inline") {
        out += child.content;
      } else if (child.type === "math_inline") {
        // rehype-slug runs before rehype-katex, so the *source* is what feeds
        // the anchor — minus the `$` delimiters, which it strips anyway.
        out += child.content;
      } else if (child.type === "wikilink" || child.type === "wikilink_open") {
        // The alias, or the target without its anchor, as Swift's
        // `Heading.plainText` reads it, not the text the link shows.
        out += child.meta.alias || child.meta.target;
        while (child.type === "wikilink_open" && i + 1 < children.length &&
               children[i + 1].type !== "wikilink_close") i++;
      }
    }
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

  // ofm.ts:147, as the site has it. The site matches it against the first
  // line of the paragraph's first text node (ofm.ts:477), and `(.+?)?` runs
  // on to the first `]` in that text after the marker's own: the text up to
  // it is the callout's metadata, so `[!note] As shown in [HLL23], …` is
  // titled `, …` there, and here. `siteTextNode` finds that text.
  var CALLOUT = /^\[\!([\w-]+)\|?(.+?)?\]([+-]?)/;

  // What OFM splits that text node at, in the order it applies them
  // (ofm.ts:239): a wikilink (ofm.ts:123), a highlight (ofm.ts:143), an
  // arrow (ofm.ts:121) and a tag (ofm.ts:155), unless the tag is digits and
  // slashes only. The tag's `(?<=^| )` is captured as `(^| )` here, and the
  // pattern is built at run time: an engine without Unicode property escapes
  // then loses the tag split, not this file.
  var SITE_WIKILINK = /!?\[\[([^\[\]\|\#\\]+)?(#+[^\[\]\|\#\\]+)?(\\?\|[^\[\]\#]*)?\]\]/g;
  var SITE_HIGHLIGHT = /==([^=]+)==/g;
  var SITE_ARROW = /(-{1,2}>|={1,2}>|<-{1,2}|<={1,2})/g;
  var SITE_TAG = (function () {
    try {
      return new RegExp("(^| )#((?:[-_\\p{L}\\p{Emoji}\\p{M}\\d])+(?:\\/[-_\\p{L}\\p{Emoji}\\p{M}\\d]+)*)", "gu");
    } catch (e) {
      return null;
    }
  })();

  // remark-gfm's literal links that markdown-it's inline parse does not
  // make: `www.` ones (markdown-it's linkify leaves them alone) and email
  // addresses (its `linkify` core rule links those after the inline parse).
  var SITE_WWW = /(^|[\s*_~(])www\.[A-Za-z0-9_-]/i;

  // What micromark counts as punctuation next to a `~`
  // (micromark-util-character 2.0.1, the site's): ASCII punctuation and
  // Unicode's P. Built at run time, as SITE_TAG is; without it, ASCII only.
  var SITE_PUNCTUATION = (function () {
    try {
      return new RegExp("^(?:[!-\\/:-@\\[-`{-~]|\\p{P})$", "u");
    } catch (e) {
      return /^[!-\/:-@\[-`{-~]$/;
    }
  })();

  /** Obsidian's other names for a callout (ofm.ts:71). */
  var CALLOUT_ALIASES = {
    summary: "abstract", tldr: "abstract", hint: "tip", important: "tip",
    check: "success", done: "success", help: "question", faq: "question",
    attention: "warning", caution: "warning", missing: "failure", fail: "failure",
    error: "danger", cite: "quote",
  };

  /** Only the callout's first line is its marker and title: the site puts
   *  the lines after it in a paragraph of their own, so
   *  `> [!note] Title` and `> Body.` on the next line are a title and a
   *  body. Before the inline parse, so a title keeps its math, links and
   *  emphasis. A `-` that folds the callout on the site is not honoured:
   *  the reader has no control to unfold it. */
  function callouts(md) {
    md.core.ruler.after("block", "ccwiki_callouts", function (state) {
      var tokens = state.tokens;
      for (var i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== "blockquote_open") continue;
        // blockquote_open, paragraph_open, inline, paragraph_close, ...
        var para = tokens[i + 1], inline = tokens[i + 2];
        if (!para || para.type !== "paragraph_open" || !inline || inline.type !== "inline") continue;
        var newline = inline.content.indexOf("\n");
        var first = newline < 0 ? inline.content : inline.content.slice(0, newline);
        var node = siteTextNode(state.md, first, state.env);
        var match = CALLOUT.exec(node.text);
        if (!match) continue;

        var name = match[1].toLowerCase();
        var kind = Object.prototype.hasOwnProperty.call(CALLOUT_ALIASES, name)
          ? CALLOUT_ALIASES[name] : name;
        var title = first.slice(node.at[match[0].length]).trim() ||
          (match[1].charAt(0).toUpperCase() + match[1].slice(1)).replace(/-/g, " ");

        tokens[i].tag = "div";
        tokens[i].attrJoin("class", "callout callout-" + kind);
        var close = findMatching(tokens, i, "blockquote_open", "blockquote_close");
        if (close >= 0) tokens[close].tag = "div";

        // The marker paragraph becomes the styled title, and the lines
        // after its first, if any, a paragraph of the body.
        // (ofm.ts:187 makes that paragraph; its visitor, ofm.ts:483, too.)
        if (newline >= 0 && para.map) {
          var bodyLines = [para.map[0] + 1, para.map[1]];
          var bodyOpen = new state.Token("paragraph_open", "p", 1);
          var bodyInline = new state.Token("inline", "", 0);
          var bodyClose = new state.Token("paragraph_close", "p", -1);
          bodyOpen.map = bodyLines;
          bodyInline.map = bodyLines.slice();
          bodyInline.content = inline.content.slice(newline + 1);
          bodyInline.children = [];
          [bodyOpen, bodyInline, bodyClose].forEach(function (token, k) {
            token.block = true;
            token.level = (k === 1 ? inline : para).level;
          });
          tokens.splice(i + 4, 0, bodyOpen, bodyInline, bodyClose);
          para.map = [para.map[0], para.map[0] + 1];
          inline.map = para.map.slice();
        }
        para.tag = "div";
        para.attrJoin("class", "callout-title");
        tokens[i + 3].tag = "div";
        inline.content = title;
      }
    });
  }

  /** The text the site matches `CALLOUT` against, for a paragraph whose
   *  first line is `line`, as written: the paragraph's first text node,
   *  decoded, and `at`, where each of its characters starts in `line`, one
   *  more for where the node ends. micromark ends that node where it parses
   *  anything but text; markdown-it's inline parser reads the line as it
   *  would (escapes and entities are text; a link, an image, math, code,
   *  emphasis, an autolink, HTML or a wikilink is not). Then remark-gfm's
   *  single-`~` strikethrough and literal links, and OFM's splits, end it
   *  sooner. */
  function siteTextNode(md, line, env) {
    var tokens = [];
    md.inline.parse(line, md, scratchEnv(env), tokens);
    var text = "", at = [], written = [], pos = 0;
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i];
      if (token.type !== "text" && token.type !== "text_special") break;
      // A `text` token is the line as written; a `text_special` one is an
      // escape or an entity, decoded, its source in `markup`.
      for (var k = 0; k < token.content.length; k++) {
        at.push(token.type === "text" ? pos + k : pos);
        written.push(token.type === "text");
      }
      text += token.content;
      pos += token.type === "text" ? token.content.length : token.markup.length;
    }
    at.push(pos);

    var end = text.length;
    var strike = singleTildeStrike(line, text, at, written);
    if (strike >= 0) end = Math.min(end, strike);
    var www = SITE_WWW.exec(text);
    if (www) end = Math.min(end, www.index + www[1].length);
    var emails = (md.linkify && md.linkify.match(text)) || [];
    for (var e = 0; e < emails.length; e++) {
      if (emails[e].schema === "mailto:") { end = Math.min(end, emails[e].index); break; }
    }
    text = text.slice(0, end);

    [SITE_WIKILINK, SITE_HIGHLIGHT, SITE_ARROW].forEach(function (split) {
      split.lastIndex = 0;
      var found = split.exec(text);
      if (found) text = text.slice(0, found.index);
    });
    if (SITE_TAG) SITE_TAG.lastIndex = 0;
    for (var tag = SITE_TAG && SITE_TAG.exec(text); tag; tag = SITE_TAG.exec(text)) {
      var hash = tag.index + tag[1].length;
      if (!/^[\/\d]+$/.test(tag[2])) { text = text.slice(0, hash); break; }
      SITE_TAG.lastIndex = hash + 1;
    }
    return { text: text, at: at.slice(0, text.length + 1) };
  }

  /** Where in `text` (`siteTextNode`'s, with `at` and which of its
   *  characters are `written` as in the line) the site starts a
   *  strikethrough markdown-it does not make, or -1. remark-gfm's
   *  micromark-extension-gfm-strikethrough 2.0.0 takes a lone `~` as a
   *  marker (`singleTilde`, on by default) and pairs it as CommonMark pairs
   *  emphasis: a `~` opens before a letter, or before punctuation after a
   *  space or punctuation, closes the other way round, and closes the
   *  nearest open one before it. An escaped `~`, or one next to another, is
   *  no such marker; `~~` is markdown-it's own. Only a closing `~` in `text`
   *  is looked for. */
  function singleTildeStrike(line, text, at, written) {
    function side(character) {
      if (character === "" || /^\s$/.test(character)) return "space";
      return SITE_PUNCTUATION.test(character) ? "punctuation" : "other";
    }
    var open = [], first = -1;
    for (var k = 0; k < text.length; k++) {
      if (text.charAt(k) !== "~" || !written[k]) continue;
      var p = at[k];
      if ((k > 0 && written[k - 1] && text.charAt(k - 1) === "~") || line.charAt(p + 1) === "~") continue;
      var before = side(Array.from(line.slice(Math.max(0, p - 2), p)).pop() || "");
      var after = side(Array.from(line.slice(p + 1, p + 3))[0] || "");
      var opens = after === "other" || (after === "punctuation" && before !== "other");
      var closes = before === "other" || (before === "punctuation" && after !== "other");
      if (closes && open.length) {
        var opener = open.pop();
        if (first < 0 || opener < first) first = opener;
      } else if (opens) {
        open.push(k);
      }
    }
    return first;
  }

  /** `env` for a parse whose tokens are thrown away: the footnote plugin
   *  counts each reference it reads into `env.footnotes`, so those are
   *  copies. */
  function scratchEnv(env) {
    var notes = env.footnotes;
    return {
      references: env.references,
      footnotes: notes && {
        refs: Object.assign({}, notes.refs),
        list: (notes.list || []).map(function (note) { return Object.assign({}, note); }),
      },
    };
  }

  function findMatching(tokens, from, openType, closeType) {
    var depth = 0;
    for (var i = from; i < tokens.length; i++) {
      if (tokens[i].type === openType) depth++;
      else if (tokens[i].type === closeType && --depth === 0) return i;
    }
    return -1;
  }

  // ======================================================= text transform ==
  // The site edits the text before it parses it (ofm.ts:179): it deletes
  // `%%` comments, and in a table it escapes the pipes of each wikilink,
  // which would otherwise end the cell. So does this, ahead of the block
  // parser. Deleting a comment that spans lines moves the lines after it,
  // so `ccwiki_comment_lines` then puts every token's `map` back on the
  // lines of the text it was handed, which the stamps, the review and
  // `SourceLineMap` read.

  var COMMENT = /%%[\s\S]*?%%/g;                                            // ofm.ts:145
  var TABLE = /^\|([^\n])+\|\n(\|)( ?:?-{3,}:? ?\|)+\n(\|([^\n])+\|\n?)+/gm;  // ofm.ts:135
  var TABLE_LINK = /(!?\[\[[^\]]*?\]\]|\[\^[^\]]*?\])/g;                    // ofm.ts:140

  /** The blocks markdown-it shows as written, at any depth. */
  var VERBATIM = { fence: true, code_block: true, math_block: true, html_block: true };
  /** A table, whose lines markdown-it splits into cells. */
  var TABLE_OPEN = { table_open: true };

  function textTransform(md) {
    md.core.ruler.after("normalize", "ccwiki_text_transform", function (state) {
      var src = state.src;
      if (src.indexOf("%%") >= 0) {
        var kept = withoutComments(src);
        src = kept.text;
        state.ccwikiLineOf = kept.lineOf;
      }
      var verbatim = null;
      var escaped = src.replace(TABLE, function (table) {
        // A table inside fenced code (or display math, or HTML) is shown as
        // written, its cells never split: it gets the site's edit and
        // nothing more, so it reads as it does on the site, and a `\|` in
        // it, or in its math, stays as written.
        verbatim = verbatim || linesInBlocks(state.md, src, VERBATIM);
        if (verbatim[lineAt(src, arguments[arguments.length - 2])]) {
          return table.replace(TABLE_LINK, siteTableLink);
        }
        return table.replace(TABLE_LINK, function (link) {
          // markdown-it's cell split takes one backslash off each `\|`, so
          // every pipe gets one, escaped or not, and the cell holds the
          // link as written: the key Swift resolved it by. (The site also
          // escapes a `#`, which markdown-it would keep, and the link
          // would no longer parse.)
          return link.replace(/\|/g, "\\|");
        }).split("\n").map(mathPipes).join("\n");
      });
      state.src = escaped === src ? src : splitRowsOnly(state.md, src, escaped, verbatim);
    });

    md.core.ruler.before("ccwiki_source_lines", "ccwiki_comment_lines", function (state) {
      var lineOf = state.ccwikiLineOf;
      if (!lineOf) return;
      state.tokens.forEach(function (token) {
        if (token.map) token.map = [lineOf[token.map[0]], lineOf[token.map[1]]];
      });
    });
  }

  /** ofm.ts:196's edit of a link in a table, exactly: its first `#`, and
   *  each `|` no backslash escapes, escaped. */
  function siteTableLink(link) {
    return link.replace("#", "\\#").replace(/((^|[^\\])(\\\\)*)\|/g, "$1\\|");
  }

  /** `src` with the escapes `escaped` adds kept on the lines markdown-it
   *  splits into cells or shows as written, and on no other: only the cell
   *  split takes the second backslashes off again. Rows the site's regex
   *  finds that make no table (a header with another number of cells than
   *  the line under it, or rows that continue a list item's or a quote's
   *  paragraph) are a paragraph's lines, where the site decodes each `\|`
   *  it added, so the link and the math there read as written. A row put
   *  back that would make a table of its own (its link's `|` the end of a
   *  cell again) keeps its escapes, so the tables stay the site's. */
  function splitRowsOnly(md, src, escaped, verbatim) {
    var lines = escaped.split("\n"), written = src.split("\n");
    var keep = linesInBlocks(md, escaped, TABLE_OPEN);
    for (;;) {
      var text = lines.map(function (line, n) {
        return keep[n] || verbatim[n] ? line : written[n];
      }).join("\n");
      var grew = false;
      linesInBlocks(md, text, TABLE_OPEN).forEach(function (inTable, n) {
        if (keep[n]) return;
        keep[n] = true;
        grew = true;
      });
      if (!grew) return text;
    }
  }

  /** For each line of `src`, whether it is in a block of one of `types`, at
   *  any depth. From a parse of its own, whose tokens and `env` are thrown
   *  away; a table's escapes add no line. */
  function linesInBlocks(md, src, types) {
    var tokens = [], lines = [];
    md.block.parse(src, md, {}, tokens);
    tokens.forEach(function (token) {
      if (!token.map || !types[token.type]) return;
      for (var line = token.map[0]; line < token.map[1]; line++) lines[line] = true;
    });
    return lines;
  }

  /** The 0-based line of `text` that `offset` is on. */
  function lineAt(text, offset) {
    var line = 0;
    for (var i = text.indexOf("\n"); i >= 0 && i < offset; i = text.indexOf("\n", i + 1)) line++;
    return line;
  }

  /** `src` without its comments, and the line of `src` each line of what is
   *  left starts on, with one more for the end of the text. */
  function withoutComments(src) {
    var text = "", last = 0, line = 0, lineOf = [0];
    function keep(part) {
      for (var i = 0; i < part.length; i++) {
        if (part.charCodeAt(i) === 0x0a /* \n */) lineOf.push(++line);
      }
      text += part;
    }
    src.replace(COMMENT, function (comment, at) {
      keep(src.slice(last, at));
      line += comment.split("\n").length - 1;
      last = at + comment.length;
      return comment;
    });
    keep(src.slice(last));
    lineOf.push(line + 1);
    return { text: text, lineOf: lineOf };
  }

  /** A table row with a second backslash on each `\|` in its math. The
   *  site keeps math as written, and unescapes a pipe only in code
   *  (mdast-util-gfm-table), so `$\|x\|$` is ‖x‖ there; markdown-it's cell
   *  split would leave `|x|`. Read as the cell is: an escape first, then
   *  whichever of code and math opens first, neither past the cell's
   *  unescaped `|`. */
  function mathPipes(row) {
    var out = "", i = 0, n = row.length;
    while (i < n) {
      var c = row.charCodeAt(i);
      if (c === 0x5c /* \ */) { out += row.slice(i, i + 2); i += 2; continue; }
      if (c !== 0x24 /* $ */ && c !== 0x60 /* ` */) { out += row.charAt(i); i++; continue; }
      var open = i;
      while (i < n && row.charCodeAt(i) === c) i++;
      var size = i - open;
      var close = closingRun(row, i, c, size);
      if (close < 0) { out += row.slice(open, i); continue; }
      var inside = row.slice(i, close);
      out += row.slice(open, i) + (c === 0x24 ? inside.replace(/\\\|/g, "\\\\|") : inside) +
        row.slice(close, close + size);
      i = close + size;
    }
    return out;
  }

  /** Where a run of exactly `size` `c`s starts at or after `from` in `row`,
   *  or -1 if the cell ends first. */
  function closingRun(row, from, c, size) {
    var j = from, n = row.length;
    while (j < n) {
      var d = row.charCodeAt(j);
      if (d === 0x7c /* | */ && row.charCodeAt(j - 1) !== 0x5c) return -1;
      if (d !== c) { j++; continue; }
      var start = j;
      while (j < n && row.charCodeAt(j) === c) j++;
      if (j - start === size) return start;
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

  // =========================================================== typography ==
  // What the site does to the words. OFM's arrows first (ofm.ts:101, on by
  // default): `->`, `-->`, `=>`, `==>`, `<-`, `<--`, `<=` and `<==`. Then
  // remark-smartypants (gfm.ts:24) with retext-smartypants' defaults: curly
  // quotes, ``` `` ``` and `''` (only two) as “ and ”, `--` (only two) an em
  // dash, and three or more dots an ellipsis. Nothing else, so `---`, `(c)`,
  // `+-` and `..` stay as written and markdown-it's `replacements` is off;
  // its `smartquotes` stands in for the quotes. A link's text too,
  // whatever made the link: the site's parser makes an autolink, and
  // remark-gfm a URL or an address, a link with a text node before any of
  // this runs, and smartypants and the arrows edit every text node, so on
  // the site `https://x.org/a--b` reads `https://x.org/a—b`. Its href
  // stays.

  var ARROWS = /(-{1,2}>|={1,2}>|<-{1,2}|<={1,2})/g;   // ofm.ts:121
  var ARROW = {
    "->": "→", "-->": "⇒", "=>": "⇒", "==>": "⇒",
    "<-": "←", "<--": "⇐", "<=": "⇐", "<==": "⇐",
  };

  function educated(text) {
    return text
      .replace(ARROWS, function (arrow) { return ARROW[arrow]; })
      .replace(/(^|[^-])--(?!-)/g, "$1—")
      .replace(/\.{3,}/g, "…");
  }

  /** LaTeX's quotes, ``` ``like this'' ```: before `smartquotes`, which
   *  would take the `''` for two apostrophes. */
  function backticks(text) {
    return text.replace(/(^|[^`])``(?!`)/g, "$1“").replace(/(^|[^'])''(?!')/g, "$1”");
  }

  function typography(md) {
    md.disable("replacements");
    md.core.ruler.before("smartquotes", "ccwiki_backticks", eachText(backticks));
    // After `text_join`, so an escaped character counts, as it does once
    // micromark has decoded it.
    md.core.ruler.after("text_join", "ccwiki_typography", eachText(educated));
  }

  /** A core rule that edits the text of every inline block, each `text`
   *  token on its own, a link's included. */
  function eachText(edit) {
    return function (state) {
      state.tokens.forEach(function (block) {
        if (block.type !== "inline" || !block.children) return;
        block.children.forEach(function (token) {
          if (token.type === "text") token.content = edit(token.content);
        });
      });
    };
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
      typographer: true,       // smartquotes; the rest is `typography`
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

    wikilinkText(md);
    typography(md);
    headingIds(md);
    callouts(md);
    sourceLines(md);
    textTransform(md);

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

    /** A wikilink's opening tag; its text and `</a>` follow. */
    function wikilinkTag(meta, resolved) {
      if (isNewPage(resolved)) {
        return '<a class="new" title="' + NEW_PAGE_TITLE + '">';
      }
      // Swift resolved every link before the markdown crossed the bridge; a
      // miss here means no page, alias or folder claims that slug. The website
      // renders those as ordinary links to nowhere. Showing them as broken is
      // the one deliberate divergence: in an app you use to *edit* the wiki,
      // a dead link is information.
      if (!resolved || !resolved.href) {
        return '<a class="broken" title="Nothing resolves to “' +
          md.utils.escapeHtml(meta.target || meta.anchor) + '”">';
      }
      if (resolved.external) {
        return '<a class="external" href="' + md.utils.escapeHtml(resolved.href) + '">';
      }
      return '<a class="internal' + (resolved.kind === "folder" ? " folder" : "") +
        '" href="' + md.utils.escapeHtml(resolved.href) + '">';
    }

    md.renderer.rules.wikilink_open = function (tokens, idx, options, env) {
      return wikilinkTag(tokens[idx].meta, (env.links || {})[tokens[idx].meta.raw]);
    };
    md.renderer.rules.wikilink_close = function () { return "</a>"; };

    // An embed, which `ccwiki_wikilink_text` leaves as one token: an image,
    // or a link to what it embeds.
    md.renderer.rules.wikilink = function (tokens, idx, options, env) {
      var meta = tokens[idx].meta;
      var resolved = (env.links || {})[meta.raw];
      var label = md.utils.escapeHtml(displayText(meta));
      if (!isNewPage(resolved) && resolved && resolved.href && meta.embed && resolved.isImage) {
        return '<img src="' + md.utils.escapeHtml(resolved.href) + '" alt="' + label +
          '" loading="lazy">';
      }
      return wikilinkTag(meta, resolved) + label + "</a>";
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
    typography(pm);
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

  /** What a wikilink shows: its alias; else its heading, which ofm.ts:218
   *  makes the alias of `[[page#Heading]]` (one `#` off), except on a page
   *  in a table, where the site escapes the `#` first; else the last
   *  segment of its target, as the site's prettyLinks (links.ts:136) cuts
   *  it. prettyLinks cuts an alias or a heading to its last `/` segment
   *  too (`[[p-poly|P/poly]]` reads `poly` there); here they stay whole
   *  (plans/render-pipeline.md, "Still different from the site"). */
  function displayText(meta) {
    if (meta.alias) return meta.alias;
    if (meta.anchor && !(meta.inTable && meta.target)) return meta.anchor.replace(/^#/, "").trim();
    return meta.target.split("/").pop();
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
  //
  // That holds because every non-blank line is in a block: the lines
  // markdown-it maps to none, a footnote's definition (moved to the end of
  // the page) or a link reference definition (drawn as nothing), are blocks
  // of their own, shown as their source.

  var BLANK_LINES_ONLY = "Only blank lines changed here. See Source.";
  var WHITESPACE_ONLY = "Whitespace only";
  var SHOWN_AS_SOURCE = "Shown as source";

  /** The top-level blocks of `source`: their lines, `[start, end)` and
   *  0-based, their source text, and their HTML, rendered from the tokens
   *  of one parse, so a footnote or a reference definition elsewhere in the
   *  text still resolves. Lines in none of markdown-it's blocks are added
   *  by `withSourceBlocks`. */
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
    return withSourceBlocks(md, lines, blocks);
  }

  /** `blocks`, in order, with a block for each run of non-blank lines in
   *  none of them, its HTML the lines as written. Without these, a change
   *  to a footnote's text or a link's target met no block, and the review
   *  said only blank lines had changed. */
  function withSourceBlocks(md, lines, blocks) {
    var covered = [];
    blocks.forEach(function (block) {
      for (var k = block.start; k < block.end; k++) covered[k] = true;
    });
    var all = blocks.slice();
    var start = -1;
    for (var line = 0; line <= lines.length; line++) {
      var loose = line < lines.length && !covered[line] && !/^\s*$/.test(lines[line]);
      if (loose && start < 0) start = line;
      if (!loose && start >= 0) {
        var text = lines.slice(start, line).join("\n");
        all.push({
          start: start,
          end: line,
          text: text,
          html: "<pre>" + md.utils.escapeHtml(text) + "</pre>",
          note: SHOWN_AS_SOURCE,
        });
        start = -1;
      }
    }
    return all.sort(function (a, b) { return a.start - b.start; });
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
   * whitespace, and otherwise "Shown as source" on a block shown as its
   * lines (`withSourceBlocks`). `flags` are the file's flags whose lines
   * meet the entry, each on the first entry it meets; a flag that meets
   * none, or has no lines, is on no entry, and `renderReview` shows it with
   * the file.
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
        note: (extra && extra.note) || block.note || null,
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

  /** The signs the frontmatter box shows in its gutter, by kind. */
  var FRONTMATTER_SIGNS = { added: "+", removed: "\u2212", context: " ", gap: "" };

  /**
   * The frontmatter of one file of the payload (§6.3), as the review's box
   * shows it: `[{ kind, sign, text }]`. `added`, `removed` and `context`
   * are lines of the YAML, each with its sign; a `gap` is a run of
   * unchanged lines left out, and its text a caption ("3 unchanged lines"),
   * never a line of the file. Any other kind reads as context.
   */
  function reviewFrontmatter(lines) {
    return (Array.isArray(lines) ? lines : []).map(function (line) {
      var kind = line && Object.prototype.hasOwnProperty.call(FRONTMATTER_SIGNS, line.kind)
        ? line.kind : "context";
      return { kind: kind, sign: FRONTMATTER_SIGNS[kind], text: String((line && line.text) || "") };
    });
  }

  global.CCwikiMarkdown = {
    create: create,
    createPreview: createPreview,
    reviewEntries: reviewEntries,
    reviewFrontmatter: reviewFrontmatter,
  };
})(typeof window !== "undefined" ? window : this);
