# tickets.md — the mock fixture's ticket file

This file is the mock fixture's own ticket inventory, written in the same grammar the real
inventory uses (`## T-XXXX - Title` headers, `**Field:**` lines, `**Purpose:**` blocks, diary
entries). Every ticket here is invented for the mock; none of the real deployment's tickets is
included. Statuses are data, not authority — nothing can make a ticket "done" but a commit.

---

## T-0001 - Mock: stand up the example widget registry

**Status:** done
**Owner:** mock-agent
**Priority:** now
**Tags:** mock, example, registry
**Depends on:** none
**Coordination:** none

**Purpose:**
Give the mock fixture a first ticket that is closed, so `list_tickets` and the status counts
have a done row to show, and so the example docs can point at something that exists.

**Diary:**
- Chose the name "widget registry" because the fixture needed a noun that is obviously not
  anyone's real project. `verified-here` by reading the fixture and finding no real name.
- Registered three example widgets: alpha, beta, gamma. Their properties are lorem-ipsum grade
  on purpose.
- Marked done by this fixture's own commit rule: the status above is data; the commit is the
  authority.

---

## T-0002 - Mock: wire the frobnicator to the sample queue

**Status:** in-progress
**Owner:** mock-agent
**Priority:** next
**Tags:** mock, example, queue
**Depends on:** T-0001
**Coordination:** pairs with T-0004

**Purpose:**
Be the fixture's long ticket: a diary long enough that `get_ticket` at its default cap trims
it from the middle, keeping the head (title, status, purpose) and the latest entries at the
end, with the omission note naming what `max_chars` returns all of it. Everything between is
padding about a frobnicator, a sample queue, and the weather in an invented town.

**Diary:**
- Morning, day one: the frobnicator booted. Its sample queue was empty. Registered the queue
  with a capacity of forty and a polling interval of one minute, both numbers invented here so
  that a reader can tell fixture text from real configuration at a glance.
- Noon, day one: wired the first three widgets (alpha, beta, gamma) to the queue. The queue
  took them. The frobnicator's logs show lorem lines where real logs would be.
- Evening, day one: a first trimming rehearsal. Asked for this ticket at the default cap and
  read what came back: the head was here, the tail was there, the middle was the note. That is
  the shape the canonical server's trimming contract promises, and the mock reproduces it.
- Morning, day two: the queue's polling interval was too slow for the demo, so the fixture's
  imaginary operator raised the poll rate. In a real repo this line would carry measured
  numbers; here it carries the intent of having numbers.
- Noon, day two: practiced the failure mode. A cut that kept only the head would report this
  in-progress ticket with its purpose and no latest entries, which is exactly why the trim is
  middle-shaped and not head-shaped. The note in the middle says how to get everything.
- Evening, day two: the sample queue filled with forty lorem items and drained at the
  invented rate. No real system was involved anywhere in this diary; every noun after
  "frobnicator" is fixture vocabulary.
- Morning, day three: wrote down the wiring as `docs/example-queue-wiring.md` so
  `read_doc` and `search_docs` have something to find, and so the fixture's doc tools have a
  stable target for their own checks.
- Noon, day three: the frobnicator now keeps its own mock ledger. The ledger is a fixture file;
  it exists so a search for the word "ledger" finds exactly one place and a reader can confirm
  the search contract without any real data being present.
- Evening, day three: rehearsed the whole loop once more end to end: list, get, search, doc
  index, doc read, doc search, facts. All seven tools answered from this fixture. The loop is
  the point: a user of the chart can exercise the same loop against the real server later and
  nothing about the shapes will have changed.
- Morning, day four: cleaned up yesterday's rehearsal artifacts (the imaginary ledger rows).
  The fixture keeps only what its checks need: this diary for trimming, the docs for the doc
  tools, the status spread for the counts.
- Noon, day four: recorded the wiring's one surprise — the frobnicator emits a startup event
  that the sample queue ignores on purpose (the fixture does not model event handling) — into
  the queue-wiring doc's last section, which sits near the end of a long file so an end-trim
  rehearsal finds it.
- Evening, day four: marked the wiring rehearsal complete. The ticket stays in-progress until
  the mock's own checks pass in CI, then a commit flips it; statuses are data and commits are
  authority, in the fixture exactly as anywhere else.

---

## T-0003 - Mock: choose the gizmo naming scheme

**Status:** open
**Owner:** nobody
**Priority:** someday
**Tags:** mock, example, naming
**Depends on:** none
**Coordination:** none

**Purpose:**
Give the fixture an open ticket: something proposed but not decided, so the status counts and
the search index have an open row. The candidates are "gizmo-vN", "N-gizmo", and "just N" —
the fixture has no stake in any of them.

---

## T-0004 - Mock: write the widget deployment runbook

**Status:** blocked
**Owner:** mock-agent
**Priority:** next
**Tags:** mock, example, runbook
**Depends on:** T-0002
**Coordination:** none

**Purpose:**
Be the fixture's blocked ticket: it waits on T-0002's queue wiring, which shows the
`Depends on` field doing its job and gives the docs a reason to have a runbook stub.

---

## T-0005 - Mock: prune the sample data

**Status:** wont-do
**Owner:** nobody
**Priority:** someday
**Tags:** mock, example, hygiene
**Depends on:** none
**Coordination:** none

**Purpose:**
Be the fixture's wont-do ticket. The fixture's data is small by construction — invented rows
in a handful of files — so there is nothing to prune; the wont-do status records that
decision instead of leaving the idea dangling as open work.

---

## T-0006 - Mock: schedule the quarterly demo

**Status:** proposed
**Owner:** nobody
**Priority:** someday
**Tags:** mock, example, demo
**Depends on:** none
**Coordination:** none

**Purpose:**
Be the fixture's proposed ticket: an idea with a date-shaped question attached (which
quarter?), so the status counts have a proposed row and the fixture demonstrates that a
proposed ticket is a ticket too.
