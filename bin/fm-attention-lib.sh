# shellcheck shell=bash
# fm-attention-lib.sh - the single owner of firstmate's captain-attention contract.
# Usage: . bin/fm-attention-lib.sh
#
# WHY THIS EXISTS
# Firstmate could stop on a decision or an external delay without the captain
# ever receiving a self-contained explanation of what was needed, why it
# mattered, or what would happen next. Three separate mechanisms each dropped
# that information:
#   1. a captain decision was recorded as a one-line title plus a one-line
#      reason, so every renderer could only truncate it - there was nowhere
#      durable to put the concrete choice, the consequence of waiting, the
#      options, or the recommendation;
#   2. a declared external wait was deliberately excluded from the
#      captain-relevant verb set (bin/fm-classify-lib.sh), which correctly stops
#      wedge-nagging an idle pane but also removed the wait from every
#      captain-facing surface, so a wait that never cleared looked identical to
#      one that was about to;
#   3. supervision counted only state/<id>.meta, so a home whose only live work
#      was an unanswered decision or a standing wait reported as idle.
# This library replaces all three with ONE derived, read-only contract over
# state firstmate already keeps durably, so nothing here is a second status
# surface: it re-reads the backlog and the status event logs and says what is
# open right now.
#
# WHAT AN ATTENTION RECORD IS
# Exactly two classes, and every open item is exactly one of them:
#   decision - the captain's own answer is needed before the work can move.
#   wait     - a meaningful delay that needs no captain action yet, including a
#              declared external delay or backlog work held on another blocker.
#              The captain is still owed what is being awaited and when it is
#              next checked.
# A status-log wait that has been re-declared FM_ATTENTION_WAIT_REDECLARES times
# (default 3) without ever resolving is escalated to a decision, because a delay
# that keeps repeating is by definition no longer clearing on its own. That
# escalation is derived from the keyed event fold, never from reading the prose
# of the wait, so it cannot false-positive on wording.
#
# IDENTITY AND DEDUPLICATION
# Every record carries a stable, TEXT-FREE identity:
#   decision:<hold-id>            a captain-held backlog item
#   decision:<task-id>:<key>:<generation>  an open keyed status decision
#   wait:<task-id>:<key>:<generation>      an open keyed status wait
#   wait:<backlog-id>             a held backlog row waiting on other work
# Identities exclude all prose deliberately: a wait re-declared hourly with
# slightly different wording keeps ONE identity while it stays open, so a
# standing delay is surfaced once rather than every hour. If that wait clears and
# later opens again, the generation changes. An escalated wait keeps its wait
# identity and only changes class, so escalation itself surfaces exactly once.
#
# SURFACING
# state/.captain-attention records the digest of the set most recently rendered
# to a captain-facing surface by bin/fm-attention.sh:
#   attention=<digest over every identity>
#   decisions=<digest over decision identities only>
# A digest that differs from the recorded one means the set CHANGED and has not
# been surfaced since. Rendering is surfacing: bin/fm-attention.sh records the
# digest as a side effect of printing its captain-facing view, so an ordinary
# read that changes nothing can never become an alarm, and an item that is
# answered simply drops out of the set. The marker never suppresses the ledger
# itself - an open item stays rendered until it is resolved; the marker only
# bounds the INTERRUPT.
#
# CONSUMERS
#   bin/fm-attention.sh        the captain-facing renderer (pull, single place)
#   bin/fm-guard.sh            surfaces a changed set on every guarded command
#   bin/fm-turnend-guard.sh    stops a turn ending on an unsurfaced decision
#   bin/fm-session-start.sh    the session-start digest section
#   bin/fm-decision-hold.sh    writes the durable captain briefing this reads
# All of them are harness-agnostic and runtime-backend-agnostic: this library
# reads only data/backlog.md and state/*.status and never inspects a pane, an
# endpoint, or a harness.
#
# DEPENDENCIES
# jq and a successful backlog projection are required to know the complete set.
# When that derivation fails this library reports FM_ATT_AVAILABLE=false and
# FM_ATT_UNKNOWN=true; callers must not treat it as an empty set.

