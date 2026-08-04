#!/usr/bin/env bash
# Regression tests for the captain-attention contract: open decisions and
# declared waits must reach the captain in plain language, only captain-visible
# delivery can record a receipt, and every item must clear when it resolves.
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

run_turnend() {  # <home> [<assistant-message>]
  local home=$1 message=${2:-}
  jq -cn --arg message "$message" \
    '{stop_hook_active:false,session_id:"attention-test",last_assistant_message:$message}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$TURNEND" 2>&1
}

run_turnend_claude() {  # <home> [<stop-hook-active>] [<assistant-message>]
  local home=$1 active=${2:-false} message=${3:-}
  jq -cn --argjson active "$active" --arg message "$message" \
    '{stop_hook_active:$active,session_id:"attention-test",last_assistant_message:$message}' \
    | CLAUDECODE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$TURNEND" --claude 2>&1
}

# A Stop payload from a harness whose hook cannot deliver the assistant reply at
# all: the evidence field is absent, not empty.
run_turnend_no_evidence() {  # <home>
  local home=$1
  jq -cn '{stop_hook_active:false,session_id:"attention-test"}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$TURNEND" 2>&1
}

record_visible() {  # <home>
  local home=$1 message
  message=$(attention "$home" --no-mark)
  printf '%s' "$message" | attention "$home" --record-visible
}

add_row() {  # <home> <section> <line>
  local home=$1 section=$2 line=$3
  FM_TEST_SECTION="## $section" FM_TEST_ROW="$line" awk '
    BEGIN {
      section = ENVIRON["FM_TEST_SECTION"]
      row = ENVIRON["FM_TEST_ROW"]
    }
    { print }
    $0 == section { print row }
  ' "$home/data/backlog.md" > "$home/data/backlog.md.tmp"
  mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
}

failing_snapshot() {  # <home>
  local home=$1
  local bin="$home/bin/failing-snapshot"
  printf '#!/usr/bin/env bash\nexit 42\n' > "$bin"
  chmod +x "$bin"
  printf '%s\n' "$bin"
}

add_unsurfaced_decision() {  # <home>
  local home=$1
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the worker installs (repo: sample) (kind: captain) (since 2026-07-28) (hold: the machine needs approval before workers run there) (hold-kind: captain)
  Captain briefing v1:
  Semantic revision: worker-installs-v1
  Choice: Approve the worker installs now, or leave the machine unavailable.
  Why now: The queued worker setup cannot proceed without the approval.
  If this waits: The worker setup and its dependent work remain stopped.
  Option: Approve the installs now.
  Option: Leave the machine unavailable and reroute the work.
  Recommended: Approve the installs now so the queued setup can proceed.'
}

add_unsupervised_work() {  # <home>
  local home=$1
  fm_write_meta "$home/state/task1.meta" \
    "window=fixture:fm-task1" "project=$home/projects/sample" "kind=ship"
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
    --semantic-revision fork-main-sync-v1 \
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

test_new_decision_requires_a_complete_briefing() {
  local home out status
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip-ish: tasks-axi absent, complete-briefing validation not exercised"; return 0; }
  home=$(make_home complete-required)
  fm_write_meta "$home/state/fork-sync.meta" \
    "window=fixture:fm-fork-sync" "project=$home/projects/firstmate" "kind=ship"
  printf 'working: auditing\n' > "$home/state/fork-sync.status"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync \
    --title 'Sync the fork main' --reason 'the board is waiting' --repo firstmate \
    --semantic-revision fork-main-sync-v1 \
    --choice 'Sync now or wait.' --recommend 'Sync now.' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an incomplete initial briefing was accepted"
  assert_contains "$out" 'why-now must not be empty' "the missing briefing fact was not named"
  assert_not_contains "$(attention "$home" --no-mark --status)" 'decisions=1' \
    "an incomplete initial briefing created a live decision"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync \
    --title 'Sync the fork main' --reason 'the board is waiting' --repo firstmate \
    --choice 'Sync now or wait.' \
    --why-now 'The board is ready to move.' \
    --cost-of-waiting 'The board remains stopped.' \
    --option 'Sync now.' \
    --recommend 'Sync now.' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a complete briefing without a semantic revision was accepted"
  assert_contains "$out" 'semantic-revision must be a non-empty privacy-safe slug' \
    "the missing semantic revision was not named"
  pass "a new captain decision requires every briefing fact"
}

# The documented way to gate ordinary work on the captain is
# "tasks-axi hold <id> --reason ... --kind captain", which leaves the item own
# kind as ship. Selecting on the snapshot captain_actionable flag therefore
# missed exactly the threads this contract exists for and rendered the real
# fork-sync case as a routine delay with no captain action attached.
test_a_captain_gated_work_item_is_a_decision_not_a_delay() {
  local home out
  home=$(make_home captain-gated)
  add_row "$home" Queued \
    '- [ ] sample-board - Ship the live task board (repo: sample) (kind: ship) (hold: The fork main must be synced with upstream before this can be rebased) (hold-kind: captain)'
  out=$(attention "$home" --no-mark)
  assert_contains "$out" '1 decision needs you' \
    "a captain-held ship item must count as a decision"
  assert_contains "$out" 'NEEDS YOUR DECISION' "the decision section is missing"
  assert_not_contains "$out" 'WAITING ON SOMETHING ELSE' \
    "a captain-held item must not be laundered into a routine delay"

  # A captain hold whose blocker is still open is not answerable yet, so it
  # stays a wait; otherwise every future-gated hold would nag the captain now.
  home=$(make_home captain-gated-blocked)
  add_row "$home" Queued \
    '- [ ] sample-board - Ship the live task board blocked-by: sample-other (repo: sample) (kind: ship) (hold: The fork main must be synced first) (hold-kind: captain)'
  out=$(attention "$home" --no-mark)
  assert_contains "$out" '0 decisions need you' \
    "a captain hold with an unresolved blocker is not yet answerable"
  assert_contains "$out" 'WAITING ON SOMETHING ELSE' "the blocked hold must still be listed as a wait"
  pass "a captain-gated work item is a decision, while a still-blocked one waits"
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

test_partial_briefing_renders_recorded_fields_and_names_missing_ones() {
  local home out json
  home=$(make_home partial-briefing)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] partial-decision - Pick the release path (repo: sample) (kind: captain) (since 2026-07-28) (hold: release path needs captain input) (hold-kind: captain)
  Captain briefing v1:
  Recommended: Use the staged rollout.

## Done
EOF
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'Recommended:' "a partial briefing must render the field that was written"
  assert_contains "$out" 'Use the staged rollout.' "a partial briefing must render the recorded recommendation"
  assert_contains "$out" 'Still needs:' "a partial briefing must name missing fields"
  assert_contains "$out" 'The choice' "a partial briefing must name the missing choice"
  assert_contains "$out" 'Why it matters now' "a partial briefing must name the missing timing/stakes field"
  assert_contains "$out" 'If this waits' "a partial briefing must name the missing waiting-cost field"
  assert_not_contains "$out" 'No plain-language explanation has been written for this one yet.' \
    "a briefing with recognized fields must not fall back to the no-briefing branch"
  json=$(attention "$home" --no-mark --json | jq -r '.[0] | "\(.briefed)|\(.recommendation)|\(.briefing_missing | join(","))"')
  assert_contains "$json" 'true|Use the staged rollout.|' "the JSON contract must expose the partial briefing"

  home=$(make_home header-only-briefing)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] header-only - Pick the launch window (repo: sample) (kind: captain) (since 2026-07-28) (hold: launch window needs captain input) (hold-kind: captain)
  Captain briefing v1:

## Done
EOF
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'No plain-language explanation has been written for this one yet.' \
    "a briefing header with no recognized fields must still use the no-briefing branch"
  assert_not_contains "$out" 'Still needs:' "the no-briefing branch must not claim a partial briefing exists"
  pass "a partial captain briefing renders written fields and names missing ones"
}

