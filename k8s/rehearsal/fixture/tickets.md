# Tickets — rehearsal fixture

Synthetic content for the phase-5 CI rehearsal's test repo (invented; no real
tickets ever enter this repo). The narrowed copy rules require all four
entries (`tickets.md`, `STATE.md`, `docs/`, `decisions/`) to exist — the
ArtifactGenerator's `optional: false` turns a missing file into a loud
failure. Commit #1 carries this tree; commits #2–#4 append the rehearsal
tickets (T-9002, T-9003, T-9004) that the script asserts appear in
`list_tickets` with nobody doing anything.

## T-9001 - Example: the seed ticket of the phase-5 rehearsal

**Status:** in-progress
**Owner:** rehearsal-fixture
**Priority:** next

**Purpose:**
One synthetic ticket the first reconciliation must deliver end to end
(GitRepository 1m interval, ArtifactGenerator narrowing, the fetcher's swap,
and the published server's list_tickets answering over the Service).

---