_FM_ATTENTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_ATTENTION_LIB_DIR="."

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$_FM_ATTENTION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
# shellcheck disable=SC1091
. "$_FM_ATTENTION_LIB_DIR/fm-supervision-lib.sh"

# The snapshot is the ONE owner of backlog row parsing; this library never
# re-implements it. --backlog-json is its cheap projection: one jq pass over
# data/backlog.md with no endpoint, secondmate, or network reads.
FM_ATTENTION_SNAPSHOT_BIN="${FM_ATTENTION_SNAPSHOT_BIN:-$_FM_ATTENTION_LIB_DIR/fm-fleet-snapshot.sh}"

# How many times a declared wait may be re-declared before it stops counting as
# routine and becomes a captain decision.
FM_ATTENTION_WAIT_REDECLARES=${FM_ATTENTION_WAIT_REDECLARES:-3}
case "$FM_ATTENTION_WAIT_REDECLARES" in ''|*[!0-9]*|0) FM_ATTENTION_WAIT_REDECLARES=3 ;; esac

# --- durable captain briefing grammar ---------------------------------------
#
# The plain language a captain needs is not derivable from backlog metadata, so
# bin/fm-decision-hold.sh writes it into the hold's own durable body and this
# library reads it back. One writer, one reader, one grammar, stated here.
#
#   Captain briefing v1:
#   Choice: <one line>
#   Why now: <one line>
#   If this waits: <one line>
#   Option: <one line>            (repeatable)
#   Recommended: <one line>
#
# Every value is one line, matching the one-line validation the hold command
# already applies to titles and reasons. A hold with no briefing block still
# renders; it is marked as not yet written rather than dressing up a raw
# operational note as if it were plain language.
FM_ATTENTION_BRIEF_HEADER='Captain briefing v1:'
FM_ATTENTION_BRIEF_CHOICE='Choice:'
FM_ATTENTION_BRIEF_WHY='Why now:'
FM_ATTENTION_BRIEF_COST='If this waits:'
FM_ATTENTION_BRIEF_OPTION='Option:'
FM_ATTENTION_BRIEF_RECOMMEND='Recommended:'

# fm_attention_brief_lines <choice> <why-now> <cost> <recommend> [option...]
# Print the durable briefing block for a hold body, or nothing when no field was
# supplied. Fields are emitted in fixed order so an idempotent re-registration
# produces byte-identical output.
fm_attention_brief_lines() {
  local choice=${1:-} why=${2:-} cost=${3:-} recommend=${4:-} opt
  shift 4 2>/dev/null || true
  if [ -z "$choice" ] && [ -z "$why" ] && [ -z "$cost" ] && [ -z "$recommend" ] && [ "$#" -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "$FM_ATTENTION_BRIEF_HEADER"
  [ -z "$choice" ] || printf '%s %s\n' "$FM_ATTENTION_BRIEF_CHOICE" "$choice"
  [ -z "$why" ] || printf '%s %s\n' "$FM_ATTENTION_BRIEF_WHY" "$why"
  [ -z "$cost" ] || printf '%s %s\n' "$FM_ATTENTION_BRIEF_COST" "$cost"
  for opt in "$@"; do
    [ -z "$opt" ] || printf '%s %s\n' "$FM_ATTENTION_BRIEF_OPTION" "$opt"
  done
  [ -z "$recommend" ] || printf '%s %s\n' "$FM_ATTENTION_BRIEF_RECOMMEND" "$recommend"
}

# --- status-side collection --------------------------------------------------

# Seconds until the supervision cycle next re-checks a declared wait, or -1 when
# nothing is watching. bin/fm-classify-lib.sh owns the cadence constant; this
# only does the arithmetic against the status log's last write.
fm_attention_wait_next_check() {  # <status-file> <state-dir>
  local f=$1 state=$2 cadence m now beat age grace
  cadence=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
  case "$cadence" in ''|*[!0-9]*|0) cadence=$FM_PAUSE_RESURFACE_SECS_DEFAULT ;; esac
  grace=${FM_GUARD_GRACE:-300}
  beat="$state/.last-watcher-beat"
  now=$(date +%s)
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$((now - m))
      [ "$age" -lt "$grace" ] || { printf '%s' -1; return 0; }
    else
      printf '%s' -1
      return 0
    fi
  else
    printf '%s' -1
    return 0
  fi
  m=$(fm_sup_stat_mtime "$f")
  [ -n "$m" ] || { printf '%s' "$cadence"; return 0; }
  printf '%s' "$(( m + cadence - now ))"
}

