#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# `origin` is always the authoritative runnable and routine-push repository.
# A fork-based installation may also configure a fetch-only `upstream` remote.
# This script fetches that remote and reports whether origin already contains
# its default branch, is simply behind it, or has diverged from it. It never
# advances from upstream directly: upstream changes first enter origin through
# a reviewed intake PR, then this updater installs the resulting origin commit.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

report_upstream_intake() {
  local origin_default upstream_ref upstream_default counts fork_only upstream_only

  if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
    echo "upstream-intake: not configured"
    return 0
  fi
  if ! git -C "$FM_ROOT" fetch upstream --prune --quiet 2>/dev/null; then
    echo "upstream-intake: skipped: upstream fetch failed"
    return 0
  fi

  origin_default=$(default_branch "$FM_ROOT") || {
    echo "upstream-intake: skipped: cannot determine origin default branch"
    return 0
  }
  upstream_ref=$(git -C "$FM_ROOT" symbolic-ref --quiet --short refs/remotes/upstream/HEAD 2>/dev/null || true)
  upstream_default=${upstream_ref#upstream/}
  if [ -z "$upstream_default" ]; then
    upstream_default=$origin_default
  fi
  if ! git -C "$FM_ROOT" rev-parse --verify --quiet "origin/$origin_default^{commit}" >/dev/null; then
    echo "upstream-intake: skipped: origin/$origin_default does not exist"
    return 0
  fi
  if ! git -C "$FM_ROOT" rev-parse --verify --quiet "upstream/$upstream_default^{commit}" >/dev/null; then
    echo "upstream-intake: skipped: upstream/$upstream_default does not exist"
    return 0
  fi

  counts=$(git -C "$FM_ROOT" rev-list --left-right --count \
    "origin/$origin_default...upstream/$upstream_default" 2>/dev/null) || {
    echo "upstream-intake: skipped: cannot compare origin and upstream"
    return 0
  }
  read -r fork_only upstream_only <<< "$counts"

  if [ "$upstream_only" -eq 0 ]; then
    echo "upstream-intake: current (origin/$origin_default contains upstream/$upstream_default)"
  elif [ "$fork_only" -eq 0 ]; then
    echo "upstream-intake: pending: origin/$origin_default is $upstream_only commit(s) behind upstream/$upstream_default; open a reviewed intake PR into origin before rerunning"
  else
    echo "upstream-intake: pending: origin/$origin_default and upstream/$upstream_default diverged ($fork_only fork-only, $upstream_only upstream-only); open a reviewed intake PR into origin before rerunning"
  fi
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi
report_upstream_intake

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
