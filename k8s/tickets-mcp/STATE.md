# STATE.md — the fixture's short version

> **Test-only fixture.** Invented for the published server's selftest; carries no real state.

Repo: the fixture tree beside this file. Canonical state: the files as committed.
Before anything changes here, run: `python3 tools/mcp/selftest.py` from this directory.

Count: 7 tickets / 2 done (T-0001 done, T-0005 wont-do, one per other status).

The server under test reads this tree through the documented per-call contract; the
selftest is the proof. Nothing in this file is about any real deployment.
