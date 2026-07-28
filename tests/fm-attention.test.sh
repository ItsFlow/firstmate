#!/usr/bin/env bash
# Regression tests for the captain-attention contract: open decisions and
# declared waits must reach the captain in plain language, exactly once per
# distinct set, and must clear when they resolve.
#
# The reproduction these tests are built from is the real task-board / fork-sync
# case: a piece of work parked behind a fork synchronization the captain had to
# approve, re-reported hourly as a routine delay, while the captain-facing
# surfaces showed a truncated fragment of an unrelated note and the supervision
# stack - which counts only spawned-task metadata - reported an idle home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTENTION="$ROOT/bin/fm-attention.sh"
GUARD="$ROOT/bin/fm-guard.sh"
TURNEND="$ROOT/bin/fm-turnend-guard.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-attention)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/bin"
  [ ! -f "$ROOT/.tasks.toml" ] || cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

# A home shaped like a real primary checkout, so the turn-end guard's scoping
# check treats it as one. The secondmate marker is the supported force-include
# for a home that is not a plain clone of this repo.
make_primary_home() {  # <name>
  local home
  home=$(make_home "$1")
  printf 'sm-attention-test\n' > "$home/.fm-secondmate-home"
  : > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

attention() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ATTENTION" "$@"
}

run_guard() {  # <home>
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$GUARD" 2>&1
}

run_turnend() {  # <home>
  local home=$1
  printf '{"stop_hook_active":false,"session_id":"attention-test"}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$TURNEND" 2>&1
}

add_row() {  # <home> <section> <line>
  local home=$1 section=$2 line=$3
  awk -v section="## $section" -v row="$line" '
    { print }
    $0 == section { print row }
  ' "$home/data/backlog.md" > "$home/data/backlog.md.tmp"
  mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
}

# --- the recorded explanation must survive intact ---------------------------
#
# The captain-facing text was truncated at its first comma before it ever
# reached a renderer, because the backlog reader treated commas as metadata
# separators inside a free-text hold reason. Everything else here is worthless
# while that is true, so it is asserted first and directly on the parser.
test_hold_reason_keeps_its_full_text() {
  local home reason parsed
  home=$(make_home reason-text)
  reason='Confirm trusted, saved-affinity, and discovery soft targets before implementation.'
  add_row "$home" Queued \
    "- [ ] sample-decision-slots - Choose the slot mix (repo: sample) (kind: captain) (since 2026-07-28) (hold: $reason) (hold-kind: captain)"
  parsed=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$SNAPSHOT" --backlog-json | jq -r '.records[0].hold_reason')
  [ "$parsed" = "$reason" ] || fail "hold reason was truncated: $parsed"

  # The comma-separated metadata group form must still parse, so the fix cannot
  # be a blanket relaxation.
  home=$(make_home reason-groups)
  add_row "$home" Queued \
    '- [ ] sample-grouped - Grouped metadata (repo: sample, kind: captain, priority: 2) (hold: a, b) (hold-kind: captain)'
  parsed=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$SNAPSHOT" --backlog-json | jq -r '.records[0] | "\(.repo)|\(.kind)|\(.priority)|\(.hold_reason)"')
  [ "$parsed" = 'sample|captain|2|a, b' ] || fail "comma-separated metadata group regressed: $parsed"
  pass "a recorded captain explanation keeps its full text, and grouped metadata still parses"
}