test_failed_backlog_projection_is_unknown_not_empty() {
  local home snapshot out status
  home=$(make_primary_home snapshot-unknown)
  snapshot=$(failing_snapshot "$home")

  out=$(FM_ATTENTION_SNAPSHOT_BIN="$snapshot" attention "$home" 2>&1); status=$?
  expect_code 3 "$status" "a failed backlog projection must make attention unavailable"
  assert_contains "$out" 'could not determine whether anything needs your decision or is waiting' \
    "unknown attention must say the open set could not be determined"
  assert_not_contains "$out" 'Nothing needs your decision, and nothing is waiting.' \
    "unknown attention must not render as an all-clear"
  assert_absent "$home/state/.captain-attention" \
    "unknown attention must not record the surfaced marker"

  out=$(FM_ATTENTION_SNAPSHOT_BIN="$snapshot" attention "$home" --status 2>&1); status=$?
  expect_code 3 "$status" "unknown status must keep attention unavailable"
  assert_contains "$out" 'attention=unknown' "unknown status must be explicit"
  assert_absent "$home/state/.captain-attention" \
    "unknown status must not record the surfaced marker"

  out=$(FM_ATTENTION_SNAPSHOT_BIN="$snapshot" run_turnend "$home"); status=$?
  expect_code 2 "$status" "a turn end must stop once when the attention set is unknown"
  assert_contains "$out" 'TURN WOULD END WITHOUT KNOWING WHAT THE CAPTAIN NEEDS' \
    "unknown turn-end stop must be explicit"
  assert_absent "$home/state/.captain-attention" \
    "unknown turn-end stop must not record the surfaced marker"

  out=$(FM_ATTENTION_SNAPSHOT_BIN="$snapshot" run_turnend "$home"); status=$?
  expect_code 0 "$status" "a persistent unknown must be bounded to one forced continuation"
  [ -z "$out" ] || fail "the bounded unknown turn end produced output: $out"
  pass "a failed backlog projection is unknown, not an empty captain call"
}

