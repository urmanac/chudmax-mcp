# Implementation Tasks: chudmax k8s phase 6 engine and web charts with umbrella

**Setup and parallel-safety (hard boundaries from the steering)**
- [ ] Check `helix-specs design/tasks/000914_*` (phase 5's spec) at implementation start; adopt-by-copy any kind scaffolding approach into phase-6's own files — never depend on, edit, or push to phase 5's branch
- [ ] Branch off current `main` (feature branch for the single PR); touch ONLY `k8s/engine-chart/`, `k8s/web-chart/`, `k8s/umbrella/`, `.github/workflows/umbrella.yml` (plus this task dir on helix-specs) — no `rehearsal*` files, no phase-5 fixtures, no top-level README

**Engine chart (`k8s/engine-chart/`)**
- [ ] Chart.yaml (v2, name `chudmax-engine`, version 0.1.0); values.yaml — `endpoint.host` default `192.0.2.1` (TEST-NET-1) with the "set this to your engine's address" comment, `endpoint.port` default 8080, `test.enabled` default true
- [ ] Templates: selectorless Service (port 8080, name `http`); EndpointSlice (`discovery.k8s.io/v1`, `addressType: IPv4`, `kubernetes.io/service-name` label, endpoint = host:port); Helm test hook pod (`curlimages/curl` pinned, curls `/health` through the Service, fail-fast labels); `_helpers.tpl`; NOTES.txt (repeats the set-your-address note + `helm test` usage); README.md (stable-in-cluster-name/alias note, installer-facing values table, legacy-Endpoints alternative, **no workload renders — by design**)
- [ ] Local proof: `helm lint` + `helm template` ×2 (TEST-NET-1 defaults; TEST-NET-2 `198.51.100.10` engine-address variant) + kubeconform on rendered templates — `verified-here`

**Web chart (`k8s/web-chart/`) — image-source choice (a), recorded**
- [ ] Chart.yaml (v2, name `chudmax-web`, version 0.1.0); values.yaml — `web.image` default `ghcr.io/urmanac/chudmax/web` : `0.1.0` + "unpublished until phase 10 — supply your own" comment (the option-(a) record; the investigation receipt lives in the spec docs), `web.port` 8080, `web.engineUrl`, probe knobs — each labeled a documented guess ("revisit at phase 10")
- [ ] Templates: Deployment (pod-level `automountServiceAccountToken: false` + securityContext runAsNonRoot / drop ALL / seccomp RuntimeDefault — the 4b pattern), Service, `_helpers.tpl`, NOTES.txt, README.md (installer values table; the two documented deviations: no bundled mock engine — the fake engine is rehearsal scaffolding; no NetworkPolicies — the F5/Cilium trap)
- [ ] Local proof: `helm lint` + `helm template` ×2 (defaults; custom image/port/engineUrl) + kubeconform on rendered — `verified-here`

**Umbrella + stand-in (`k8s/umbrella/`)**
- [ ] Chart.yaml (v2, name `chudmax`, version 0.1.0) — three `file://` deps on the sibling charts in this checkout (`../engine-chart`, `../web-chart`, `../chart/chudmax-mcp`), condition-gated, all enabled by default; values.yaml — the mcp chart's 4b defaults (`server.enabled=true`, tickets-mcp image) + the documented rehearsal profile (`web.enabled=false` pending phase 10; engine endpoint set at install time); README.md (local file:// deps, the phase-10 OCI switch, the rehearsal profile); `charts/` gitignored
- [ ] `standin/mock_engine.py` — python-stdlib single file: GET `/health` → 200, documented permissive catch-all; `standin/Dockerfile` — `FROM python:3.12-alpine`, COPY-only (no RUN), `USER 65532:65532`, local image `chudmax-engine-standin:0.1.0` (never published); `standin/README.md`
- [ ] `kind-smoke.sh`: kind up (docker provider) → podman build stand-in + fetcher + tickets-mcp (amd64) → `podman save` → `kind load image-archive` (no registry) → `helm dependency build` → `helm install` with rehearsal values (engine endpoint = the kind node's IP:8080 via kubectl; `web.enabled=false`) → `helm test` (the `/health` hook) → mcp receipts (release deployed; pod Running; server HTTP 200 initialize over its Service; fetcher waiting = expected) → print the honest framing line (Service→EndpointSlice→stand-in, not the real engine)
- [ ] Local proof: full `kind-smoke.sh` run in-sandbox — `verified-here`

**CI (`.github/workflows/umbrella.yml` — the one new workflow)**
- [ ] Chart job: per-child lint + template ×2 + kubeconform(rendered ×2); umbrella lint + template ×2 (defaults + engine-address variant) + kubeconform
- [ ] Stand-in image job: podman manifest build both arches (no push), arch-count check, amd64 `/health` smoke (docker buildx noted as fallback)
- [ ] Kind job on `ubuntu-latest` (docker provider): the `kind-smoke.sh` steps (`speculation` until green — record honestly from the first run); all existing workflows stay green
- [ ] CI green on the PR (`handoff-reported` receipt from the checks page)

**Flow and hygiene**
- [ ] Record proofs in this task dir (`proofs.md`) with the three labels: helm/kubeconform outputs, the kind install + `/health`-through-Service + mcp-pod receipts, the both-arch stand-in build
- [ ] Implementation corrections folded back into the task docs where the first kind run changes a mechanism (e.g. hostNetwork vs NodePort vs pod IP for the stand-in endpoint)
- [ ] One PR via `propose_pull_request` (no approval wait); conventional commits; three labels on every claim; box untouched; nothing on `main` unreviewed; no registry push; the engine's real LAN address absent from every public artifact; missing-LICENSE flag in the PR description; merge authority CoS; `mark_task_complete` only after the PR merges
