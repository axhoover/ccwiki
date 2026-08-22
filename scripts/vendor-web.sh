#!/usr/bin/env bash
# CityDesk — vendor the offline rendering pipeline into CityDesk/Resources/web/
#
#   ./scripts/vendor-web.sh            # fetch + verify + install
#   ./scripts/vendor-web.sh --check    # verify what's already installed, fetch nothing
#
# Run this ONCE on a machine with network; commit the result. The app itself
# never touches the network. Requires: curl, tar, shasum, sed. Does NOT require
# node/npm (we only untar published dist bundles), but node is fine to have.
set -euo pipefail

# ---------------------------------------------------------------- pinned versions
MARKDOWN_IT_VER=15.0.0
MDIT_FOOTNOTE_VER=4.0.0
MDIT_MARK_VER=4.0.0
MDIT_ANCHOR_VER=9.2.1
GITHUB_SLUGGER_VER=2.0.0   # ESM-only; we emit a UMD shim below
KATEX_VER=0.16.47
PSEUDOCODE_VER=2.4.1                 # for pseudocode.min.css only
# The wiki ships a PATCHED pseudocode.js (adds the \algname{...} directive that
# 54 Game / 4 Oracle blocks in content/ depend on). Upstream 2.4.1 does NOT have
# it. Pin the exact wiki commit we vendored it from.
WIKI_REPO=axhoover/cryptology.city
WIKI_SHA=75f254251cd77489c40df4e664b9ccf4521b976a
PSEUDOCODE_JS_SHA256=98fa1ecb0383e71e3c5d85b26b18e4f625800fbedc628fc14e445f4aa414a8e2

# ---------------------------------------------------------------- npm tarball sha1 (dist.shasum)
SHA1_markdown_it=dc199771f75b01d792316e5b524855b3973868e2
SHA1_mdit_footnote=02ede0cb68a42d7e7774c3abdc72d77aaa24c531
SHA1_mdit_mark=c19cbc87d9cb9fd1a495e8fe31b740b6d9ebf8c8
SHA1_mdit_anchor=0df1665838d1003f234feed6e864ede30734c203
SHA1_github_slugger=52cf2f9279a21eb6c59dd385b410f0c0adda8f1a
SHA1_katex=0a13a42c2deb4f74e61f162d440b9165a548030f
SHA1_pseudocode=603be2a345786dd56af3411bd240627dac5f3ac0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/Resources/web"
VENDOR="$WEB/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

fetch_tgz() { # name version expected_sha1 -> extracts to $TMP/<name>/package
  local name="$1" ver="$2" want="$3"
  local url="https://registry.npmjs.org/${name}/-/${name}-${ver}.tgz"
  local out="$TMP/${name}-${ver}.tgz"
  log "fetch ${name}@${ver}"
  curl -fsSL "$url" -o "$out" || die "download failed: $url"
  local got; got="$(shasum -a 1 "$out" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "sha1 mismatch for ${name}@${ver}: got $got want $want"
  mkdir -p "$TMP/$name"
  tar xzf "$out" -C "$TMP/$name"
}

if [ "${1:-}" = "--check" ]; then
  log "verifying installed vendor tree"
  [ -f "$VENDOR/pseudocode/pseudocode.js" ] || die "missing $VENDOR/pseudocode/pseudocode.js"
  got="$(shasum -a 256 "$VENDOR/pseudocode/pseudocode.js" | cut -d' ' -f1)"
  [ "$got" = "$PSEUDOCODE_JS_SHA256" ] || die "pseudocode.js checksum drift ($got)"
  n="$(ls "$VENDOR/katex/fonts"/*.woff2 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "20" ] || die "expected 20 KaTeX woff2 fonts, found $n"
  grep -q 'url(fonts/KaTeX_Main-Regular.woff2)' "$VENDOR/katex/katex.min.css" || die "katex.min.css lost its relative font paths"
  log "OK"
  exit 0
fi

