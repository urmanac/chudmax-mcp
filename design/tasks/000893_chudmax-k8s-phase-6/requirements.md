# Requirements: chudmax k8s phase 6 engine and web charts with umbrella

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 6 (`kubernetes/phases.md`; source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row F), as steered by the CoS brief (2026-11-25, `handoff-reported`): **the engine chart (renders no workload — a Service without a selector plus a values-driven EndpointSlice, defaulted to a TEST-NET-1 documentation placeholder), the web chart (a thin shell whose image the installer supplies), and the umbrella chart with a kind install proof.** All work happens in `urmanac/chudmax-mcp` under `k8s/engine-chart/`, `k8s/web-chart/`, `k8s/umbrella/` and one new workflow `.github/workflows/umbrella.yml` — **in parallel with phase 5** (its agent is generating its spec now; branch family `feature/000914-*`; boundaries below are hard). Depends on phase 3 (merged).

Two card texts are superseded by the steering and recorded here so they don't resurface: (1) the card's literal EndpointSlice address is the engine's **real LAN address — it must never appear in any public artifact** (same hygiene as credentials); (2) "web chart with the mock engine" — the fake engine is the **rehearsal's stand-in** (umbrella test scaffolding), not a web-chart workload, and the web image question is answered below as **option (a)** after investigation.

## Preconditions (verified, 2026-11-25)

