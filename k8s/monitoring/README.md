# k8s/monitoring — the chudmax observability contract

One GitOps-reconciled Prometheus contract for the whole stack: **Flux repo-sync, the Traefik
Gateway API layer, Flagger progressive canaries, and Strata's native Prometheus/vLLM
`/metrics`**. Adapted from `github.com/fluxcd/flux2-monitoring-example` (two-Kustomization
split, pinned `kube-prometheus-stack` OCI + HelmRelease, kube-state-metrics
customResourceState) without its bloat — no `loki-stack`, no `promtail`, no `minio`,
Alertmanager off, Grafana values-gated.

```
Flux Kustomization monitoring-controllers ──► controllers/   (the Prometheus stack)
      │ dependsOn
      ▼
Flux Kustomization monitoring-configs ──────► configs/       (everything chudmax)
```

## The two profiles

| Profile | Apply | What you get | For |
|---|---|---|---|
| **Full stack** | `controllers/` then `configs/` (or let `kustomization-flux.yaml` reconcile both) | kube-prometheus-stack (Prometheus + kube-state-metrics; Alertmanager off, Grafana disabled) + all chudmax configs | standalone clusters, kind rehearsals, phase-15 placement |
| **Configs-only** | `configs/` alone | all chudmax scrape targets, alerts, NetworkPolicies, MetricTemplates, dashboard — **no operator CRDs duplicated** | platforms that already run Prometheus Operator / VictoriaMetrics Operator (e.g. Cozystack) |

```sh
# full stack
kubectl apply -k k8s/monitoring/controllers
kubectl apply -k k8s/monitoring/configs
# configs-only
kubectl apply -k k8s/monitoring/configs
```

`kustomization-flux.yaml` is the **full-stack** Flux entry point
(`monitoring-controllers` → `dependsOn` → `monitoring-configs`). Configs-only platforms apply
`configs/` with their own tooling — the pair's `dependsOn` presumes the controllers build.

## Prerequisite: the reconciling GitRepository

`kustomization-flux.yaml` pins `sourceRef: {kind: GitRepository, name: chudmax-mcp}` — the
name `flux bootstrap` gives a fleet repo bootstrapped against `urmanac/chudmax-mcp` (a public
repo, so no auth Secret). If the fleet reconciles under another name, edit the two
`sourceRef.name` values — a per-install edit like the ones below. Phase 12's platform
inventory owns the real wiring.

## Per-install edits (placeholders, like the repo-sync manifests')

| File | Placeholder | Turn it when |
|---|---|---|
| `configs/metrictemplates.yaml` | `namespace: flux-system` (assumed flagger home; templates are reachable from canaries anywhere via flagger's namespace fallback) | flagger runs elsewhere |
| `configs/networkpolicy-allow-monitoring-scrape.yaml` (web doc) | `namespace: chudmax-releases` (the release-namespace placeholder) | the umbrella installs into another namespace |
| `configs/networkpolicy-allow-monitoring-scrape.yaml` (traefik doc) | `namespace: flux-system` (assumed Traefik home) | Traefik runs elsewhere |
| `configs/servicemonitor-chudmax-engine.yaml` | the commented-out `authorization` block | the host engine sets an API key (Secret created out-of-band, referenced by name only) |

## Phase-7 interop contract (what this module assumes of the canary install)

| Assumption | Where | If phase 7 differs |
|---|---|---|
| Traefik pods labeled `app.kubernetes.io/name: traefik`, metrics on port name `metrics` (:9100) | `podmonitor-gateway.yaml` + the NetworkPolicies | edit the label/port in both manifests |
| Traefik static config `providers.kubernetesGateway.enabled: true` with `metrics.addServicesLabels=true` / `addRoutersLabels=true` (so `traefik_service_requests_total` carries the `service` label) | phase 7's Traefik values | the `chudmax-http-success-rate` template and the dashboard turn |
| flagger pods labeled `app: flagger`, metrics on port name `http` (:8080) — the stock deployment's shape | `podmonitor-flagger.yaml` (namespace-agnostic by design) | edit the label/port |
| `-primary`/`-canary` Services keep the original Service's labels (flagger clones them) | `servicemonitor-chudmax-web.yaml`'s selector | add the suffixes to the selector |
| `web.allowedHosts` includes the `-primary`/`-canary` Service DNS names | phase 7's chart values (phase 6's `auto` list covers only the original Service) | chart edit on phase 7's side |
| Gateway→chudmax-web ingress admission | INCLUDED in `networkpolicy-allow-monitoring-scrape.yaml` (web doc) on purpose — see the composition note below | no separate phase-7 policy needed for the default shape |
| MetricTemplate provider address | `http://kube-prometheus-stack-prometheus.monitoring:9090` (full stack) | lightweight-kind alternative: `http://prometheus.monitoring:9090` — patch `spec.provider.address` per install; the templates stay byte-identical |