# --- creation: the fork-sync decision, rendered concretely -------------------
test_briefed_decision_renders_concretely() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip-ish: tasks-axi absent, briefed-decision creation not exercised"; return 0; }
  home=$(make_home fork-sync)
  fm_write_meta "$home/state/fork-sync.meta" \
    "window=fixture:fm-fork-sync" "project=$home/projects/firstmate" "kind=ship"
  printf 'working: auditing the fork topology\n' > "$home/state/fork-sync.status"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync \
    --title 'Sync the fork main branch with the author upstream' \
    --reason 'The task board cannot be rebased or re-validated until the fork main matches upstream' \
    --repo firstmate \
    --choice 'Sync the fork main from the author upstream now, or keep it frozen and rebase the task board onto the current fork main.' \
    --why-now 'The task board is the last thing before the live view ships and cannot be validated against a stale fork main.' \
    --cost-of-waiting 'The task board stays parked and nothing else will move it.' \
    --option 'Sync the fork main from upstream now, then rebase and re-validate.' \
    --option 'Leave the fork frozen and rebase the board onto the current fork main.' \
    --recommend 'Sync the fork main from upstream now; it is the smaller change and unblocks everything downstream.' \
    >/dev/null || fail "could not register the briefed captain decision"

  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'Sync the fork main branch with the author upstream' "the decision headline is missing"
  assert_contains "$out" 'The choice:' "the concrete choice is missing"
  assert_contains "$out" 'Why it matters now:' "the reason it matters now is missing"
  assert_contains "$out" 'If this waits:' "the consequence of waiting is missing"
  assert_contains "$out" 'Options:' "the options are missing"
  assert_contains "$out" 'Recommended:' "the recommendation is missing"
  assert_contains "$out" 'Sync the fork main from upstream now, then rebase and re-validate.' "an option body is missing"
  assert_not_contains "$out" 'fork-sync-decision-fork-main-sync' "the captain view must not carry internal identifiers"
  pass "a briefed captain decision renders the choice, the stakes, the options, and a recommendation"
}

test_unbriefed_decision_is_honest_about_missing_language() {
  local home out
  home=$(make_home unbriefed)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the change (repo: sample) (kind: captain) (since 2026-07-28) (hold: an operational note that is not plain language) (hold-kind: captain)'
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'No plain-language explanation has been written for this one yet.' \
    "an unbriefed decision must say so rather than dressing up its raw note"
  assert_contains "$out" 'an operational note that is not plain language' \
    "an unbriefed decision must still show what was actually recorded"
  pass "a decision with no captain briefing renders honestly instead of faking plain language"
}

# --- waits: what is awaited, and when it is next checked ---------------------
test_routine_wait_states_what_it_awaits_and_when_it_is_next_checked() {
  local home out
  home=$(make_home routine-wait)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  {
    printf 'working: rebasing the board\n'
    printf 'paused: the fork synchronization has not landed yet, so the board cannot be rebased\n'
  } > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'WAITING ON SOMETHING ELSE' "the waiting section is missing"
  assert_contains "$out" 'Live watchable view of the task and priority list' \
    "the wait must name the piece of work, not repeat its note as a heading"
  assert_contains "$out" 'Waiting for:' "the wait must say what is being awaited"
  assert_contains "$out" 'the fork synchronization has not landed yet' "the awaited thing is missing"
  assert_contains "$out" 'Next check: in ' "the wait must say when it is next checked"

  # With no live monitoring there is no honest next-check time, and saying so is
  # the point: a delay nothing is watching is worse than one that is.
  rm -f "$home/state/.last-watcher-beat"
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'nothing is checking this right now' \
    "an unmonitored wait must say that nothing is checking it"
  pass "a routine delay states what it awaits and when it is next checked"
}

test_repeated_wait_escalates_to_a_decision() {
  local home out
  home=$(make_home escalating-wait)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  printf 'working: rebasing the board\n' > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  printf 'paused: first recheck unchanged; the fork sync still has not landed\n' >> "$home/state/task-board.status"
  printf 'paused: second recheck unchanged; the fork sync still has not landed\n' >> "$home/state/task-board.status"
  out=$(attention "$home" --no-mark --status)
  assert_contains "$out" 'decisions=0' "two declarations must still be a routine delay"
  assert_contains "$out" 'waits=1' "two declarations must still be a routine delay"

  printf 'paused: third recheck unchanged; the fork sync still has not landed\n' >> "$home/state/task-board.status"
  out=$(attention "$home" --no-mark --status)
  assert_contains "$out" 'decisions=1' "a delay re-reported past the threshold must become a decision"
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 're-reported 3 times' \
    "the escalation must say why it stopped counting as routine"
  assert_contains "$out" 'keep waiting on this, or change the plan' \
    "the escalation must name the choice it puts to the captain"

  # A resolution of that keyed phase ends the run, so the same work does not stay
  # escalated forever once it genuinely moves again.
  printf 'working: the fork sync landed; rebasing now\n' >> "$home/state/task-board.status"
  out=$(attention "$home" --no-mark --status)
  assert_contains "$out" 'decisions=0' "progress must end the escalation"
  pass "a delay that keeps repeating becomes a captain decision, and progress ends it"
}

