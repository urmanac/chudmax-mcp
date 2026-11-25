# Design: chudmax k8s phase 4b mock ticket server

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

The mock is a fresh public-safe implementation of the canonical tickets-mcp's signatures (`kingdonb/chudmax` `tools/mcp/ticket_mcp.py` + `tools/mcp/selftest.py`, both read in full 2026-11-25 from `main` @ `de442410` — blobs `5e3d09ca` and `9bb6b883`): same protocol, same seven tools, its own data. Per the steering brief: **not a copy** — the private code is reference-only; the mock is written from the recorded contract with its own structure and wording, and nothing private (code text or data) lands in the public repo. Single file, Python 3 stdlib only, zero dependencies, under `k8s/tickets-mcp-mock/`.

## The canonical surface (recorded, reproduced exactly)

Seven read-only tools — names, order, inputSchemas and descriptions reproduced as-is (they contain no private material):

| tool | params | returns |
|---|---|---|
| `list_tickets` | — | one line per ticket: id, status (12-wide), priority (6-wide), title |
| `get_ticket` | `id` (required), `max_chars` (description: "default 3000") | one ticket, trimmed from the MIDDLE (head 40% / tail 60%, cut at line breaks, omission note between) |
| `search_tickets` | `query` (required) | matching ids + one-line snippets (first matching line, ~160 chars) |
| `repo_facts` | — | revision/checkout facts + ticket counts by status |
| `list_docs` | — | readable files: one line each (rel path, size, first `#` heading ≤70 chars) |
| `read_doc` | `name` (required), `max_chars` (description: "default 1500") | one doc, truncated from the END (docs read top-down) |
| `search_docs` | `query` (required), `max_hits` (default 12) | `file:line` matches (~140 chars each), capped with a note |

One `handle()` dispatch behind both transports:

- `initialize` → protocolVersion `2024-11-05`, `capabilities.tools.listChanged: false`, serverInfo, instructions ("nothing here can change a ticket's status; only a commit can").
- `tools/list` **and** `resources/list` both answer `{"tools": [...]}` (canonical quirk — part of the observable signature).
- `tools/call` → `{"content":[{"type":"text","text":…}]}`; unknown tool → same shape with `isError: true`; a raised exception becomes `error: <type>: <msg>` text (never kills the pipe).
- Unknown method → JSON-RPC error `-32601`.
- **stdio:** one JSON object per line; blank and unparsable lines skipped with no reply; replies one object per line, flushed.
- **HTTP (`--http PORT [--host ADDR]`, PORT 0 = OS picks):** `ThreadingHTTPServer`, HTTP/1.1, always `Content-Length`. POST (handled on any path; `/mcp` is the documented one): try the first line as JSON, else the whole body; must be an object. Malformed → **400** `{"error":{"code":-32700,…}}`. Object without `id` (notification) → **202, empty body**. Else → **200**, one JSON object + trailing newline. GET (any path) → **405**, `Allow: POST`, small text hint. Startup prints exactly `listening on <host>:<port>` (the selftests parse it).

**What the canonical selftest locks (the behavioral fingerprints worth reproducing):** `serverInfo.name == "chudmax-tickets"`; tools/list = exactly seven; repo_facts pod mode reports the handed revision + `no git was asked` + `artifact unpacked:`; the trim note regex `\n[... ...]\n?` with `max_chars=<len> returns all`; a trimmed ticket keeps its title line and its last line; each tool's actual default cap matches the `default N` its schema description advertises (the description is load-bearing — keep it verbatim); malformed POST → 400; notification → 202 + `read() == b""`; GET → 405.

## Mock vs canonical (the deltas)

1. **Data = the mock fixture** (`fixture/`): a synthetic `tickets.md` in the canonical grammar (the mock parses with the same regex grammar: `## T-XXXX - Title`, `**Status/Owner/Priority/Due/Tags/Depends on/Coordination:**`, `**Purpose:**`, diary blocks), a mock `STATE.md`, a couple of mock `docs/` and `decisions/` records, and a small `README.md` — enough to exercise every tool honestly. All content invented; no original tickets, no real names/hosts/tokens. The canonical's readable set (README.md, AGENTS.md, tickets.md, docs/, decisions/, plans/) applies unchanged — fixture files not in the set are simply not listed.
2. **Pod mode reads artifact.json per call.** `--data-root <root>` switches the whole store to `<root>/current/` reread on EVERY call (the volume contract): tickets/docs parse from the unpacked tree; `repo_facts` reads `<root>/current/artifact.json` fresh and reports its six fields (url, revision, digest, produced, unpacked, source). Missing/unparsable artifact.json → `repo_facts` says so honestly and still serves what it can. The canonical's phase-1 flags (`--revision/--artifact-produced/--artifact-unpacked`) stay accepted for CLI parity (the canonical selftest's pod-mode shape uses them); `--data-root` wins when both are given.
3. **serverInfo name mirrored verbatim** (`chudmax-tickets`) — resolved by evidence: the canonical's own selftest asserts it, and phase 5's canary may reuse those checks. The mock marks itself where it does not affect signatures: its dir README, the fixture content, and the image labels/description.
4. **CLI:** `--tickets PATH` (default: bundled fixture), `--http PORT`, `--host`, `--data-root`, plus the canonical's revision flags for parity.

