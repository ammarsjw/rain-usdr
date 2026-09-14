#!/usr/bin/env bash
#
# wrap_comments.sh - Hard-wrap `//` and /* */ comments in Solidity/JS/TS files.
#
# cli - bash ./scripts/bash/wrap_comments.sh contracts/**/*.sol
#
# Usage:
#   ./wrap_comments.sh FILE [FILE ...]
#   ./wrap_comments.sh -w 115 contracts/*.sol scripts/*.js
#   ./wrap_comments.sh contracts            # directories are searched recursively
#   ./wrap_comments.sh 'tests/**/*.sol'     # QUOTED globs are expanded here with globstar:
#                                           # '**' spans any depth incl. zero, so this matches
#                                           # tests/*.sol AND tests/**/*.t.sol in one pattern
#
# NOTE on unquoted `tests/**/*.sol`: the INVOKING shell expands it before this script runs.
# In bash without `shopt -s globstar` (and in sh), `**` degrades to `*`, so it expands to
# tests/*/*.sol only — subdirectories, NOT the top-level tests/*.t.sol files. Either quote the
# pattern (preferred), or pass the extra pattern explicitly:
#   bash scripts/bash/wrap_comments.sh tests/**/*.sol tests/**/*.t.sol
# The second pattern matches nothing in a non-globstar shell, arrives here literally, and is
# expanded below with globstar — so the pair covers everything in either kind of shell.
#
#   -w WIDTH   Column width to wrap to (default: 120, matching repo convention)
#   -p         Print result to stdout instead of editing the file in place
#   -f         Force reflow: re-fill EVERY paragraph to the width, including
#              ones that already fit. Use this to WIDEN lines after a previous
#              run at a narrower width (e.g. tried -w 100, now want -w 110).
#              Caution: discards deliberate mid-paragraph line breaks.
#
# Design: CONSERVATIVE by default. A comment paragraph whose lines already fit
# the width is left byte-for-byte untouched. Only paragraphs containing at
# least one overlong line are rewrapped. This preserves deliberate hand-crafted
# line breaks. Default wrapping is therefore one-way (never widens); use -f to
# re-fill to a wider width.
#
# Behavior:
#   - Files are edited IN PLACE by default; a file is only rewritten when its
#     content actually changes.
#   - NatSpec tags (@notice, @dev, @param, @return, ...) start a paragraph.
#     Rewrapped continuation lines get a hanging indent aligned under the text
#     following the tag (repo convention):
#         * @notice The emergency settlement module. When governance pulls
#         *         the plug, this contract freezes the system.
#   - Numbered list items (1. / 2) style) and dash bullets (- item) inside a
#     comment start their own paragraph; continuations align after the number:
#         *      3. `skip(ilkId, id)` - reclaim in-flight auctions into the
#         *         vaults they were seized from.
#   - Inline code spans in backticks (`tab / rate`, `art * rate * tag`) are
#     atomic: they are never split across lines. If a span does not fit on the
#     current line it moves whole to the next line.
#   - Table rows (| ...) are never reflowed, even when overlong.
#   - `///` and `//` markers are preserved exactly; /// never becomes "// /",
#     and adjacent /// and // runs are not merged.
#   - Divider/banner comments (/* ==== NAME ==== */, //////////, ----) are
#     untouched.
#   - Code lines and inline trailing comments (code; // comment) are untouched.

set -euo pipefail

# Expand '**' across any depth (including zero directories) in patterns that reach this script
# unexpanded — i.e. quoted globs, or globs the invoking shell failed to match and passed through.
shopt -s globstar

WIDTH=110
PRINT_STDOUT=0
FORCE=0

usage() { echo "Usage: $0 [-w WIDTH] [-p] [-f] FILE [FILE ...]" >&2; exit 1; }

while getopts "w:pf" opt; do
  case "$opt" in
    w) WIDTH="$OPTARG" ;;
    p) PRINT_STDOUT=1 ;;
    f) FORCE=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[ "$#" -eq 0 ] && usage

AWK_PROGRAM='
{ lines[NR] = $0 }

