#!/usr/bin/env bash
# fm-inbox-view.sh - the captain's decision-and-review board, written as one HTML page.
#
# This command is a READ-ONLY projection, in the same shape as fm-fleet-view.sh.
# It shells out to fm-fleet-snapshot.sh --json for fleet state and to
# `tasks-axi show <id> --full` for untruncated captain-hold text, then writes one
# self-contained HTML file through bin/fm-inbox-render.py.
# It never writes under state/ or data/, never acquires the session lock, never
# drains wakes, and never mutates the backlog. tests/fm-inbox-view.test.sh proves
# the no-mutation guarantee against a fixture home.
#
# The board is served with lavish-axi so the captain can answer decisions in the
# browser. Serving, answer relay, and escalation policy are NOT this script's
# job; it only produces the surface.
#
# Usage:
#   fm-inbox-view.sh [<output.html>]
#   fm-inbox-view.sh [options] [<output.html>]
#   fm-inbox-view.sh --help
#
# Output path defaults to $HOME/lavish-boards/inbox/board.html, the stable
# bookmarkable topic path. Any other path is written as given; parent
# directories are created. The file is written atomically.
#
# Options:
#   --cards <path>    plain-English decision cards to merge in (see below).
#                     Default: $FM_HOME/data/inbox-cards.md when it exists.
#   --verify-prs      live-check every recorded pull request with
#                     `gh pr view <url> --json state`. Without it, every
#                     recorded PR is rendered as UNVERIFIED, because locally
#                     recorded metadata cannot know a PR was closed.
#   --snapshot <path> render a previously captured fm-fleet-snapshot.sh --json
#                     document instead of running a fresh one (tests, replay).
#   --no-full-text    skip the per-decision `tasks-axi show --full` reads and
#                     accept the snapshot's truncated hold text.
#
# Decision cards file (--cards), optional and captain-private:
#   Snapshot metadata alone describes a decision in firstmate's own vocabulary,
#   which is not answerable by the captain. This file carries the plain-English
#   half. It is keyed by decision id and every field is optional; a decision with
#   no entry still renders, marked as having no plain-English summary yet.
#
#     ## <decision-id>
#     ### question
#     The decision, as a plain question.
#     ### plain
#     One or two sentences: what the captain is actually choosing.
#     ### why
#     Where this came from and what triggered it.
#     ### take
#     Firstmate's recommendation, in plain terms.
#     ### link
#     https://example.invalid/product-page
#     ### options
#     - First answer
#     - Second answer
#     ### expand
#     Technical detail, shown only when the captain expands the card.
#     ### flag
#     Firstmate assumed this because ...; accept it or drop it.
#
#   Use `flag` when the item is an assumption an investigation made rather than
#   a choice the captain ever made. It renders as an explicit callout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RENDERER="$SCRIPT_DIR/fm-inbox-render.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-inbox-view: %s\n' "$1" >&2
  exit "${2:-1}"
}

OUT=
CARDS=
SNAPSHOT_IN=
VERIFY_PRS=0
FULL_TEXT=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cards)
      [ "$#" -ge 2 ] || die "--cards requires a path" 2
      CARDS=$2; shift 2 ;;
    --snapshot)
      [ "$#" -ge 2 ] || die "--snapshot requires a path" 2
      SNAPSHOT_IN=$2; shift 2 ;;
    --verify-prs) VERIFY_PRS=1; shift ;;
    --no-full-text) FULL_TEXT=0; shift ;;
    --) shift; break ;;
    -*) usage >&2; exit 2 ;;
    *)
      [ -z "$OUT" ] || die "only one output path is accepted" 2
      OUT=$1; shift ;;
  esac
done
if [ "$#" -gt 0 ]; then
  [ -z "$OUT" ] || die "only one output path is accepted" 2
  OUT=$1
fi

[ -n "$OUT" ] || OUT="${HOME:-/tmp}/lavish-boards/inbox/board.html"
[ -f "$RENDERER" ] || die "renderer is missing: $RENDERER"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

