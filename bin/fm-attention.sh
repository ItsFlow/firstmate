#!/usr/bin/env bash
# fm-attention.sh - the single captain-facing place for open decisions and waits.
#
# Renders the captain-attention contract owned by bin/fm-attention-lib.sh, which
# derives the open set from data/backlog.md and state/*.status. This command
# parses no fleet state of its own.
#
# Every open item is exactly one of two things:
#   a decision - your answer is needed before the work can move;
#   a wait     - a meaningful delay that needs no captain action yet, shown with
#                what is being awaited and when it is next checked.
# Only an explicit action-required `needs-decision` or `blocked` status
# transition changes a wait into a captain decision.
#
# A turn-end adapter may pass the actual assistant reply to --record-visible.
# That mode validates the captain category, headline, and complete explanation
# before recording a receipt. Every rendering mode is read-only.
#
# The default view is captain-safe plain English under AGENTS.md section 9: it
# carries no internal identifiers or vocabulary and can be relayed as written.
# --brief is the firstmate-facing form and does carry identifiers, so it is a
# read-only diagnostic, never a captain-facing surface.
#
# Usage:
#   fm-attention.sh                 captain-facing view (read-only)
#   fm-attention.sh --brief         one line per item, with identifiers (read-only)
#   fm-attention.sh --json          the raw record array (read-only)
#   fm-attention.sh --status        counts and change flags (read-only)
#   fm-attention.sh --record-visible validate an assistant reply from stdin
#   fm-attention.sh --no-mark       compatibility alias for read-only rendering
#   fm-attention.sh -h | --help
#
# Exit status is 0 whenever the requested read or receipt succeeds.
# Exit 3 means the complete set could not be derived, and exit 4 means the
# supplied assistant reply did not contain the required visible records.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-attention-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-attention-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

MODE=view
while [ "$#" -gt 0 ]; do
  case "$1" in
    --brief) MODE=brief ;;
    --json) MODE=json ;;
    --status) MODE=status ;;
    --record-visible) MODE=record-visible ;;
    --no-mark) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

fm_attention_status "$FM_HOME"

render_unknown() {
  printf "CAPTAIN'S CALL\n"
  printf 'I could not determine whether anything needs your decision or is waiting.\n'
  printf 'Treat this as unresolved until Firstmate can read the open decision and wait list.\n'
}

render_brief_unknown() {
  printf "CAPTAIN'S CALL: unknown - the open decision and wait list could not be determined.\n"
}

if [ "$FM_ATT_AVAILABLE" != true ]; then
  case "$MODE" in
    json)
      printf '%s\n' "$FM_ATT_JSON"
      ;;
    status)
      printf 'attention=unknown decisions=unknown waits=unknown new=true decisions_new=true unknown=true\n'
      ;;
    brief)
      render_brief_unknown
      ;;
    *)
      render_unknown
      ;;
  esac
  exit 3
fi

record_visible() {
  local message seen_att seen_dec wrote=0
  message=$(cat 2>/dev/null || true)
  seen_att=$(sed -n 's/^attention=//p' "$STATE/.captain-attention" 2>/dev/null | tail -1 || true)
  seen_dec=$(sed -n 's/^decisions=//p' "$STATE/.captain-attention" 2>/dev/null | tail -1 || true)
  if fm_attention_message_covers "$message" all; then
    seen_att=$FM_ATT_DIGEST
    wrote=1
  fi
  if [ "$FM_ATT_DECISIONS" -gt 0 ] && fm_attention_message_covers "$message" decisions; then
    seen_dec=$FM_ATT_DECISION_DIGEST
    wrote=1
  fi
  [ "$wrote" -eq 1 ] || return 4
  [ -d "$STATE" ] || return 4
  printf 'attention=%s\ndecisions=%s\n' "$seen_att" "$seen_dec" > "$STATE/.captain-attention" 2>/dev/null || return 4
  rm -f "$STATE/.captain-attention-unknown" 2>/dev/null || true
  return 0
}