# --- deduplication ----------------------------------------------------------
test_identities_ignore_wording_so_repeats_do_not_re_alarm() {
  local home first second
  home=$(make_home dedup)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  printf 'paused: first recheck unchanged\n' > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  first=$(attention "$home" --no-mark --json | jq -r '.[].identity')
  printf 'paused: second recheck unchanged, with entirely different wording\n' >> "$home/state/task-board.status"
  second=$(attention "$home" --no-mark --json | jq -r '.[].identity')
  [ "$first" = "$second" ] || fail "re-wording a delay changed its identity: $first vs $second"

  # The whole point of a stable identity: the guard interrupts once, not once per
  # re-declaration.
  assert_contains "$(run_guard "$home")" "CAPTAIN'S CALL CHANGED" "the first changed set must surface"
  printf 'paused: third recheck unchanged, worded differently again\n' >> "$home/state/task-board.status"
  assert_not_contains "$(run_guard "$home")" "CAPTAIN'S CALL" "a re-worded repeat must not surface again"
  pass "attention identities ignore wording, so a repeated delay surfaces once"
}

test_ordinary_reads_do_not_become_false_alarms() {
  local home out
  home=$(make_home quiet-reads)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the change (repo: sample) (kind: captain) (since 2026-07-28) (hold: a reason) (hold-kind: captain)'
  assert_contains "$(run_guard "$home")" "CAPTAIN'S CALL CHANGED" "the first changed set must surface"
  # Reading the set, listing it, and running the guard again are all ordinary
  # conductor reads and must be silent.
  attention "$home" --no-mark --json >/dev/null
  attention "$home" --no-mark --status >/dev/null
  out=$(run_guard "$home")
  [ -z "$out" ] || fail "an ordinary read produced a false alarm: $out"
  # And rendering must not resurrect the alarm either: rendering IS surfacing.
  attention "$home" >/dev/null
  out=$(run_guard "$home")
  [ -z "$out" ] || fail "rendering the ledger produced a false alarm: $out"
  pass "ordinary reads and re-renders never become false alarms"
}

test_ledger_keeps_showing_an_open_item_after_it_was_surfaced() {
  local home out
  home=$(make_home persistent)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the change (repo: sample) (kind: captain) (since 2026-07-28) (hold: a reason) (hold-kind: captain)'
  attention "$home" >/dev/null
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'Approve the change' \
    "an open decision must stay listed after it was surfaced; the marker bounds the interrupt, not the ledger"
  pass "an open item stays visible until it resolves, even once its interrupt is spent"
}

# --- resolution -------------------------------------------------------------
test_resolution_clears_the_item() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip-ish: tasks-axi absent, resolution path not exercised"; return 0; }
  home=$(make_home resolution)
  fm_write_meta "$home/state/fork-sync.meta" \
    "window=fixture:fm-fork-sync" "project=$home/projects/firstmate" "kind=ship"
  printf 'working: auditing\n' > "$home/state/fork-sync.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync \
    --title 'Sync the fork main branch with the author upstream' \
    --reason 'the board cannot be rebased until the fork main matches upstream' \
    --repo firstmate \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --recommend 'Sync now.' >/dev/null || fail "could not register the decision"
  assert_contains "$(attention "$home" --no-mark --status)" 'decisions=1' "the decision should be open"

  ( cd "$home" && tasks-axi add board-rebase 'Rebase and revalidate the task board' --kind ship --repo firstmate >/dev/null \
      && tasks-axi block board-rebase --by fork-sync-decision-fork-main-sync >/dev/null ) \
    || fail "could not create the dependent work"
  printf 'Sync the fork main from upstream now.\n' > "$home/decision.txt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" resolve fork-sync fork-main-sync --decision-file "$home/decision.txt" --routed-to board-rebase >/dev/null \
    || fail "could not resolve the decision"

  assert_contains "$(attention "$home" --no-mark --status)" 'decisions=0' "a resolved decision must clear"
  out=$(attention "$home" --no-mark)
  assert_not_contains "$out" 'Sync the fork main branch with the author upstream' "a resolved decision must leave the ledger"
  pass "a resolved decision clears from the captain view"
}

