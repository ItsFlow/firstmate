# Captain's call: open decisions and waits

Firstmate could stop on a decision or an external delay without the captain ever receiving a self-contained explanation of what was needed, why it mattered, or what happened next.
Work sat parked, and the fleet read as permanently waiting for no understandable reason.
This document is the operator reference for the contract that fixes it; each script's header and `--help` own exact flags and mechanics.

## What the contract covers

Every open item is exactly one of two things.

- A **decision** needs the captain's own answer before the work can move.
- A **wait** is a meaningful delay that needs no captain action yet, including a declared external delay or backlog work held on another blocker.
  It still owes the captain what is being awaited and when it is next checked.

A status-derived wait becomes a decision only through an explicit action-required `needs-decision` or `blocked` status transition.
Repetition never changes a routine external or timed wait into a critical alert.

## Where it comes from

`bin/fm-attention-lib.sh` is the single owner of the contract.
It derives the open set from home-local records Firstmate already keeps - `data/backlog.md`, `state/*.meta`, and `state/*.status` - and uses `state/.last-watcher-beat` only to estimate a wait's next check.
It stores no item records of its own.
It is therefore not a second status surface, and it is harness-agnostic and runtime-backend-agnostic: it never inspects a pane, an endpoint, or a harness.
Backlog rows are read through `bin/fm-fleet-snapshot.sh --backlog-json`, which remains the one owner of backlog parsing.
If that projection, state directory, metadata record, or status stream cannot be read, the result is unknown, not empty: renderers say that the open decision and wait list could not be determined, never print an all-clear, and never record a captain receipt.
Firstmate follows readable symbolic links for the state directory and task records.
A dangling link makes the set unknown instead of looking empty.

A backlog row is a decision when it carries a captain hold with a reason and no unresolved blocker, whatever the item's own `kind` says.
The documented way to gate ordinary work on the captain is `tasks-axi hold <id> --reason "<reason>" --kind captain`, which leaves `kind` as `ship`, so the snapshot's narrower `captain_actionable` flag is false for exactly the threads this contract exists for.
A captain hold whose blocker is still open is not answerable yet and stays a wait, so a future-gated hold does not nag the captain now.

## The durable captain briefing

A title and a one-line reason cannot carry a decision, so every renderer could only truncate them.
`bin/fm-decision-hold.sh hold` requires `--semantic-revision`, `--choice`, `--why-now`, `--cost-of-waiting`, at least one `--option`, and `--recommend` for every new hold and explicit revision, and stores that plain language in the hold's own durable body.
The privacy-safe semantic revision stays the same for wording-only paraphrases and changes whenever the choice, stakes, waiting cost, options, or recommendation changes substantively.
Supplying the complete briefing rewrites it and preserves unrecognized body lines; supplying no briefing flags leaves an existing complete briefing untouched, so an idempotent retry never erases one.
Legacy decisions with no briefing still render and are marked as incomplete, rather than presenting a raw operational note as if it were plain language or recording a captain receipt.
A partial briefing renders the fields that were written and names the missing ones.

## Where the captain sees it

`bin/fm-attention.sh` is the single place firstmate reads the open set from and relays into chat, so no reply has to reconstruct it.
Its default view is plain English with no internal identifiers or vocabulary, so it can be relayed as written; `--brief` is the firstmate-facing form and does carry identifiers, and is read-only.

The same set also reaches ordinary replies through four integrated paths, so nothing depends on remembering to look:

- `bin/fm-session-start.sh` prints it as its own read-only digest section, before the supervision block and the context.
- `bin/fm-guard.sh` renders a changed set read-only on every guarded command and at the top of every wake-handling turn, before any in-flight test.
- `bin/fm-turnend-guard.sh` stops a turn that would end while a captain decision the captain has never been shown is open.
- `bin/fm-supervision-instructions.sh` carries a one-line count in the emitted operating block.

`/bearings` renders the same items in its Captain's Call and Charted Next sections.

The [inbox board](inbox-board.md) is the other captain-facing surface for the same decisions, and the two are complementary rather than duplicates: this contract owns the derived set, its plain language, and how often firstmate is allowed to interrupt with it, while the board is where the captain answers one in a browser.
They select decisions by the same rule - the captain hold itself, not the item's own `kind` - so the surfaces cannot disagree about what needs the captain.
Keep that rule in step when either side changes it.

## Surfacing, deduplication, and false alarms

`state/.captain-attention` records the digest of the set most recently verified in an actual assistant reply by `bin/fm-attention.sh --record-visible`.
Every rendering mode is read-only; only `--record-visible`, fed the assistant message by a turn-end adapter, can record a receipt, and it validates each alert as one associated block with the correct category, headline, and that record's own briefing facts.
Firstmate-facing projections such as the default view, `--brief`, `--json`, `--status`, and `--no-mark` cannot spend the receipt.
Identities carry no prose, so a delay re-reported hourly with new wording stays one item and surfaces once; if that delay clears and later opens again, its generation changes and it surfaces again.
Decision receipts include the explicit semantic revision, so a substantive revision reopens the receipt while a wording-only paraphrase does not.
A generated captain item merges with its origin and key, while a direct item merges only with a same-task status whose explicit key equals the item id; ambiguous records remain separate.
When that decision is transferred to its durable captain item, the current wait remains attached until a terminal work outcome closes the wait portion.
The marker bounds the interrupt only - an open item stays listed until it is answered or clears.

On a harness whose turn-end payload carries the assistant reply, the turn-end stop remains active until the complete alert appears in an actual captain-visible assistant reply.
On a harness whose payload cannot carry the reply, no receipt can ever validate at turn end, so that stop is bounded by a separate decision marker to one interrupt per changed decision set; the open decision stays on every pull surface until it is answered.
Routine external and timed waits never stop a turn because they need no captain action.
An unknown derivation can also stop a turn once, using a separate unknown marker so a broken projection cannot loop the session and cannot mark a decision set as surfaced.
Read-only calls never reset the unknown marker; an explicitly mutating turn-end or receipt path resets it after a readable derivation, so a later derivation failure is surfaced as a fresh unknown.
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
