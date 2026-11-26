# Design: Chudmax k8s monitoring: Flux, Gateway, and Strata Prometheus stack

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

## Architecture

```
Flux (flux-system)                       k8s/monitoring/
  Kustomization monitoring-controllers ──► controllers/            [full-stack only]
    │  namespace monitoring + kube-prometheus-stack
    │  OCIRepository (oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack, semver 69.x)
    │  HelmRelease: Prometheus + kube-state-metrics (Alertmanager off, Grafana gated)
    ▼ dependsOn
  Kustomization monitoring-configs ──────► configs/                [both profiles]
      podmonitor-flux.yaml           (6 Flux controllers + source-watcher, port http-prom, ns flux-system)
      podmonitor-flagger.yaml        (app: flagger, port http, ns any)
      podmonitor-gateway.yaml        (app.kubernetes.io/name: traefik, port metrics, ns any)
      servicemonitor-chudmax-web.yaml   (Services labeled app.kubernetes.io/name: chudmax-web →
                                        original + Flagger -primary/-canary; /metrics?format=prometheus)
      servicemonitor-chudmax-engine.yaml (selectorless Service + manual EndpointSlice; optional Bearer auth)
      metrictemplates.yaml           (chudmax-http-success-rate, chudmax-strata-ttft-p95)
      prometheusrules.yaml           (Flux ready, canary failedChecks, GPU VRAM/temp)
      networkpolicy-allow-monitoring-scrape.yaml
      dashboards/chudmax-overview.json (grafana_dashboard: "1" ConfigMap)

Scrape targets:  Flux controllers :8080/http-prom ─┐
                 flagger :8080/http ───────────────┤
                 traefik :9100/metrics ────────────┼──► Prometheus (monitoring ns)
                 chudmax-web :8080 /metrics ───────┤      (Strata serves vllm:* + strata:* text format)
                 chudmax-engine :8080 /metrics ────┘
```