## The NetworkPolicy composition rule (read before applying)

kindnet has enforced NetworkPolicy since kind v0.24. The moment ANY NetworkPolicy selects a
pod, that pod's ingress becomes default-deny for everything the union of all selecting
policies does not admit. These policies are written **additive-only relative to the
no-policy baseline**:

- `allow-monitoring-scrape-web` (release namespace, selecting `chudmax-web` pods) admits:
  the `monitoring` namespace (scrapes), **Traefik pods (the Gateway→web route — included so
  applying the monitoring overlay never unintentionally blocks Gateway traffic)**, Flagger
  pods (analysis traffic), and same-namespace pods (helm test hooks, in-ns callers).
- `allow-monitoring-scrape-traefik` (Traefik namespace) admits the `monitoring` namespace on
  :9100 and keeps TCP 80/443 open to all sources — the data-plane ports were open before any
  policy selected these pods; tightening them is phase 12's placement inventory, not this
  overlay's move.

If another phase's install adds its own selecting policies, the allow rules union — but any
NEW selecting policy narrows what THIS pair alone allowed; whoever adds the next policy owns
re-checking the union.

## kube-state-metrics coverage (`gotk_*`)

Upstream's Info GVKs (Kustomization, HelmRelease, GitRepository, Bucket, HelmRepository,
HelmChart, OCIRepository, Alert, Provider, Receiver, ImageRepository, ImagePolicy,
ImageUpdateAutomation) **plus** chudmax's three additions:

| GVK | Exposed |
|---|---|
| `source.extensions.fluxcd.io/v1beta1 ArtifactGenerator` | `gotk_resource_info` (ready, suspended) |
| `source.toolkit.fluxcd.io/v1 ExternalArtifact` | `gotk_resource_info` (ready, suspended, revision) |
| `flagger.app/v1beta1 Canary` | `gotk_resource_info` (phase, suspended, weight) + Gauges `gotk_canary_failed_checks`, `gotk_canary_canary_weight` |

The `gotk_*` metrics are INFO-valued (always 1): alert on label state
(`gotk_resource_info{ready="False"}`), never on value — numeric states are Gauges.

## The Strata scrape contract (verified against kingdonb/Strata)

- `GET /metrics?format=prometheus` (or `Accept: text/plain`) returns
  `text/plain; version=0.0.4` in vLLM's names: `vllm:num_requests_running`,
  `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc`, `vllm:prompt_tokens_total`,
  `vllm:generation_tokens_total`, `vllm:request_success_total`, histograms
  `vllm:time_to_first_token_seconds` (buckets 0.001…2560 s), `vllm:inter_token_latency_seconds`,
  `vllm:e2e_request_latency_seconds` — plus `strata:live_state`, `strata:live_tok_s`,
  `strata:live_slots`, `strata:gpu_util`, `strata:gpu_mem_used_bytes`,
  `strata:gpu_mem_total_bytes`, `strata:gpu_temp_celsius`, `strata:gpu_power_watts` (each GPU
  sample labeled `gpu="<index>"`).
- Strata's Host guard admits IP-literal Hosts (verified in `http_api.py::host_allowed`) —
  Prometheus scrapes endpoints by IP, so no relabeling; a Service-DNS relabel is the
  documented fallback if a future guard hardens.
- Without an API key the scrape is unauthenticated; with one, add the ServiceMonitor
  `authorization` block (the engine file shows the shape).

## Validation

```sh
kustomize build k8s/monitoring/controllers
kustomize build k8s/monitoring/configs
flux schema validate k8s/monitoring/kustomization-flux.yaml --schema-location default
kubeconform -strict -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  <(kustomize build k8s/monitoring/configs)
promtool check rules <(kustomize build k8s/monitoring/configs | yq -e 'select(.kind == "PrometheusRule")')
```

CI (`.github/workflows/monitoring-validate.yml`) runs all of these plus the live Strata
mock-engine scrape smoke and the public-hygiene grep on every push and PR.
