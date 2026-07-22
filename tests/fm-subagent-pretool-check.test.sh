#!/usr/bin/env bash
# Behavior tests for the two-layer primary-session delegation guard: the
# permissions.deny tool-availability list and the delegation-shape PreToolUse
# backstop behind it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
SETTINGS="$ROOT/.claude/settings.json"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

BRIEF_ONLY_ROUTE='investigation and ship work both go to bin/fm-brief.sh then bin/fm-spawn.sh'
SCOUT_ROUTE='investigation or diagnosis goes to bin/fm-scout.sh "<question>" [project], and ship work goes to bin/fm-brief.sh then bin/fm-spawn.sh'

# Every delegation, scheduling, worktree, and task-tracking tool Claude Code
# 2.1.217 offers a primary session. Layer 1 must remove all of these from the
# model's schema, so a Claude Code upgrade or a careless edit cannot silently
# drop one. Recorded from an observed baseline tool list, see
# docs/subagent-guard.md.
DENIED_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate CronDelete CronList TaskCreate TaskGet TaskList TaskUpdate TaskStop TaskOutput'

# Tools that must stay available: denying these would break ordinary work.
PRESERVED_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings DesignSync PushNotification'

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

# ---------------------------------------------------------------------------
# Layer 1: the permissions.deny tool-availability list (the primary fix).
# ---------------------------------------------------------------------------

test_deny_list_covers_every_known_delegation_tool() {
  local tool
  for tool in $DENIED_TOOLS; do
    jq -e --arg t "$tool" '.permissions.deny | index($t)' "$SETTINGS" >/dev/null \
      || fail "permissions.deny lost the delegation tool $tool"
  done
  # "Task" is the historical key and "Agent" is the name the tool presents
  # under; both are verified to work and both are pinned so neither a rename
  # nor a rollback can reopen the surface.
  jq -e '.permissions.deny | index("Task") and index("Agent")' "$SETTINGS" >/dev/null \
    || fail "both the Task and Agent deny keys must stay pinned"
  pass "permissions.deny pins every known Claude Code delegation and scheduling tool"
}

test_deny_list_preserves_ordinary_tools() {
  local tool
  for tool in $PRESERVED_TOOLS; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) | not' "$SETTINGS" >/dev/null \
      || fail "permissions.deny must not remove the ordinary tool $tool"
  done
  pass "permissions.deny leaves every ordinary working tool available"
}

# ---------------------------------------------------------------------------
# Layer 2: the delegation-shape PreToolUse backstop.
# ---------------------------------------------------------------------------

test_backstop_denies_every_currently_known_delegation_tool() {
  local tool
  for tool in $DENIED_TOOLS; do
    case "$tool" in
      TaskOutput|TaskStop|TaskGet|TaskList|CronList) continue ;;
    esac
    expect_deny "known delegation tool" "$tool"
  done
  pass "the backstop independently denies every work-creating delegation tool by shape"
}

test_backstop_denies_hypothetical_future_tools() {
  # The whole reason this layer exists: a deny list is fail-open against tools
  # that do not exist yet. None of these names is on any list.
  local tool
  for tool in SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun \
              ScheduleJob CronSchedule CreateWorktree DispatchAgent TaskHandoff \
              RemoteExec BackgroundAgent; do
    expect_deny "future delegation tool" "$tool"
  done
  pass "the backstop denies delegation-shaped tools that no deny list knows about yet"
}

test_backstop_allows_ordinary_and_observe_only_tools() {
  local tool
  for tool in $PRESERVED_TOOLS; do
    expect_allow "ordinary tool" "$tool"
  done
  # Observing or stopping work that already exists is not creating unaccounted
  # work, and blocking it would strand a runaway task with no way to end it.
  for tool in TaskOutput TaskStop TaskGet TaskList CronList BashOutput KillShell; do
    expect_allow "observe-or-stop tool" "$tool"
  done
  pass "the backstop leaves ordinary tools and observe-or-stop operations alone"
}

test_backstop_never_classifies_mcp_tools() {
  # An MCP server names its own tools; a task or agent noun there is common and
  # has nothing to do with fleet dispatch.
  local tool
  for tool in mcp__linear__list_issues mcp__tracker__create_task \
              mcp__acme__spawn_agent mcp__slack__slack_send_message; do
    expect_allow "MCP tool" "$tool"
  done
  pass "MCP tool names are never classified as harness delegation"
}

test_scout_entry_point_named_when_present() {
  local actual
  printf '#!/usr/bin/env bash\n' > "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-present case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$SCOUT_ROUTE"*) ;;
    *) fail "deny must name bin/fm-scout.sh when it exists: $actual" ;;
  esac
  rm -f "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "scout-absent case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$BRIEF_ONLY_ROUTE"*) ;;
    *) fail "deny must degrade to brief-then-spawn when fm-scout.sh is absent: $actual" ;;
  esac
  pass "deny names bin/fm-scout.sh when it exists and degrades gracefully when it does not"
}

test_escape_hatch_allows_deliberate_use() {
  local rc value
  expect_allow "escape hatch set" Agent FM_ALLOW_SUBAGENT=1
  expect_deny "escape hatch unset" Agent
  for value in '' 0 yes true 11; do
    rc=0
    run_tool Agent "FM_ALLOW_SUBAGENT=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_SUBAGENT='$value' must not release the guard, got exit $rc"
  done
  pass "the single documented escape hatch releases the guard only on the exact opt-in value"
}

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "task-worktree no-op wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "task-worktree no-op wrote stderr: $(cat "$ERR")"

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the backstop is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home operates a fleet and must be guarded, got exit $rc"
  pass "a marked secondmate home is guarded even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"Agent"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[subagent-dispatch]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Bash through stdin must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and tool-name-less payloads fail open rather than blocking every tool call"
}

test_claude_hook_registration_preserves_bash_seatbelts() {
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher != "Bash") | .hooks[].command]
      | any(contains("fm-subagent-pretool-check.sh --claude"))
  ' "$SETTINGS" >/dev/null || fail "Claude settings omit the delegation-shape PreToolUse backstop"
  # The backstop matcher must reach the delegation-shaped names, not just one
  # literal tool, or it cannot catch a future tool at all.
  jq -e '
    [.hooks.PreToolUse[] | select(.hooks[].command | contains("fm-subagent-pretool-check.sh")) | .matcher] | .[0]
      | (contains("Agent") and contains("Task") and contains("Workflow") and contains("Cron") and contains("Worktree"))
  ' "$SETTINGS" >/dev/null || fail "the backstop matcher no longer covers the delegation-shaped families"
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] as $bash
      | ($bash | any(contains("fm-arm-pretool-check.sh")))
      and ($bash | any(contains("fm-cd-pretool-check.sh")))
      and ($bash | any(contains("fm-continuity-pretool-check.sh")))
  ' "$SETTINGS" >/dev/null || fail "the existing Bash PreToolUse seatbelts changed"
  jq -e '.hooks.Stop[0].hooks[0].command | contains("fm-turnend-guard.sh")' "$SETTINGS" >/dev/null \
    || fail "the Stop turn-end backstop changed"
  pass "Claude wires the backstop while preserving the Bash seatbelts and the Stop guard"
}

test_deny_list_covers_every_known_delegation_tool
test_deny_list_preserves_ordinary_tools
test_backstop_denies_every_currently_known_delegation_tool
test_backstop_denies_hypothetical_future_tools
test_backstop_allows_ordinary_and_observe_only_tools
test_backstop_never_classifies_mcp_tools
test_scout_entry_point_named_when_present
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_malformed_transport_fails_open
test_claude_hook_registration_preserves_bash_seatbelts
