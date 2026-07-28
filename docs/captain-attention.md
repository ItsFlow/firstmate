# Captain's call: open decisions and waits

Firstmate could stop on a decision or an external delay without the captain ever receiving a self-contained explanation of what was needed, why it mattered, or what happened next.
Work sat parked, and the fleet read as permanently waiting for no understandable reason.
This document is the operator reference for the contract that fixes it; each script's header and `--help` own exact flags and mechanics.

## What the contract covers

Every open item is exactly one of two things.

- A **decision** needs the captain's own answer before the work can move.
- A **wait** is a declared external delay that needs no captain action, but still owes the captain what is being awaited and when it is next checked.

A wait that has been re-declared past `FM_ATTENTION_WAIT_REDECLARES` (default 3) without ever clearing is promoted to a decision, because a delay that keeps repeating is no longer resolving on its own.
That promotion is derived from the keyed event fold, never from reading the wording of the delay, so it cannot fire on phrasing alone.

## Where it comes from

`bin/fm-attention-lib.sh` is the single owner of the contract.
It derives the open set from state firstmate already keeps durably - `data/backlog.md` and `state/*.status` - and stores nothing of its own except the surfaced-digest marker below.
It is therefore not a second status surface, and it is harness-agnostic and runtime-backend-agnostic: it never inspects a pane, an endpoint, or a harness.
Backlog rows are read through `bin/fm-fleet-snapshot.sh --backlog-json`, which remains the one owner of backlog parsing.

## The durable captain briefing

A title and a one-line reason cannot carry a decision, so every renderer could only truncate them.
`bin/fm-decision-hold.sh hold` accepts `--choice`, `--why-now`, `--cost-of-waiting`, repeatable `--option`, and `--recommend`, and stores that plain language in the hold's own durable body.
Supplying any briefing flag rewrites the briefing and preserves unrecognized body lines; supplying none leaves an existing briefing untouched, so an idempotent retry never erases one.
A decision with no briefing still renders and is marked as not yet written, rather than presenting a raw operational note as if it were plain language.

## Where the captain sees it

`bin/fm-attention.sh` is the single captain-facing place.
Its default view is plain English with no internal identifiers or vocabulary, so it can be relayed as written; `--brief` is the firstmate-facing form and does carry identifiers.

The same set also reaches ordinary replies through three integrated paths, so nothing depends on remembering to look:

- `bin/fm-session-start.sh` prints it as its own digest section, before the supervision block and the context.
- `bin/fm-guard.sh` surfaces a changed set on every guarded command and at the top of every wake-handling turn, before any in-flight test.
- `bin/fm-turnend-guard.sh` stops a turn that would end while a captain decision the captain has never been shown is open.
- `bin/fm-supervision-instructions.sh` carries a one-line count in the emitted operating block.

`/bearings` renders the same items in its Captain's Call and Charted Next sections.

## Surfacing, deduplication, and false alarms

`state/.captain-attention` records the digest of the set most recently rendered to a captain-facing surface.
Rendering is surfacing: printing records the digest as a side effect, so an ordinary read that changes nothing can never become an alarm.
Identities carry no prose, so a delay re-reported hourly with new wording stays one item and surfaces once.
The marker bounds the interrupt only - an open item stays listed until it is answered or clears.

The turn-end stop is bounded by construction rather than by a budget: it records the surfaced digest before blocking, so one distinct set of open decisions costs at most one forced continuation on any harness.
Declared waits never stop a turn.
`FM_ATTENTION_TURNEND_BLOCK=0` disables that stop without touching the watcher-liveness backstop, and `FM_GUARD_NO_ATTENTION=1` suppresses the guard section.

## The primary-activity blind spot

`bin/fm-supervision-lib.sh` counts `state/*.meta`, which exist only after `bin/fm-spawn.sh` runs.
That is an accurate answer to "does a watcher need to be running" and a wrong answer to "is this home idle": a primary holding work itself - an unanswered decision, a standing delay - had nothing to count, so every guard concluded the home was idle and the whole stack went silent.
`fm_attention_home_idle` in `bin/fm-attention-lib.sh` owns the idleness question and adds the derived attention set to those counts, so unaccounted primary work reads as suspicious rather than idle.
It is deliberately kept out of `FM_SUP_NEEDED`: a standing decision needs the captain, not a watcher, and folding it in would demand a live watcher forever on any home with a long-lived open decision.

## Compatibility

Every supported primary harness and runtime backend was reviewed; see [supervision verification](verification/supervision.md#captains-call-decisions-and-waits) for the review and its evidence.

## Verification

The focused regression entry point is `tests/fm-attention.test.sh`.
