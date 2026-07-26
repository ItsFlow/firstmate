#!/usr/bin/env python3
"""Render the captain's decision-and-review board from a fleet snapshot.

Driven by bin/fm-inbox-view.sh, which owns argument handling, the snapshot and
tasks-axi reads, and the atomic write. This module only turns those inputs into
one self-contained HTML page. It writes nothing but the file named by --out.

Three helper modes let the caller collect the extra inputs it needs before the
final render:
  --decision-ids  print the ids of every open captain decision, one per line
  --pr-urls       print every recorded pull request URL, one per line
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from datetime import datetime, timezone

SCHEMA = "fm-inbox-board.v1"
PR_STALE_STATES = {"CLOSED", "MERGED"}

# --------------------------------------------------------------------------
# snapshot selection
# --------------------------------------------------------------------------


def structured_records(snap):
    return [r for r in snap.get("backlog", {}).get("records", []) if r.get("structured")]


def unresolved(record):
    return record.get("unresolved_blocker_ids") or []


def open_captain_decisions(snap):
    """Every captain-held queued item with nothing blocking it.

    Keyed on hold_kind alone. The snapshot's own captain_actionable flag also
    requires kind == "captain", which only bin/fm-decision-hold.sh sets, so it
    silently hides every thread gated with `tasks-axi hold --kind captain`.
    Those are the captain's oldest waiting decisions.
    """
    out = []
    for r in structured_records(snap):
        if r.get("state") != "queued":
            continue
        if r.get("hold_kind") != "captain":
            continue
        if not r.get("hold_reason"):
            continue
        if unresolved(r):
            continue
        out.append(r)
    return out


def recorded_prs(snap):
    """Recorded pull request URLs for work that has not landed yet.

    Task metadata first, then the backlog. Work already recorded as done is
    skipped: its pull request belongs to the shipped list, not to a review
    queue.
    """
    done = {
        r.get("id")
        for r in structured_records(snap)
        if r.get("state") == "done"
    }
    seen = {}
    for task in snap.get("tasks", []):
        url = (task.get("pr") or {}).get("url")
        if url and url not in seen and task.get("id") not in done:
            seen[url] = {"url": url, "id": task.get("id"), "source": "task record"}
    for r in structured_records(snap):
        url = r.get("pr_url")
        if url and url not in seen and r.get("state") != "done":
            seen[url] = {"url": url, "id": r.get("id"), "source": "backlog"}
    return list(seen.values())


# --------------------------------------------------------------------------
# tasks-axi full text
# --------------------------------------------------------------------------

_AXI_FIELD = re.compile(r"^  ([a-z_]+): (.*)$")


def parse_axi_show(text):
    """Parse one `tasks-axi show <id> --full` block into a flat dict."""
    fields = {}
    for line in text.splitlines():
        m = _AXI_FIELD.match(line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2).strip()
        if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
            raw = raw[1:-1].replace('\\"', '"')
        raw = raw.replace("\\n", "\n")
        fields[key] = raw
    return fields


def load_full_text(directory):
    out = {}
    if not directory or not os.path.isdir(directory):
        return out
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".txt"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                out[name[: -len(".txt")]] = parse_axi_show(fh.read())
        except OSError:
            continue
    return out


# --------------------------------------------------------------------------
# plain-English decision cards
# --------------------------------------------------------------------------

CARD_FIELDS = ("question", "plain", "why", "take", "link", "options", "expand", "flag")


def load_cards(path):
    """Parse the optional plain-English cards file. See fm-inbox-view.sh --help."""
    cards = {}
    if not path or not os.path.isfile(path):
        return cards
    current = None
    field = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("## "):
                current = line[3:].strip()
                cards[current] = {}
                field = None
                continue
            if current is None:
                continue
            if line.startswith("### "):
                name = line[4:].strip().lower()
                field = name if name in CARD_FIELDS else None
                if field:
                    cards[current].setdefault(field, [])
                continue
            if field:
                cards[current][field].append(line)
    normalized = {}
    for key, fields in cards.items():
        entry = {}
        for name, lines in fields.items():
            if name == "options":
                entry[name] = [
                    ln.lstrip("-* ").strip()
                    for ln in lines
                    if ln.strip().startswith(("-", "*"))
                ]
            else:
                entry[name] = "\n".join(lines).strip()
        normalized[key] = entry
    return normalized


# --------------------------------------------------------------------------
# text helpers
# --------------------------------------------------------------------------

_URL = re.compile(r"(https?://[^\s<>\"')\]]+)")


def esc(value):
    return html.escape(value if value is not None else "", quote=True)


def linkify(escaped):
    return _URL.sub(r'<a href="\1" rel="noreferrer">\1</a>', escaped)


def rich(text):
    """Escaped paragraphs with bare URLs turned into links."""
    if not text:
        return ""
    blocks = [b.strip() for b in re.split(r"\n\s*\n", text) if b.strip()]
    return "".join(
        "<p>%s</p>" % linkify(esc(b).replace("\n", "<br>")) for b in blocks
    )


NO_PROJECT = "no project"

# The board is captain-facing, so internal run-state and completion vocabulary is
# translated once, here, rather than leaked into the page.
LIVE_LABELS = {
    "working": "in progress",
    "running": "in progress",
    "fixing": "in progress",
    "ci": "waiting on checks",
    "done": "finished, being wrapped up",
    "paused": "waiting on something external",
    "blocked": "stopped",
    "failed": "stopped",
}

COMPLETION_LABELS = {
    "merged": "merged",
    "reported": "findings filed",
    "done": "done",
}


def project_of(record, task=None):
    repo = record.get("repo") if record else None
    if not repo and task:
        path = task.get("project") or ""
        repo = os.path.basename(path.rstrip("/")) if path else None
    if not repo:
        return NO_PROJECT
    return repo.rstrip("/").split("/")[-1]


# Readable area labels for the many personal-idea and firstmate-infra items that
# carry no project yet. The captain will organize projects later; until then a
# generic "no project" badge is useless, so a small known map plus the item's
# own leading id token gives every row a readable, filterable name.
_AREA_ALIASES = {
    "fm": "firstmate",
    "harden": "firstmate",
    "add": "firstmate",
    "workflowy": "personal",
    "network": "personal",
    "planning": "planning",
    "touchbase": "touchbase",
    "content": "content",
}


def origin_of(record):
    """The originating investigation id from a decision's body, when present."""
    for line in (record.get("body_lines") or []):
        if line.lower().startswith("origin:"):
            return line.split(":", 1)[1].strip()
    return None


