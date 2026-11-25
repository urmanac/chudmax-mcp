# AGENTS.md — the mock fixture's stub

The real repo's AGENTS.md is its epistemic rulebook. This fixture carries a stub so the
readable set (README.md, AGENTS.md, tickets.md, docs/, decisions/, plans/) is complete and
`list_docs` has something to index for it.

The mock's own rules, short: read-only tools only; statuses are data; commits are authority;
every read goes through the `current` symlink per call when a `--data-root` is given.