test_failed_state_collection_is_unknown_not_empty() {
  local home fake_bin metadata_bin enumeration_bin out status
  home=$(make_home status-unknown)
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  printf 'paused: waiting for a readable source\n' > "$home/state/task-board.status"
  fake_bin="$home/bin/failing-cat"
  mkdir -p "$fake_bin"
  printf '#!/usr/bin/env bash\ncase "$1" in *.status) exit 42 ;; esac\nexec /bin/cat "$@"\n' > "$fake_bin/cat"
  chmod +x "$fake_bin/cat"

  PATH="$fake_bin:$PATH" bash -c '. "$1"; fm_attention_status_rows "$2"' \
    _ "$ROOT/bin/fm-attention-lib.sh" "$home/state" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable status stream was accepted as an empty collection"

  metadata_bin="$home/bin/failing-metadata-cat"
  mkdir -p "$metadata_bin"
  printf '#!/usr/bin/env bash\ncase "$1" in *.meta) exit 42 ;; esac\nexec /bin/cat "$@"\n' > "$metadata_bin/cat"
  chmod +x "$metadata_bin/cat"
  PATH="$metadata_bin:$PATH" bash -c '. "$1"; fm_attention_status_rows "$2"' \
    _ "$ROOT/bin/fm-attention-lib.sh" "$home/state" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable metadata record was accepted with the default task kind"

  enumeration_bin="$home/bin/failing-state-enumeration"
  mkdir -p "$enumeration_bin"
  printf '#!/usr/bin/env bash\nexit 42\n' > "$enumeration_bin/find"
  chmod +x "$enumeration_bin/find"
  PATH="$enumeration_bin:$PATH" bash -c '. "$1"; fm_attention_status_rows "$2"' \
    _ "$ROOT/bin/fm-attention-lib.sh" "$home/state" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "a failed state enumeration was accepted as an empty collection"

  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample"
  bash -c '. "$1"; fm_attention_status_rows "$2"' \
    _ "$ROOT/bin/fm-attention-lib.sh" "$home/state" >/dev/null 2>&1 \
    || fail "readable metadata without a task kind did not use the default"
  printf 'kind=\n' >> "$home/state/task-board.meta"
  bash -c '. "$1"; fm_attention_status_rows "$2"' \
    _ "$ROOT/bin/fm-attention-lib.sh" "$home/state" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an explicitly empty task kind was accepted as an omitted kind"

  out=$(FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" bash -c '
    . "$1"
    fm_attention_status_rows() { return 42; }
    fm_attention_status "$2"
    printf "available=%s unknown=%s json=%s\n" "$FM_ATT_AVAILABLE" "$FM_ATT_UNKNOWN" "$FM_ATT_JSON"
  ' _ "$ROOT/bin/fm-attention-lib.sh" "$home")
  assert_contains "$out" 'available=false' "a state collection failure left attention available"
  assert_contains "$out" 'unknown=true' "a state collection failure did not report unknown"
  assert_contains "$out" 'json={"unknown":true}' "a state collection failure rendered a false empty set"
  pass "state, metadata, and status collection failures report unknown"
}

test_linked_state_inputs_follow_targets_and_dangling_links_are_unknown() {
  local home json out status
  home=$(make_home linked-state)
  mv "$home/state" "$home/state-target"
  ln -s state-target "$home/state"
  fm_write_meta "$home/state-target/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  printf 'needs-decision [key=route]: choose the deployment route\n' \
    > "$home/state-target/task-board.status-source"
  ln -s task-board.status-source "$home/state-target/task-board.status"

  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq 'length')" -eq 1 ] \
    || fail "a readable linked state directory did not expose its decision"
  printf '%s' "$json" | jq -e '.[0].identity == "decision:task-board:route:1"' >/dev/null \
    || fail "a readable linked status stream did not expose its decision"

  home=$(make_home dangling-state)
  rmdir "$home/state"
  ln -s missing-state "$home/state"
  out=$(attention "$home" --status 2>&1)
  status=$?
  expect_code 3 "$status" "a dangling state directory must report unknown"
  assert_contains "$out" 'attention=unknown' "a dangling state directory rendered a false empty set"

  home=$(make_home dangling-status)
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  ln -s missing-status "$home/state/task-board.status"
  out=$(attention "$home" --status 2>&1)
  status=$?
  expect_code 3 "$status" "a dangling status stream must report unknown"
  assert_contains "$out" 'attention=unknown' "a dangling status stream rendered a false empty set"
  pass "linked state inputs follow targets and dangling links report unknown"
}

test_unknown_projection_surfaces_again_after_successful_derivation() {
  local home snapshot out status
  home=$(make_primary_home snapshot-unknown-reopens)
  snapshot=$(failing_snapshot "$home")

  out=$(FM_ATTENTION_SNAPSHOT_BIN="$snapshot" run_turnend "$home"); status=$?
  expect_code 2 "$status" "the first unknown projection must stop the turn"
  assert_contains "$out" 'TURN WOULD END WITHOUT KNOWING WHAT THE CAPTAIN NEEDS' \
    "the first unknown projection must surface explicitly"
  assert_present "$home/state/.captain-attention-unknown" \
    "the unknown stop must record its bounded marker"

  attention "$home" --status >/dev/null
  attention "$home" --json >/dev/null
  attention "$home" --no-mark >/dev/null
  assert_present "$home/state/.captain-attention-unknown" \
    "read-only attention calls must not reset an unknown marker"

  out=$(run_turnend "$home"); status=$?
  expect_code 0 "$status" "a readable projection with nothing open must allow"
  [ -z "$out" ] || fail "the readable turn end produced output: $out"
  assert_absent "$home/state/.captain-attention-unknown" \
    "a successful derivation must reset the bounded unknown marker"

  out=$(FM_ATTENTION_SNAPSHOT_BIN="$snapshot" run_turnend "$home"); status=$?
  expect_code 2 "$status" "a fresh unknown after recovery must stop again"
  assert_contains "$out" 'TURN WOULD END WITHOUT KNOWING WHAT THE CAPTAIN NEEDS' \
    "a fresh unknown after recovery must surface explicitly"
  pass "an unknown projection surfaces again after a readable projection"
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

test_overdue_monitored_wait_is_due_now() {
  local home next
  home=$(make_home overdue-wait)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  printf 'paused: waiting for the fork synchronization\n' > "$home/state/task-board.status"
  touch -t 202001010000 "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"
  next=$(FM_PAUSE_RESURFACE_SECS=1 attention "$home" --json | jq -r '.[0].next_check_seconds')
  [ "$next" = 0 ] || fail "a monitored overdue wait reported next_check_seconds=$next"
  assert_contains "$(FM_PAUSE_RESURFACE_SECS=1 attention "$home")" 'Next check: due now' \
    "a monitored overdue wait must not be reported as unmonitored"
  pass "a monitored overdue wait reports its next check as due now"
}

test_repeated_wait_stays_routine_until_captain_action_is_explicit() {
  local home out
  home=$(make_home repeated-wait)
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
  assert_contains "$out" 'decisions=0' "repetition alone must not turn a routine delay into a decision"
  assert_contains "$out" 'waits=1' "a repeated external delay must remain a wait"

  printf 'blocked: firstmate must repair the failed synchronization\n' >> "$home/state/task-board.status"
  out=$(attention "$home" --no-mark --status)
  assert_contains "$out" 'decisions=1' "an action-required blocker must remain a critical decision"
  assert_contains "$out" 'waits=0' "the same keyed wait must fold into the action-required blocker"

  printf 'needs-decision: choose whether to keep waiting or reroute the work\n' >> "$home/state/task-board.status"
  out=$(attention "$home" --no-mark --status)
  assert_contains "$out" 'decisions=1' "an explicit captain-action transition must create a decision"
  assert_contains "$out" 'waits=0' "the same keyed wait must fold into the explicit decision"
  pass "routine delays stay routine until an explicit action-required transition"
}

test_same_key_decision_and_wait_render_once_as_combined() {
  local home out json
  home=$(make_home combined-key)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  {
    printf 'needs-decision [key=release]: choose whether to keep the release parked\n'
    printf 'paused [key=release]: waiting for legal review\n'
    printf 'paused [key=release]: legal review is still pending\n'
    printf 'paused [key=release]: waiting for the final legal answer\n'
  } > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"
  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq 'length')" -eq 1 ] || fail "one keyed issue rendered more than once: $json"
  [ "$(printf '%s' "$json" | jq -r '.[0] | "\(.class)|\(.identity)|\(.combined_wait)|\(.redeclares)"')" \
    = 'decision|decision:task-board:release:1|true|3' ] \
    || fail "the keyed decision and wait were not combined: $json"
  out=$(attention "$home")
  assert_contains "$out" 'choose whether to keep the release parked' "the decision fact disappeared"
  assert_contains "$out" 'Waiting for:' "the combined alert omitted its wait"
  assert_contains "$out" 'waiting for the final legal answer' "the combined alert omitted the current wait fact"
  assert_not_contains "$out" 'WAITING ON SOMETHING ELSE' \
    "the same keyed issue was rendered under a second category"

  printf 'done [key=release]: the worker finished\n' >> "$home/state/task-board.status"
  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq -r '.[0] | [.class, (.combined_wait // false), (.awaiting // "")] | join("|")')" \
    = 'decision|false|' ] \
    || fail "terminal work left a stale wait attached to the unresolved decision: $json"
  pass "one keyed issue combines once and terminal work closes only its wait portion"
}