def area_of(record, task=None):
    """Project when known, otherwise a readable area derived from origin or id."""
    project = project_of(record, task)
    if project != NO_PROJECT:
        return project
    base = origin_of(record) or record.get("id") or ""
    token = base.split("-", 1)[0].strip().lower()
    if not token:
        return NO_PROJECT
    return _AREA_ALIASES.get(token, token)


def slugify(value):
    return re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-") or "item"


# --------------------------------------------------------------------------
# section assembly
# --------------------------------------------------------------------------


def live_state(task):
    if not task:
        return None
    return (task.get("current_state") or {}).get("state")


def build_model(snap, full_text, cards, pr_state, pr_verified):
    tasks = {t.get("id"): t for t in snap.get("tasks", []) if t.get("id")}
    records = structured_records(snap)

    decisions = open_captain_decisions(snap)
    decided_ids = {r.get("id") for r in decisions}

    stuck = []
    for r in records:
        rid = r.get("id")
        if rid in decided_ids or r.get("state") == "done":
            continue
        task = tasks.get(rid)
        reasons = []
        if live_state(task) in ("failed", "blocked"):
            reasons.append("the worker stopped and needs help")
        if (task or {}).get("hints", {}).get("blocked_event"):
            reasons.append("the worker reported a blocker")
        if (task or {}).get("hints", {}).get("pending_decision"):
            reasons.append("the worker is waiting on an answer")
        if r.get("blocked_reason"):
            reasons.append(r["blocked_reason"])
        if reasons:
            stuck.append((r, task, reasons))
    stuck_ids = {r.get("id") for r, _, _ in stuck}

    prs = []
    stale_prs = []
    for entry in recorded_prs(snap):
        rid = entry["id"]
        record = next((r for r in records if r.get("id") == rid), None) or {}
        task = tasks.get(rid)
        state = (pr_state.get(entry["url"]) or "").upper()
        row = {
            "id": rid,
            "url": entry["url"],
            "source": entry["source"],
            "title": record.get("title") or (task or {}).get("id") or rid,
            "project": area_of(record, task),
            "state": state,
            "verified": bool(pr_verified and state),
        }
        if row["verified"] and state in PR_STALE_STATES:
            stale_prs.append(row)
        else:
            prs.append(row)
    pr_ids = {row["id"] for row in prs}

    underway = [
        (r, tasks.get(r.get("id")))
        for r in records
        if r.get("state") == "in_flight" and r.get("id") not in stuck_ids
    ]
    underway_ids = {r.get("id") for r, _ in underway}

    queued = [
        r
        for r in records
        if r.get("state") == "queued"
        and r.get("id") not in decided_ids
        and r.get("id") not in stuck_ids
        and r.get("id") not in underway_ids
    ]

    shipped = [r for r in records if r.get("state") == "done"]

    return {
        "decisions": [
            decision_view(r, tasks.get(r.get("id")), full_text, cards) for r in decisions
        ],
        "prs": prs,
        "stale_prs": stale_prs,
        "pr_ids": pr_ids,
        "stuck": stuck,
        "underway": underway,
        "queued": queued,
        "shipped": shipped,
        "tasks": tasks,
    }