## Repo layout

```
k8s/tickets-mcp-mock/
  ticket_mcp_mock.py     the server — fresh single-file stdlib implementation
  fixture/               tickets.md, STATE.md, README.md, docs/, decisions/ (mock records)
  test_tickets_mcp_mock.py  subprocess-based suite, canonical selftest style (keyed results)
  Dockerfile             python:3.12-alpine, COPY-only, non-root, stdio default entrypoint
  README.md              what it is / what it is not (no real data; canonical stays private)
k8s/chart/chudmax-mcp/README.md   NEW (docs-only): the optional-server example values → mock image
README.md, .github/workflows/image-chart.yml     pointer + CI edits
```

## Key decisions

1. **Fresh implementation against a recorded contract.** "Signature-compatible" is enforced by the recorded surface (the table above) and by the mock's own suite asserting the same fingerprints the canonical selftest asserts. The private code is reference-only — own structure, own comments, no copied text; the implementing session re-verifies the canonical files' heads before merging (cheap provider-API read; if the head moved past `de442410`, diff and adjust).
2. **Fixture ships inside the image** at a fixed path; standalone mode (no `--data-root`) always works — the image is demoable with `podman run -i --rm <image>` alone. In pod mode the volume is the only data source; until the first artifact swap the tree is absent and the tools answer honestly (no tickets, artifact facts missing).
3. **Pod mode = per-call rereads through `current`** — matches the fetcher README's `repo_facts` contract and the chart's shared-volume mount; a test swaps the symlink mid-run to prove facts swap with content, no restart.
4. **Dockerfile: `python:3.12-alpine`, COPY-only, numeric non-root USER.** No RUN → no emulation in the manifest build (the multi-arch base carries the arch difference; the fetcher image's cross-compile pin is unnecessary here). Build: `podman build --platform linux/amd64,linux/arm64 --manifest localhost/chudmax-tickets-mock:0.1.0 -f k8s/tickets-mcp-mock/Dockerfile k8s/tickets-mcp-mock`.
5. **Example values live in a new chart README** (`k8s/chart/chudmax-mcp/README.md` — the chart dir has none today; docs-only, `helm lint`/`template` provably unaffected). CI templates the example via `--set` flags (the phase-3-proven pattern) rather than a separate values file. No `values.yaml` changes — the default install stays fetcher-only (phase-3 boundary).
6. **CI extends `image-chart.yml`** (existing jobs untouched): a Python test job (`setup-python@v5`, pinned 3.12, runs the mock suite); a `mock-image` job (both-arches manifest build, arch-count check, HTTP smoke: initialize → 200, notification → 202, GET → 405, malformed → 400); one more chart-job template step with the mock example values. No registry push anywhere.
7. **Public-safe by construction.** A hygiene test scans the fixture + server for a denylist (LAN-shaped addresses, token-ish strings, real hostnames — none present); the chart README references only the unpublished ghcr tag and local build commands; no LAN addresses, credential names, or proxy hostnames anywhere in the diff.

## Notes for future agents (learnings)

- **Canonical quirks mirrored deliberately — they ARE the signature:** `resources/list` answers with the tools list; POST is accepted on any path (the docstring's `/mcp` is documentation, not enforcement); `protocolVersion` pinned to `2024-11-05`; 202 bodies truly empty; tickets trim MIDDLE (40/60, line-aligned, omission note), docs trim END; `read_doc` refuses anything outside the readable set via a resolve-based traversal check. The canonical selftest's check style is also the pattern to copy: spawn the server as a real subprocess, key results by call id (never by tool name — the same tool is called several times), assert on trimmed-vs-advertised caps.
- **The `default N` schema descriptions are load-bearing** — the canonical selftest parses them and cross-checks behavior. Changing that wording is a signature break, not a docs edit.
- The canonical `main` head was `de442410` on 2026-11-25 (unchanged since phase 4's verification); public `main` is `67d8616` (phases 2–4 merged). The recorded surface is current as of those commits.
- Podman gotchas from phase 3 still apply in this sandbox: binfmt_misc is denied (no arm64 containers; host-side `qemu-aarch64` exec is the proven workaround), rootless pasta refuses container→host via the bridge gateway (smoke with `--network host` + host loopback).
- Public-mirror discipline stands: no LAN addresses, credential names, or internal proxy hostnames in the public repo; the three labels (`verified-here` / `handoff-reported` / `speculation`) on every claim; the `helix-specs` branch is fast-forward-only.
- PR flow (owner's standing delegation): propose freely via `propose_pull_request`, no approval wait; CI green + in-sandbox verification before merge; merge authority is CoS/owner; `mark_task_complete` only after merge; conventional commits; carry the deferred-LICENSE flag line in the PR description.
