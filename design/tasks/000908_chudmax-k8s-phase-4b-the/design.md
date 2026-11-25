# Design: chudmax k8s phase 4b mock ticket server

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

The mock is a public stand-in for the canonical tickets-mcp (`kingdonb/chudmax` `tools/mcp/ticket_mcp.py`, read in full 2026-11-25 — blob `5e3d09ca` on `main` @ `de442410`): same protocol, same seven tools, its own data. Implementation is a mirror of the canonical single-file Python program (stdlib only, zero dependencies) with the data source swapped for synthetic fixtures under `k8s/tickets-mcp-mock/`.

## The canonical surface (recorded, mirrored verbatim)

Seven read-only tools — names, order, inputSchemas and descriptions copied as-is (they contain no private material):

| tool | params | returns |
|---|---|---|
| `list_tickets` | — | one line per ticket: id, status, priority, title |
| `get_ticket` | `id` (required), `max_chars` (default 3000) | one ticket, trimmed from the MIDDLE (head 40% / tail 60%, cut at line breaks, omission note between) |
| `search_tickets` | `query` (required) | matching ids + one-line snippets |
| `repo_facts` | — | revision/checkout facts + ticket counts by status |
| `list_docs` | — | readable files: one line each (rel path, size, first heading) |
| `read_doc` | `name` (required), `max_chars` (default 1500) | one doc, truncated from the END (docs read top-down) |
| `search_docs` | `query` (required), `max_hits` (default 12) | `file:line` matches, capped |

One `handle()` dispatch behind both transports:

- `initialize` → protocolVersion `2024-11-05`, `capabilities.tools.listChanged: false`, serverInfo, instructions ("nothing here can change a ticket's status; only a commit can").
- `tools/list` **and** `resources/list` both answer `{"tools": [...]}` (canonical quirk — kept).
- `tools/call` → `{"content":[{"type":"text","text":…}]}`; unknown tool → same shape with `isError: true`; a raised exception becomes `error: <type>: <msg>` text (never kills the pipe).
- Unknown method → JSON-RPC error `-32601`.
- **stdio:** one JSON object per line; blank and unparsable lines skipped with no reply; replies one object per line, flushed.
- **HTTP (`--http PORT [--host ADDR]`):** `ThreadingHTTPServer`, HTTP/1.1. POST (any path; `/mcp` is the documented one): try the first line as JSON, else the whole body; must be an object. Malformed → **400** `{"error":{"code":-32700,…}}`. Object without `id` (notification) → **202**, empty body. Else → **200**, one JSON object + trailing newline. GET (any path) → **405**, `Allow: POST`, small text hint. Startup prints `listening on <host>:<port>` (the selftest reads that line).

## Mock vs canonical (the deltas)