def decision_view(record, task, full_text, cards):
    rid = record.get("id")
    axi = full_text.get(rid, {})
    card = cards.get(rid, {})

    hold = axi.get("hold_reason") or record.get("hold_reason") or ""
    body = axi.get("body") or "\n".join(record.get("body_lines") or [])
    title = axi.get("title") or record.get("title") or rid

    origin = None
    for line in body.splitlines():
        if line.lower().startswith("origin:"):
            origin = line.split(":", 1)[1].strip()
    report = None
    if origin:
        report = "data/%s/report.md" % origin

    # Options are quick-picks, never a gate: the free-text answer stands alone.
    options = card.get("options") or []

    return {
        "id": rid,
        "question": card.get("question") or title,
        "plain": card.get("plain"),
        "why": card.get("why"),
        "take": card.get("take"),
        "link": card.get("link"),
        "flag": card.get("flag"),
        "expand": card.get("expand"),
        "options": options,
        "hold": hold,
        "body": body,
        "origin": origin,
        "report": report,
        "since": record.get("since"),
        "project": area_of(record, task),
        "annotated": bool(card),
    }


# --------------------------------------------------------------------------
# HTML
# --------------------------------------------------------------------------

CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{
  color-scheme:light dark;
  --bg:#fbfaf8; --panel:#ffffff; --ink:#1d1f21; --muted:#5f6672; --faint:#8b929c;
  --line:#e4e2dd; --line-soft:#efeee9; --accent:#8a5a2b; --accent-soft:#f5efe6;
  --flagbg:#fdf6e6; --flagline:#e3d3ac; --ok:#2f6b48; --warn:#8a5a2b;
  --radius:10px;
}
@media (prefers-color-scheme:dark){
  :root{
    --bg:#16181b; --panel:#1d2024; --ink:#e8e6e2; --muted:#a3a9b2; --faint:#7d848d;
    --line:#2e3238; --line-soft:#25282d; --accent:#d9a86a; --accent-soft:#2a2620;
    --flagbg:#2a2620; --flagline:#4a4030; --ok:#7fb894; --warn:#d9a86a;
  }
}
:root[data-theme="dark"]{
  --bg:#16181b; --panel:#1d2024; --ink:#e8e6e2; --muted:#a3a9b2; --faint:#7d848d;
  --line:#2e3238; --line-soft:#25282d; --accent:#d9a86a; --accent-soft:#2a2620;
  --flagbg:#2a2620; --flagline:#4a4030; --ok:#7fb894; --warn:#d9a86a;
}
:root[data-theme="light"]{
  --bg:#fbfaf8; --panel:#ffffff; --ink:#1d1f21; --muted:#5f6672; --faint:#8b929c;
  --line:#e4e2dd; --line-soft:#efeee9; --accent:#8a5a2b; --accent-soft:#f5efe6;
  --flagbg:#fdf6e6; --flagline:#e3d3ac; --ok:#2f6b48; --warn:#8a5a2b;
}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font:16px/1.6 ui-sans-serif,-apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased;
}
html,body{max-width:100%; overflow-x:hidden}
.wrap{max-width:56rem; margin:0 auto; padding:2.5rem 1.25rem 5rem}
/* A long title, id, or URL must wrap rather than widen the page at any nesting
   level. Lavish's layout audit flags horizontal overflow as an error, so every
   text container wraps unbreakable strings and every flex/grid child gets a
   min-width:0 track so it can actually shrink. Genuinely wide blocks scroll
   inside their own container instead of stretching the page. */
*{min-width:0}
a{color:var(--accent); overflow-wrap:anywhere}
.card,.field,.field p,.flag,form.answer,form.discuss,
.card h3,.tag,li.row,li.row .what,li.row .what .t,li.row .what .sub{
  overflow-wrap:anywhere; word-break:break-word;
}
h1{font-size:1.55rem; line-height:1.25; margin:0 0 .4rem; letter-spacing:-.01em}
.lede{margin:0 0 .35rem; color:var(--muted); max-width:44rem}
.meta{margin:0; color:var(--faint); font-size:.82rem}
header.board{border-bottom:1px solid var(--line); padding-bottom:1.5rem; margin-bottom:1.5rem}

.controls{
  display:flex; flex-wrap:wrap; gap:.75rem 1.25rem; align-items:flex-end;
  margin-bottom:2.25rem;
}
.control{display:flex; flex-direction:column; gap:.35rem; min-width:0}
.control > span{font-size:.72rem; letter-spacing:.08em; text-transform:uppercase; color:var(--faint)}
.segmented{display:flex; border:1px solid var(--line); border-radius:var(--radius); overflow:hidden}
.segmented button{
  appearance:none; border:0; background:var(--panel); color:var(--muted);
  font:inherit; font-size:.88rem; padding:.42rem .85rem; cursor:pointer;
  border-right:1px solid var(--line);
}
.segmented button:last-child{border-right:0}
.segmented button[aria-pressed="true"]{background:var(--accent-soft); color:var(--ink); font-weight:600}
select{
  font:inherit; font-size:.88rem; padding:.42rem .6rem; border-radius:var(--radius);
  border:1px solid var(--line); background:var(--panel); color:var(--ink); max-width:100%;
}
.tally{margin-left:auto; color:var(--faint); font-size:.82rem; align-self:flex-end}

