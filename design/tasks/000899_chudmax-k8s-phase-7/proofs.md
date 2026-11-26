# Proofs — chudmax k8s phase 7 Flagger canary rehearsal in CI

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Labels: `verified-here` = run/proven in this sandbox; `handoff-reported` = owner/coordination provided; `speculation` = not yet proven (the CI receipt pending).

## The sandbox pre-flight (2026-11-26) — `verified-here`

Environment: the canonical server run on the host (stdlib-only — `python3 k8s/tickets-mcp/tools/mcp/ticket_mcp.py --data-root <fixture> --http 18080 --host 0.0.0.0`), Strata run as the phase-6 image (`docker build` of `k8s/umbrella/chudmax/web-image/Dockerfile` from the Strata clone at the pin `de34ebaa521d8f628b4bb1884e5c34101730299a`, tag `v0.2.21-mbp.rtx.1`, image 367MB disk / 86.8MB content, amd64), the two wired by `--mcp-config` over the host network (`--network host` — rootless docker's `host.docker.internal` was refused, the host network is the reliable route here).

The fixture (the fetcher's volume contract, faithfully): `<root>/revisions/<digest>/` containing the phase-5 fixture tree (`tickets.md`, `STATE.md`, `docs/`, `decisions/`) + `artifact.json` (the sidecar's fields: url/revision/digest/produced/unpacked/origin_revision/source), `<root>/current` → the revision dir.

### The hub ↔ canonical-server integration (the spike's settled question, now LIVE)

- `GET /mcp` (hub status) → `tickets` **ready, 7 tools** + the builtin `strata` stdio server **ready, 9 tools**; `tools: 16`.
- `GET /v1/mcp/tools` → a JSON ARRAY of 16 OpenAI function objects. Exact names (pinned for the webhook suite):
  `tickets__list_tickets, tickets__get_ticket, tickets__search_tickets, tickets__repo_facts, tickets__list_docs, tickets__read_doc, tickets__search_docs, strata__strata_status, strata__strata_models, strata__strata_remove, strata__strata_install, strata__strata_start, strata__strata_stop, strata__strata_logs, strata__strata_benchmark, strata__strata_connect_info`.
- `POST /v1/mcp/call {"name":"tickets__list_tickets","arguments":{}}` →
  `{"server": "tickets", "tool": "list_tickets", "ok": true, "text": "T-9001  in-progress   next    Example: the seed ticket of the phase-5 rehearsal", "chars": 79, "truncated": false, "ms": 1}`.
- `POST /v1/mcp/call {"name":"tickets__repo_facts","arguments":{}}` → `ok: true`, the text carries `revision: main@sha1:…`, `artifact unpacked: …`, `origin revision: …`, and `no git was asked`.
- `POST /v1/mcp/call {"name":"tickets__get_ticket","arguments":{"id":"T-9001"}}` → `ok: true`, 370 chars, first line `## T-9001 - Example: the seed ticket of the phase-5 rehearsal`.
- `POST /v1/chat/completions {"messages":[{"role":"user","content":"hi"}]}` →
  `{"id": "chatcmpl-…", "object": "chat.completion", "created": …, "model": "qwen3.8-flash-next", "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hello from the mock engine."}, …}]}` — the scripted reply, EXACT.

### The silent-omission behavior (the broken upgrade's engine)

A second instance with the dead-URL config (`http://chudmax-mcp-dead.invalid:8080/mcp`):
`tickets failed 0 tools` + `strata ready 9 tools` (total 9), and `/health` still **200** — the canary stays Ready-but-failing; the webhook's tool asserts (not a probe, not a progress deadline) are the tripwire. Exactly the design's story.

### The metrics pipeline (the metric dimension's de-risking receipt)

- `GET /metrics?format=prometheus` → the OpenMetrics text: `vllm:request_success_total{model_name="qwen3.8-flash-next"} 0` before, **`1` after one chat turn**; `vllm:e2e_request_latency_seconds_sum{model_name="qwen3.8-flash-next"} 0.000561` (+ the `_bucket{le=…}` series) — the histogram observed on the finished request.
- `GET /metrics` with `Accept: text/plain;version=0.0.4` (no query) → the same OpenMetrics (the `wants_prometheus` rule confirmed live: the annotation path may carry the query string; the Accept header alone also triggers the format).
- Consequence recorded: the loadtest must drive **chat completions** — GET probes never touch the counter.

### Corrections folded into the design (learnings)

- The builtin `strata` MCP server **IS in the image** (9 `strata__*` tools, stdio, ready) — the planning handoff's "likely absent" guess was wrong: the stdio server registers from within `terminal/serve/`, and the image COPYs all of `terminal/`. The webhook suite's count-equality assert holds (both versions carry the same 9 builtin tools); the tickets presence asserts are by NAME.
- Rootless docker networking: `host.docker.internal` (host-gateway) was REFUSED from the container; `--network host` is the sandbox's reliable route. No cluster impact (the rehearsal's callers dial Services, not container-to-host paths).

## The CI receipts (pending — the kind job is the authoritative receipt)

- [ ] The chart proofs (lint/template ×2/kubeconform) — sandbox + CI
- [ ] The kind rehearsal: the good upgrade's promotion, the broken upgrade's rollback, the weight timeline, both suites, the metric instant-query receipts
