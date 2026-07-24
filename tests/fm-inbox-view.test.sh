#!/usr/bin/env bash
# Behavior tests for the read-only captain decision-and-review board.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-inbox-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-view)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # tasks-axi stub: only `show <id> --full` is used, and it returns text that is
  # deliberately longer and comma-bearing so a truncating reader is detectable.
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "show" ] || exit 1
printf 'task:\n'
printf '  id: %s\n' "$2"
printf '  title: "Full title for %s"\n' "$2"
case "$2" in
  hidden-decision)
    printf '  hold_reason: "First clause, second clause, and the FULLTEXTMARKER tail."\n'
    ;;
  *)
    printf '  hold_reason: "Recorded note for %s, with a comma."\n' "$2"
    ;;
esac
printf '  hold_kind: captain\n'
printf '  body: "Origin: some-scout\\nDecision key: k\\nState: awaiting captain decision."\n'
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/tasks-axi"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] running-task - Running Task (repo: alpha) (kind: ship) (since 2026-07-07)

## Queued
- [ ] hidden-decision - Hidden Decision (repo: alpha) (kind: ship) (since 2026-07-01) (hold: short snapshot text) (hold-kind: captain)
- [ ] plain-decision - Plain Decision (repo: beta) (kind: captain) (since 2026-07-02) (hold: another note) (hold-kind: captain)
- [ ] workflowy-partner-idea - Workflowy Partner Idea (kind: captain) (since 2026-07-02) (hold: a no-project decision) (hold-kind: captain)
- [ ] blocked-decision - Blocked Decision blocked-by: running-task (repo: alpha) (kind: captain) (since 2026-07-03) (hold: waiting note) (hold-kind: captain)
- [ ] pr-task - PR Task (repo: alpha) (kind: ship) (since 2026-07-05)

## Done
- [x] shipped-task - Shipped Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  fm_write_meta "$home/state/pr-task.meta" \
    "window=firstmate:fm-pr-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/920"
  fm_write_meta "$home/state/shipped-task.meta" \
    "window=firstmate:fm-shipped-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/7"
}

write_cards() {  # <path>
  cat > "$1" <<'EOF'
## hidden-decision
### question
Should we do the plain-English thing?
### plain
This is what you are actually choosing.
### why
It came from an investigation that hit this fork in the road.
### take
Do it, it is cheap.
### link
https://example.invalid/product
### options
- Yes, do it
- No, drop it
### expand
The deep technical detail nobody needs up front.
### flag
Firstmate assumed this because nobody ever said otherwise; accept it or drop it.
EOF
}

# section_of <board> <block>: print one rendered section so an assertion can
# target it instead of the whole page.
section_of() {
  python3 - "$1" "$2" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()
match = re.search(
    r'<section class="block" data-block="%s".*?</section>' % re.escape(sys.argv[2]),
    src,
    re.S,
)
sys.stdout.write(match.group(0) if match else "")
PY
}

# manifest <home>: content hash of every file under state/ and data/, so a test
# can prove the board generator mutated nothing.
manifest() {
  local home=$1 f
  ( cd "$home" && find state data -type f 2>/dev/null | LC_ALL=C sort ) | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s %s\n' "$(shasum -a 256 "$home/$f" | cut -d' ' -f1)" "$f"
  done
}

test_help_exits_zero() {
  local out
  out=$("$VIEW" --help) || fail "--help must exit 0"
  assert_contains "$out" "READ-ONLY projection" "--help must print the script header"
  assert_contains "$out" "--verify-prs" "--help must document its options"
  pass "--help prints the header and exits 0"
}

test_selects_captain_holds_regardless_of_kind() {
  local home fakebin out board
  home=$(make_home selection)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" 2>&1) \
    || fail "generator must succeed: $out"

  # The snapshot's own captain_actionable also requires kind == "captain", which
  # hides every thread gated with `tasks-axi hold --kind captain`. hidden-decision
  # is exactly that shape and must still reach the board.
  assert_grep 'id="decision-hidden-decision"' "$board" \
    "a captain hold on a ship-kind item must appear in Decide"
  assert_grep 'id="decision-plain-decision"' "$board" \
    "a captain-kind captain hold must appear in Decide"
  assert_no_grep 'id="decision-blocked-decision"' "$board" \
    "a captain hold with an unresolved blocker must not appear in Decide"
  assert_grep '3 decisions' "$board" "the Decide count must match the selection"
  pass "Decide selects on the captain hold alone and excludes blocked holds"
}

