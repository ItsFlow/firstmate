# Captain decision-and-review board (reference)

The inbox board is one Lavish HTML surface that collects everything waiting on the captain - decisions to make, pull requests to approve, and stopped work - so it arrives in one place he opens when he wants, instead of as scattered chat interruptions.
This is the operator reference; each script's own `--help` owns exact flags and mechanics.

## Operator commands

`bin/fm-inbox-view.sh` generates the board as a pure read-only projection over `bin/fm-fleet-snapshot.sh --json` plus `tasks-axi show <id> --full`, writing nothing but the HTML file.
`tests/fm-inbox-view.test.sh` proves it leaves `state/` and `data/` byte-identical.

`bin/fm-inbox-arm.sh` writes and registers the answer relay described below, and it writes firstmate's own private `state/`, so it is run from the operating home.

`bin/fm-inbox-serve.sh` is the one operator command: it regenerates the board, arms the relay, serves the board on this machine's Tailscale address, and prints and verifies the link.
Serve the board with this, not a bare `lavish-axi` call, so answers actually reach firstmate.

## Decision cards

Every open captain decision (selected on `hold_kind == "captain"` alone, which the snapshot's own `captain_actionable` flag narrows away) renders as a card that leads with plain English: the question, what the captain is actually choosing, why it is a question, firstmate's recommendation, an optional research link, and a collapsed technical section.
The plain-English text is not derivable from backlog metadata, so it comes from an optional captain-private cards file (`data/inbox-cards.md` by default; see `fm-inbox-view.sh --help` for the format).
A decision with no card still renders and is marked as not yet written, rather than presenting a raw hold note as if it were plain English.
An item that is firstmate's own assumption rather than a choice the captain made is flagged as such on the card.

## Answering

The captain answers in the browser through Lavish's input contract:

- A free-text answer is first-class, and any predefined options are optional quick-picks with a clear-selection reset, so the captain can always submit his own answer with no option selected.
- Each card also has a discuss path that sends a question back (`DISCUSS <id>: ...`) instead of an answer (`DECISION <id>: ...`), so a decision can be clarified rather than forced.
- Submitting queues exactly one prompt and sends it immediately with a visible confirmation, so an answer never sits waiting on a separate control.

## The answer relay (why answers reliably arrive)

Submitted answers are committed to the Lavish server and never lost, but something has to poll for them.
`fm-inbox-arm.sh` writes `state/inbox.check.sh` - a bounded relay that only calls `lavish-axi poll` after the board port is already listening - and binds its exact bytes with `bin/fm-check-register.sh`, so firstmate's supervision cycle runs it on the normal check cadence, appends any answer to `state/inbox-answers/`, and wakes firstmate to act on it.
This is the same registered-check pattern as the Workflowy `@go` channel.
The relay fails closed: when the board is not being served, the check exits before polling, prints nothing, and wakes no one.
It only runs while a supervision cycle is armed, so answer latency is one check sweep (`FM_CHECK_INTERVAL`, default 300s).

## Serving

Boards are served on the Tailscale address so the captain reaches them from the MacBook Pro (`data/captain.md`).
`fm-inbox-serve.sh` reads the address from `ifconfig` because the `tailscale` CLI misreports "logged out" on the mini, and advertises it via `LAVISH_AXI_LINK_HOST` with `LAVISH_AXI_HOST=0.0.0.0` and `LAVISH_AXI_NO_OPEN=1`.

## Verification evidence

The active evidence is recorded in [supervision verification](verification/supervision.md#captain-inbox-answer-relay).
The focused regression entry points are `tests/fm-inbox-view.test.sh` and `tests/fm-inbox-arm.test.sh`.