section.block{margin:0 0 2.75rem}
section.block > h2{
  font-size:.78rem; letter-spacing:.11em; text-transform:uppercase; color:var(--faint);
  margin:0 0 .25rem; font-weight:600;
}
section.block > .blurb{margin:0 0 1rem; color:var(--muted); font-size:.88rem}
.empty{color:var(--faint); font-size:.9rem; font-style:italic; margin:0}

.card{
  background:var(--panel); border:1px solid var(--line); border-radius:var(--radius);
  padding:1.4rem 1.5rem; margin-bottom:1.1rem;
}
.card > h3{font-size:1.12rem; line-height:1.35; margin:0 0 .6rem; letter-spacing:-.005em}
.tags{display:flex; flex-wrap:wrap; gap:.4rem; margin:0 0 1rem}
.tag{
  font-size:.72rem; letter-spacing:.03em; color:var(--muted); background:var(--line-soft);
  border-radius:99px; padding:.16rem .55rem; white-space:nowrap;
}
.tag.warn{background:var(--flagbg); color:var(--warn); border:1px solid var(--flagline)}

.field{margin:0 0 .95rem}
.field > .label{
  font-size:.74rem; letter-spacing:.06em; text-transform:uppercase; color:var(--faint);
  margin:0 0 .18rem; font-weight:600;
}
.field p{margin:0 0 .5rem}
.field p:last-child{margin-bottom:0}
.field.take p{color:var(--ink)}

.flag{
  background:var(--flagbg); border:1px solid var(--flagline); border-radius:var(--radius);
  padding:.8rem 1rem; margin:0 0 1rem;
}
.flag .label{color:var(--warn)}

details{border-top:1px solid var(--line-soft); margin-top:1.1rem; padding-top:.85rem}
details summary{
  cursor:pointer; font-size:.85rem; color:var(--muted); list-style:none;
  display:inline-flex; align-items:center; gap:.4rem;
}
details summary::-webkit-details-marker{display:none}
details summary::before{content:"+"; color:var(--faint); font-weight:600}
details[open] summary::before{content:"\\2212"}
details .inner{padding-top:.85rem; font-size:.92rem; color:var(--muted); overflow-x:auto}
details .inner code, details .inner .src{
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.84rem;
}

form.answer{border-top:1px solid var(--line-soft); margin-top:1.1rem; padding-top:1rem}
form.answer .label{
  font-size:.74rem; letter-spacing:.06em; text-transform:uppercase; color:var(--faint);
  margin:0 0 .5rem; font-weight:600;
}
form.answer label.opt{
  display:flex; gap:.6rem; align-items:flex-start; padding:.38rem 0; cursor:pointer;
  font-size:.95rem; overflow-wrap:anywhere;
}
form.answer input[type=radio]{margin-top:.35rem; flex:none}
form.answer .clear{
  appearance:none; background:none; border:0; padding:.2rem 0; margin-top:.15rem;
  font:inherit; font-size:.8rem; color:var(--muted); cursor:pointer; text-decoration:underline;
}
form.answer textarea,form.discuss textarea{
  width:100%; margin-top:.7rem; min-height:3.6rem; font:inherit; font-size:.92rem;
  padding:.55rem .7rem; border-radius:var(--radius); border:1px solid var(--line);
  background:var(--bg); color:var(--ink); resize:vertical; max-width:100%;
}
form.answer .send,form.discuss .send{
  display:flex; align-items:center; gap:.75rem; margin-top:.75rem; flex-wrap:wrap;
}
form.answer button[type=submit],form.discuss button[type=submit]{
  appearance:none; font:inherit; font-size:.9rem; font-weight:600; cursor:pointer;
  padding:.45rem 1rem; border-radius:var(--radius); border:1px solid var(--accent);
  background:var(--accent); color:var(--panel);
}
form.answer .status,form.discuss .status{font-size:.84rem; color:var(--muted); overflow-wrap:anywhere}
form.answer .status.done,form.discuss .status.done{color:var(--ok); font-weight:600}
form.discuss{margin-top:.4rem}
form.discuss summary{
  cursor:pointer; font-size:.85rem; color:var(--muted); list-style:none;
  display:inline-flex; align-items:center; gap:.4rem;
}
form.discuss summary::-webkit-details-marker{display:none}
form.discuss summary::before{content:"?"; color:var(--faint); font-weight:700}