rm -rf "$VENDOR"
mkdir -p "$VENDOR/markdown-it" "$VENDOR/katex/fonts" "$VENDOR/pseudocode"

# ---------------------------------------------------------------- markdown-it core + plugins
fetch_tgz markdown-it          "$MARKDOWN_IT_VER"   "$SHA1_markdown_it"
fetch_tgz markdown-it-footnote "$MDIT_FOOTNOTE_VER" "$SHA1_mdit_footnote"
fetch_tgz markdown-it-mark     "$MDIT_MARK_VER"     "$SHA1_mdit_mark"
fetch_tgz markdown-it-anchor   "$MDIT_ANCHOR_VER"   "$SHA1_mdit_anchor"
fetch_tgz github-slugger       "$GITHUB_SLUGGER_VER" "$SHA1_github_slugger"

cp "$TMP/markdown-it/package/dist/browser/markdown-it.umd.min.js"       "$VENDOR/markdown-it/"
cp "$TMP/markdown-it-footnote/package/dist/markdown-it-footnote.min.js" "$VENDOR/markdown-it/"
cp "$TMP/markdown-it-mark/package/dist/markdown-it-mark.min.js"         "$VENDOR/markdown-it/"
cp "$TMP/markdown-it/package/LICENSE"          "$VENDOR/markdown-it/LICENSE.markdown-it"
cp "$TMP/markdown-it-footnote/package/LICENSE" "$VENDOR/markdown-it/LICENSE.markdown-it-footnote"
cp "$TMP/markdown-it-mark/package/LICENSE"     "$VENDOR/markdown-it/LICENSE.markdown-it-mark"
cp "$TMP/markdown-it-anchor/package/dist/markdownItAnchor.umd.js" "$VENDOR/markdown-it/"
cp "$TMP/markdown-it-anchor/package/UNLICENSE" "$VENDOR/markdown-it/UNLICENSE.markdown-it-anchor"