Two profiles, documented in `k8s/monitoring/README.md`:
- **Full stack** (`controllers/` + `configs/`): standalone clusters (kind rehearsals, phase 15's placement) — installs kube-prometheus-stack then the configs.
- **Configs-only** (`configs/` alone): platforms like Cozystack that already run a Prometheus/VictoriaMetrics operator — all Chudmax scrape targets, alerts, policies and templates, no duplicate operator CRDs. (VictoriaMetrics operator consumes `monitoring.coreos.com` PodMonitor/ServiceMonitor/PrometheusRule natively — `speculation`, confirmed at phase 15.)

## Key decisions

1. **Adapt, don't vendor, `flux2-monitoring-example`**: keep the two-Kustomization split with `dependsOn` (the operator must exist before its CRD objects are applied), the pinned OCIRepository + HelmRelease with `driftDetection`, and the kube-state-metrics customResourceState pattern; **omit** loki-stack/promtail/minio (no log pipeline, no object store in scope) and Alertmanager (off by default). Grafana is values-gated instead of upstream's always-on-with-`adminPassword: flux` — an inline password is a credential-shaped artifact this repo forbids; the enabled path documents `grafana.admin.existingSecret`.

2. **One PodMonitor per scrape shape, not per tool.** The seven flux-system controllers (6 stock + source-watcher) all expose metrics on a port NAMED `http-prom` (verified against source-watcher's deployment) → one PodMonitor with an `app In [...]` expression. Flagger (port name `http`) and Traefik (port name `metrics`, different label scheme) each get their own PodMonitor with `spec.namespaceSelector: {}` so their home namespace — phase 7's decision — never breaks the scrape. PodMonitor (not ServiceMonitor) for both: no Service requirement, matches the pods wherever they run.

3. **No `__address__` relabeling for the Strata scrapes.** Verified (`http_api.py::host_allowed`): an IP-literal Host always passes Strata's DNS-rebinding guard, and Prometheus scrapes endpoints by IP. So the ServiceMonitors work with stock relabeling; the Service-DNS-name relabel trick is documented as an option (it makes the `instance` label nicer and satisfies a future non-IP-host guard), not required. The engine's optional `authorization` block covers the API-key case (an API key skips the host guard entirely — verified in `parse_request`).

4. **`params: {format: [prometheus]}` on both Strata ServiceMonitors.** Strata's `wants_prometheus` also triggers on Prometheus's own `Accept: text/plain` header, so the param is belt-and-suspenders — it makes the contract explicit and works for any scraper.

5. **KSM customResourceState extension**: upstream's 12 Info GVKs (prefix `gotk`) + three chudmax additions. `ArtifactGenerator` (`source.extensions.fluxcd.io/v1beta1`) and `ExternalArtifact` (`source.toolkit.fluxcd.io/v1`) get the same Info pattern (ready from `status.conditions[type=Ready]`, suspended, revision for ExternalArtifact); `Canary` gets Info (name, exported_namespace, phase, suspended) **plus two Gauges** — `gotk_canary_failed_checks` (path `status.failedChecks`) and `gotk_canary_canary_weight` (path `status.canaryWeight`) — because the brief's alert (`failedChecks > 0`) needs a numeric metric, which an Info label cannot express. `rbac.extraRules` gains the `flagger.app` group + `canaries` resource.

6. **Alerts ride the KSM info-metric labels**: `gotk_resource_info{ready="False"} == 1 for: 5m` scoped by `customresource_kind` to GitRepository/ArtifactGenerator/ExternalArtifact (the brief's three; `for:` gives the 5-minute grace). GPU alerts use the verified `strata:` names — `strata:gpu_mem_used_bytes / strata:gpu_mem_total_bytes > 0.95` and `strata:gpu_temp_celsius > 83`, each `for: 5m`. NOTE: the brief's `strata:gpu_total_bytes` does not exist in the source; the verified name is `gpu_mem_total_bytes`.

7. **Flagger MetricTemplates calibrated to LLM physics**: `chudmax-strata-ttft-p95` measures the `vllm:time_to_first_token_seconds` P95 (buckets 0.001…2560 s in Strata's exposition) with `vllm:num_requests_waiting` exposed beside it for queue-aware thresholds — because real requests take 3-6+ s across 1-4 batch slots and a naive 500 ms P99 would falsely roll back healthy web upgrades. `chudmax-http-success-rate` measures the Traefik 5xx share over `traefik_service_requests_total` (≥ 99% non-5xx), templated with Flagger's `.TargetService` vars. Both ship with the provider address pointing at the kube-prometheus-stack in-cluster service (phase 15's shape) and a README table giving the lightweight-kind alternative — phase 7 patches the address per profile, the templates themselves stay byte-identical. Thresholds are NOT baked into the templates (phase 7's canary values set them).

8. **Namespaces are explicit where they differ**: PodMonitors/ServiceMonitors/PrometheusRules land in `monitoring` (the prom-operator selectors discover them by label from anywhere), while `metrictemplates.yaml` and the scrape-admission NetworkPolicy carry explicit `metadata.namespace` placeholders (flagger's home ns; `chudmax-releases` for the web policy per the repo-sync per-install-edit precedent). Whether the configs `kustomization.yaml`'s `namespace: monitoring` transformer respects explicit per-file namespaces is proven with a build receipt in the first task (fallback: explicit namespaces everywhere).

9. **NetworkPolicy composition, stated honestly**: NetworkPolicy allow rules across all selecting policies are unioned; kindnet enforces since kind v0.24 (owner-verified fact), so the moment ANY ingress policy selects the web pods, unmatched traffic is denied. This module ships the monitoring-scrape admission the brief pins; the Gateway→web admission belongs to phase 7's canary policies / phase 12's placement inventory. The README records the contract and the temporary-gap behavior so nobody debugs a "broken" Gateway traffic path into this policy.

10. **The reconciling GitRepository is an install prerequisite**, documented in the README (mirroring the repo-sync Secrets pattern): `kustomization-flux.yaml` pins `sourceRef: {kind: GitRepository, name: chudmax-mcp}` assuming a `flux bootstrap` against this public repo; phase 12's platform inventory may rename it (Open Question 3).

## Verified primary-source facts (for the implementer)

| Fact | Source | Label |
|---|---|---|
| Upstream file set + shapes (release/repository/podmonitor/configs/monitoring.yaml/validate.sh) | fluxcd/flux2-monitoring-example @ `7ab65dc` | `verified-here` |
| source-watcher pod label `app: source-watcher`, metrics port named `http-prom` :8080 | fluxcd/source-watcher `config/manager/deployment.yaml` | `verified-here` |
| Flagger pod label `app: flagger`, single port `http` :8080 (serves `/metrics` + `/healthz`) | fluxcd/flagger `artifacts/flagger/deployment.yaml` @ main (1.45.0) | `verified-here` |
| `GET /metrics?format=prometheus` → text/plain 0.0.4; metric names incl. `strata:gpu_mem_total_bytes`, NOT `gpu_total_bytes`; histogram buckets to 2560 s | kingdonb/Strata `terminal/serve/prometheus.py` | `verified-here` |
| `host_allowed`: IP-literal Host always passes; API key skips the guard | kingdonb/Strata `serve/server_parts/http_api.py` | `verified-here` |
| web Service named port `http` :8080, labels `app.kubernetes.io/name: chudmax-web`; engine selectorless Service port `http` | local clone, umbrella subcharts | `verified-here` |
| Release-ns placeholder `chudmax-releases`; per-install-edit precedent | k8s/repo-sync/README.md | `verified-here` |
| Flagger clones the original Service's labels into -primary/-canary; MetricTemplate ns fallback | flagger source | `speculation` |
| VM operator consumes monitoring.coreos.com CRDs natively (Cozystack profile) | VictoriaMetrics docs | `speculation` |
| Traefik chart default pod label + `metrics` port name; `addServicesLabels`/`addRoutersLabels` are static config | Traefik docs/chart | `handoff-reported` |
| Flux's shipped `allow-scraping` policy opens :8080 cross-namespace | flux2 install policies | `handoff-reported` |
| kindnet enforces NetworkPolicy since kind v0.24 | owner verification (4b) | `verified-here` (carried) |

## CI design (`monitoring-validate.yml`)

Jobs, all on push/PR, `permissions: contents: read`, pinned tool versions:

1. **build**: `kustomize` (pinned v5.x) `build` on `controllers` and `configs` with `--load-restrictor=LoadRestrictionsNone` (the upstream validate.sh flags).
2. **flux-schema**: `fluxcd/flux2/action@v2.10.1` + `plugins: schema` (the phase-4 repo-sync pattern), `flux schema validate` on `k8s/monitoring/kustomization-flux.yaml` + the two controllers Flux files.
3. **kubeconform**: `-strict` on both builds; schema locations = `default` + the datreeio/CRDs-catalog URL template `https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json` (covers `monitoring.coreos.com` and `flagger.app`); recorded fallback: download the two operators' CRDs and convert, if the catalog URL is unreachable or a schema is missing.
4. **promtool**: prometheus release tarball (pinned); `promtool check rules` on the rendered `prometheusrules.yaml`; then `yq` extracts each MetricTemplate `spec.query`, wraps it in a scratch rule (`expr: <query>`), and `promtool check rules` validates the PromQL.
5. **strata-smoke**: clone kingdonb/Strata at the phase-6 pin → `pip install -r terminal/requirements.txt` → `python -m serve.server --engine mock --host 127.0.0.1 --port 8095 &` (loopback passes the Host guard) → POST one `/v1/chat/completions` (non-stream, small max_tokens) → `curl -s 'http://127.0.0.1:8095/metrics?format=prometheus' | promtool check metrics` → grep the output for `vllm:request_success_total` and `vllm:time_to_first_token_seconds_bucket`.
6. **hygiene**: grep the write set for RFC1918 (`10\.\d+\.\d+\.\d+`, `172\.(1[6-9]|2\d|3[01])\.\d+\.\d+`, `192\.168\.\d+\.\d+`) and credential-value shapes (e.g. `adminPassword:` with a value, quoted `password`/`token` literals) while allowing `secretRef`/`secretName`/`credentials.name` name references.

Sandbox honesty (the phase-6 pattern): this sandbox has docker + kubectl but no kustomize/flux/promtool/kubeconform on PATH — the in-sandbox proof installs the binaries ad-hoc where feasible, and CI is the authoritative receipt for everything else.

## Interop contracts (for phase 7 / phase 15)

- **Phase 7 consumes**: `podmonitor-gateway.yaml` (must match its Traefik install's pod label + metrics port name), `podmonitor-flagger.yaml` (namespace-agnostic by design), `metrictemplates.yaml` (patches the provider address per profile; sets canary thresholds), and the `-primary`/`-canary` scrape coverage via the web ServiceMonitor's label selector. Phase 7 must add the `-primary`/`-canary` Service DNS names to `web.allowedHosts` (its chart edit — phase 6's `auto` list covers only the original Service) and own the Gateway→web ingress admission if kindnet is enforcing.
- **Phase 15 consumes**: the controllers/ profile as-is (the release pins `semver: 69.x`), the MetricTemplates with the kube-prometheus-stack address, the alerts against the KSM `gotk_*` metrics.
- **Read-only consumption everywhere**: this module observes labels/ports; if a phase's install changes a label or port name, THIS module's manifest turns — the README's interop table is the place to record it.

## Learnings for future agents

- This repo's monitoring contract is upstream `flux2-monitoring-example`'s shape with three chudmax extensions (source-watcher/flagger pod coverage, KSM GVK additions, LLM-calibrated templates) — keep the upstream file names and split so future diffs against upstream stay readable.
- Strata's `/metrics` needs `?format=prometheus` (or `Accept: text/plain`) — the JSON monitor format is the default; scrapers that omit both get JSON and promtool fails. The ServiceMonitors pin the param.
- The Host guard is a non-issue for scrapers (IP hosts pass) — do not add speculative relabeling; if a future guard hardens, the documented Service-DNS relabel is the fallback.
- The `gotk_` KSM metrics are INFO-valued (always 1): alert on label state (`ready="False"`), never on value; numeric states (failedChecks, canaryWeight) must be Gauge metrics, which is why the Canary block has both.
- Strata's GPU metric family labels each sample with `gpu="<index>"` — `sum by` or aggregate before alerting on multi-card hosts.

## Implementation notes (2026-11-26, local receipts)

All six validation receipts ran green in the sandbox (CI re-proves them): kustomize v5.4.3 builds (4 + 12 docs, every namespace as designed), flux-schema v0.18.0 (4 Flux resources valid), kubeconform v0.6.7 `-strict` (16/16 valid, 0 skipped — every CRD schema resolved from the datreeio CRDs-catalog, no fallback needed), promtool v2.53.4 (4 alerts + the 3 MetricTemplate queries SUCCESS — the `{{ .TargetService.Name }}` templates sit inside quoted matchers and parse as plain PromQL), the Strata scrape smoke (tag `v0.2.21-mbp.rtx.1` = `de34eba`: mock server up on loopback, completion answered, `/metrics?format=prometheus` returned 86 `vllm:` + 18 `strata:` samples and `promtool check metrics` parsed it with only the expected vLLM `:`-name lint — `promtool`'s lint flags colon names, which is vLLM's own convention, so the CI job fails only on anything beyond that lint), and the hygiene grep (clean).

Two kustomize behaviors proven by experiment and encoded in the manifests:
1. The kustomization-level `namespace:` transformer OVERRIDES explicit per-file namespaces — configs/ therefore uses no kustomization-level namespace and every object pins its own `metadata.namespace`.
2. Patches never match generated resources (neither by bare name nor by labelSelector) — the dashboard ConfigMap is therefore a static manifest with the JSON inlined, not a configMapGenerator product.

Deviations from the approved design, all recorded:
- A third MetricTemplate, `chudmax-strata-queue-depth` (`max(vllm:num_requests_waiting)`) — the design's queue-awareness exposed as its own checkable gate for phase 7's canaries.
- The web scrape-admission NetworkPolicy also admits Traefik pods (the Gateway data plane), Flagger pods and same-namespace callers — the Open Question 4 composition resolved conservatively so applying the monitoring overlay can never sever Gateway traffic; the README's composition section documents the union rule.
- The dashboard ships as `configs/dashboards-configmap.yaml` (static, namespace-pinned) instead of a `dashboards/*.json` file behind the generator.
- Open Questions 1–3 (Traefik namespace/labels, MetricTemplate namespace placeholder, the reconciling GitRepository's name) remain per-install edits documented in the README — they turn at phase 7 / phase 12.
