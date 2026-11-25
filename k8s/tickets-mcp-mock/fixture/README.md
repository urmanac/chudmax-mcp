# The mock fixture

This directory is `tickets-mcp-mock`'s bundled data: a small, fully invented inventory in the
same file grammar as the real one. The mock server reads it when it is started without
`--data-root` (standalone mode over stdio or HTTP).

- `tickets.md` — six mock tickets across done / in-progress / open / blocked / wont-do /
  proposed; T-0002's diary is long on purpose so the middle-trim contract is exercisable.
- `STATE.md` — the short-version file the real artifact also carries.
- `docs/`, `decisions/` — example records for the doc tools.
- `AGENTS.md` — a stub so the readable set is complete.

None of the private deployment's tickets or docs is included here; the fixture is invented
end to end. A hygiene check in the test suite asserts the denylist (no LAN-shaped addresses,
no real hostnames, no credential-shaped strings).