1. **Data = the mock fixture.** `fixture/` carries a synthetic `tickets.md` in the canonical grammar (the mock parses with the canonical's exact regexes: `## T-XXXX - Title`, `**Status/Owner/Priority/Due/Tags/Depends on/Coordination:**`, `**Purpose:**`, diary blocks), plus README/AGENTS and `docs/`, `decisions/`, `plans/` examples — enough for list/search/trim/counts to be meaningful. All content invented; no original tickets, no real names/hosts/tokens.
2. **Pod mode reads artifact.json per call.** `--data-root <root>` switches the whole store to `<root>/current/` reread on EVERY call (the volume contract): tickets/docs parse from the unpacked tree; `repo_facts` reads `<root>/current/artifact.json` fresh and reports its six fields (url, revision, digest, produced, unpacked, source). Missing/unparsable artifact.json → `repo_facts` says so honestly and still serves what it can. This is the mock's pod mode per the task direction; the canonical's phase-1 static flags (`--revision/--artifact-produced/--artifact-unpacked`) stay supported for CLI parity when no `--data-root` is given.
3. **serverInfo marked.** `serverInfo.name: "chudmax-tickets-mock"`, title gains "(mock fixture)" — pending Open Question 1.
4. **CLI:** `--tickets PATH` (default: bundled fixture), `--http PORT` (0 = OS picks, the selftest's mode), `--host`, `--data-root`.

## Repo layout

```
k8s/tickets-mcp-mock/
  ticket_mcp_mock.py     the server — single file, stdlib only
  fixture/               tickets.md, README.md, AGENTS.md, docs/, decisions/, plans/
  selftest.py            numbered checks: both transports + pod mode (canonical selftest style)
  Dockerfile             python:3.12-alpine, COPY-only, non-root, stdio default entrypoint
  README.md              what it is / what it is not (no real data; canonical stays private)
k8s/chart/examples/values-tickets-mcp-mock.yaml   the optional-server example values
README.md, .github/workflows/image-chart.yml      pointer + CI edits
```

## Key decisions

1. **Mirror the canonical, don't rewrite it.** "Signature-compatible" is easiest to keep by mirroring the canonical's structure (TOOLS list, `handle()` dispatch, HTTP handler, trim helpers) and swapping the data source. Zero dependencies keeps the image trivial and the diff reviewable. The recorded surface is the contract; the implementing session re-verifies the canonical file's head before merging (cheap provider-API read; if it moved past `de442410`, diff the TOOLS block and adjust).
2. **Fixture ships inside the image** at a fixed path; standalone mode (no `--data-root`) always works — the image is demoable with `podman run -i --rm <image>` alone. In pod mode the volume is the only data source; until the first artifact swap the tree is absent and the tools answer honestly (no tickets, artifact facts missing).
3. **Pod mode = per-call rereads through `current`** — matches the fetcher README's `repo_facts` contract and the chart's shared-volume mount; a selftest swaps the symlink mid-run to prove facts swap with content, no restart.
4. **Dockerfile: `python:3.12-alpine`, COPY-only, numeric non-root USER.** No RUN → no emulation in the manifest build (the multi-arch base carries the arch difference; the fetcher image's cross-compile pin is unnecessary here). Build: `podman build --platform linux/amd64,linux/arm64 --manifest localhost/chudmax-tickets-mock:0.1.0 -f k8s/tickets-mcp-mock/Dockerfile k8s/tickets-mcp-mock`.
5. **Example values live outside the chart** (`k8s/chart/examples/`) so `helm lint`/`package` are untouched; CI templates them with `-f`. No `values.yaml` default changes — the default install stays fetcher-only (phase-3 boundary). The example's `command`/`args` run HTTP mode on the `server.port` with `--data-root /data`.
6. **CI extends `image-chart.yml`** (existing jobs untouched): a Python selftest job (`setup-python@v5`, pinned 3.12); a `mock-image` job (both-arches manifest build, arch-count check, HTTP smoke: initialize → 200, notification → 202, GET → 405, malformed → 400); one more chart-job template step with the example values. No registry push anywhere.
7. **Public-safe by construction.** A hygiene test scans the fixture + server for a denylist (LAN-shaped addresses, token-ish strings, real hostnames — none present); the example values reference only the unpublished ghcr tag and local build commands; no LAN addresses, credential names, or proxy hostnames anywhere in the diff.

## Notes for future agents (learnings)

- Canonical quirks mirrored deliberately — they ARE the signature: `resources/list` answers with the tools list; POST is accepted on any path (the docstring's `/mcp` is documentation, not enforcement); `protocolVersion` pinned to `2024-11-05`; 202 bodies truly empty; trimming rules matter (tickets trim MIDDLE 40/60, docs trim END; `read_doc` refuses anything outside README.md/AGENTS.md/tickets.md/docs//decisions//plans/ via a resolve-based check).
- The canonical `main` head was `de442410` on 2026-11-25 (unchanged since phase 4's verification) — the recorded tool surface is current as of that commit.
- The chart's server values render `command`/`args`/`env`/`port` verbatim (`templates/deployment.yaml`); the Service + ingress NetworkPolicy appear only when `server.enabled=true`; `helm template` never pulls images, so the unpublished example tag renders fine.
- Public-mirror discipline stands: no LAN addresses, credential names, or internal proxy hostnames in the public repo; the three labels (`verified-here` / `handoff-reported` / `speculation`) on every claim; the `helix-specs` branch is fast-forward-only.
- PR flow (owner's standing delegation): propose freely via `propose_pull_request`, no approval wait; merge authority is CoS/owner with CI green; conventional commits; carry the deferred-LICENSE flag line in the PR description.
