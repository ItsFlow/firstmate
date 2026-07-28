#!/usr/bin/env bash
# fm-inbox-serve.sh - generate, serve, and arm the captain's decision board.
#
# One operator command makes the board reliable end to end:
#   1. regenerates the board through bin/fm-inbox-view.sh (read-only),
#   2. writes and registers a bounded watcher relay at state/inbox.check.sh so
#      the captain's answers reach firstmate without anyone remembering to poll,
#   3. serves the board on the advertised Tailscale address,
#   4. prints and verifies the exact link to hand the captain.
#
# The relay is the fix for the captain's core complaint: with nothing polling
# the board, submitted answers looked silently eaten. Once armed, firstmate's
# supervision cycle polls the served board on its normal check cadence, appends
# any answer to state/inbox-answers/, and wakes firstmate to act on it. When the
# board is not being served the poll fails fast and the relay stays a silent
# no-op, so it never floods.
#
# Unlike bin/fm-inbox-view.sh, which is a pure read-only generator, this command
# writes firstmate's own private runtime state (the relay and its registration).
# Run it from the operating firstmate home.
#
# Usage:
#   fm-inbox-serve.sh [<board.html>]
#   fm-inbox-serve.sh [options] [<board.html>]
#   fm-inbox-serve.sh --help
#
# Board path defaults to $HOME/lavish-boards/inbox/board.html.
#
# Options:
#   --no-generate       serve the board as it stands; do not regenerate it.
#   --no-arm            serve without writing or registering the relay (the
#                       answers will not reach firstmate on their own).
#   --link-host <ip>    Tailscale address to advertise in the link. Default is
#                       the first 100.* address reported by `ifconfig`.
#   --cards <path>      passed through to fm-inbox-view.sh.
#   --verify-prs        passed through to fm-inbox-view.sh.
#   Any other fm-inbox-view.sh option can follow `--` and is passed through.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-inbox-serve: %s\n' "$1" >&2
  exit "${2:-1}"
}

BOARD=
GENERATE=1
ARM=1
LINK_HOST=
PORT=${LAVISH_AXI_PORT:-4387}
VIEW_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-generate) GENERATE=0; shift ;;
    --no-arm) ARM=0; shift ;;
    --link-host)
      [ "$#" -ge 2 ] || die "--link-host requires an address" 2
      LINK_HOST=$2; shift 2 ;;
    --cards)
      [ "$#" -ge 2 ] || die "--cards requires a path" 2
      VIEW_ARGS+=(--cards "$2"); shift 2 ;;
    --verify-prs) VIEW_ARGS+=(--verify-prs); shift ;;
    --) shift; VIEW_ARGS+=("$@"); break ;;
    -*) usage >&2; exit 2 ;;
    *)
      [ -z "$BOARD" ] || die "only one board path is accepted" 2
      BOARD=$1; shift ;;
  esac
done

[ -n "$BOARD" ] || BOARD="${HOME:-/tmp}/lavish-boards/inbox/board.html"
case "$BOARD" in
  /*) ;;
  *) BOARD="$PWD/$BOARD" ;;
esac
command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi not found"

if [ "$GENERATE" -eq 1 ]; then
  "$SCRIPT_DIR/fm-inbox-view.sh" "${VIEW_ARGS[@]}" "$BOARD" || die "board generation failed"
fi
[ -f "$BOARD" ] || die "board not found: $BOARD (generate it first, or drop --no-generate)"

# Arm the relay so answers reach firstmate without manual polling. Owned by
# fm-inbox-arm.sh; this is firstmate's own private state.
if [ "$ARM" -eq 1 ]; then
  "$SCRIPT_DIR/fm-inbox-arm.sh" --port "$PORT" "$BOARD" \
    || die "could not arm the answer relay"
fi

# Detect the advertised Tailscale address unless one was supplied. The active
# interface address is enough for Lavish links and does not depend on the
# tailscale CLI's login-state reporting.
if [ -z "$LINK_HOST" ]; then
  LINK_HOST=$(ifconfig 2>/dev/null | awk '/inet 100\./ {print $2; exit}')
fi
[ -n "$LINK_HOST" ] || die "could not determine a Tailscale address; pass --link-host <ip>"

# Serve on all interfaces with the advertised link so the captain can reach it
# from another device. Do not open a local browser on the serving machine.
served=$(LAVISH_AXI_HOST=0.0.0.0 LAVISH_AXI_LINK_HOST="$LINK_HOST" LAVISH_AXI_NO_OPEN=1 \
  lavish-axi "$BOARD" 2>&1) || die "lavish-axi could not serve the board:
$served"

url=$(printf '%s\n' "$served" | awk -F'"' '/url:/ {print $2; exit}')
[ -n "$url" ] || url=$(printf '%s\n' "$served" | grep -oE 'https?://[^ ]+/session/[A-Za-z0-9]+' | head -1)
[ -n "$url" ] || die "served the board but could not read its link:
$served"

session=${url##*/session/}
verify="http://$LINK_HOST:$PORT/session/$session"
code=$(curl -s -o /dev/null -w '%{http_code}' "$verify" 2>/dev/null || printf '000')

printf 'board: %s\n' "$BOARD"
printf 'link:  %s\n' "$url"
if [ "$code" = 200 ]; then
  printf 'reachable: yes (HTTP 200 over Tailscale)\n'
else
  printf 'reachable: could not confirm (HTTP %s from %s)\n' "$code" "$verify" >&2
  exit 1
fi