ul.rows{list-style:none; margin:0; padding:0}
li.row{
  display:flex; gap:.75rem; align-items:baseline; padding:.6rem 0;
  border-bottom:1px solid var(--line-soft); min-width:0;
}
li.row:last-child{border-bottom:0}
li.row .who{flex:none; width:8.5rem; color:var(--faint); font-size:.78rem; overflow-wrap:anywhere}
li.row .what{flex:1 1 auto; min-width:0}
li.row .what .t{display:block; overflow-wrap:anywhere}
li.row .what .sub{display:block; color:var(--faint); font-size:.82rem; overflow-wrap:anywhere}
li.row .what .sub a{overflow-wrap:anywhere}
@media (max-width:34rem){
  .wrap{padding:1.75rem 1rem 4rem}
  .card{padding:1.15rem 1.1rem}
  li.row{flex-direction:column; gap:.15rem}
  li.row .who{width:auto}
  .tally{margin-left:0; width:100%}
}
"""

JS = """
(function(){
  var root=document.documentElement;
  var typeButtons=[].slice.call(document.querySelectorAll('[data-type-filter]'));
  var projectSelect=document.getElementById('project-filter');
  var tally=document.getElementById('tally');
  var state={type:'all',project:'all'};

  function visibleFor(section){
    if(state.type==='all') return true;
    if(state.type==='decisions') return section.dataset.block==='decide';
    if(state.type==='shipped') return section.dataset.block==='shipped';
    return true;
  }

  function apply(){
    var shown=0;
    [].forEach.call(document.querySelectorAll('section.block'),function(section){
      var allowed=visibleFor(section);
      var live=0;
      [].forEach.call(section.querySelectorAll('[data-project]'),function(item){
        var ok=allowed&&(state.project==='all'||item.dataset.project===state.project);
        item.hidden=!ok;
        if(ok){live++;}
      });
      var none=section.querySelector('.empty-filtered');
      if(none){none.hidden=!(allowed&&live===0);}
      section.hidden=!allowed;
      shown+=live;
      if(section.dataset.block==='decide'){
        var c=section.querySelector('.count');
        if(c){c.textContent=live===1?'1 decision':(live+' decisions');}
      }
    });
    if(tally){tally.textContent=shown+(shown===1?' item shown':' items shown');}
  }

  typeButtons.forEach(function(btn){
    btn.addEventListener('click',function(){
      state.type=btn.dataset.typeFilter;
      typeButtons.forEach(function(b){
        b.setAttribute('aria-pressed',String(b===btn));
      });
      apply();
    });
  });
  if(projectSelect){
    projectSelect.addEventListener('change',function(){
      state.project=projectSelect.value;
      apply();
    });
  }
  var toggle=document.getElementById('theme-toggle');
  if(toggle){
    toggle.addEventListener('click',function(){
      var dark=root.getAttribute('data-theme')==='dark';
      root.setAttribute('data-theme',dark?'light':'dark');
    });
  }
  apply();
})();
"""

QUEUE_JS = """
// Clear the quick-pick radios so a selection is never a trap.
function fmInboxClear(button){
  var form=button.closest('form');
  if(!form){return;}
  form.querySelectorAll('input[name=answer]').forEach(function(r){r.checked=false;});
}
// One shared send path. It queues exactly one prompt and sends it immediately
// so an answer never sits waiting on a separate Send button the captain has to
// find - the failure mode where the board looked like it silently ate answers.
function fmInboxSend(form, text, data, confirm){
  var mark=form.querySelector('.status');
  if(window.lavish&&window.lavish.queuePrompt){
    window.lavish.queuePrompt(text,{
      tag:data.tag, queueKey:data.queueKey, element:form, text:data.summary, data:data
    });
    if(window.lavish.sendQueuedPrompts){window.lavish.sendQueuedPrompts();}
    if(mark){mark.textContent=confirm; mark.classList.add('done');}
  }else if(mark){
    mark.textContent='Open this board through Lavish to send.';
  }
}
// The free-text answer stands alone: a picked option is a convenience, never
// required. Submit works with just the note, just an option, or both.
function fmInboxAnswer(form){
  var data=new FormData(form);
  var choice=(data.get('answer')||'').trim();
  var note=(data.get('note')||'').trim();
  var mark=form.querySelector('.status');
  if(!choice&&!note){
    if(mark){mark.textContent='Type your answer, or pick one of the options.'; mark.classList.remove('done');}
    return;
  }
  var id=form.dataset.lavishQuestion;
  var question=form.dataset.question||id;
  var body=note?(choice?(choice+' -- '+note):note):choice;
  fmInboxSend(form,'DECISION '+id+': '+body,{
    tag:'decision', queueKey:id, summary:question+' -> '+body,
    hold:id, question:question, answer:choice, note:note
  },'Sent to firstmate.');
}
// The discuss path asks a question back instead of deciding. firstmate replies;
// it does not treat this as the answer.
function fmInboxDiscuss(form){
  var data=new FormData(form);
  var text=(data.get('question')||'').trim();
  var mark=form.querySelector('.status');
  if(!text){
    if(mark){mark.textContent='Type your question first.'; mark.classList.remove('done');}
    return;
  }
  var id=form.dataset.lavishQuestion;
  var hold=id.replace(/-discuss$/,'');
  var question=form.dataset.question||hold;
  fmInboxSend(form,'DISCUSS '+hold+': '+text,{
    tag:'discuss', queueKey:id, summary:'Question on '+question,
    hold:hold, question:question, message:text
  },'Question sent to firstmate.');
}
"""


def tag(text, cls="tag"):
    return '<span class="%s">%s</span>' % (cls, esc(text))


def field(label, body, extra=""):
    if not body:
        return ""
    return '<div class="field %s"><p class="label">%s</p>%s</div>' % (
        extra,
        esc(label),
        body,
    )


def render_decision(view):
    parts = []
    parts.append(
        '<article class="card" data-project="%s" id="decision-%s">'
        % (esc(view["project"]), esc(slugify(view["id"])))
    )
    parts.append("<h3>%s</h3>" % esc(view["question"]))

    tags = ['<div class="tags">', tag(view["project"])]
    if view["since"]:
        tags.append(tag("waiting since %s" % view["since"]))
    if view["flag"]:
        tags.append(tag("firstmate's assumption, not your call", "tag warn"))
    if not view["annotated"]:
        tags.append(tag("no plain-English summary written yet", "tag warn"))
    tags.append("</div>")
    parts.append("".join(tags))

    if view["plain"]:
        parts.append(field("In plain terms", rich(view["plain"])))
    else:
        parts.append(
            field(
                "In plain terms",
                rich(view["hold"] or "No description was recorded for this decision."),
            )
        )
    if view["why"]:
        parts.append(field("Why this is even a question", rich(view["why"])))
    elif view["origin"]:
        parts.append(
            field(
                "Why this is even a question",
                rich("It came out of the %s investigation. Full write-up: %s"
                     % (view["origin"], view["report"] or "not recorded")),
            )
        )
    if view["take"]:
        parts.append(field("My take", rich(view["take"]), extra="take"))
    if view["link"]:
        parts.append(
            field(
                "Look into it",
                '<p><a href="%s" rel="noreferrer">%s</a></p>'
                % (esc(view["link"]), esc(view["link"])),
            )
        )
    if view["flag"]:
        parts.append(
            '<div class="flag"><p class="label">Check this assumption</p>%s</div>'
            % rich(view["flag"])
        )

    inner = []
    if view["expand"]:
        inner.append(rich(view["expand"]))
    if view["hold"] and view["hold"] != view.get("plain"):
        inner.append(
            '<p class="label">Recorded decision note</p><div class="src">%s</div>'
            % rich(view["hold"])
        )
    trail = []
    if view["origin"]:
        trail.append("came from the %s investigation" % view["origin"])
    if view["report"]:
        trail.append("full write-up in %s" % view["report"])
    trail.append("tracked as %s" % view["id"])
    inner.append("<p>%s.</p>" % esc("; ".join(trail).capitalize()))
    parts.append(
        "<details><summary>The technical detail</summary>"
        '<div class="inner">%s</div></details>' % "".join(inner)
    )

    # Quick-pick options are optional. Each carries a clear-selection reset so a
    # picked radio is never a trap the captain cannot back out of, and the
    # free-text box below submits on its own.
    opts = ""
    if view["options"]:
        rows = "".join(
            '<label class="opt"><input type="radio" name="answer" value="%s">'
            "<span>%s</span></label>" % (esc(option), esc(option))
            for option in view["options"]
        )
        opts = (
            '<div class="opts">%s'
            '<button type="button" class="clear" '
            'onclick="fmInboxClear(this);">Clear selection</button>'
            "</div>" % rows
        )
    parts.append(
        '<form class="answer" data-lavish-question="%s" data-question="%s" '
        'onsubmit="event.preventDefault();fmInboxAnswer(event.currentTarget);">'
        '<p class="label">Your answer</p>%s'
        '<textarea name="note" placeholder="%s"></textarea>'
        '<div class="send"><button type="submit">Send answer to firstmate</button>'
        '<span class="status" role="status"></span></div></form>'
        % (
            esc(view["id"]),
            esc(view["question"]),
            opts,
            esc(
                "Write your own answer here. You do not have to pick an option above."
                if view["options"]
                else "Write your answer here."
            ),
        )
    )
    parts.append(
        '<form class="discuss" data-lavish-question="%s-discuss" data-question="%s" '
        'onsubmit="event.preventDefault();fmInboxDiscuss(event.currentTarget);">'
        "<details><summary>Not ready to answer? Ask a question instead</summary>"
        '<textarea name="question" placeholder="%s"></textarea>'
        '<div class="send"><button type="submit">Send question to firstmate</button>'
        '<span class="status" role="status"></span></div></details></form>'
        % (
            esc(view["id"]),
            esc(view["question"]),
            esc(
                "What is unclear? firstmate will reply here, it will not treat "
                "this as your decision."
            ),
        )
    )
    parts.append("</article>")
    return "".join(parts)


def render_row(project, who, what, sub=""):
    return (
        '<li class="row" data-project="%s"><span class="who">%s</span>'
        '<span class="what"><span class="t">%s</span>%s</span></li>'
        % (
            esc(project),
            esc(who),
            what,
            '<span class="sub">%s</span>' % sub if sub else "",
        )
    )


def section(block, title, blurb, body, count_label=""):
    head = '<h2>%s%s</h2>' % (
        esc(title),
        ' <span class="count">%s</span>' % esc(count_label) if count_label else "",
    )
    return (
        '<section class="block" data-block="%s">%s<p class="blurb">%s</p>%s'
        '<p class="empty empty-filtered" hidden>Nothing here for this filter.</p>'
        "</section>" % (esc(block), head, esc(blurb), body)
    )


def render(model, snap, home, pr_verified):
    generated = snap.get("generated") or datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    projects = set()
    for view in model["decisions"]:
        projects.add(view["project"])
    for row in model["prs"] + model["stale_prs"]:
        projects.add(row["project"])
    for record, task, _ in model["stuck"]:
        projects.add(area_of(record, task))
    for record, task in model["underway"]:
        projects.add(area_of(record, task))
    for record in model["queued"] + model["shipped"]:
        projects.add(area_of(record, model["tasks"].get(record.get("id"))))

    options = "".join(
        '<option value="%s">%s</option>' % (esc(p), esc(p))
        for p in sorted(projects, key=lambda s: (s == NO_PROJECT, s))
    )

    titles = {r.get("id"): r.get("title") for r in structured_records(snap)}

    blocks = []

    # Decide
    if model["decisions"]:
        body = "".join(render_decision(v) for v in model["decisions"])
    else:
        body = '<p class="empty">Nothing is waiting on you.</p>'
    blocks.append(
        section(
            "decide",
            "Decide",
            "Open questions that are yours to answer. Nothing is blocking any of them.",
            body,
            count_label="%d decisions" % len(model["decisions"]),
        )
    )

    # Review and merge
    rows = []
    for row in model["prs"]:
        if pr_verified and row["state"] == "OPEN":
            note = "checked just now: open"
        elif pr_verified:
            note = "could not be checked"
        else:
            note = "not checked, it may already be closed or merged"
        rows.append(
            render_row(
                row["project"],
                row["project"],
                esc(row["title"]),
                '<a href="%s" rel="noreferrer">%s</a> &middot; %s'
                % (esc(row["url"]), esc(row["url"]), esc(note)),
            )
        )
    if rows:
        body = '<ul class="rows">%s</ul>' % "".join(rows)
    else:
        body = '<p class="empty">Nothing is waiting for your review.</p>'
    if model["stale_prs"]:
        stale = "".join(
            '<li class="row" data-project="%s"><span class="who">%s</span>'
            '<span class="what"><span class="t">%s</span>'
            '<span class="sub"><a href="%s" rel="noreferrer">%s</a> &middot; %s</span>'
            "</span></li>"
            % (
                esc(row["project"]),
                esc(row["project"]),
                esc(row["title"]),
                esc(row["url"]),
                esc(row["url"]),
                esc("already %s, no longer merge-ready" % row["state"].lower()),
            )
            for row in model["stale_prs"]
        )
        body += (
            '<p class="blurb" style="margin-top:1rem">Recorded links that are no '
            'longer open:</p><ul class="rows">%s</ul>' % stale
        )
    blocks.append(
        section(
            "review",
            "Review and merge",
            "Finished work waiting for your yes."
            + (
                ""
                if pr_verified
                else " These links were read from local records, so a closed or already"
                " merged pull request can still appear here."
            ),
            body,
        )
    )

    # Underway
    rows = []
    for record, task in model["underway"]:
        state = LIVE_LABELS.get(live_state(task) or "", "in progress")
        rows.append(
            render_row(
                area_of(record, task),
                area_of(record, task),
                esc(record.get("title") or record.get("id")),
                esc("%s, started %s" % (state, record.get("since") or "recently")),
            )
        )
    blocks.append(
        section(
            "underway",
            "Underway",
            "Being worked on right now. Nothing for you to do.",
            '<ul class="rows">%s</ul>' % "".join(rows)
            if rows
            else '<p class="empty">Nothing is running.</p>',
        )
    )

    # Queued
    rows = []
    for record in model["queued"]:
        task = model["tasks"].get(record.get("id"))
        blockers = unresolved(record)
        if blockers:
            sub = "waiting for %s" % ", ".join(
                titles.get(b) or b for b in blockers
            )
        elif record.get("hold_reason"):
            sub = "on hold: %s" % record["hold_reason"]
        else:
            sub = "queued since %s" % (record.get("since") or "recently")
        rows.append(
            render_row(
                area_of(record, task),
                area_of(record, task),
                esc(record.get("title") or record.get("id")),
                esc(sub),
            )
        )
    blocks.append(
        section(
            "queued",
            "Queued",
            "Lined up behind something else, or parked on purpose.",
            '<ul class="rows">%s</ul>' % "".join(rows)
            if rows
            else '<p class="empty">Nothing is queued.</p>',
        )
    )

    # Shipped
    rows = []
    for record in model["shipped"]:
        task = model["tasks"].get(record.get("id"))
        verb = (record.get("completion") or {}).get("verb") or "done"
        date = (record.get("completion") or {}).get("date") or record.get("since") or ""
        sub = "%s %s" % (COMPLETION_LABELS.get(verb, verb), date)
        if record.get("pr_url"):
            sub += ' &middot; <a href="%s" rel="noreferrer">%s</a>' % (
                esc(record["pr_url"]),
                esc(record["pr_url"]),
            )
            rows.append(
                render_row(
                    area_of(record, task),
                    area_of(record, task),
                    esc(record.get("title") or record.get("id")),
                    sub,
                )
            )
        else:
            rows.append(
                render_row(
                    area_of(record, task),
                    area_of(record, task),
                    esc(record.get("title") or record.get("id")),
                    esc(sub),
                )
            )
    blocks.append(
        section(
            "shipped",
            "Recently built and shipped",
            "Landed work, most recent first.",
            '<ul class="rows">%s</ul>' % "".join(rows)
            if rows
            else '<p class="empty">Nothing has landed yet.</p>',
        )
    )

    # Stuck
    rows = []
    for record, task, reasons in model["stuck"]:
        rows.append(
            render_row(
                area_of(record, task),
                area_of(record, task),
                esc(record.get("title") or record.get("id")),
                esc("; ".join(reasons)),
            )
        )
    blocks.append(
        section(
            "stuck",
            "Stuck",
            "Stopped and not going to move on its own.",
            '<ul class="rows">%s</ul>' % "".join(rows)
            if rows
            else '<p class="empty">Nothing is stuck.</p>',
        )
    )

    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="generator" content="{schema}">
<title>Decisions and reviews firstmate needs from you</title>
<style>{css}</style>
</head>
<body>
<div class="wrap">
<header class="board">
  <h1>Decisions and reviews firstmate needs from you</h1>
  <p class="lede">This is the one place firstmate puts work that is waiting on you:
    decisions to make, finished work to approve, and anything that has stopped.
    Answer a decision here and firstmate picks it up. Everything below it is
    context, not a task.</p>
  <p class="meta">Built from live fleet state at {generated} &middot; {home}</p>
</header>

<div class="controls">
  <div class="control">
    <span>Show</span>
    <div class="segmented">
      <button type="button" data-type-filter="all" aria-pressed="true">Everything</button>
      <button type="button" data-type-filter="decisions" aria-pressed="false">Decisions</button>
      <button type="button" data-type-filter="shipped" aria-pressed="false">Built and shipped</button>
    </div>
  </div>
  <div class="control">
    <span>Project</span>
    <select id="project-filter"><option value="all">All projects</option>{options}</select>
  </div>
  <div class="control">
    <span>Theme</span>
    <div class="segmented"><button type="button" id="theme-toggle">Switch</button></div>
  </div>
  <p class="tally" id="tally"></p>
</div>

{blocks}
</div>
<script>{queue_js}</script>
<script>{js}</script>
</body>
</html>
""".format(
        schema=SCHEMA,
        css=CSS,
        generated=esc(generated),
        home=esc(home),
        options=options,
        blocks="\n".join(blocks),
        queue_js=QUEUE_JS,
        js=JS,
    )


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------