test_direct_captain_hold_and_same_task_status_render_once() {
  local home json
  home=$(make_home direct-hold-dedup)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Choose the task board release path (repo: sample) (kind: ship) (hold: the release path needs captain input) (hold-kind: captain)
  Captain briefing v1:
  Semantic revision: task-board-release-v1
  Choice: Release the board now, or keep it parked.
  Why now: The board is otherwise ready to ship.
  If this waits: The board release remains parked.
  Option: Release the board now.
  Option: Keep the board parked.
  Recommended: Release the board now.'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  {
    printf 'needs-decision [key=task-board]: choose whether to release the board\n'
    printf 'paused [key=task-board]: waiting for final release confirmation\n'
  } > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq 'length')" -eq 1 ] \
    || fail "a direct captain hold duplicated its same-task status alert: $json"
  [ "$(printf '%s' "$json" | jq -r '.[0] | "\(.identity)|\(.combined_wait)|\(.awaiting)"')" \
    = 'decision:task-board|true|waiting for final release confirmation' ] \
    || fail "the direct captain hold did not retain its same-task status wait: $json"
  pass "a direct captain hold and its same-task status render once"
}

test_ambiguous_direct_hold_keeps_every_keyed_decision_visible() {
  local home json identities
  home=$(make_home direct-hold-ambiguous)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Choose the task board direction (repo: sample) (kind: ship) (hold: the board needs captain input) (hold-kind: captain)
  Captain briefing v1:
  Semantic revision: task-board-direction-v1
  Choice: Choose the board direction.
  Why now: The board is ready for direction.
  If this waits: The board remains parked.
  Option: Choose a direction now.
  Recommended: Choose a direction now.'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  {
    printf 'needs-decision [key=route]: choose the board route\n'
    printf 'needs-decision [key=access]: choose the board access policy\n'
  } > "$home/state/task-board.status"

  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq 'length')" -eq 3 ] \
    || fail "an ambiguous direct hold consumed a distinct keyed decision: $json"
  identities=$(printf '%s' "$json" | jq -r '.[].identity')
  assert_contains "$identities" 'decision:task-board' "the direct captain item disappeared"
  assert_contains "$identities" 'decision:task-board:route:1' "the route decision disappeared"
  assert_contains "$identities" 'decision:task-board:access:1' "the access decision disappeared"
  pass "an ambiguous direct hold leaves every keyed decision visible"
}

