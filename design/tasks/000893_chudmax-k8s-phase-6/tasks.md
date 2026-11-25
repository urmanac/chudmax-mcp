# Implementation Tasks: chudmax k8s phase 6 engine and web charts with umbrella

**Engine chart (`urmanac/chudmax-engine` — repo's first content)**
- [ ] Branch off `main`; add `k8s/chart/chudmax-engine/`: Chart.yaml (v2, 0.1.0), values (`engine.endpoint.host` empty default, `engine.endpoint.port` 8080), templates — selectorless Service (port 8080, name `http`), EndpointSlice (`discovery.k8s.io/v1`, `addressType: IPv4`, `kubernetes.io/service-name` label) rendered only when `endpoint.host` is set, Helm test hook (curl `/health` through the Service, `curlimages/curl` pinned), `_helpers.tpl`, NOTES.txt (install-supplied address, `helm test` usage), chart README; repo top-level README (what the repo is, naming-table pointer, publish-at-phase-10 note, no-LAN-address rule)
- [ ] CI: `chart.yml` — `helm lint`, `helm template` both variants (endpoint unset; TEST-NET placeholder set), kubeconform on rendered templates (both variants)
- [ ] Local proof: lint + both template variants + kubeconform green — `verified-here`

**Web chart + mock engine (`urmanac/chudmax-web` — repo's first content)**
- [ ] Branch off `main`; add `k8s/mock-engine/`: single-file Python-stdlib server (`/health` → 200; documented permissive catch-all; port 8080), COPY-only Dockerfile (non-root, alpine base off 3.21), dir README
- [ ] Add `k8s/chart/chudmax-web/`: Chart.yaml (v2, 0.1.0), values — `web.image` default `ghcr.io/urmanac/chudmax/web:0.1.0` + unpublished-tag note, `web.port`/`web.engineUrl`/probe knobs (guesses labeled), pod-level `automountServiceAccountToken: false` + securityContext (runAsNonRoot, drop ALL, seccomp RuntimeDefault), `mockEngine.enabled` default true, `mockEngine.hostNetwork` default false; templates — web Deployment + Service, mock-engine Deployment + Service (mock pair rendered only when enabled), Helm test hook on the web Service, `_helpers.tpl`, NOTES.txt, chart README (out-of-the-box story, real-engine override, no-NetworkPolicies-this-phase note); repo top-level README
- [ ] CI: `chart.yml` (lint + template both variants — mock on / mock off + custom `web.engineUrl` — + kubeconform on rendered) and `mock-engine-image.yml` (podman manifest build both arches, no push, arch-count check, amd64 `/health` smoke; docker buildx fallback noted)
- [ ] Local proof: podman + helm installed per the phase-3 recipe; mock-engine manifest list builds both arches under podman; amd64 run answers `/health` 200 — `verified-here`

**Umbrella (recommended home: `k8s/umbrella/chudmax/` in `urmanac/chudmax-mcp` — Open Question 1)**
- [ ] Add the umbrella chart: Chart.yaml (v2, 0.1.0; three `file://` deps `chudmax-engine`, `chudmax-web`, `chudmax-mcp`, condition-gated, all enabled), values (rehearsal defaults: mock on, web → engine Service, mcp chart defaults), `scripts/fetch-charts.sh` (clone the three repos at pinned SHAs → `charts/`, gitignored), README with the pins table + phase-10 OCI note
- [ ] Add `scripts/kind-smoke.sh`: kind up (docker provider) → fetch deps → `helm dependency build` → build/load images (mock-engine + fetcher + tickets-mcp, amd64, `podman save` → `kind load image-archive`) → one-step `helm install` (engine endpoint = node IP:8080 resolved via kubectl) → `helm test` → `/health`-through-engine-Service probe → report (mcp fetcher's waiting state recorded as expected)
- [ ] CI: `umbrella-kind.yml` — chart job (lint + template with vendored deps + kubeconform) and kind job on `ubuntu-latest` (docker provider, `speculation` until green); existing chudmax-mcp workflows stay green
- [ ] Local proof: full umbrella rehearsal end to end in-sandbox — kind up, install, hook passes — `verified-here`

**Flow and hygiene**
- [ ] Three PRs (one per repo) via `propose_pull_request`; conventional commits; three labels on every claim; the missing-LICENSE flag in the engine and web PR descriptions; no registry push; no LAN address, credential or internal hostname in any public artifact; the box untouched throughout
- [ ] Update this task's docs with implementation corrections (mechanism actually proven for the engine endpoint: hostNetwork vs NodePort vs pod IP) before merge
- [ ] `mark_task_complete` only after all three PRs merge
