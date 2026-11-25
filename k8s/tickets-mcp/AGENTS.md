# AGENTS.md — rules for agents working in this fixture tree

> **Test-only fixture.** This AGENTS.md is invented for the published server's selftest —
> it is the file the relative-launch check reads (`--tickets tickets.md` from this
> directory, the launch shape the local harness uses in the source-of-truth repo).

The rules that matter here:

- **verified-here**: a claim is only believed once it was reproduced in the sandbox that
  reports it; anything else is labeled handoff-reported or speculation, and the label
  travels with the claim.
- **Public-safe by construction**: this tree carries no real ticket data, no network
  addresses, no credential names — the fixtures are invented and stay invented.
- **Read-only**: the server this fixture exercises has no write path at all; a ticket's
  status changes only when the file changes in git.
- **Small payloads**: answers trim to a caller's max_chars; tickets trim from the middle
  (the start and the latest entries both matter), docs trim from the end.
