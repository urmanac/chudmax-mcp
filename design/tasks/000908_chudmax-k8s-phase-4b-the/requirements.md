# Requirements: chudmax k8s phase 4b mock ticket server

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 interstitial (owner direction, 2026-11-25): the public repo `urmanac/chudmax-mcp` ships a **mock ticket server** — representative of, and signature-compatible with, the canonical chudmax tickets-mcp, which stays private in `kingdonb/chudmax` with the real data. Phase 3's boundary stands for real deployments (a production server is still bring-your-own); the mock is the repo's own worked example: it gives the chart's optional-server container a concrete, runnable default and lets later rehearsal phases (e.g. phase 5's commit → `list_tickets`) run against something public. The mock serves its own mock fixture data — **NONE of the original repo's tickets**.

Everything happens in the public repo via the Helix proxy origin. Phases 2–4 are merged: the fetcher (`k8s/fetcher/`), the fetcher-only image + chart (PR #2), the repo-sync manifests (PR #3). No registry push (ghcr.io is phase 10); local podman + CI build only. The box is untouched; nothing lands on `main` unreviewed; conventional commits; the three labels on every claim.

## Preconditions (verified)

- [x] The canonical tool surface is recorded from `kingdonb/chudmax` `main` @ `de442410` — `tools/mcp/ticket_mcp.py` (blob `5e3d09ca5cf5aa46df52f156b885218ee2cbf194`, 21,239 B, fetched read-only via the provider API, 2026-11-25): exactly **seven read-only tools** — `list_tickets`, `get_ticket`, `search_tickets`, `repo_facts`, `list_docs`, `read_doc`, `search_docs` — and no write path anywhere in the file (`verified-here`).
- [x] The volume contract the mock codes against is written down: `k8s/fetcher/README.md` — `revisions/<digest-hex>/`, the relative `current` symlink swapped by rename(2), and `artifact.json` (url, revision, digest, produced, unpacked, source) beside every unpacked tree (`verified-here`).
- [x] The chart's optional-server values exist and render: `server.enabled/image/command/args/env/port` (disabled by default; Service + ingress NetworkPolicy render only when enabled) — `verified-here` (`k8s/chart/chudmax-mcp/values.yaml`, `templates/deployment.yaml`).
- [x] CI today: `fetcher-test` (Go) and `image-chart` (chart lint/template + podman both-arches build, no push) — `verified-here`.

## User stories

1. **As a user installing the chart**, I enable `server.enabled` with the shipped example values and get a working MCP server container pointed at the mock image — a real example of the bring-your-own interface instead of a placeholder.
2. **As an MCP client author**, I can drive the mock over stdio or HTTP and exercise the same seven read-only tools, the same `initialize`/`tools/list`/`tools/call` shapes, and the same HTTP semantics (one JSON object per POST to `/mcp`, 202 for notifications, 405 for GET, 400 for malformed) that the canonical server speaks.
3. **As the phase-5 rehearsal**, I run "commit → `list_tickets`" against the mock in pod mode: the fetcher swaps `/data/current`, and the mock's `repo_facts` answers from `/data/current/artifact.json` read per call — no restart, no git.
4. **As the owner**, I want the mock's fixture data obviously synthetic (no original tickets, no LAN addresses, no credential names, no proxy hostnames), so the public repo stays public-safe by construction.
5. **As CI**, I want every push to re-prove the mock: selftest over both transports, a both-arches image build (no push), and a chart template with the example values.

## Acceptance criteria

- [ ] `k8s/tickets-mcp-mock/` ships the mock server as a single-file Python 3 stdlib program plus its mock fixture (tickets + docs) and a selftest that drives BOTH transports.
- [ ] Signature-compatible with the canonical surface: the same seven tools (names, order, inputSchemas), the same `initialize`/`tools/list`/`tools/call` result shapes (text content blocks; `isError` result for an unknown tool; `-32601` for an unknown method; notifications get no stdio reply), and the same HTTP semantics: POST → one JSON object (200), notification (no `id`) → 202 empty body, GET → 405 with `Allow: POST`, malformed body → 400 with `-32700`. stdio: one JSON-RPC object per line; blank and unparsable lines skipped silently.
- [ ] Pod mode: started with `--data-root <root>`, every `repo_facts` call reads `<root>/current/artifact.json` fresh through the symlink and reports url, revision, digest, produced, unpacked, source (plus ticket counts); ticket/doc tools read the unpacked tree through `current` per call. A test swaps the symlink mid-run and proves the next call reports the new facts — no restart.
- [ ] The mock's fixture is its own: synthetic tickets in the canonical `tickets.md` grammar (`## T-XXXX - Title`, `**Status/Owner/Priority/…:**`, `**Purpose:**`, diary entries) across several statuses, one long enough to exercise `get_ticket`'s middle-trim; synthetic docs for `list_docs`/`read_doc`/`search_docs`. Zero original-repo tickets; zero LAN addresses, credential names, or proxy hostnames; a hygiene test asserts the denylist.
- [ ] One OCI image builds as a manifest list for `linux/amd64` and `linux/arm64` under podman (COPY-only Dockerfile → no emulation), runs non-root, defaults to stdio over the bundled fixture; no registry push.
- [ ] The chart gains an example values file (e.g. `k8s/chart/examples/values-tickets-mcp-mock.yaml`) with `server.enabled: true`, the mock image (`ghcr.io/urmanac/chudmax/tickets-mcp-mock:0.1.0`, unpublished until phase 10 — build it yourself meanwhile), HTTP mode on `server.port`, and `--data-root` on the shared volume; `helm template` with it renders the Service + ingress NetworkPolicy. Chart template logic is untouched.
- [ ] CI: the mock selftest runs (Python job); the mock image builds both arches and gets an HTTP smoke (initialize 200, notification 202, GET 405, malformed 400); the chart job templates the example values. Existing jobs stay green.
- [ ] The root README's "Bring your own MCP server" section points at the mock as the worked example; the mock dir has its own README (what it is, what it is not — no real data; the canonical server stays private).
- [ ] The box is untouched; nothing lands on `main` unreviewed; conventional commits; three labels on every claim; the missing-LICENSE flag rides along in the PR description (phase-3 precedent).

## Out of scope (owned by other phases or decisions)

- Publishing any image (ghcr.io, cosign) — phase 10. Live-cluster rehearsal — phase 5.
- The canonical server and the real ticket data — they stay private in `kingdonb/chudmax`; nothing from them enters the public repo except the protocol surface (tool names, schemas, protocol semantics), which is metadata, not data.
- Chart template logic changes (probes, new values fields) — the optional-server interface stands as phase 3 shipped it.
- The repo's LICENSE choice — owner-deferred; flagged, not decided here.

## Open Questions

1. **serverInfo identity:** mirror the canonical's `serverInfo.name: "chudmax-tickets"` verbatim, or mark the mock honestly (`"chudmax-tickets-mock"`)? Default assumed: the marked name (honesty over byte-identity; no known client selects by serverInfo name). Correct me if something keys on it.
2. **Example values' data mode:** the example runs the mock in pod mode (`--data-root /data`), so a pod without the ExternalArtifact crash-loops the fetcher (phase-3 documented behavior) and the mock serves an absent tree until the first swap. Alternative: point the example at the mock's bundled fixture (always works, less representative). Default assumed: pod mode, with the crashloop-until-artifact behavior documented in the example file.
3. **`--revision` CLI parity:** the canonical's pod mode (phase 1 shape) takes revision facts as CLI flags; this task defines artifact.json-per-call as the mock's pod mode. Plan: the mock accepts both — `--data-root` (per-call artifact.json, wins when set) and the canonical's `--revision/--artifact-produced/--artifact-unpacked` (cheap parity for scripts written against the canonical CLI). Keep, or drop the legacy flags?