END {
  n = NR
  i = 1
  while (i <= n) {
    line = lines[i]
    if (isDivider(line)) {
      print line
      i++
    } else if (line ~ /^[ \t]*\/\//) {
      # ---- run of consecutive // (or ///) comment lines ----
      delete cOrig; delete cText; cc = 0
      runMarker = ""; runIndent = ""
      while (i <= n && lines[i] ~ /^[ \t]*\/\// && !isDivider(lines[i])) {
        match(lines[i], /^[ \t]*/)
        ind = substr(lines[i], RSTART, RLENGTH)
        rest = substr(lines[i], RLENGTH + 1)
        match(rest, /^\/+/)
        marker = substr(rest, 1, RLENGTH)          # "//", "///", ...
        if (cc > 0 && marker != runMarker) break   # do not merge // with ///
        runMarker = marker; runIndent = ind
        content = substr(rest, RLENGTH + 1)
        sub(/^ /, "", content)                     # one separator space only
        cc++
        cOrig[cc] = lines[i]
        cText[cc] = content
        i++
      }
      emitComment(cOrig, cText, cc, runIndent, runMarker " ", 1)
    } else if (line ~ /^[ \t]*\/\*/) {
      # ---- block comment ----
      delete blk; bc = 0
      bc++; blk[bc] = lines[i]
      hasClose = (lines[i] ~ /\*\//)
      i++
      if (!hasClose) {
        while (i <= n && lines[i] !~ /\*\//) { bc++; blk[bc] = lines[i]; i++ }
        if (i <= n) { bc++; blk[bc] = lines[i]; i++ }
      }
      handleBlock(blk, bc)
    } else {
      print line
      i++
    }
  }
}

# Divider/banner: a run of 6+ identical punctuation chars.
function isDivider(s) {
  return (s ~ /\/\/\/\/\/\//) || (s ~ /------/) || (s ~ /======/) || \
         (s ~ /\*\*\*\*\*\*/) || (s ~ /######/) || (s ~ /~~~~~~/)
}

function handleBlock(blk, bc,    j, ind, isDoc, fitsAll, s, cc, cOrig, cText) {
  # Divider anywhere -> whole block verbatim.
  for (j = 1; j <= bc; j++) if (isDivider(blk[j])) { for (j = 1; j <= bc; j++) print blk[j]; return }
  # Everything fits -> verbatim (preserves one-liners, custom framing, all
  # breaks). Skipped in force mode: -f re-fills even conforming blocks.
  # One-line blocks that fit stay verbatim even under -f (nothing to widen).
  if (bc == 1 && length(blk[1]) <= width) { print blk[1]; return }
  if (!force) {
    fitsAll = 1
    for (j = 1; j <= bc; j++) if (length(blk[j]) > width) { fitsAll = 0; break }
    if (fitsAll) { for (j = 1; j <= bc; j++) print blk[j]; return }
  }

  match(blk[1], /^[ \t]*/)
  ind = substr(blk[1], RSTART, RLENGTH)
  isDoc = (blk[1] ~ /^[ \t]*\/\*\*/)

  # Extract inner content lines; keep originals for conservative emission.
  cc = 0; delete cOrig; delete cText
  s = blk[1]
  sub(/^[ \t]*\/\*\*?/, "", s)
  if (bc == 1) sub(/\*\/[ \t]*$/, "", s)
  sub(/^ /, "", s)
  sub(/[ \t]+$/, "", s)
  if (s != "") { cc++; cText[cc] = s; cOrig[cc] = ind " * " s }   # canonical orig (framing moved off)
  for (j = 2; j < bc; j++) {
    s = blk[j]
    sub(/[ \t]+$/, "", s)
    if (s ~ /^[ \t]*\*/) { sub(/^[ \t]*\*/, "", s); sub(/^ /, "", s) }
    else sub(/^[ \t]*/, "", s)
    cc++; cText[cc] = s; cOrig[cc] = blk[j]
  }
  if (bc > 1) {
    s = blk[bc]
    sub(/\*\/[ \t]*$/, "", s)
    sub(/[ \t]+$/, "", s)
    if (s ~ /^[ \t]*\*/) { sub(/^[ \t]*\*/, "", s); sub(/^ /, "", s) }
    else sub(/^[ \t]*/, "", s)
    if (s != "") { cc++; cText[cc] = s; cOrig[cc] = ind " * " s }
  }

  print ind (isDoc ? "/**" : "/*")
  emitComment(cOrig, cText, cc, ind, " * ", 0)
  print ind " */"
}

# Core paragraph engine, shared by // runs and block comments.
#   cOrig[]  original source lines (printed verbatim when a paragraph fits)
#   cText[]  content with marker stripped, internal indentation preserved
#   prefix   e.g. "// ", "/// ", " * "
#   markerOnly: 1 when a blank content line should print indent+trimmed marker
# Paragraph kinds and alignment:
#   tag  : starts with @word; start col 0, continuation col = len("@word ")
#   item : numbered ("3. ", "4) ") or bullet ("- "); start col = own indent,
#          continuation col = indent + marker length
#   plain: anything else; start col = own indent, continuation col = same
function emitComment(cOrig, cText, cc, ind, prefix, markerOnly,
                     j, t, lead, pOrig, pText, pc, pStart, pCont, pFits, pk, mlen, blank) {
  pc = 0; pText = ""; pk = ""
  for (j = 1; j <= cc; j++) {
    t = cText[j]
    match(t, /^ */)
    lead = RLENGTH
    sub(/^ +/, "", t)
    sub(/[ \t]+$/, "", t)
    if (t == "") {
      flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix)
      pc = 0; pText = ""; pk = ""
      if (markerOnly) { blank = ind prefix; sub(/ +$/, "", blank); print blank }
      else print ind " *"
    } else if (t ~ /^\|/) {
      # Table row: always verbatim.
      flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix)
      pc = 0; pText = ""; pk = ""
      print cOrig[j]
    } else if (t ~ /^@[A-Za-z]/) {
      flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix)
      pc = 1; pOrig[1] = cOrig[j]; pText = t; pk = "tag"
      pStart = 0
      pCont = (match(t, /^@[A-Za-z0-9]+ /)) ? RLENGTH : 0
      pFits = (length(cOrig[j]) <= width)
    } else if (match(cText[j], /^ *[0-9]+[.)] /) || match(cText[j], /^ *[-*+] /)) {
      mlen = RLENGTH                       # includes leading indent
      flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix)
      pc = 1; pOrig[1] = cOrig[j]; pText = t; pk = "item"
      pStart = lead
      pCont = mlen
      pFits = (length(cOrig[j]) <= width)
    } else if (pc > 0 && (lead == pCont || (lead == 0 && pk == "tag"))) {
      # Continuation of the open paragraph.
      pc++; pOrig[pc] = cOrig[j]
      pText = pText " " t
      if (length(cOrig[j]) > width) pFits = 0
    } else {
      flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix)
      pc = 1; pOrig[1] = cOrig[j]; pText = t; pk = "plain"
      pStart = lead
      pCont = lead
      pFits = (length(cOrig[j]) <= width)
    }
  }
  flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix)
}