# Wrap free prose to a readable width under a fixed indent. Keeps a long
# recorded explanation readable instead of running off the line.
wrap() {  # <indent-spaces> <text>
  local indent=$1 text=$2
  printf '%s' "$text" | awk -v indent="$indent" -v width=78 '
    BEGIN { pad = sprintf("%" indent "s", "") }
    {
      n = split($0, w, /[ \t]+/)
      line = ""
      for (i = 1; i <= n; i++) {
        if (w[i] == "") continue
        if (line == "") { line = w[i]; continue }
        if (length(pad) + length(line) + 1 + length(w[i]) > width) {
          print pad line
          line = w[i]
        } else {
          line = line " " w[i]
        }
      }
      if (line != "") print pad line
    }'
}

# Wrap <text> at <indent>, then replace the first line's indent with <prefix>.
# The prefix must be exactly <indent> characters wide so continuation lines align
# under it ("1. " with indent 3, "- " with indent 2).
wrap_prefixed() {  # <prefix> <indent> <text>
  local prefix=$1 indent=$2 text=$3
  wrap "$indent" "$text" | awk -v prefix="$prefix" -v indent="$indent" '
    NR == 1 { print prefix substr($0, indent + 1); next }
    { print }'
}

count_phrase() {  # <n> <singular> <plural> <singular-verb> <plural-verb>
  if [ "$1" -eq 1 ]; then printf '%s %s %s' "$1" "$2" "$4"; else printf '%s %s %s' "$1" "$3" "$5"; fi
}

human_duration() {  # <seconds>
  local s=$1
  if [ "$s" -lt 0 ]; then printf 'unknown'; return 0; fi
  if [ "$s" -lt 90 ]; then printf 'under 2 minutes'; return 0; fi
  if [ "$s" -lt 5400 ]; then printf 'about %s minutes' "$(( (s + 30) / 60 ))"; return 0; fi
  if [ "$s" -lt 172800 ]; then printf 'about %s hours' "$(( (s + 1800) / 3600 ))"; return 0; fi
  printf 'about %s days' "$(( (s + 43200) / 86400 ))"
}

next_check_phrase() {  # <seconds>
  local s=$1
  case "$s" in ''|null) printf 'when the work it is waiting on finishes'; return 0 ;; esac
  if [ "$s" -lt 0 ]; then
    printf 'nothing is checking this right now, because monitoring is not running'
    return 0
  fi
  if [ "$s" -le 0 ]; then printf 'due now'; return 0; fi
  printf 'in %s' "$(human_duration "$s")"
}

field() {  # <index> <jq-path>
  printf '%s' "$FM_ATT_JSON" | jq -r --argjson i "$1" ".[\$i] | $2 // \"\"" 2>/dev/null
}