- [x] Phases 2, 3, 4, 4b merged on public `main` @ `af65272`: the fetcher image, the repo-sync manifests, the REAL canonical ticket server at `k8s/tickets-mcp/` (no mock), the hardened mcp chart (pod-level securityContext, `server.enabled=true` with the `ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0` default), kubeconform-in-CI — `verified-here` (local clone).
- [x] **Phase 5 runs in parallel and is NOT merged**: no `.github/workflows/rehearsal*` exists on `main` — `verified-here`. Phase 5's artifacts are not prerequisites for phase 6 and must not be touched (see boundaries).
- [x] **Image-source investigation (GitHub web UI, `verified-here`)**: the public org `urmanac` carries `chudmax-engine`, `chudmax-web` and `hermes-agent` as single-commit **empty placeholders** (280ae98 / c0d4331 / 9d6fe53 — "initial empty commit"; no source, no tags, no packages). No public source exists from which CI could build a web image; the fork's code is private until phase 10; inventing a source is forbidden. → **Choice: option (a).**
- [x] Sandbox: docker, kind, kubectl on PATH; podman and helm not preinstalled (the phase-3 recipe installs them) — `verified-here`. The sandbox cannot reach the engine host (curl exits 7) — `verified-here` — so every rehearsal uses the stand-in.
- [x] The published canonical's contract for the mcp receipts: server runs `--http 8080 --host 0.0.0.0 --data-root /data` (chart values), answers honestly with no data before the first artifact, and the fetcher's startup `Get` retries with backoff (4b's fix) — `verified-here` (`k8s/tickets-mcp/`, `k8s/chart/chudmax-mcp/values.yaml`).

## Parallel-work boundaries (hard, from the steering)

- Phase 5 owns `.github/workflows/rehearsal*` and its fixtures. Phase 6 owns `k8s/engine-chart/`, `k8s/web-chart/`, `k8s/umbrella/` and `.github/workflows/umbrella.yml` — **nothing else**.
- Do not edit any file phase 5 might touch — including the top-level README (the structure line for the new dirs is deferred to a later sweep and noted in the PR description).
- Shared helpers are **duplicated**, never cross-edited or waited on. Branch off current `main`; never push to or depend on phase 5's branch.
- If phase 5's spec (`helix-specs design/tasks/000914_*`) defines reusable kind scaffolding, adopt the same approach **in your own copy** — but never depend on its branch existing. Check for it at implementation start.

## User stories

1. **As the human**, I want the engine chart to be a pure pointer: a Service without a selector plus an EndpointSlice whose address comes from values — defaulted to TEST-NET-1 (`192.0.2.1:8080`) with "set this to your engine's address" comments — so the cluster gets a **stable in-cluster name for the external engine** while the real address lives only in private deployment values (phase 11+).
2. **As the human**, I want "first test of any cluster is a pod reaching `/health` through that Service" shipped as a rerunnable Helm test hook, exercised by the umbrella's kind job — **honestly framed**: in CI it proves the Service→EndpointSlice→pod path against a stand-in, not the real engine (which is external and unavailable in CI); phase 11 reruns the same hook with the real address.
3. **As a user installing the web chart**, I get a thin, honest shell: Deployment + Service with the image I supply (the default reference is the unpublished phase-10 tag, commented as build-it-yourself), hardened pod settings, and no pretense of a bundled engine or image.
4. **As the rehearsal**, I want the umbrella to install engine + mcp on kind and prove exactly two things: the `/health`-through-the-engine-Service path, and the mcp pod being Up with the server answering HTTP 200 (honest no-data response) while the fetcher waits for the ExternalArtifact — expected pre-phase-5 — **without duplicating phase 5's commit→tickets proof**.
5. **As CI**, I want one `umbrella.yml` workflow re-proving all three new charts (lint/template/kubeconform, both variants), building the stand-in image for both architectures, and running the kind install job — with every existing workflow staying green.
6. **As the human**, I want the standing hygiene: box untouched, no registry push, no LAN address/credential/internal hostname in any public artifact, three labels on every claim, conventional commits, the missing-LICENSE flag in the PR, merge authority CoS.

## Acceptance criteria

**The hard rule (LAN address)**
- [ ] The engine's real LAN address (named in the card; never printed in this doc) appears in **no public manifest, values default, README, workflow, or test assertion** — same hygiene as credentials. Public artifacts carry only TEST-NET documentation addresses; the real address enters solely via private deployment values (phase 11+).

**Engine chart (`k8s/engine-chart/`)**
- [ ] Chart.yaml (apiVersion v2, name `chudmax-engine`, version 0.1.0): a Service **without a selector** (port 8080, named `http`) and an EndpointSlice (`discovery.k8s.io/v1`, `addressType: IPv4`, `kubernetes.io/service-name` label, one endpoint = `endpoint.host:endpoint.port`). `endpoint.host` defaults `192.0.2.1` (TEST-NET-1) and `endpoint.port` defaults 8080, with the values comment "set this to your engine's address"; NOTES.txt repeats it. **No workload renders** (no Deployment, no RBAC, no NetworkPolicy, no image). A legacy-Endpoints alternative is noted in the README.
- [ ] Chart README documents the **stable-in-cluster-name note** (the Service name is the alias for the external engine; the EndpointSlice is the only moving part when the engine moves) and carries an installer-facing values table (4b pattern).
- [ ] A Helm test hook pod (gated `test.enabled`, default true; `curlimages/curl` pinned by tag) curls `http://<engine-service>:8080/health` and passes on 200 — runs only on explicit `helm test`, reused unchanged at phase 11.
- [ ] `helm lint` and `helm template` pass in both variants (defaults = TEST-NET-1; engine-address variant = TEST-NET-2 `198.51.100.10`), rendered templates pass kubeconform — locally and in CI.

**Web chart (`k8s/web-chart/`)** — image-source choice **(a)**, recorded
- [ ] Chart.yaml (v2, name `chudmax-web`, version 0.1.0): a Deployment whose image comes from values (`web.image` defaults `ghcr.io/urmanac/chudmax/web` : `0.1.0` with the "unpublished until phase 10 — supply your own" comment; the repo's own precedent for unpublished tags) and a Service; pod-level `automountServiceAccountToken: false` + securityContext (runAsNonRoot, drop ALL, seccomp RuntimeDefault — the 4b pattern); serving-port / engine-URL / probe knobs with defaults labeled as documented guesses ("revisit at phase 10" when the fork publishes its shape).
- [ ] **No bundled mock engine** and **no NetworkPolicies** in this chart — both deviations documented in the README with their reasons (the fake engine is rehearsal scaffolding; CNI-dependent policy guesses were the F5/Cilium trap, and the web's constraints wait for phases 12/15).
- [ ] `helm lint`/`helm template` in both variants (defaults; custom image/port/engineUrl) + kubeconform on rendered — locally and in CI.

**Umbrella (`k8s/umbrella/`)**
- [ ] Chart.yaml (v2, name `chudmax`, version 0.1.0) with three `file://` dependencies on the sibling charts **in this same checkout** (`../engine-chart`, `../web-chart`, `../chart/chudmax-mcp`), condition-gated, all enabled by default; values carry the mcp chart's 4b defaults (`server.enabled=true`, tickets-mcp image) and a documented **rehearsal profile** (`web.enabled=false` pending phase 10; engine endpoint overridden at install time); README explains the local deps, the phase-10 OCI switch, and the rehearsal profile; `charts/` (the `helm dependency build` output) is gitignored.
- [ ] `k8s/umbrella/standin/` — the rehearsal's fake engine: a single-file Python-stdlib HTTP server (GET `/health` → 200; a documented permissive catch-all so unmocked paths don't hard-fail), Dockerfile `FROM python:3.12-alpine`, **COPY-only** (no RUN → no emulation), non-root uid 65532 (the established image pattern); local image name `chudmax-engine-standin:0.1.0` — rehearsal-only, never published; dir README.
- [ ] `kind-smoke.sh` + CI kind job: kind up (docker provider) → podman build the stand-in + fetcher + tickets-mcp images (amd64 — the kind node's arch) → `podman save` → `kind load image-archive` (**no registry**) → `helm dependency build` → `helm install` the umbrella with rehearsal values (engine endpoint = the kind node's IP:8080, resolved from the cluster; `web.enabled=false`) → `helm test` (the engine Service `/health` hook) passes → mcp receipts recorded: release `deployed`, pod `Running` (fetcher waiting for the ExternalArtifact = **expected**), server answers HTTP 200 on its Service port (initialize handshake) with the honest no-data response; **explicitly not** phase 5's commit→tickets proof.
- [ ] CI `.github/workflows/umbrella.yml`: (a) chart job — per-child lint + template ×2 + kubeconform(rendered), plus the umbrella lint/template ×2/kubeconform (defaults + engine-address variant); (b) stand-in image job — podman manifest build both arches (no push), arch-count check, amd64 `/health` smoke; (c) kind job on `ubuntu-latest` (docker provider — well-precedented, `speculation` until green; docker buildx is the recorded podman fallback). Existing workflows stay green.

**Proofs and flow**
- [ ] Proofs recorded in this task dir on helix-specs (a `proofs.md`) with the three labels: helm lint/template/kubeconform outputs, the kind umbrella install + `/health`-through-Service + mcp-pod receipts, the both-arch stand-in build — all `verified-here` where this sandbox ran them.
- [ ] One PR via `propose_pull_request` (no approval wait) from a feature branch off current `main`; conventional commits; three labels on every claim; the box untouched; no registry push; the missing-LICENSE flag in the PR description; no edits to phase-5's files or the top-level README; merge authority CoS; `mark_task_complete` only after merge.

## Out of scope (owned by other phases or decisions)

- Publishing anything (ghcr.io, cosign), creating the engine/web repos' real content, the real web image — phase 10.
- The commit→tickets data-path rehearsal and the policy-denial proof — phase 5 (parallel; do not duplicate).
- Canary (Flagger, phase 7), image automation (phase 8), the Hermes chart (phase 9 — that's `hermes-agent`, the empty placeholder, not the web harness).
- Real placement, the real EndpointSlice address anywhere public, web/engine NetworkPolicies, the platform CNI inventory — phases 11–12.
- The web/engine split route and any stand-in expansion beyond `/health` — phase 15.
- mTLS (phase 17); the box (untouched throughout).

## Open Questions

None — the CoS steering (2026-11-25) resolved all four from the first draft (umbrella home = chudmax-mcp; endpoint default = TEST-NET-1 placeholder; the fake engine = rehearsal scaffolding; the web image = option (a) after investigation). The web's port/probe defaults remain documented guesses, but they are values with knobs and a "revisit at phase 10" note — not blockers, and not worth a question.