_fm_attention_drop_key() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}

_fm_attention_row_for_key() {  # <open-set> <key>
  local set=$1 key=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) printf '%s' "$line"; return 0 ;;
    esac
  done <<EOF
$set
EOF
  return 1
}

_fm_attention_generation_get() {  # <generation-set> <key>
  local set=$1 key=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) printf '%s' "${line#*$'\t'}"; return 0 ;;
    esac
  done <<EOF
$set
EOF
  printf '0'
}

_fm_attention_generation_set() {  # <generation-set> <key> <generation>
  local set=$1 key=$2 gen=$3
  set=$(_fm_attention_drop_key "$set" "$key")
  [ -n "$set" ] && set="${set}"$'\n'
  printf '%s%s\t%s\n' "$set" "$key" "$gen"
}

# Emit one TAB-separated status-derived row per open decision or wait:
#   <class> <task-id> <key> <generation> <verb> <redeclares> <next-check-secs> <note>
# Only tasks with live metadata are considered: an id whose metadata is gone was
# torn down, and any decision it still owed was transferred to a durable backlog
# hold by bin/fm-decision-hold.sh. Terminal tasks are skipped for the same reason
# origin_open_decisions skips them.
fm_attention_status_rows() {  # <state-dir>
  local state=$1 meta id status kind last verb key note n next line stripped pause resolve held
  local decisions waits decision_gens wait_gens existing gen
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    status="$state/$id.status"
    [ -f "$status" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    if [ "$kind" != secondmate ]; then
      last=$(last_status_line "$status")
      verb=$(status_line_verb "$last")
      case "$verb" in done|failed) continue ;; esac
    fi
    decisions=''
    waits=''
    decision_gens=''
    wait_gens=''
    while IFS= read -r line || [ -n "$line" ]; do
      stripped=${line//[[:space:]]/}
      [ -n "$stripped" ] || continue
      verb=$(status_line_verb "$line")
      key=$(_fm_decision_key "$line") || continue
      note=$(status_line_note "$line")
      case "$verb" in
        needs-decision|blocked)
          existing=$(_fm_attention_row_for_key "$decisions" "$key" || true)
          if [ -n "$existing" ]; then
            IFS=$'\t' read -r _ _ gen _ <<EOF
$existing
EOF
          else
            gen=$(_fm_attention_generation_get "$decision_gens" "$key")
            gen=$((gen + 1))
            decision_gens=$(_fm_attention_generation_set "$decision_gens" "$key" "$gen")
          fi
          decisions=$(_fm_attention_drop_key "$decisions" "$key")
          [ -n "$decisions" ] && decisions="${decisions}"$'\n'
          decisions="${decisions}${key}"$'\t'"${verb}"$'\t'"${gen}"$'\t'"${note}"$'\n'
          waits=$(_fm_attention_drop_key "$waits" "$key")
          [ -n "$waits" ] && waits="${waits}"$'\n'
          ;;
        "$resolve"|"$held")
          decisions=$(_fm_attention_drop_key "$decisions" "$key")
          [ -n "$decisions" ] && decisions="${decisions}"$'\n'
          waits=$(_fm_attention_drop_key "$waits" "$key")
          [ -n "$waits" ] && waits="${waits}"$'\n'
          ;;
        done|failed|working)
          waits=$(_fm_attention_drop_key "$waits" "$key")
          [ -n "$waits" ] && waits="${waits}"$'\n'
          ;;
        "$pause")
          existing=$(_fm_attention_row_for_key "$waits" "$key" || true)
          if [ -n "$existing" ]; then
            IFS=$'\t' read -r _ _ gen n _ <<EOF