test_uses_untruncated_hold_text() {
  local home fakebin board
  home=$(make_home fulltext)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  assert_grep 'FULLTEXTMARKER' "$board" \
    "decision text must come from tasks-axi show --full, not the truncated snapshot"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --no-full-text "$board" >/dev/null 2>&1 \
    || fail "--no-full-text must succeed"
  assert_no_grep 'FULLTEXTMARKER' "$board" \
    "--no-full-text must fall back to the snapshot text"
  pass "full decision text is read through tasks-axi and can be opted out of"
}

test_recorded_pr_is_marked_unverified() {
  local home fakebin board review
  home=$(make_home prstate)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  review=$(section_of "$board" review)
  assert_contains "$review" "pull/920" "an unlanded recorded pull request belongs in review"
  assert_contains "$review" "it may already be closed or merged" \
    "an unverified pull request must say so rather than read as ready to merge"
  assert_not_contains "$review" "pull/7\"" \
    "a pull request on landed work must not appear in the review section"
  assert_contains "$(section_of "$board" shipped)" "pull/7" \
    "a landed pull request stays linked from the shipped section"
  pass "recorded pull requests render as unverified and landed ones stay out"
}

test_unknown_pr_verification_stays_reviewable() {
  local home fakebin board review
  home=$(make_home prunknown)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh"
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --verify-prs "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  review=$(section_of "$board" review)
  assert_contains "$review" "pull/920" \
    "a pull request with an unknown verification result must stay reviewable"
  assert_contains "$review" "could not be checked" \
    "an unknown verification result must be marked as unchecked"
  assert_not_contains "$review" "already unknown" \
    "an unknown verification result must not be classified as stale"
  pass "unknown PR verification stays in Review and merge"
}

test_cards_render_and_absence_is_declared() {
  local home fakebin board cards
  home=$(make_home cards)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  cards=$home/cards.md
  write_cards "$cards"
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --cards "$cards" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  assert_grep 'Should we do the plain-English thing?' "$board" "the plain question must lead the card"
  assert_grep 'This is what you are actually choosing.' "$board" "In plain terms must render"
  assert_grep 'It came from an investigation' "$board" "the why must render"
  assert_grep 'Do it, it is cheap.' "$board" "the recommendation must render"
  assert_grep 'https://example.invalid/product' "$board" "the research link must render"
  assert_grep 'The deep technical detail' "$board" "the expandable detail must render"
  assert_grep "firstmate&#x27;s assumption, not your call" "$board" \
    "an assumption must be flagged as such"
  assert_grep 'no plain-English summary written yet' "$board" \
    "a decision with no card must declare that rather than look complete"
  pass "decision cards render in full and missing cards are declared"
}

test_answer_control_queues_once_per_question() {
  local home fakebin board queue_calls
  home=$(make_home answers)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  assert_grep 'data-lavish-question="hidden-decision"' "$board" \
    "each decision needs its own question wrapper"
  assert_grep 'onsubmit=' "$board" "answers are queued on submit, not on radio change"
  assert_no_grep 'onchange=' "$board" "a radio change must not queue a prompt"
  queue_calls=$(grep -c -F 'window.lavish.queuePrompt(text' "$board")
  [ "$queue_calls" -eq 1 ] \
    || fail "one shared queue call is expected, not one per card, got $queue_calls"
  pass "answers queue exactly once per question, on submit"
}

test_free_text_answer_is_first_class() {
  local home fakebin cards board
  home=$(make_home freeform)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  cards=$home/cards.md
  write_cards "$cards"
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --cards "$cards" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  # A free-text answer must submit on its own: the guard blocks only when BOTH
  # the note and any picked option are empty, never on a missing option alone.
  assert_grep 'if(!choice&&!note){' "$board" \
    "the answer must submit with just free text, not require an option"
  assert_no_grep 'var answer=data.get(' "$board" \
    "the old option-required submit path must be gone"
  assert_grep 'You do not have to pick an option above.' "$board" \
    "the free-text box must say an option is not required"
  # A card with options still offers them as quick-picks with a clear-selection
  # reset, so a picked radio is never a trap.
  assert_grep 'name="answer" value="Yes, do it"' "$board" \
    "predefined options remain available as quick-picks"
  assert_grep 'fmInboxClear(this)' "$board" "a clear-selection reset must exist"
  pass "free text answers stand alone and options are optional quick-picks"
}