def load_pr_state(path):
    state = {}
    if not path or not os.path.isfile(path):
        return state
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "\t" not in line:
                continue
            url, value = line.rstrip("\n").split("\t", 1)
            state[url] = value
    return state


def main(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--full-text-dir", default="")
    parser.add_argument("--cards", default="")
    parser.add_argument("--pr-state", default="")
    parser.add_argument("--pr-verified", default="0")
    parser.add_argument("--home", default="")
    parser.add_argument("--out", default="")
    parser.add_argument("--decision-ids", action="store_true")
    parser.add_argument("--pr-urls", action="store_true")
    args = parser.parse_args(argv)

    with open(args.snapshot, "r", encoding="utf-8", errors="replace") as fh:
        snap = json.load(fh)

    if args.decision_ids:
        for record in open_captain_decisions(snap):
            print(record.get("id", ""))
        return 0
    if args.pr_urls:
        for entry in recorded_prs(snap):
            print(entry["url"])
        return 0

    if not args.out:
        parser.error("--out is required")

    pr_verified = args.pr_verified == "1"
    model = build_model(
        snap,
        load_full_text(args.full_text_dir),
        load_cards(args.cards),
        load_pr_state(args.pr_state),
        pr_verified,
    )
    page = render(model, snap, args.home or snap.get("fm_home", ""), pr_verified)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(page)
    counts = (
        len(model["decisions"]),
        len(model["prs"]),
        len(model["underway"]),
        len(model["queued"]),
        len(model["shipped"]),
        len(model["stuck"]),
    )
    print(
        "decisions=%d review=%d underway=%d queued=%d shipped=%d stuck=%d" % counts,
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