$existing
EOF
            n=$((n + 1))
          else
            gen=$(_fm_attention_generation_get "$wait_gens" "$key")
            gen=$((gen + 1))
            wait_gens=$(_fm_attention_generation_set "$wait_gens" "$key" "$gen")
            n=1
          fi
          waits=$(_fm_attention_drop_key "$waits" "$key")
          [ -n "$waits" ] && waits="${waits}"$'\n'
          waits="${waits}${key}"$'\t'"${verb}"$'\t'"${gen}"$'\t'"${n}"$'\t'"${note}"$'\n'
          ;;
      esac
    done < "$status"
    while IFS=$'\t' read -r key verb gen note; do
      [ -n "$key" ] || continue
      printf 'decision\t%s\t%s\t%s\t%s\t0\t-1\t%s\n' "$id" "$key" "$gen" "$verb" "$note"
    done <<EOF
$decisions
EOF
    next=$(fm_attention_wait_next_check "$status" "$state")
    while IFS=$'\t' read -r key verb gen n note; do
      [ -n "$key" ] || continue
      printf 'wait\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$key" "$gen" "$verb" "$n" "$next" "$note"
    done <<EOF
$waits
EOF
  done
  return 0
}

# --- the derived attention set ----------------------------------------------

# fm_attention_json <fm-home>
# Print the attention set as a JSON array, newest-identity-last within class.
# Read-only: it acquires no lock and writes nothing.
fm_attention_json() {  # <fm-home>
  local home=$1 state data backlog_json rows
  state="${FM_STATE_OVERRIDE:-$home/state}"
  data="${FM_DATA_OVERRIDE:-$home/data}"
  command -v jq >/dev/null 2>&1 || return 1
  backlog_json=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$FM_ATTENTION_SNAPSHOT_BIN" --backlog-json 2>/dev/null) || return 1
  [ -n "$backlog_json" ] || return 1
  printf '%s' "$backlog_json" | jq -e 'type == "object" and (.records | type == "array")' >/dev/null 2>&1 || return 1
  rows=$(fm_attention_status_rows "$state")
  printf '%s' "$rows" | jq -Rn \
    --argjson backlog "$backlog_json" \
    --argjson escalate "$FM_ATTENTION_WAIT_REDECLARES" \
    --arg brief_header "$FM_ATTENTION_BRIEF_HEADER" \
    --arg f_choice "$FM_ATTENTION_BRIEF_CHOICE" \
    --arg f_why "$FM_ATTENTION_BRIEF_WHY" \
    --arg f_cost "$FM_ATTENTION_BRIEF_COST" \
    --arg f_option "$FM_ATTENTION_BRIEF_OPTION" \
    --arg f_recommend "$FM_ATTENTION_BRIEF_RECOMMEND" '
    def field($lines; $label):
      ([ $lines[] | select(startswith($label)) | ltrimstr($label) | sub("^[[:space:]]+"; "") ] | .[0]) // null;
    def fields($lines; $label):
      [ $lines[] | select(startswith($label)) | ltrimstr($label) | sub("^[[:space:]]+"; "") ];
    def empty_briefing:
      {briefed:false,choice:null,why_now:null,cost_of_waiting:null,options:[],recommendation:null,briefing_missing:[]};
    def briefing($record):
      ($record.body_lines // []) as $lines
      | if ($lines | index($brief_header)) == null then
          empty_briefing
        else
          (field($lines; $f_choice)) as $choice
          | (field($lines; $f_why)) as $why
          | (field($lines; $f_cost)) as $cost
          | (fields($lines; $f_option)) as $options
          | (field($lines; $f_recommend)) as $recommend
          | if ($choice == null and $why == null and $cost == null and ($options | length) == 0 and $recommend == null) then
              empty_briefing
            else
              {briefed:true,
               choice:$choice,
               why_now:$why,
               cost_of_waiting:$cost,
               options:$options,
               recommendation:$recommend,
               briefing_missing:([
                 if $choice == null then "The choice" else empty end,
                 if $why == null then "Why it matters now" else empty end,
                 if $cost == null then "If this waits" else empty end,
                 if ($options | length) == 0 then "Options" else empty end,
                 if $recommend == null then "Recommended" else empty end
               ])}
            end
        end;
    # Selected on the captain hold itself, not on the snapshot captain_actionable
    # flag, which also requires the item own kind to be "captain". The documented
    # way to gate an ordinary work item on the captain is
    # "tasks-axi hold <id> --reason ... --kind captain", which leaves kind as
    # ship, so that flag is false for exactly the threads this contract exists
    # for and they would render as routine delays. A captain hold that still has
    # unresolved blockers is not answerable yet and stays a wait below.
    def is_captain_decision:
      .structured == true
      and (.state == "queued" or .state == "in_flight")
      and .hold_kind == "captain"
      and .hold_reason != null
      and ((.unresolved_blocker_ids // []) | length) == 0;
    def backlog_decisions:
      [ $backlog.records[]?
        | select(is_captain_decision)
        | {class:"decision",
           identity:("decision:" + .id),
           source:"captain-hold",
           id:.id,
           key:.id,
           headline:(.title // .id),
           detail:(.hold_reason // "no reason recorded"),
           awaiting:null,
           blocked_by:[],
           redeclares:0,
           escalated:false,
           next_check_seconds:null}
          + briefing(.) ];
    def backlog_waits:
      [ $backlog.records[]?
        | select(.structured == true
                 and (.state == "queued" or .state == "in_flight")
                 and (is_captain_decision | not)
                 and ((.hold_reason != null and .hold_kind != null)
                      or ((.unresolved_blocker_ids // []) | length) > 0))
        | {class:"wait",
           identity:("wait:" + .id),
           source:"backlog-hold",
           id:.id,
           key:.id,
           headline:(.title // .id),
           detail:(.hold_reason // .blocked_reason // "waiting on other work"),
           awaiting:(.hold_reason // .blocked_reason // "other work to finish"),
           blocked_by:(.unresolved_blocker_ids // []),
           redeclares:0,
           escalated:false,
           next_check_seconds:null,
           briefed:false,choice:null,why_now:null,cost_of_waiting:null,
           options:[],recommendation:null,briefing_missing:[]} ];
    def status_rows:
      [ inputs
        | select(length > 0)
        | split("\t")
        | select(length >= 8)
        | {class:.[0],id:.[1],key:.[2],generation:.[3],verb:.[4],
           redeclares:(.[5] | tonumber? // 0),
           next_check_seconds:(.[6] | tonumber? // -1),
           note:(.[7:] | join("\t"))} ];
    # The title of the work item itself, so a captain-facing line names the piece
    # of work rather than repeating the event note as its own heading. Falls back
    # to the note when the backlog has no matching row, and never to the raw id,
    # which is internal vocabulary.
    def work_title($id):
      ([ $backlog.records[]? | select(.structured == true and .id == $id) | .title ] | .[0]) // null;
    def status_records:
      [ status_rows[]
        | (.redeclares >= $escalate) as $esc
        | {class:(if .class == "wait" and $esc then "decision" else .class end),
           identity:(.class + ":" + .id + ":" + .key + ":" + .generation),
           source:(if .class == "wait" then "declared-wait" else "status-decision" end),
           id:.id,
           key:.key,
           headline:(work_title(.id) // (.note | if . == "" then .id else . end)),
           detail:.note,
           awaiting:(if .class == "wait" then .note else null end),
           blocked_by:[],
           redeclares:.redeclares,
           escalated:(.class == "wait" and $esc),
           next_check_seconds:(if .class == "wait" then .next_check_seconds else null end),
           briefed:false,choice:null,why_now:null,cost_of_waiting:null,
           options:[],recommendation:null,briefing_missing:[]} ];
    (backlog_decisions + status_records) as $primary
    # A live declared wait supersedes the backlog-level wait row for the same
    # work item: both describe one thing waiting, and the live one carries the
    # current wording and the next check time. Keeping both would show the
    # captain the same item twice.
    | ($primary + [ backlog_waits[] | select(. as $b | ($primary | any(.id == $b.id)) | not) ])
    | reduce .[] as $r ([]; if any(.[]; .identity == $r.identity) then . else . + [$r] end)
    | sort_by([(if .class == "decision" then 0 else 1 end), .identity])
  '
}

_fm_attention_digest_of() {  # <newline-separated identities>
  local text=$1
  [ -n "$text" ] || { printf 'empty'; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$text" | cksum | awk '{print $1 "-" $2}'
  fi
}

# fm_attention_status <fm-home>
# Populate for the home at $1:
#   FM_ATT_AVAILABLE       true/false - false when the complete set is unavailable
#   FM_ATT_UNKNOWN         true/false - true when the complete set is unknowable
#   FM_ATT_ERROR           human-readable unknown-state reason
#   FM_ATT_JSON            the record array
#   FM_ATT_COUNT           total open records
#   FM_ATT_DECISIONS       open records needing the captain
#   FM_ATT_WAITS           open declared delays
#   FM_ATT_DIGEST          digest over every identity
#   FM_ATT_DECISION_DIGEST digest over decision identities only
#   FM_ATT_NEW             true when the whole set changed since it was surfaced
#   FM_ATT_DECISIONS_NEW   true when the decision set changed since it was surfaced
#   FM_ATT_UNKNOWN_DIGEST  digest for bounding repeated unknown turn-end stops
#   FM_ATT_UNKNOWN_NEW     true when the same unknown has not been surfaced
# Always returns 0.
fm_attention_status() {  # <fm-home>
  local home=$1 state seen_att seen_dec seen_unknown ids='' dec_ids='' summary
  state="${FM_STATE_OVERRIDE:-$home/state}"
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh, fm-turnend-guard.sh, fm-attention.sh) after sourcing.
  FM_ATT_AVAILABLE=true
  FM_ATT_UNKNOWN=false
  FM_ATT_ERROR=''
  FM_ATT_JSON='[]'
  FM_ATT_COUNT=0
  FM_ATT_DECISIONS=0
  FM_ATT_WAITS=0
  FM_ATT_DIGEST=empty
  FM_ATT_DECISION_DIGEST=empty
  FM_ATT_UNKNOWN_DIGEST=empty
  FM_ATT_NEW=false
  FM_ATT_DECISIONS_NEW=false
  FM_ATT_UNKNOWN_NEW=false

  if ! command -v jq >/dev/null 2>&1 || ! FM_ATT_JSON=$(fm_attention_json "$home" 2>/dev/null) || [ -z "$FM_ATT_JSON" ]; then
    FM_ATT_AVAILABLE=false
    FM_ATT_UNKNOWN=true
    FM_ATT_ERROR='The open decision and wait list could not be determined.'
    FM_ATT_JSON='{"unknown":true}'
    FM_ATT_DIGEST=unknown
    FM_ATT_DECISION_DIGEST=unknown
    FM_ATT_UNKNOWN_DIGEST=$(_fm_attention_digest_of 'unknown:attention-derivation')
    FM_ATT_NEW=true
    FM_ATT_DECISIONS_NEW=true
    seen_unknown=$(sed -n 's/^unknown=//p' "$state/.captain-attention-unknown" 2>/dev/null | tail -1 || true)
    [ "$FM_ATT_UNKNOWN_DIGEST" = "$seen_unknown" ] || FM_ATT_UNKNOWN_NEW=true
    return 0
  fi
  # One jq pass for counts and both identity lists; this runs on every guarded
  # command, so it must not spawn a process per field.
  summary=$(printf '%s' "$FM_ATT_JSON" | jq -r '
    "\(length) \([.[] | select(.class == "decision")] | length)",
    "--attention--", (.[].identity),
    "--decisions--", (.[] | select(.class == "decision") | .identity)' 2>/dev/null) || summary=''
  if [ -n "$summary" ]; then
    FM_ATT_COUNT=${summary%%$'\n'*}
    FM_ATT_DECISIONS=${FM_ATT_COUNT#* }
    FM_ATT_COUNT=${FM_ATT_COUNT%% *}
    case "$FM_ATT_COUNT" in ''|*[!0-9]*) FM_ATT_COUNT=0 ;; esac
    case "$FM_ATT_DECISIONS" in ''|*[!0-9]*) FM_ATT_DECISIONS=0 ;; esac
    ids=$(printf '%s\n' "$summary" | awk '/^--attention--$/{s=1;next} /^--decisions--$/{s=0} s')
    dec_ids=$(printf '%s\n' "$summary" | awk '/^--decisions--$/{s=1;next} s')
  else
    FM_ATT_AVAILABLE=false
    # shellcheck disable=SC2034 # Read by callers after sourcing.
    FM_ATT_UNKNOWN=true
    # shellcheck disable=SC2034 # Read by callers after sourcing.
    FM_ATT_ERROR='The open decision and wait list could not be determined.'
    FM_ATT_JSON='{"unknown":true}'
    FM_ATT_DIGEST=unknown
    FM_ATT_DECISION_DIGEST=unknown
    FM_ATT_UNKNOWN_DIGEST=$(_fm_attention_digest_of 'unknown:attention-derivation')
    FM_ATT_NEW=true
    FM_ATT_DECISIONS_NEW=true
    seen_unknown=$(sed -n 's/^unknown=//p' "$state/.captain-attention-unknown" 2>/dev/null | tail -1 || true)
    # shellcheck disable=SC2034 # Read by callers after sourcing.
    [ "$FM_ATT_UNKNOWN_DIGEST" = "$seen_unknown" ] || FM_ATT_UNKNOWN_NEW=true
    return 0
  fi
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_ATT_WAITS=$((FM_ATT_COUNT - FM_ATT_DECISIONS))
  FM_ATT_DIGEST=$(_fm_attention_digest_of "$ids")
  FM_ATT_DECISION_DIGEST=$(_fm_attention_digest_of "$dec_ids")

  seen_att=$(sed -n 's/^attention=//p' "$state/.captain-attention" 2>/dev/null | tail -1 || true)
  seen_dec=$(sed -n 's/^decisions=//p' "$state/.captain-attention" 2>/dev/null | tail -1 || true)
  rm -f "$state/.captain-attention-unknown" 2>/dev/null || true
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  [ "$FM_ATT_DIGEST" = "$seen_att" ] || FM_ATT_NEW=true
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  [ "$FM_ATT_DECISION_DIGEST" = "$seen_dec" ] || FM_ATT_DECISIONS_NEW=true
  return 0
}

# fm_attention_home_idle <fm-home> [grace-seconds]
# Exit 0 (true) only when this home genuinely has NOTHING accounted for: no
# in-flight task metadata, no X-mode relay poll, and no open decision or wait.
#
# This is the answer to the meta-blindness defect. bin/fm-supervision-lib.sh
# counts state/*.meta, which exist only after bin/fm-spawn.sh runs, so a primary
# that holds work itself - an unanswered decision, a standing delay - counted as
# zero and every guard concluded the home was idle. Unaccounted primary work must
# read as suspicious, not idle, so idleness is asserted here against the derived
# attention set as well as the metadata count. It is deliberately NOT folded into
# FM_SUP_NEEDED: a standing decision does not need a watcher, and treating it as
# watcher-need would nag forever on a home with long-lived open decisions.
fm_attention_home_idle() {  # <fm-home> [grace]
  local home=$1 grace=${2:-${FM_GUARD_GRACE:-300}} state
  state="${FM_STATE_OVERRIDE:-$home/state}"
  fm_supervision_status "$state" "$grace"
  [ "$FM_SUP_NEEDED" = false ] || return 1
  fm_attention_status "$home"
  [ "$FM_ATT_AVAILABLE" = true ] || return 1
  [ "$FM_ATT_COUNT" -eq 0 ]
}