test_combined_alert_is_receiptable_through_transfer_and_clears_on_terminal_work() {
  local home out json status first_wait second_wait
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip-ish: tasks-axi absent, combined transfer not exercised"; return 0; }
  home=$(make_home combined-transfer)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=secondmate"
  {
    printf 'needs-decision [key=release]: choose whether to ship after legal review\n'
    printf 'paused [key=release]: waiting for the final legal answer\n'
  } > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold task-board release \
    --title 'Choose the release path' \
    --reason 'legal review is pending' \
    --repo sample \
    --semantic-revision release-v1 \
    --choice 'Ship after approval, or keep the release parked.' \
    --why-now 'The release is otherwise ready to move.' \
    --cost-of-waiting 'The release remains parked.' \
    --option 'Ship after legal approval.' \
    --option 'Keep the release parked.' \
    --recommend 'Ship after legal approval.' >/dev/null \
    || fail "could not register the combined captain decision"

  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq 'length')" -eq 1 ] || fail "the durable decision duplicated its live status copy: $json"
  [ "$(printf '%s' "$json" | jq -r '.[0] | "\(.identity)|\(.briefing_complete)|\(.combined_wait)|\(.awaiting)"')" \
    = 'decision:task-board-decision-release|true|true|waiting for the final legal answer' ] \
    || fail "the durable decision did not retain the combined wait: $json"
  out=$(attention "$home")
  printf '%s' "$out" | attention "$home" --record-visible >/dev/null
  status=$?
  expect_code 0 "$status" "a complete combined alert must earn a captain-visible receipt"

  first_wait=$(printf '%s' "$json" | jq -r '.[0].combined_wait_identity')
  {
    printf 'working [key=release]: legal review resumed\n'
    printf 'paused [key=release]: waiting for renewed legal confirmation\n'
  } >> "$home/state/task-board.status"
  json=$(attention "$home" --json)
  second_wait=$(printf '%s' "$json" | jq -r '.[0].combined_wait_identity')
  [ "$first_wait" != "$second_wait" ] \
    || fail "a reopened combined wait reused its previous receipt identity: $first_wait"
  assert_contains "$second_wait" 'wait:task-board:release:2' \
    "a reopened combined wait must carry a new generation"
  assert_contains "$(attention "$home" --status)" 'new=true' \
    "a reopened combined wait must surface after the earlier generation was receipted"
  record_visible "$home"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" complete task-board release >/dev/null \
    || fail "could not transfer the combined decision"
  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq -r '.[0] | "\(.briefing_complete)|\(.combined_wait)|\(.awaiting)"')" \
    = 'true|true|waiting for renewed legal confirmation' ] \
    || fail "the captain-held transfer lost the combined wait: $json"

  printf 'done [key=release]: the reviewed work finished\n' >> "$home/state/task-board.status"
  json=$(attention "$home" --json)
  [ "$(printf '%s' "$json" | jq -r '.[0] | [.briefing_complete, (.combined_wait // false), (.awaiting // "")] | join("|")')" \
    = 'true|false|' ] \
    || fail "terminal work left stale combined-wait text: $json"
  assert_not_contains "$(attention "$home")" 'waiting for renewed legal confirmation' \
    "terminal work must remove the stale combined wait from the captain view"
  pass "a combined alert remains receiptable through transfer and terminal work clears its wait"
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
  record_visible "$home"
  printf 'paused: third recheck unchanged, worded differently again\n' >> "$home/state/task-board.status"
  assert_not_contains "$(run_guard "$home")" "CAPTAIN'S CALL" "a re-worded repeat must not surface again"
  pass "attention identities ignore wording, so a repeated delay surfaces once"
}

test_reopened_status_items_get_new_generation_identity() {
  local home first second third out
  home=$(make_home wait-generation)
  add_row "$home" 'In flight' \
    '- [ ] task-board - Live watchable view of the task and priority list (repo: sample) (kind: ship) (since 2026-07-23)'
  fm_write_meta "$home/state/task-board.meta" \
    "window=fixture:fm-task-board" "project=$home/projects/sample" "kind=ship"
  printf 'paused: first external wait\n' > "$home/state/task-board.status"
  touch "$home/state/.last-watcher-beat"

  first=$(attention "$home" --no-mark --json | jq -r '.[0].identity')
  record_visible "$home"
  printf 'working: unblocked for implementation\npaused: second external wait\n' >> "$home/state/task-board.status"
  second=$(attention "$home" --no-mark --json | jq -r '.[0].identity')
  [ "$first" != "$second" ] || fail "a reopened wait reused its previous identity: $first"
  assert_contains "$second" 'wait:task-board:default:2' "a reopened wait must carry a new generation"
  assert_contains "$(attention "$home" --no-mark --status)" 'new=true' \
    "a reopened wait must re-surface even if the earlier generation was surfaced"
  record_visible "$home"
  printf 'paused: same wait with new wording\n' >> "$home/state/task-board.status"
  third=$(attention "$home" --no-mark --json | jq -r '.[0].identity')
  [ "$second" = "$third" ] || fail "a still-open wait changed identity on rewording: $second vs $third"
  out=$(attention "$home" --no-mark --status)
  assert_contains "$out" 'new=false' "a still-open wait must stay deduped after rewording"

  home=$(make_home decision-generation)
  fm_write_meta "$home/state/api-shape.meta" \
    "window=fixture:fm-api-shape" "project=$home/projects/sample" "kind=ship"
  printf 'needs-decision: choose the API shape\n' > "$home/state/api-shape.status"
  first=$(attention "$home" --no-mark --json | jq -r '.[0].identity')
  printf 'resolved: the first shape was chosen\nneeds-decision: choose the migration shape\n' >> "$home/state/api-shape.status"
  second=$(attention "$home" --no-mark --json | jq -r '.[0].identity')
  [ "$first" != "$second" ] || fail "a reopened status decision reused its previous identity: $first"
  assert_contains "$second" 'decision:api-shape:default:2' \
    "a reopened status decision must carry a new generation"
  pass "reopened status decisions and waits carry a new generation identity"
}

test_brief_form_never_spends_captain_surface_marker() {
  local home out status
  home=$(make_primary_home brief-no-mark)
  add_unsurfaced_decision "$home"
  attention "$home" --brief >/dev/null
  assert_absent "$home/state/.captain-attention" \
    "the firstmate-facing brief form must not record the surfaced digest"

  out=$(run_turnend "$home"); status=$?
  expect_code 2 "$status" "brief output must not satisfy the captain-facing turn-end stop"
  assert_contains "$out" 'NEEDS YOUR DECISION' "the turn-end stop must render the captain-safe view"
  out=$(run_turnend "$home"); status=$?
  expect_code 2 "$status" "an internal turn-end render must not record a captain receipt"
  out=$(run_turnend "$home" "$(attention "$home" --no-mark)"); status=$?
  expect_code 0 "$status" "the actual captain-visible reply must record the surfaced digest"
  [ -z "$out" ] || fail "the captain-visible turn end produced output: $out"
  pass "the brief form never spends the captain-facing surface marker"
}