test_discuss_path_present() {
  local home fakebin board
  home=$(make_home discuss)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  assert_grep 'data-lavish-question="hidden-decision-discuss"' "$board" \
    "each decision needs a discuss path distinct from its answer"
  assert_grep 'fmInboxDiscuss' "$board" "the discuss control must be wired"
  assert_grep "'DISCUSS '+hold" "$board" \
    "a question must be relayed as a discussion, not an answer"
  assert_grep 'Ask a question instead' "$board" "the discuss affordance must be visible"
  pass "every decision offers a discuss/clarify path"
}

test_answer_sends_immediately() {
  local home fakebin board
  home=$(make_home immediate)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  # The submit both queues and sends, so an answer never waits on a separate
  # Send button the captain has to find - the silently-eaten-answers failure.
  assert_grep 'window.lavish.sendQueuedPrompts()' "$board" \
    "a submitted answer must be sent, not left queued"
  assert_grep 'Sent to firstmate.' "$board" "the card must confirm delivery"
  pass "a submitted answer is sent immediately with visible confirmation"
}

test_no_project_items_get_readable_names() {
  local home fakebin board
  home=$(make_home areas)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  # workflowy-partner-idea has no repo; it must read as a named area, never as
  # the useless generic "no project" badge.
  assert_grep 'id="decision-workflowy-partner-idea"' "$board" \
    "the no-project decision must render"
  assert_grep '<option value="personal">' "$board" \
    "a no-project item must get a readable area name in the filter"
  assert_no_grep '>no project<' "$board" \
    "no item should show the generic no-project label"
  pass "no-project items get readable area names instead of a generic badge"
}

test_long_titles_wrap() {
  local home fakebin board
  home=$(make_home overflow)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  # Lavish's layout audit flags horizontal overflow as an error, so the page
  # must not scroll sideways and long unbreakable strings must wrap.
  assert_grep 'overflow-x:hidden' "$board" "the page body must not scroll sideways"
  assert_grep 'word-break:break-word' "$board" "long titles and ids must wrap"
  pass "long titles wrap instead of overflowing the card"
}

test_filters_are_present() {
  local home fakebin board
  home=$(make_home filters)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  assert_grep 'data-type-filter="decisions"' "$board" "a decisions-only filter must exist"
  assert_grep 'data-type-filter="shipped"' "$board" "a shipped-only filter must exist"
  assert_grep 'id="project-filter"' "$board" "a per-project filter must exist"
  assert_grep '<option value="alpha">' "$board" "each project must be selectable"
  assert_grep '<option value="beta">' "$board" "each project must be selectable"
  assert_grep 'data-block="decide"' "$board" "every section carries its type"
  assert_grep 'data-block="stuck"' "$board" "every section carries its type"
  pass "type and project filters are rendered for every section"
}

test_generator_mutates_nothing() {
  local home fakebin board before after
  home=$(make_home readonly)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  board=$home/board.html
  before=$(manifest "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" "$board" >/dev/null 2>&1 \
    || fail "generator must succeed"
  after=$(manifest "$home")
  [ "$before" = "$after" ] || fail "board generation mutated state/ or data/:
$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  assert_present "$board" "the board itself must be written"
  assert_absent "$home/data/inbox-cards.md" "the generator must not create its own inputs"
  pass "board generation leaves state/ and data/ byte-identical"
}

test_missing_cards_file_refuses() {
  local home fakebin out code=0
  home=$(make_home badcards)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --cards "$home/absent.md" "$home/b.html" 2>&1) \
    || code=$?
  expect_code 1 "$code" "an explicitly named missing cards file must refuse"
  assert_contains "$out" "decision cards file not found" "the refusal must name the problem"
  assert_absent "$home/b.html" "a refused run must not leave a board behind"
  pass "a missing explicit cards file refuses instead of rendering a silent gap"
}

test_help_exits_zero
test_selects_captain_holds_regardless_of_kind
test_uses_untruncated_hold_text
test_recorded_pr_is_marked_unverified
test_unknown_pr_verification_stays_reviewable
test_cards_render_and_absence_is_declared
test_answer_control_queues_once_per_question
test_free_text_answer_is_first_class
test_discuss_path_present
test_answer_sends_immediately
test_no_project_items_get_readable_names
test_long_titles_wrap
test_filters_are_present
test_generator_mutates_nothing
test_missing_cards_file_refuses
