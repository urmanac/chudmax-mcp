# STATE.md — the mock fixture's short version

This fixture's STATE.md exists so the narrowed-artifact shape is honest: the real artifact
carries tickets.md, STATE.md, docs/ and decisions/, so the mock's fixture does too. Everything
in it is invented for the mock.

- tickets.md: 6 mock tickets. 1 done, 1 in-progress, 1 open, 1 blocked, 1 wont-do, 1 proposed
- decisions/0001-0002: two example records (naming, demo cadence) — invented, cited to nobody
- docs/: two example records (queue wiring, runbook stub) — invented end to end
- The canonical state is the fixture directory itself; there is no other door.

## Boundaries in force
- Read-only: the mock server has no write path; statuses change only when the fixture files do.
- The real deployment's data is not here, on purpose — this fixture is the public stand-in.