# github-slugger is ESM-only (2 files, no deps). Emit a UMD shim -- no bundler,
# just string surgery, so the vendored file is auditable line-by-line against
# the npm source. Heading ids MUST match Quartz's rehype-slug, which uses this
# exact package.
log "shim github-slugger -> UMD"
node -e '
  const fs = require("fs");
  const dir = process.argv[1], out = process.argv[2];
  const regex = fs.readFileSync(dir + "/regex.js", "utf8")
    .replace(/^\/\/.*$/gm, "")
    .replace(/\/\* eslint[\s\S]*?\*\//g, "")
    .replace("export const regex", "var regex").trim();
  const index = fs.readFileSync(dir + "/index.js", "utf8")
    .replace(/^import[^\n]*\n/m, "")
    .replace("export default class BananaSlug", "class GithubSlugger")
    .replace("export function slug", "function slug");
  fs.writeFileSync(out,
`/*! github-slugger 2.0.0 (MIT) - UMD shim generated by scripts/vendor-web.sh */
(function (root, factory) {
  if (typeof exports === "object" && typeof module !== "undefined") { module.exports = factory(); }
  else { root.GithubSlugger = factory(); }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
${regex}
${index}
GithubSlugger.slug = slug;
return GithubSlugger;
});
`);
' "$TMP/github-slugger/package" "$VENDOR/markdown-it/github-slugger.umd.js"
cp "$TMP/github-slugger/package/LICENSE" "$VENDOR/markdown-it/LICENSE.github-slugger"
node -e 'var G=require(process.argv[1]); var s=new G(); if (s.slug("CCA Security")!=="cca-security" || s.slug("Syntax")!=="syntax" || s.slug("Syntax")!=="syntax-1") { console.error("github-slugger shim self-test FAILED"); process.exit(1);} ' "$VENDOR/markdown-it/github-slugger.umd.js"

# ---------------------------------------------------------------- KaTeX
fetch_tgz katex "$KATEX_VER" "$SHA1_katex"
cp "$TMP/katex/package/dist/katex.min.js"  "$VENDOR/katex/"
cp "$TMP/katex/package/dist/katex.min.css" "$VENDOR/katex/"
cp "$TMP/katex/package/LICENSE"            "$VENDOR/katex/LICENSE"
# woff2 only: WebKit has supported woff2 since Safari 10; shipping woff+ttf too
# would add ~876 KB for formats that are never requested.
cp "$TMP/katex/package/dist/fonts/"*.woff2 "$VENDOR/katex/fonts/"
# Drop the woff/ttf fallbacks from the @font-face src lists so nothing can 404.
# katex.min.css references fonts as url(fonts/NAME.ext) RELATIVE TO ITSELF, so
# katex.min.css and fonts/ MUST stay siblings. Do not flatten this directory.
sed -i '' -E 's#,url\(fonts/[^)]+\.woff\) format\("woff"\),url\(fonts/[^)]+\.ttf\) format\("truetype"\)##g' \
  "$VENDOR/katex/katex.min.css"
grep -q '\.ttf' "$VENDOR/katex/katex.min.css" && die "ttf refs survived the sed; check katex CSS format"

# ---------------------------------------------------------------- pseudocode.js
# CSS from upstream npm; JS from the wiki's PATCHED fork.
fetch_tgz pseudocode "$PSEUDOCODE_VER" "$SHA1_pseudocode"
cp "$TMP/pseudocode/package/build/pseudocode.min.css" "$VENDOR/pseudocode/"
cp "$TMP/pseudocode/package/LICENSE"                  "$VENDOR/pseudocode/LICENSE" 2>/dev/null || true

log "fetch patched pseudocode.js from ${WIKI_REPO}@${WIKI_SHA:0:8}"
curl -fsSL "https://raw.githubusercontent.com/${WIKI_REPO}/${WIKI_SHA}/quartz/static/pseudocode.js" \
  -o "$VENDOR/pseudocode/pseudocode.js" || die "could not fetch patched pseudocode.js"
got="$(shasum -a 256 "$VENDOR/pseudocode/pseudocode.js" | cut -d' ' -f1)"
[ "$got" = "$PSEUDOCODE_JS_SHA256" ] || die "patched pseudocode.js sha256 mismatch: got $got"
grep -q 'algname' "$VENDOR/pseudocode/pseudocode.js" || die "vendored pseudocode.js has no \\algname support"

# ---------------------------------------------------------------- manifest
cat > "$VENDOR/VENDOR.txt" <<EOF
CityDesk vendored web assets — regenerate with scripts/vendor-web.sh
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

markdown-it            ${MARKDOWN_IT_VER}   MIT   dist/browser/markdown-it.umd.min.js  -> window.markdownit
markdown-it-footnote   ${MDIT_FOOTNOTE_VER}    MIT   dist/markdown-it-footnote.min.js     -> window.markdownitFootnote
markdown-it-mark       ${MDIT_MARK_VER}    MIT   dist/markdown-it-mark.min.js         -> window.markdownitMark
markdown-it-anchor     ${MDIT_ANCHOR_VER}    Unlicense dist/markdownItAnchor.umd.js         -> window.markdownItAnchor
github-slugger         ${GITHUB_SLUGGER_VER}    MIT   UMD shim (see script)                -> window.GithubSlugger
katex                  ${KATEX_VER}  MIT   dist/katex.min.{js,css} + 20 woff2    -> window.katex
pseudocode (css)       ${PSEUDOCODE_VER}    MIT   build/pseudocode.min.css
pseudocode (js)        PATCHED FORK from ${WIKI_REPO}@${WIKI_SHA}
                       quartz/static/pseudocode.js — adds \\algname{...};
                       sha256 ${PSEUDOCODE_JS_SHA256}   -> window.pseudocode
EOF

log "installed:"
find "$VENDOR" -type f | sed "s|$VENDOR/|  |" | sort
printf '\033[32m==>\033[0m total %s\n' "$(du -sh "$VENDOR" | cut -f1)"
