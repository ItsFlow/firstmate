#!/usr/bin/env bash
# Behavior tests for the captain-inbox answer relay (bin/fm-inbox-arm.sh) and
# the bounded check it registers. Proves the relay is a valid, registered,
# fail-closed watcher check that stays silent until the board is actually served.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-inbox-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-arm)

# check_registered <state-dir> <id>: true when the watcher would execute the
# check, using the same trust primitives the watcher itself uses.
check_registered() {
  bash -c '
    ROOT=$1; state=$2; id=$3
    # shellcheck disable=SC1090
    . "$ROOT/bin/fm-pr-lib.sh"
    . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$state" "$id"
  ' _ "$ROOT" "$1" "$2"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state"
  printf '<html>board</html>' > "$home/board.html"
  printf '%s\n' "$home"
}

test_help_exits_zero() {
  local out
  out=$("$ARM" --help) || fail "--help must exit 0"
  assert_contains "$out" "answer relay" "--help must describe the relay"
  pass "--help prints the header and exits 0"
}

test_no_arg_refuses() {
  local code=0
  "$ARM" >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "arming with no board path must refuse"
  pass "a missing board path refuses"
}

test_writes_and_registers_a_valid_check() {
  local home out
  home=$(make_home valid)
  out=$(FM_HOME="$home" "$ARM" "$home/board.html") || fail "arming must succeed"
  assert_contains "$out" "armed:" "arming must confirm"
  assert_present "$home/state/inbox.check.sh" "the relay file must be written"
  assert_present "$home/state/inbox.check-trust" "the relay must be registered"
  [ "$(stat -f '%Lp' "$home/state/inbox.check.sh" 2>/dev/null \
      || stat -c '%a' "$home/state/inbox.check.sh")" = 700 ] \
    || fail "the relay must be mode 0700"
  check_registered "$home/state" inbox || fail "the watcher must accept the relay"
  pass "arming writes a mode-0700 relay and registers it for the watcher"
}

test_registration_rejects_tampering() {
  local home
  home=$(make_home tamper)
  FM_HOME="$home" "$ARM" "$home/board.html" >/dev/null || fail "arming must succeed"
  check_registered "$home/state" inbox || fail "the fresh relay must be accepted"
  printf '\n# tampered\n' >> "$home/state/inbox.check.sh"
  if check_registered "$home/state" inbox; then
    fail "a byte change to the relay must invalidate its registration"
  fi
  pass "editing the relay after registration invalidates it"
}

test_relay_is_silent_when_board_unserved() {
  local home out
  home=$(make_home silent)
  FM_HOME="$home" "$ARM" "$home/board.html" >/dev/null || fail "arming must succeed"
  # No Lavish session is serving this board, so the poll fails fast and the relay
  # prints nothing and wakes no one. This is what keeps an idle relay quiet.
  out=$(bash "$home/state/inbox.check.sh")
  [ -z "$out" ] || fail "an unserved relay must print nothing, got: $out"
  assert_absent "$home/state/inbox-answers" \
    "an unserved relay must not create an answers directory"
  pass "the relay stays silent and writes nothing while the board is unserved"
}

test_relay_targets_the_board_path() {
  local home
  home=$(make_home path)
  FM_HOME="$home" "$ARM" "$home/board.html" >/dev/null || fail "arming must succeed"
  assert_grep "$home/board.html" "$home/state/inbox.check.sh" \
    "the relay must poll the exact board it was armed for"
  assert_grep "state/inbox-answers" "$home/state/inbox.check.sh" \
    "the relay must record answers durably for firstmate to pick up"
  pass "the relay is bound to its board and a durable answer drop"
}

test_help_exits_zero
test_no_arg_refuses
test_writes_and_registers_a_valid_check
test_registration_rejects_tampering
test_relay_is_silent_when_board_unserved
test_relay_targets_the_board_path