function flushP(pOrig, pc, pText, pStart, pCont, pFits, ind, prefix,
                k, w1, w2, wrapped, wc, s1, s2) {
  if (pc == 0) return
  if (pFits && !force) {
    # Conservative path: paragraph already conforms; keep it byte-for-byte.
    for (k = 1; k <= pc; k++) print pOrig[k]
    return
  }
  gsub(/[ \t]+/, " ", pText)
  s1 = spaces(pStart); s2 = spaces(pCont)
  w1 = width - length(ind) - length(prefix) - pStart
  w2 = width - length(ind) - length(prefix) - pCont
  wc = wrap2(pText, w1, w2, wrapped)
  for (k = 1; k <= wc; k++) print ind prefix (k == 1 ? s1 : s2) wrapped[k]
}

function spaces(m,    r, q) { r = ""; for (q = 1; q <= m; q++) r = r " "; return r }

# Count backticks in a string.
function tickCount(s,    c, p) {
  c = 0
  for (p = 1; p <= length(s); p++) if (substr(s, p, 1) == "`") c++
  return c
}

# Greedy wrap: first line budget w1, continuation budget w2.
# Words are first merged into atoms: a backtick span (`...`) plus any words
# inside it forms one atom, so inline code is never split across lines.
function wrap2(text, w1, w2, outArr,    cnt, words, atoms, ac, open, i2, cand, cur, wc, limit) {
  # ---- tokenize into atoms ----
  cnt = split(text, words, / /)
  ac = 0; open = 0
  for (i2 = 1; i2 <= cnt; i2++) {
    if (words[i2] == "") continue
    if (open) {
      atoms[ac] = atoms[ac] " " words[i2]
    } else {
      ac++; atoms[ac] = words[i2]
    }
    if (tickCount(words[i2]) % 2 == 1) open = !open
  }
  # ---- greedy wrap over atoms ----
  wc = 0
  cur = ""
  limit = w1
  for (i2 = 1; i2 <= ac; i2++) {
    cand = (cur == "") ? atoms[i2] : cur " " atoms[i2]
    if (length(cand) > limit && cur != "") {
      wc++; outArr[wc] = cur
      cur = atoms[i2]
      limit = w2
    } else {
      cur = cand
    }
  }
  if (cur != "") { wc++; outArr[wc] = cur }
  return wc
}
'

# Build the file list: files pass through, directories are searched recursively,
# unmatched glob patterns (e.g. a quoted "contracts/*.sol") are expanded here.
FILES=()
status=0
for arg in "$@"; do
  if [ -f "$arg" ]; then
    FILES+=("$arg")
  elif [ -d "$arg" ]; then
    while IFS= read -r f; do FILES+=("$f"); done \
      < <(find "$arg" -type f \( -name '*.sol' -o -name '*.js' -o -name '*.ts' -o -name '*.vy' \) | sort)
  else
    matched=0
    while IFS= read -r f; do
      [ -f "$f" ] && { FILES+=("$f"); matched=1; }
    done < <(compgen -G "$arg" || true)
    if [ "$matched" -eq 0 ]; then
      echo "No such file, directory, or matching pattern: $arg" >&2
      status=1
    fi
  fi
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "Nothing to do." >&2
  exit "$status"
fi

for file in "${FILES[@]}"; do
  if [ "$PRINT_STDOUT" -eq 1 ]; then
    awk -v width="$WIDTH" -v force="$FORCE" "$AWK_PROGRAM" "$file"
  else
    tmp="$(mktemp)"
    awk -v width="$WIDTH" -v force="$FORCE" "$AWK_PROGRAM" "$file" > "$tmp"
    if cmp -s "$tmp" "$file"; then
      rm -f "$tmp"
      echo "Unchanged: $file" >&2
    else
      mv "$tmp" "$file"
      echo "Wrapped:   $file" >&2
    fi
  fi
done
exit "$status"
