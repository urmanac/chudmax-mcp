# k8s/tickets-mcp — the canonical ticket server, published

This directory **is** the source-of-truth repo's MCP server, published byte-exact:
`tools/mcp/ticket_mcp.py` is the fixed canonical file (the per-call contract), and
`tools/mcp/selftest.py` is its own self-test. The scope decision was flipped from a
mock to this publication — the real server ships, and it is public-safe by ruling:
its **source** was blessed for publication; its **data** never enters this repo. The
`tickets.md` / `AGENTS.md` / `STATE.md` / `docs/` / `decisions/` files here are
**invented, test-only fixtures** that the selftest runs against — nothing in them is
a real ticket.

## The fixed contract (what "per call" means)

The fetcher swaps `<data-root>/current` (a symlink to a revision tree) and prunes the
revision dirs it no longer keeps. The server therefore:

- opens every file **through the symlink on every call** — `current` is resolved ONCE
  at the START of each call, and the whole call (tickets, docs, facts) reads that
  resolved snapshot: a fetcher swap is picked up on the NEXT call, with no restart,
  and one call never mixes two revisions;
- takes `repo_facts` from `<data-root>/current/artifact.json` read per call — url,
  revision, digest, produced, unpacked, source, and `origin_revision` when the
  fetcher recorded it (see `k8s/fetcher/README.md` for the volume contract).

Plain-file mode (`--tickets PATH`, no `--data-root`) is the no-fetcher setup: the path
resolves ONCE at startup (no symlink churn behind a plain path — and that startup
resolve is what makes a relative `--tickets tickets.md` launch work from any cwd).

## Transports

- **stdio** (default): one JSON-RPC message per line on stdin, one JSON object per line
  on stdout. This is the local-harness launch shape.
- **HTTP** (`--http PORT`): POST one JSON-RPC object to `/mcp` (any path is accepted),
  get one JSON object back; a notification (no `id`) → **202** with an empty body;
  GET → **405** with `Allow: POST`; a malformed body → **400**. The server announces
  `listening on <host>:<port>` on stdout at startup.

## Bearer token (HTTP only; per `kubernetes/mcp.md`)

`--bearer-token-file PATH` requires `Authorization: Bearer <token>` on every POST. The
token file is read **per request**, so a Secret rotation needs no restart. Missing,
wrong, or unreadable token → **401**, fail-closed. stdio is a local pipe and stays
auth-free. The chart wires this via `server.auth.*` (a Secret mounted at
`/var/run/mcp-auth`); token VALUES never enter values.yaml.

## The seven tools

`list_tickets`, `get_ticket(id, max_chars=3000)` (middle-trim), `search_tickets(query)`,
`repo_facts()`, `list_docs()`, `read_doc(name, max_chars=1500)` (end-trim, resolve-based
readable set: README.md, AGENTS.md, tickets.md, docs/, decisions/, plans/),
`search_docs(query, max_hits=12)`.

## Self-test

```sh
python3 tools/mcp/selftest.py        # from this directory
```

Spawns the server as a real subprocess and asserts on the answers: all seven tools over
both transports, the 202/405/400 semantics, the trim fingerprints (against this tree's
own fixtures), the per-call proof (a fixture volume: v1 → swap to v2 without a restart
→ prune v1 → still answers, docs and facts asserted), the relative-launch shape, and
the bearer option (401s, pass, rotation).

## Image

```sh
podman build --platform linux/amd64,linux/arm64 \
  --manifest ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0 \
  -f k8s/tickets-mcp/Dockerfile k8s/tickets-mcp
```

COPY-only (no RUN), runs as uid 65532, default entrypoint stdio in pod mode against
`/data`. No registry push from CI; publishing the image is a later phase.

## What this directory is NOT

- Not a mock: the server file is the canonical implementation, unmodified.
- Not data: every fixture file is invented; the private source-of-truth repo's tickets
  never enter this repo.
- Not drift-prone: the private copy of the server is frozen history; this public file
  is the server's home now.
