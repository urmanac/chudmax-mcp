# k8s/canary — the phase-7 Flagger canary rehearsal's fixtures

The canary rehearsal (T-0037 phase 7, source `design/tasks/000888_fetch-mr-17/design.md`
SPIKE row G): in CI, ONE web upgrade is promoted by Flagger after its tests, one
broken upgrade is rolled back, and both are recorded. The spec lives in the
helix-specs task dir (`design/tasks/000899_chudmax-k8s-phase-7/`).

## The shape

- kind cluster (the phase-5 `kind-config.yaml`, Cilium per the phase-5 recipe)
- the artifact chain (phase 5's, consumed by path: the gittestserver helper +
  the `k8s/repo-sync/` test manifests + one seed push) so the mcp pod goes
  Ready and `chudmax-mcp:8080` serves REAL data (the ready-gated Service path
  phase 6 pointed at this phase)
- the umbrella installed with `values-rehearsal.yaml`: engine OFF (both
  versions run the in-process mock), the chart Service OFF (Flagger generates
  its own), the hub wiring ON (`web.mcpConfig` → `http://chudmax-mcp:8080/mcp`),
  the scrape annotations ON (`prometheus.io/path: "/metrics"`, negotiated via
  Prometheus's `Accept: application/openmetrics-text` / `text/plain` header);
  note that `artifact-ingress.yaml` also rewrites `app.kubernetes.io/name` to
  `mcp` because the umbrella aliases the `chudmax-mcp` subchart as `mcp`
- **Traefik** as the Gateway API controller (ADR 001, production parity:
  `providers.kubernetesGateway.enabled=true`, metrics on :9100); the Gateway
  `chudmax-gateway` (`gatewayClassName: traefik`) is dialed IN-CLUSTER only —
  no MetalLB, its LoadBalancer stays pending, that is fine
- **Flagger** (`meshProvider=gatewayapi:v1`) + its ONE-pod Prometheus
  (`prometheus.install=true`) + the loadtester, all chart-pinned
- the **good upgrade**: `kubectl set image` to the same bytes retagged
  `0.1.1` → the pre-rollout suite passes → the real metrics pass → the weight
  steps 10→50 → promotion
- the **broken upgrade**: ONE combined JSON patch (image → `0.1.1-broken`, the
  broken-config volume+mount, the `--mcp-config` arg → the broken path) → the
  hub silently omits the unreachable server (verified behavior) → the
  pre-rollout webhook fails → halt → rollback; the METRICS stay healthy (the
  engine works) — the webhook is the broken upgrade's only tripwire

## The files

| file | what it is |
| ---- | ---------- |
| `gateway.yaml` | the Gateway the canary's HTTPRoute attaches to (GatewayClass asserted by the script, applied here only if the chart did not create it) |
| `metric-templates.yaml` | the CUSTOM MetricTemplates on Strata's native metrics (`${METRICS_SERVER}` is envsubst'd from the `canary.metricsServer` knob) |
| `mcp-config-broken.yaml` | the well-formed-but-dead hub config the broken upgrade points at |
| `canary.yaml` | the Canary CRD (analysis + the pre-rollout suite + the load-test webhook); `${TRAEFIK_URL}` envsubst'd |
| `values-rehearsal.yaml` | the umbrella override profile the rehearsal installs with |
| `canary-rehearse.sh` | the whole rehearsal (kind → chain → Flagger → both upgrades → receipts → teardown) |

## The metrics (why custom templates, and the calibration note)

The builtin gatewayapi templates (Flagger's HttpObserver) query
`http_request_duration_seconds_*` — a metric Strata does NOT expose (verified
against the pinned source + the live pre-flight). The analysis therefore uses
Strata's OWN native metrics (`terminal/serve/prometheus.py`,
`GET /metrics?format=prometheus`):

- `request-finish-rate` — `sum(rate(vllm:request_success_total{...}[i]))` — the
  finished-requests rate on the target's pods; a small positive `min` threshold.
  Only CHAT completions finish engine requests, which is why the load-test
  webhook drives chat completions.
- `request-duration-p99` — the p99 of `vllm:e2e_request_latency_seconds` —
  **sub-second thresholds are calibrated for `--engine mock`** (the mock
  finishes in ~1ms; the pre-flight measured 0.56ms). Multi-second decode slots
  arrive with the REAL engine in phase 15 — retune the threshold there, do not
  copy this value forward.

The pod regex (`kubernetes_pod_name=~"{{ target }}-[0-9a-zA-Z]+(-[0-9a-zA-Z]+)"`)
follows Flagger's own HttpObserver style and matches BOTH the target's (canary)
pods and the `-primary` pods — the mixed measurement is Flagger's documented
pod-metric pattern. The CLEAN canary-only alternative (Traefik's
`traefik_service_request_duration_seconds_bucket{service=~"<ns>-<target>-canary-…@kubernetescrd"}`
— the query shape verified from Flagger's `observers/traefik.go`) is recorded
but not primary.

## What this deliberately keeps OUT

- the monitoring card's stack (`k8s/monitoring/**`, kube-prometheus-stack +
  Grafana + its CI) — untouchable; phase 15 flips `canary.metricsServer` at
  that stack and turns on flagger's ServiceMonitor; the MetricTemplate
  fixtures need no edits (their provider address is envsubst'd)
- the real engine, the web→engine attach route (phase 15), publishing (10)
- no LAN addresses, no credentials, no real domains (the route host
  `chudmax.rehearsal` is a rehearsal doc name)

## The pins (verified against upstream sources, 2026-11-26)

kind v0.33.0 · Cilium v1.18.1 (the phase-5 recipe verbatim) · flux v2.10.1
(`--components-extra=source-watcher`) · **flagger chart 1.45.0** · **loadtester
chart 0.39.0** · **Traefik chart 43.0.0** (value keys verified against the
pinned chart source: `providers.kubernetesGateway.enabled`; `gatewayClass.enabled:
true` default auto-creates the `traefik` GatewayClass — asserted, applied here
only if missing; `gateway.enabled: true` default deploys an unwanted default
Gateway — disabled; `metrics.prometheus` is ON by default at the `metrics`
entryPoint; the unprivileged `web` entrypoint listens on `:8000`, matched by
`gateway.yaml`'s listener `port: 8000`, while the `traefik` Service exposes
`:80` → `targetPort: web`) · Gateway API CRDs v1.7.0 (`v1.TLSRoute` +
`v1.TCPRoute` served, as required by Traefik v3.8.0) · the web image = the
phase-6 build at the umbrella README's pinned SHA (`de34ebaa…`, tag
`v0.2.21-mbp.rtx.1`).

Three mechanics verified against Flagger's/Strata's sources and folded into
the fixtures:

- the loadtester dispatches on `metadata.type` — the load-test webhook carries
  NO type, so its cmd is a **background** shell task answered with `202
  Accepted`: `hey -z 50s` streams inside each 1m analysis window while Flagger
  steps the weights (finishing cleanly before the next tick), and `timeout: 5s`
  is only how long Flagger waits for the HTTP answer
  (`pkg/loadtester/server.go`).
- the web pods' Host guard strips the port and matches the `allowedHosts`
  list **exactly** (`serve/server_parts/http_api.py` `host_allowed`/`_name_in`)
  — so `values-rehearsal.yaml` carries the mid-form names
  (`chudmax-web-canary.chudmax`, `chudmax-web-primary.chudmax`) the webhook
  suite's curls actually send, not just the short names.
- the tiny Prometheus (`prometheus.install: true`; Service
  `flagger-prometheus` in ns `flagger`, the chart's fullname helper) is what
  `canary.metricsServer`'s default points at.