test_guard_banner_never_spends_captain_receipt() {
  local home out status
  home=$(make_home guard-captain-safe)
  add_row "$home" Queued \
    '- [ ] sample-decision-x - Approve the change (repo: sample) (kind: captain) (since 2026-07-28) (hold: an operational note that is not plain language) (hold-kind: captain)'
  out=$(run_guard "$home")
  assert_contains "$out" 'NEEDS YOUR DECISION' "the guard banner must include the captain-safe decision section"
  assert_not_contains "$out" 'sample-decision-x' "the guard banner must not use the identifier-only brief form"
  status=$(attention "$home" --no-mark --status)
  assert_contains "$status" 'new=true' "an internal guard render must leave the captain receipt open"
  pass "the guard banner renders the captain-safe view without spending its receipt"
}

test_only_the_captain_renderer_writes_the_surface_marker() {
  local writers
  writers=$(
    while IFS= read -r file; do
      grep -n -- '\.captain-attention' "$file" \
        | grep -v -- '\.captain-attention-unknown' \
        | grep -v -- '\.captain-attention-decisions' \
        | grep -E -- '(^|[[:space:]])>[[:space:]]*"?[^"]*\.captain-attention("|$)|(^|[[:space:]])(tee|mv|cp|touch|rm)[[:space:]].*\.captain-attention' >/dev/null \
        && printf '%s\n' "$file"
    done <<EOF
$(grep -RIl -- '\.captain-attention' "$ROOT/bin")
EOF
  )
  writers=$(printf '%s\n' "$writers" | sort -u | sed '/^$/d')
  [ "$writers" = "$ROOT/bin/fm-attention.sh" ] || fail "surface marker writers escaped the captain renderer: $writers"
  if grep -R -- 'fm_attention_mark_surfaced' "$ROOT/bin" >/dev/null 2>&1; then
    fail "general-purpose surface marker writer was reintroduced"
  fi
  pass "only the captain-safe renderer writes the surfaced marker"
}

test_ordinary_reads_do_not_become_false_alarms() {
  local home out
  home=$(make_home quiet-reads)
  add_unsurfaced_decision "$home"
  assert_contains "$(run_guard "$home")" "CAPTAIN'S CALL CHANGED" "the first changed set must surface"
  # Reading the set, listing it, and running the guard again are all ordinary
  # conductor reads and must be silent.
  attention "$home" --no-mark --json >/dev/null
  attention "$home" --no-mark --status >/dev/null
  out=$(run_guard "$home")
  assert_contains "$out" "CAPTAIN'S CALL CHANGED" \
    "an ordinary read must not spend the captain-visible receipt"
  record_visible "$home"
  out=$(run_guard "$home")
  [ -z "$out" ] || fail "rendering the ledger produced a false alarm: $out"
  pass "ordinary reads and re-renders never become false alarms"
}

test_ledger_keeps_showing_an_open_item_after_it_was_surfaced() {
  local home out
  home=$(make_home persistent)
  add_unsurfaced_decision "$home"
  record_visible "$home"
  out=$(attention "$home" --no-mark)
  assert_contains "$out" 'Approve the worker installs' \
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
    --semantic-revision fork-main-sync-v1 \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --why-now 'The board is ready to rebase now.' \
    --cost-of-waiting 'The board remains blocked.' \
    --option 'Sync now.' \
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
    --semantic-revision fork-main-sync-v1 \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --why-now 'The board is ready to rebase now.' \
    --cost-of-waiting 'The board remains blocked.' \
    --option 'Sync now.' \
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
    --semantic-revision fork-main-sync-v2 \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --why-now 'The board is ready to rebase now.' \
    --cost-of-waiting 'The board remains blocked.' \
    --option 'Rebase onto the current fork main instead.' \
    --recommend 'Rebase onto the current fork main instead.' >/dev/null || fail "briefing update failed"
  out=$(attention "$home" --no-mark --json | jq -r '.[0].recommendation')
  [ "$out" = 'Rebase onto the current fork main instead.' ] || fail "briefing update did not take: $out"
  pass "an idempotent retry preserves a written briefing and an explicit update replaces it"
}