render_view() {
  local total=$FM_ATT_COUNT n=$FM_ATT_DECISIONS w=$FM_ATT_WAITS i num=0
  local class headline choice why cost recommend detail awaiting briefed next opts missing combined

  printf "CAPTAIN'S CALL\n"
  if [ "$total" -eq 0 ]; then
    printf 'Nothing needs your decision, and nothing is waiting.\n'
    return 0
  fi
  printf '%s you. %s waiting.\n' \
    "$(count_phrase "$n" decision decisions needs need)" \
    "$(count_phrase "$w" thing things "is" "are")"

  if [ "$n" -gt 0 ]; then
    printf '\nNEEDS YOUR DECISION\n'
    i=0
    while [ "$i" -lt "$total" ]; do
      class=$(field "$i" '.class')
      if [ "$class" != decision ]; then i=$((i + 1)); continue; fi
      num=$((num + 1))
      headline=$(field "$i" '.headline')
      briefed=$(field "$i" '.briefed')
      detail=$(field "$i" '.detail')
      combined=$(field "$i" '.combined_wait')
      printf '\n'
      wrap_prefixed "$(printf '%s. ' "$num")" 3 "$headline"
      if [ "$briefed" = true ]; then
        choice=$(field "$i" '.choice')
        why=$(field "$i" '.why_now')
        cost=$(field "$i" '.cost_of_waiting')
        recommend=$(field "$i" '.recommendation')
        [ -z "$choice" ] || { printf '   The choice:\n'; wrap 5 "$choice"; }
        [ -z "$why" ] || { printf '   Why it matters now:\n'; wrap 5 "$why"; }
        [ -z "$cost" ] || { printf '   If this waits:\n'; wrap 5 "$cost"; }
        opts=$(printf '%s' "$FM_ATT_JSON" | jq -r --argjson i "$i" '.[$i].options[]?' 2>/dev/null)
        if [ -n "$opts" ]; then
          printf '   Options:\n'
          while IFS= read -r opt; do
            [ -n "$opt" ] || continue
            wrap_prefixed '     - ' 7 "$opt"
          done <<EOF
$opts
EOF
        fi
        [ -z "$recommend" ] || { printf '   Recommended:\n'; wrap 5 "$recommend"; }
        missing=$(printf '%s' "$FM_ATT_JSON" | jq -r --argjson i "$i" '.[$i].briefing_missing[]?' 2>/dev/null)
        if [ -n "$missing" ]; then
          printf '   Still needs:\n'
          while IFS= read -r missing; do
            [ -n "$missing" ] || continue
            wrap_prefixed '     - ' 7 "$missing"
          done <<EOF
$missing
EOF
        fi
      else
        printf '   No plain-language explanation has been written for this one yet.\n'
        printf '   What was recorded:\n'
        wrap 5 "$detail"
      fi
      if [ "$combined" = true ]; then
        awaiting=$(field "$i" '.awaiting')
        next=$(printf '%s' "$FM_ATT_JSON" | jq -r --argjson i "$i" '.[$i].next_check_seconds // "null"' 2>/dev/null)
        printf '   Waiting for:\n'
        wrap 5 "$awaiting"
        printf '   Next check: %s\n' "$(next_check_phrase "$next")"
      fi
      i=$((i + 1))
    done
  fi

  if [ "$w" -gt 0 ]; then
    printf '\nWAITING ON SOMETHING ELSE\n'
    i=0
    while [ "$i" -lt "$total" ]; do
      class=$(field "$i" '.class')
      if [ "$class" != wait ]; then i=$((i + 1)); continue; fi
      headline=$(field "$i" '.headline')
      awaiting=$(field "$i" '.awaiting')
      next=$(printf '%s' "$FM_ATT_JSON" | jq -r --argjson i "$i" '.[$i].next_check_seconds // "null"' 2>/dev/null)
      printf '\n'
      wrap_prefixed '- ' 2 "$headline"
      printf '  Waiting for:\n'
      wrap 4 "$awaiting"
      printf '  Next check: %s\n' "$(next_check_phrase "$next")"
      i=$((i + 1))
    done
  fi
  printf '\nEverything above stays listed here until it is answered or clears.\n'
}

render_brief() {
  local total=$FM_ATT_COUNT i class id headline complete next mark
  if [ "$total" -eq 0 ]; then
    printf "CAPTAIN'S CALL: nothing open.\n"
    return 0
  fi
  printf "CAPTAIN'S CALL: %s decision(s) need the captain, %s wait(s) open.\n" \
    "$FM_ATT_DECISIONS" "$FM_ATT_WAITS"
  i=0
  while [ "$i" -lt "$total" ]; do
    class=$(field "$i" '.class')
    id=$(field "$i" '.id')
    headline=$(field "$i" '.headline')
    complete=$(field "$i" '.briefing_complete')
    mark=''
    if [ "$class" = decision ]; then
      if [ "$complete" != true ]; then
        mark=' [no captain briefing recorded - add one with bin/fm-decision-hold.sh hold]'
      fi
    else
      next=$(printf '%s' "$FM_ATT_JSON" | jq -r --argjson i "$i" '.[$i].next_check_seconds // "null"' 2>/dev/null)
      mark=" [next check: $(next_check_phrase "$next")]"
    fi
    printf '  %-8s %s - %.90s%s\n' "$class" "$id" "$headline" "$mark"
    i=$((i + 1))
  done
  printf '  Relay these to the captain in plain language: bin/fm-attention.sh\n'
}

case "$MODE" in
  record-visible)
    record_visible
    exit $?
    ;;
  json)
    printf '%s\n' "$FM_ATT_JSON"
    ;;
  status)
    printf 'attention=%s decisions=%s waits=%s new=%s decisions_new=%s\n' \
      "$FM_ATT_COUNT" "$FM_ATT_DECISIONS" "$FM_ATT_WAITS" "$FM_ATT_NEW" "$FM_ATT_DECISIONS_NEW"
    ;;
  brief)
    render_brief
    ;;
  *)
    render_view
    ;;
esac
exit 0
