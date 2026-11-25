# chudmax-web — the web chart (Strata with the in-process mock engine)

The ChudMax web is **Strata** (the public fork, `github.com/kingdonb/Strata`)
running `python -m serve.server --engine mock`: one workload whose in-process
scripted MockEngine answers chat while `/health`, `/mcp` and
`/v1/chat/completions` are real endpoints — the card's "web chart with the
mock engine", literally. The image is built from the **public** Strata at a
pinned SHA (the umbrella's README records it); phase 7's Flagger canary reuses
the same image, nothing thrown away.

## Values

| Value | Default | Meaning |
|---|---|---|
| `image` | `ghcr.io/urmanac/chudmax/web:0.1.0` | Unpublished until phase 10 — build/load it yourself until then (the umbrella's `kind-smoke.sh` does, tagged with this reference; `pullPolicy: IfNotPresent` uses the loaded image). |
| `engineMode` | `mock` | `--engine mock` (the in-process scripted engine). The real-engine attach is the phase-15 route decision — a knob, not wiring. |
| `port` | `8080` | The serving port (documented guess; revisit at phase 10). |
| `allowedHosts` | `auto` | Strata's DNS-rebinding guard: `"auto"` renders this release's Service DNS names + `localhost,127.0.0.1`; a list is used verbatim; `"*"` disables the check (available, discouraged). |
| `probe.path` | `/health` | The readiness/liveness probe path (documented guess). |
| `extraEnv` / `extraArgs` | `[]` | Passthroughs — e.g. `--mcp-config` for a user-mounted config. |
| `automountServiceAccountToken` | `false` | Pod-level (the web needs no API access). |

## The guard (STRATA_ALLOWED_HOSTS)

Without an API key, Strata's `parse_request` passes **every** request through
the Host check first — an unknown Host gets a **403** telling the caller to add
the name. The `auto` default renders exactly what in-cluster callers and
port-forwards send (the Service DNS names + loopback), so `helm test` (whose
curl sends the Service DNS name as Host) doubles as the guard's proof.

## Deviations, on purpose

- **No bundled mock engine workload** — the mock engine IS this workload
  (Strata's `--engine mock`); there is no separate fake server to deploy.
- **No NetworkPolicies** — CNI-dependent egress rules were the phase-4b F5
  trap; the web's constraints wait for the phase-15 route and the phase-12 CNI
  inventory. Policies arrive with placement (phases 12/15).
- **No engine-URL wiring** — the web runs its own in-process engine; pointing
  it at the engine Service is the phase-15 route decision.

## Phase 7 example (not wired here): the tickets-mcp McpHub config

    # a ConfigMap mounting mcp-config.json:
    # {"mcpServers": {"chudmax-tickets": {"url": "http://<mcp-service>.<ns>.svc:8080/mcp"}}}
    extraArgs: ["--mcp-config", "/etc/mcp/mcp-config.json"]

Then `GET /mcp` reports the tickets server's tools — the canary's tool-count
check.