test_briefing_revisions_preserve_body_and_reopen_receipt_semantically() {
  local home body_file show_file out
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip-ish: tasks-axi absent, briefing revision not exercised"; return 0; }
  home=$(make_home revision)
  fm_write_meta "$home/state/fork-sync.meta" \
    "window=fixture:fm-fork-sync" "project=$home/projects/firstmate" "kind=ship"
  printf 'working: auditing\n' > "$home/state/fork-sync.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'the board is waiting' --repo firstmate \
    --semantic-revision fork-main-sync-v1 \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --why-now 'The board is ready to rebase now.' \
    --cost-of-waiting 'The board remains blocked.' \
    --option 'Sync now.' \
    --recommend 'Sync now.' >/dev/null || fail "could not register the decision"

  body_file="$home/body-with-escapes"
  {
    printf 'Origin: fork-sync\nDecision key: fork-main-sync\nState: awaiting captain decision.\n\n'
    printf 'Captain briefing v1:\nSemantic revision: fork-main-sync-v1\n'
    printf 'Choice: Sync now, or rebase onto the current fork main.\n'
    printf 'Why now: The board is ready to rebase now.\nIf this waits: The board remains blocked.\n'
    printf 'Option: Sync now.\nRecommended: Sync now.\n'
    printf 'Operator note: C:\\fleet\tquoted "yes"\rcontrol='
    printf '\001\000'
    printf ':end\n'
  } > "$body_file"
  (cd "$home" && tasks-axi update fork-sync-decision-fork-main-sync --body-file "$body_file" >/dev/null) \
    || fail "could not seed the escaped body"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'the board is waiting' \
    --semantic-revision fork-main-sync-v1 \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --why-now 'The board is ready to rebase now.' \
    --cost-of-waiting 'The board remains blocked.' \
    --option 'Sync now.' \
    --recommend 'Sync now.' >/dev/null || fail "the complete briefing rewrite failed"
  show_file="$home/show-after-rewrite"
  (cd "$home" && tasks-axi show fork-sync-decision-fork-main-sync --full) > "$show_file"
  node -e '
    const fs = require("fs");
    const line = fs.readFileSync(process.argv[1], "utf8").split("\n").find((row) => row.startsWith("  body: "));
    if (!line) process.exit(1);
    const body = JSON.parse(line.slice(8));
    if (!body.includes("Operator note: C:\\fleet\tquoted \"yes\"\rcontrol=\u0001\u0000:end")) process.exit(1);
  ' "$show_file" || fail "the briefing rewrite corrupted a preserved escaped body line"

  record_visible "$home"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'the same wait in different words' \
    --semantic-revision fork-main-sync-v1 \
    --choice 'Choose between synchronizing now and rebasing on the current fork.' \
    --why-now 'The board can proceed as soon as this direction is settled.' \
    --cost-of-waiting 'Until then, the board cannot advance.' \
    --option 'Synchronize now.' \
    --recommend 'Synchronize now.' >/dev/null || fail "the wording-only briefing update failed"
  out=$(attention "$home" --status)
  assert_contains "$out" 'decisions_new=false' "a wording-only edit reopened the captain receipt"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HOLD" hold fork-sync fork-main-sync --title 'Sync the fork main' --reason 'the same wait in different words' \
    --semantic-revision fork-main-sync-v2 \
    --choice 'Sync now, or rebase onto the current fork main.' \
    --why-now 'The board is ready to rebase now.' \
    --cost-of-waiting 'The board remains blocked.' \
    --option 'Rebase onto the current fork main.' \
    --recommend 'Rebase onto the current fork main.' >/dev/null || fail "the substantive briefing update failed"
  out=$(attention "$home" --status)
  assert_contains "$out" 'decisions_new=true' "a substantive briefing revision did not reopen the receipt"
  pass "briefing revisions preserve escaped body data and reopen receipts only for substance"
}