test_retry_never_erases_a_written_briefing() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip-ish: tasks-axi absent, retry path not exercised"; return 0; }
  home=$(make_home retry)
  fm_write_meta "$home/state/fork-sync.meta" \
    "window=fixture:fm-fork-sync" "project=$home/projects/firstmate" "kind=ship"
  printf 'working: auditing\n' > "$home/state/fork-sync.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'a reason' --repo firstmate \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --recommend 'Sync now.' >/dev/null || fail "could not register the decision"
  # A plain idempotent retry carries no briefing flags and must leave the written
  # briefing alone.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'a reason' >/dev/null \
    || fail "idempotent retry failed"
  out=$(attention "$home" --no-mark --json | jq -r '.[0] | "\(.briefed)|\(.recommendation)"')
  [ "$out" = 'true|Sync now.' ] || fail "an idempotent retry damaged the written briefing: $out"

  # Supplying briefing flags updates it.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'a reason' \
    --recommend 'Rebase onto the current fork main instead.' >/dev/null || fail "briefing update failed"
  out=$(attention "$home" --no-mark --json | jq -r '.[0].recommendation')
  [ "$out" = 'Rebase onto the current fork main instead.' ] || fail "briefing update did not take: $out"
  pass "an idempotent retry preserves a written briefing and an explicit update replaces it"
}

# --- the primary-activity blind spot ----------------------------------------
#
# The defect this contract exists to close: supervision counted state/*.meta, so
# a home whose only live work was an unanswered captain decision had nothing to
# count and every guard concluded it was idle.
test_unaccounted_primary_work_is_not_idle() {
  local home out
  home=$(make_primary_home blind-spot)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the worker installs (repo: sample) (kind: captain) (since 2026-07-28) (hold: the machine needs approval before workers run there) (hold-kind: captain)'
  [ -z "$(ls "$home/state"/*.meta 2>/dev/null)" ] || fail "the blind-spot fixture must have no task metadata"

  # The old supervision predicate is unchanged and still reports an idle-looking
  # home; that is exactly why the idleness question has its own owner.
  out=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_supervision_status "$2"; printf "in_flight=%s needed=%s\n" "$FM_SUP_IN_FLIGHT" "$FM_SUP_NEEDED"' \
    _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state")
  assert_contains "$out" 'in_flight=0' "the fixture must reproduce the zero-metadata condition"
  assert_contains "$out" 'needed=false' "watcher-need must stay unchanged by this contract"

  # The idleness predicate must disagree: this home is holding captain work.
  if FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" bash -c \
    '. "$1"; fm_attention_home_idle "$2"' _ "$ROOT/bin/fm-attention-lib.sh" "$home"; then
    fail "a home holding an unanswered captain decision reported itself idle"
  fi

  # The pull guard must speak even though nothing is in flight; before this it
  # returned early and printed nothing at all.
  assert_contains "$(run_guard "$home")" "CAPTAIN'S CALL CHANGED" \
    "the guard went silent on a home whose only work is an unanswered decision"
  pass "unaccounted primary work reads as suspicious, not idle"
}

test_turn_end_stops_once_on_an_unsurfaced_decision() {
  local home out status
  home=$(make_primary_home turnend)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the worker installs (repo: sample) (kind: captain) (since 2026-07-28) (hold: the machine needs approval) (hold-kind: captain)'

  out=$(run_turnend "$home"); status=$?
  expect_code 2 "$status" "a turn must not end with a captain decision the captain has never seen"
  assert_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' "the stop banner must read as an alarm"
  assert_contains "$out" 'bin/fm-attention.sh' "the stop must point at the captain-facing renderer"

  # Bounded by construction: the same set costs exactly one forced continuation.
  out=$(run_turnend "$home"); status=$?
  expect_code 0 "$status" "the same decision set must not stop a second turn"
  [ -z "$out" ] || fail "the second turn end produced output: $out"

  # A genuinely new decision is a new set and stops once more.
  add_row "$home" Queued \
    '- [ ] sample-decision-y - Approve the second thing (repo: sample) (kind: captain) (since 2026-07-28) (hold: another approval) (hold-kind: captain)'
  run_turnend "$home" >/dev/null; status=$?
  expect_code 2 "$status" "a genuinely new decision must stop the turn"
  run_turnend "$home" >/dev/null; status=$?
  expect_code 0 "$status" "the new set must also cost only one continuation"
  pass "a turn cannot end on an unsurfaced captain decision, and each set costs one stop"
}