if [ -z "$CARDS" ] && [ -f "$DATA/inbox-cards.md" ]; then
  CARDS="$DATA/inbox-cards.md"
fi
if [ -n "$CARDS" ] && [ ! -f "$CARDS" ]; then
  die "decision cards file not found: $CARDS"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-view.XXXXXX") || die "cannot create a work directory"
trap '[ -z "${TMP:-}" ] || rm -rf -- "$TMP"' EXIT HUP INT TERM

SNAPSHOT="$TMP/snapshot.json"
if [ -n "$SNAPSHOT_IN" ]; then
  [ -f "$SNAPSHOT_IN" ] || die "snapshot file not found: $SNAPSHOT_IN"
  cat -- "$SNAPSHOT_IN" > "$SNAPSHOT" || die "cannot read snapshot: $SNAPSHOT_IN"
else
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$SNAPSHOT" || die "fleet snapshot failed"
fi

# Untruncated captain-hold text. fm-fleet-snapshot's metadata capture no longer
# stops at the first comma, but its aggregated output still length-caps a hold
# reason and carries no body at all, so the durable captain briefing written by
# fm-decision-hold.sh is unreachable from the snapshot alone; tasks-axi is the
# authority for the full text.
FULLDIR="$TMP/full"
mkdir -p "$FULLDIR"
if [ "$FULL_TEXT" -eq 1 ] && command -v tasks-axi >/dev/null 2>&1; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*|.*) continue ;;
    esac
    (cd "$FM_HOME" && tasks-axi show "$id" --full) > "$FULLDIR/$id.txt" 2>/dev/null \
      || rm -f -- "$FULLDIR/$id.txt"
  done < <(python3 "$RENDERER" --decision-ids --snapshot "$SNAPSHOT")
fi

# Recorded PR metadata cannot know a PR was closed. Verification is opt-in, and
# an unverified PR is rendered as unverified rather than as ready to merge.
PRSTATE="$TMP/pr-state.tsv"
: > "$PRSTATE"
if [ "$VERIFY_PRS" -eq 1 ]; then
  if command -v gh >/dev/null 2>&1; then
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || state=
      [ -n "$state" ] || state=unknown
      printf '%s\t%s\n' "$url" "$state" >> "$PRSTATE"
    done < <(python3 "$RENDERER" --pr-urls --snapshot "$SNAPSHOT")
  else
    printf 'fm-inbox-view: gh not found, pull requests stay unverified\n' >&2
    VERIFY_PRS=0
  fi
fi

OUT_DIR=$(dirname -- "$OUT")
mkdir -p -- "$OUT_DIR" || die "cannot create output directory: $OUT_DIR"
# Render beside the destination so the publish is one same-filesystem rename:
# an open board never sees a half-written page, and a failed render leaves the
# previous board untouched.
TMP_OUT=$(mktemp "$OUT_DIR/.fm-inbox-board.XXXXXX") || die "cannot stage the board"
trap '[ -z "${TMP:-}" ] || rm -rf -- "$TMP"; [ -z "${TMP_OUT:-}" ] || rm -f -- "$TMP_OUT"' \
  EXIT HUP INT TERM

python3 "$RENDERER" \
  --snapshot "$SNAPSHOT" \
  --full-text-dir "$FULLDIR" \
  --cards "$CARDS" \
  --pr-state "$PRSTATE" \
  --pr-verified "$VERIFY_PRS" \
  --home "$FM_HOME" \
  --out "$TMP_OUT" || die "render failed"

# BSD chmod has no `--`, so the staged name is generated by mktemp and never
# starts with a dash.
chmod 0644 "$TMP_OUT" || die "cannot set board permissions"
mv -f -- "$TMP_OUT" "$OUT" || die "cannot write board: $OUT"
TMP_OUT=
printf 'wrote %s\n' "$OUT"