test_receipt_validation_keeps_each_alert_facts_with_its_headline() {
  local home mixed reply status
  home=$(make_home receipt-association)
  add_unsurfaced_decision "$home"
  add_row "$home" Queued \
    '- [ ] sample-decision-y - Choose the launch window (repo: sample) (kind: captain) (since 2026-07-28) (hold: the release needs a launch window) (hold-kind: captain)
  Captain briefing v1:
  Semantic revision: launch-window-v1
  Choice: Launch on Tuesday, or wait until Thursday.
  Why now: The release plan is ready for a date.
  If this waits: The release team cannot schedule the rollout.
  Option: Launch on Tuesday.
  Option: Launch on Thursday.
  Recommended: Launch on Tuesday.'

  mixed="CAPTAIN'S CALL

NEEDS YOUR DECISION

1. Approve the worker installs
   The choice:
     Launch on Tuesday, or wait until Thursday.
   Why it matters now:
     The release plan is ready for a date.
   If this waits:
     The release team cannot schedule the rollout.
   Options:
     - Launch on Tuesday.
     - Launch on Thursday.
   Recommended:
     Launch on Tuesday.

2. Choose the launch window
   The choice:
     Approve the worker installs now, or leave the machine unavailable.
   Why it matters now:
     The queued worker setup cannot proceed without the approval.
   If this waits:
     The worker setup and its dependent work remain stopped.
   Options:
     - Approve the installs now.
     - Leave the machine unavailable and reroute the work.
   Recommended:
     Approve the installs now so the queued setup can proceed."
  printf '%s' "$mixed" | attention "$home" --record-visible >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "facts swapped between two alert records earned a receipt"
  assert_absent "$home/state/.captain-attention" \
    "a cross-record receipt mismatch must not write the captain marker"

  reply=$(attention "$home")
  printf '%s' "$reply" | attention "$home" --record-visible >/dev/null
  status=$?
  expect_code 0 "$status" "the correctly associated alert records must earn a receipt"
  pass "captain receipts validate each alert headline with its own required facts"
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

test_turn_end_requires_a_captain_visible_complete_alert() {
  local home out status reply
  home=$(make_primary_home turnend)
  add_unsurfaced_decision "$home"

  out=$(run_turnend "$home"); status=$?
  expect_code 2 "$status" "a turn must not end with a captain decision the captain has never seen"
  assert_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' "the stop banner must read as an alarm"
  assert_contains "$out" 'bin/fm-attention.sh' "the stop must point at the captain-facing renderer"

  out=$(run_turnend "$home"); status=$?
  expect_code 2 "$status" "an internal render must not spend the receipt"
  reply=$(attention "$home" --no-mark)
  out=$(run_turnend "$home" "${reply/NEEDS YOUR DECISION/WAITING ON SOMETHING ELSE}"); status=$?
  expect_code 2 "$status" "a display under the wrong category must not count"
  out=$(run_turnend "$home" "${reply/Approve the worker installs/Approve something else}"); status=$?
  expect_code 2 "$status" "a display under the wrong headline must not count"
  out=$(run_turnend "$home" "$reply"); status=$?
  expect_code 0 "$status" "the complete captain-visible alert must satisfy the gate"
  [ -z "$out" ] || fail "the captain-visible turn end produced output: $out"
  pass "a turn ends only after the complete alert is actually captain-visible"
}

test_evidence_less_decision_stop_is_bounded() {
  local home out status
  home=$(make_primary_home turnend-no-evidence)
  add_unsurfaced_decision "$home"

  out=$(run_turnend_no_evidence "$home"); status=$?
  expect_code 2 "$status" "an evidence-less harness must still stop once on an unsurfaced decision"
  assert_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' \
    "the evidence-less stop must show the captain banner"
  assert_present "$home/state/.captain-attention-decisions" \
    "the evidence-less stop must record its bounded marker"

  out=$(run_turnend_no_evidence "$home"); status=$?
  expect_code 0 "$status" "an open decision without payload evidence must be bounded to one stop"
  [ -z "$out" ] || fail "the bounded evidence-less turn end produced output: $out"
  assert_contains "$(attention "$home" --no-mark --status)" 'decisions_new=true' \
    "the bounded stop must not spend the captain receipt"

  add_row "$home" Queued \
    '- [ ] second-decision-y - Pick the deploy window (repo: sample) (kind: captain) (since 2026-07-29) (hold: the deploy window needs captain input) (hold-kind: captain)
  Captain briefing v1:
  Semantic revision: deploy-window-v1
  Choice: Deploy tonight or hold until the weekend window.
  Why now: The release train departs before the next weekend window.
  If this waits: The release misses the train and slips a full cycle.
  Option: Deploy tonight.
  Option: Hold for the weekend window.
  Recommended: Deploy tonight so the release makes the train.'
  out=$(run_turnend_no_evidence "$home"); status=$?
  expect_code 2 "$status" "a changed decision set must re-arm the bounded stop"
  out=$(run_turnend_no_evidence "$home"); status=$?
  expect_code 0 "$status" "the re-armed stop must stay bounded to one block"

  out=$(run_turnend "$home"); status=$?
  expect_code 2 "$status" "a payload that carries the assistant reply must keep the strict receipt requirement"
  pass "an evidence-less harness gets one bounded decision stop per changed set"
}

test_claude_autoarm_allow_paths_still_stop_for_unsurfaced_decisions() {
  local home out status

  home=$(make_primary_home claude-autoarm-loop)
  add_unsurfaced_decision "$home"
  add_unsupervised_work "$home"
  printf 'epoch=1 owner_pid=999 outcome=rewake updated_at=%s\n' "$(date +%s)" > "$home/state/.claude-autoarm-epoch"
  out=$(run_turnend_claude "$home" false); status=$?
  expect_code 2 "$status" "Claude auto-arm sync-loop allow must pass the captain-call gate"
  assert_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' \
    "Claude auto-arm sync-loop allow must not hide an unsurfaced decision"

  home=$(make_primary_home claude-autoarm-post-loop)
  add_unsurfaced_decision "$home"
  add_unsupervised_work "$home"
  printf 'epoch=1 owner_pid=999 outcome=rewake updated_at=%s\n' "$(date +%s)" > "$home/state/.claude-autoarm-epoch"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 run_turnend_claude "$home" false); status=$?
  expect_code 2 "$status" "Claude auto-arm post-loop allow must pass the captain-call gate"
  assert_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' \
    "Claude auto-arm post-loop allow must not hide an unsurfaced decision"

  home=$(make_primary_home claude-budget-attention)
  add_unsurfaced_decision "$home"
  add_unsupervised_work "$home"
  printf 'session=attention-test\ncount=3\n' > "$home/state/.turnend-claude-blocks"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 run_turnend_claude "$home" true); status=$?
  expect_code 2 "$status" "Claude budget-exhausted allow must pass the captain-call gate"
  assert_contains "$out" 'TURN WOULD END WITHOUT TELLING THE CAPTAIN' \
    "Claude budget-exhausted allow must not hide an unsurfaced decision"
  assert_not_contains "$out" '"systemMessage"' \
    "Claude budget-exhausted allow must not run once an unsurfaced decision blocks"
  pass "Claude auto-arm allow paths stop on unsurfaced decisions"
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
test_new_decision_requires_a_complete_briefing
test_a_captain_gated_work_item_is_a_decision_not_a_delay
test_unbriefed_decision_is_honest_about_missing_language
test_partial_briefing_renders_recorded_fields_and_names_missing_ones
test_failed_backlog_projection_is_unknown_not_empty
test_failed_state_collection_is_unknown_not_empty
test_linked_state_inputs_follow_targets_and_dangling_links_are_unknown
test_unknown_projection_surfaces_again_after_successful_derivation
test_routine_wait_states_what_it_awaits_and_when_it_is_next_checked
test_overdue_monitored_wait_is_due_now
test_repeated_wait_stays_routine_until_captain_action_is_explicit
test_same_key_decision_and_wait_render_once_as_combined
test_direct_captain_hold_and_same_task_status_render_once
test_ambiguous_direct_hold_keeps_every_keyed_decision_visible
test_combined_alert_is_receiptable_through_transfer_and_clears_on_terminal_work
test_identities_ignore_wording_so_repeats_do_not_re_alarm
test_reopened_status_items_get_new_generation_identity
test_brief_form_never_spends_captain_surface_marker
test_guard_banner_never_spends_captain_receipt
test_only_the_captain_renderer_writes_the_surface_marker
test_ordinary_reads_do_not_become_false_alarms
test_ledger_keeps_showing_an_open_item_after_it_was_surfaced
test_resolution_clears_the_item
test_retry_never_erases_a_written_briefing
test_briefing_revisions_preserve_body_and_reopen_receipt_semantically
test_receipt_validation_keeps_each_alert_facts_with_its_headline
test_unaccounted_primary_work_is_not_idle
test_turn_end_requires_a_captain_visible_complete_alert
test_evidence_less_decision_stop_is_bounded
test_claude_autoarm_allow_paths_still_stop_for_unsurfaced_decisions
test_declared_waits_never_stop_a_turn
test_captain_view_carries_no_internal_vocabulary
test_empty_home_says_so_plainly