test_declared_waits_never_stop_a_turn() {
  local home out status
  # A work item waiting on other work, with nothing in flight: the turn-end path
  # reaches the captain's-call check with the watcher question already answered.
  home=$(make_primary_home wait-turnend)
  add_row "$home" Queued \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23) (hold: the fork synchronization has not landed yet) (hold-kind: external)'
  assert_contains "$(attention "$home" --no-mark --status)" 'waits=1' "the fixture must have an open wait"
  assert_contains "$(attention "$home" --no-mark --status)" 'decisions=0' "the fixture must have no open decision"
  out=$(run_turnend "$home"); status=$?
  expect_code 0 "$status" "a routine delay must never force a continuation"
  [ -z "$out" ] || fail "a routine delay produced turn-end output: $out"

  # And a live declared delay never contributes the captain's-call stop either,
  # whatever the independent watcher-liveness backstop decides about it.
  home=$(make_primary_home wait-turnend-live)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  printf 'paused: the fork synchronization has not landed yet\n' > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"
  assert_contains "$(attention "$home" --no-mark --status)" 'waits=1' "the live fixture must have an open wait"
  out=$(run_turnend "$home")
  assert_not_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' \
    "a routine delay must never raise the captain's-call stop"
  pass "declared waits surface without ever stopping a turn"
}

# --- captain-facing language ------------------------------------------------
test_captain_view_carries_no_internal_vocabulary() {
  local home out term
  home=$(make_home vocabulary)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the change (repo: sample) (kind: captain) (since 2026-07-28) (hold: a reason) (hold-kind: captain)'
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  printf 'paused: the fork synchronization has not landed yet\n' > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  out=$(attention "$home" --no-mark)
  # AGENTS.md section 9 forbids these in captain-facing text; the default view is
  # written to be relayed as-is, so it must not contain them.
  for term in 'hold' 'worktree' 'watcher' 'harness' 'crewmate' 'teardown' 'backlog' 'metadata' 'state/'; do
    assert_not_contains "$out" "$term" "the captain view leaked internal vocabulary: $term"
  done
  # The firstmate-facing brief is where identifiers belong.
  assert_contains "$(attention "$home" --no-mark --brief)" 'sample-decision-x' \
    "the brief form must carry identifiers for firstmate's own use"
  pass "the captain view is plain language while the brief form keeps identifiers"
}

test_empty_home_says_so_plainly() {
  local home
  home=$(make_home empty)
  assert_contains "$(attention "$home" --no-mark)" 'Nothing needs your decision, and nothing is waiting.' \
    "an empty home must render an explicit empty state"
  assert_contains "$(attention "$home" --no-mark --brief)" "CAPTAIN'S CALL: nothing open." \
    "the brief form needs an explicit empty state too"
  pass "an empty captain's call is stated, not omitted"
}

test_hold_reason_keeps_its_full_text
test_briefed_decision_renders_concretely
test_unbriefed_decision_is_honest_about_missing_language
test_routine_wait_states_what_it_awaits_and_when_it_is_next_checked
test_repeated_wait_escalates_to_a_decision
test_identities_ignore_wording_so_repeats_do_not_re_alarm
test_ordinary_reads_do_not_become_false_alarms
test_ledger_keeps_showing_an_open_item_after_it_was_surfaced
test_resolution_clears_the_item
test_retry_never_erases_a_written_briefing
test_unaccounted_primary_work_is_not_idle
test_turn_end_stops_once_on_an_unsurfaced_decision
test_declared_waits_never_stop_a_turn
test_captain_view_carries_no_internal_vocabulary
test_empty_home_says_so_plainly
