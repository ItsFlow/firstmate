#!/usr/bin/env bash
# Behavior tests for the captain-inbox answer relay (bin/fm-inbox-arm.sh) and
# the bounded check it registers. Proves the relay is a valid, registered,
# fail-closed watcher check that stays silent until the board is actually served.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-inbox-arm.sh"
SERVE="$ROOT/bin/fm-inbox-serve.sh"
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

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
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
  [ "$(file_mode "$home/state/inbox.check.sh")" = 700 ] \
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
  local home fakebin out
  home=$(make_home silent)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'poll invoked\n' > "$POLL_MARKER"
exit 1
SH
  chmod +x "$fakebin/curl" "$fakebin/lavish-axi"
  FM_HOME="$home" "$ARM" "$home/board.html" >/dev/null || fail "arming must succeed"
  out=$(POLL_MARKER="$home/poll-invoked" PATH="$fakebin:$PATH" \
    bash "$home/state/inbox.check.sh")
  [ -z "$out" ] || fail "an unserved relay must print nothing, got: $out"
  assert_absent "$home/poll-invoked" \
    "an unserved relay must not invoke lavish-axi poll"
  assert_absent "$home/state/inbox-answers" \
    "an unserved relay must not create an answers directory"
  pass "the relay stays silent and starts no server while the board is unserved"
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

test_relay_rejects_linked_check_path_without_writing_through() {
  local home peer out
  home=$(make_home linked)
  peer="$home/external.txt"
  printf 'external sentinel\n' > "$peer"
  ln -s "$peer" "$home/state/inbox.check.sh"
  if out=$(FM_HOME="$home" "$ARM" "$home/board.html" 2>&1); then
    fail "arming must refuse a linked relay path: $out"
  fi
  [ "$(cat "$peer")" = "external sentinel" ] \
    || fail "a linked relay path must not be written through"
  [ -L "$home/state/inbox.check.sh" ] || fail "the rejected symlink must remain"
  assert_absent "$home/state/inbox.check-trust" \
    "a rejected relay path must not be registered"

  rm -f -- "$home/state/inbox.check.sh"
  printf 'hardlink sentinel\n' > "$peer"
  ln "$peer" "$home/state/inbox.check.sh"
  if out=$(FM_HOME="$home" "$ARM" "$home/board.html" 2>&1); then
    fail "arming must refuse a hardlinked relay path: $out"
  fi
  [ "$(cat "$peer")" = "hardlink sentinel" ] \
    || fail "a hardlinked relay path must not be written through"
  assert_absent "$home/state/inbox.check-trust" \
    "a rejected hardlinked relay path must not be registered"
  pass "arming refuses linked relay paths without writing through them"
}

test_relay_escapes_paths_and_exports_port() {
  local home fakebin capture actual expected
  home=$(make_home "quote'path")
  fakebin=$(fm_fakebin "$home")
  capture="$home/poll-capture.txt"
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n%s\n' "${LAVISH_AXI_PORT:-}" "${2:-}" > "$CAPTURE"
exit 1
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/lavish-axi" "$fakebin/curl"
  FM_HOME="$home" "$ARM" --port 5173 "$home/board.html" >/dev/null \
    || fail "arming a quoted path must succeed"
  bash -n "$home/state/inbox.check.sh" || fail "the relay must be valid bash"
  CAPTURE="$capture" PATH="$fakebin:$PATH" bash "$home/state/inbox.check.sh"
  actual=$(cat "$capture")
  expected=$(printf '5173\n%s' "$home/board.html")
  [ "$actual" = "$expected" ] || fail "the relay must preserve its port and board path"
  pass "the relay shell-escapes paths and exports its target port"
}

test_relay_wakes_once_for_feedback() {
  local home fakebin out answers count answer_file
  home=$(make_home feedback)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'status: feedback\n'
printf ' decision,"DECISION task: ship it"\n'
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/lavish-axi"
  FM_HOME="$home" "$ARM" "$home/board.html" >/dev/null || fail "arming must succeed"
  out=$(PATH="$fakebin:$PATH" bash "$home/state/inbox.check.sh")
  [ "$out" = "inbox board: a captain answer is waiting in state/inbox-answers" ] \
    || fail "feedback must emit exactly one fixed wake line, got: $out"
  answers=$home/state/inbox-answers
  assert_present "$answers" "feedback must create the answer drop"
  count=$(find "$answers" -type f | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "feedback must write exactly one answer file, got $count"
  [ "$(file_mode "$answers")" = 700 ] || fail "the answer drop must be mode 0700"
  answer_file=$(find "$answers" -type f -name '*.txt' -print | head -n1)
  [ -n "$answer_file" ] || fail "feedback must write a named answer file"
  [ "$(file_mode "$answer_file")" = 600 ] || fail "the answer file must be mode 0600"
  assert_grep "DECISION task: ship it" "$answer_file" \
    "the answer file must preserve the captain feedback"
  pass "the relay emits one fixed wake line for feedback"
}

test_relay_rejects_linked_answer_drop_with_diagnostic() {
  local home fakebin out peer_count
  home=$(make_home linked-answers)
  fakebin=$(fm_fakebin "$home")
  mkdir -p "$home/external-answers"
  ln -s "$home/external-answers" "$home/state/inbox-answers"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'status: feedback\n'
printf ' decision,"DECISION task: keep private"\n'
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/lavish-axi"
  FM_HOME="$home" "$ARM" "$home/board.html" >/dev/null || fail "arming must succeed"
  out=$(PATH="$fakebin:$PATH" bash "$home/state/inbox.check.sh")
  [ "$out" = "inbox board error: could not record captain answer in state/inbox-answers" ] \
    || fail "unsafe answer drop must emit one diagnostic wake, got: $out"
  [ -L "$home/state/inbox-answers" ] || fail "the unsafe answer drop symlink must remain untouched"
  peer_count=$(find "$home/external-answers" -type f | wc -l | tr -d ' ')
  [ "$peer_count" = 0 ] || fail "the relay must not write through a linked answer drop"
  pass "the relay refuses linked answer drops with a diagnostic wake"
}

test_serve_passes_resolved_port_to_relay() {
  local home fakebin out
  home=$(make_home serveport)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'url: "http://%s:%s/session/abc123"\n' "${LAVISH_AXI_LINK_HOST:-127.0.0.1}" "${LAVISH_AXI_PORT:-4387}"
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '200'
SH
  chmod +x "$fakebin/lavish-axi" "$fakebin/curl"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" LAVISH_AXI_PORT=5199 \
    "$SERVE" --no-generate --link-host 100.64.0.1 "$home/board.html" 2>&1) \
    || fail "serving must succeed: $out"
  assert_contains "$out" "reachable: yes" "the served board must be verified"
  assert_grep "export LAVISH_AXI_PORT=5199" "$home/state/inbox.check.sh" \
    "serving must arm the relay against the served port"
  pass "serve passes its resolved port into the armed relay"
}

test_help_exits_zero
test_no_arg_refuses
test_writes_and_registers_a_valid_check
test_registration_rejects_tampering
test_relay_is_silent_when_board_unserved
test_relay_targets_the_board_path
test_relay_rejects_linked_check_path_without_writing_through
test_relay_escapes_paths_and_exports_port
test_relay_wakes_once_for_feedback
test_relay_rejects_linked_answer_drop_with_diagnostic
test_serve_passes_resolved_port_to_relay
