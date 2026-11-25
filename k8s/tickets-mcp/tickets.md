# tickets.md — the fixture's synthetic ticket file

> **Test-only fixture.** Every ticket here is invented for the published server's selftest.
> Nothing in this file is a real ticket; the real ones live in the private source-of-truth
> repo and never enter this public repo.

---

## T-0001 - Stand up the demonstration ticket file

**Status:** done
**Owner:** fixture
**Priority:** next
**Tags:** fixture, demo
**Depends on:** none
**Coordination:** none

**Purpose:**
Give the published server something honest to answer with: a small synthetic ticket file in
the canonical grammar, written for the selftest, carrying no real data.

**Done 2026-11-25 (the fixture author):**
- Wrote the seven fixture tickets across every status the parser knows.
- Kept every name, host, and identifier invented.

---

## T-0002 - Exercise the in-progress status in the fixture

**Status:** in-progress
**Owner:** fixture
**Priority:** next
**Tags:** fixture, statuses
**Depends on:** T-0001
**Coordination:** none

**Purpose:**
One ticket in each status so `tickets by status` has a key per status and list_tickets shows
a varied table.

**Work log 2026-11-25:**
- The in-progress ticket is this one; the selftest counts it.

---

## T-0003 - Leave one ticket open on purpose

**Status:** open
**Owner:** fixture
**Priority:** someday
**Tags:** fixture, statuses
**Depends on:** none
**Coordination:** none

**Purpose:**
An open ticket so no fixture run ever reports an all-done board.

---

## T-0004 - Show a blocked ticket in the fixture

**Status:** blocked
**Owner:** fixture
**Priority:** next
**Tags:** fixture, statuses
**Depends on:** T-0003
**Coordination:** none

**Purpose:**
The blocked status exists in the grammar; the fixture should speak it.

---

## T-0005 - Record a wont-do decision in the fixture

**Status:** wont-do
**Owner:** fixture
**Priority:** someday
**Tags:** fixture, statuses
**Depends on:** none
**Coordination:** none

**Purpose:**
`wont-do` is the grammar's delete operation; the fixture demonstrates it with a ticket the
fixture project decided not to do.

**Done 2026-11-25 (the fixture author):**
- Marked wont-do with the reason in the diary, as the grammar intends.

---

## T-0018 - The fixture's long diary ticket, for the trim checks

**Status:** in-progress
**Owner:** fixture
**Priority:** next
**Tags:** fixture, trim, diary
**Depends on:** T-0001
**Coordination:** none

**Purpose:**
One ticket long enough that every trim behavior shows: the default cap cuts it from the
middle (the start keeps the title and status, the end keeps the latest entries), a small
cap keeps only a few lines, and a huge cap returns it whole with a note saying so. The
selftest reads this ticket's block straight from the file and asserts on which lines the
server kept.

**Work log 2026-11-19:**
- Sketched the demonstration before anything was built: a fake fetcher volume made of
  real directories and a real symlink, two revisions with visibly different ticket
  content, and an artifact record beside each tree so the facts have something honest
  to report.

**Work log 2026-11-20:**
- Wrote the demo volume contract down: the fetcher unpacks a revision tree beside a
  `current` symlink; readers open the path through the symlink on every call, never a
  resolved copy captured at startup.

**Work log 2026-11-21:**
- The first draft of the demo reader resolved the symlink once at launch and kept reading
  the stale tree after a swap - the exact bug class the per-call contract exists to kill.
  The demonstration now resolves `current` once at the START of each call instead.

**Work log 2026-11-22:**
- Retention pruned the revision the demo reader started on; the reader kept answering,
  because every call reopens through the symlink and the facts come from the artifact
  record beside the tree.

**Work log 2026-11-23:**
- Measured the trim behavior on this very ticket: a middle cut that keeps four tenths of
  the characters from the start and the rest from the end keeps both the status line and
  the newest entry visible in every answer.

**Work log 2026-11-24:**
- A start-only cut once reported a finished ticket as still blocked, because the
  resolution lived at the end of the diary. The keep-both-ends shape fixed the report.
- Also checked the small-cap case: a 300-character cap keeps between 200 and 300
  characters, cut at a line break, so the cap is an upper bound that is nearly reached
  rather than an exact count.

**Work log 2026-11-25 (morning):**
- The huge-cap case: asking for a million characters returns the block whole, and the
  omission note says the exact number that returns all of it - a caller can always
  recover the untrimmed text in one more call.
- The count check got its proof too: the server's list of tickets has exactly one line
  per `## T-` heading in this file, so the parser and the naive count agree on what a
  ticket is - seven headings, seven lines, no phantom entries either way.

**Work log 2026-11-25 (evening):**
- The demonstration ticket is long enough now; the selftest asserts the title first line
  and the last diary line both survive the default cap, that a 300-character cap keeps
  between 200 and 300 characters, and that the huge cap returns the whole block.

---

## T-0019 - A short ticket for the plain get_ticket call

**Status:** open
**Owner:** fixture
**Priority:** someday
**Tags:** fixture
**Depends on:** none
**Coordination:** none

**Purpose:**
One short ticket the selftest fetches without trimming, so the suite exercises both sizes.

---
