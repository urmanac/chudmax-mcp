# Requirements: chudmax k8s phase 6 engine and web charts with umbrella

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 6 (`kubernetes/phases.md`; source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row F): **the engine chart (renders no workload — a selectorless Service plus an EndpointSlice naming the engine host's LAN address, supplied at install; the card's literal address is recorded privately, not printed here per the public-surface rule), the web chart with the mock engine, and the umbrella chart installing all three charts on kind.** The engine stays on the box and is never containerized — the chart is a pointer. The first test of any cluster is a pod reaching `/health` through that engine Service; it ships as a Helm test hook so the same probe runs in the kind rehearsal (against the mock engine) and later against the real engine. Depends on phase 3 (done and merged).

The rules hold: podman first, CI builds arm64+amd64, the box is untouched, nothing lands on `main` unreviewed, no registry push (phase 10).

## Preconditions (verified, 2026-11-25)

- [x] Phases 2, 3, 4, 4b merged on public `urmanac/chudmax-mcp` `main` @ `af65272`: the fetcher, the mcp chart (hardened defaults, published canonical `tickets-mcp` server as the default server image), the repo-sync manifests, and the CI patterns (helm lint/template + kubeconform on rendered templates, podman both-arches image jobs) — `verified-here` (local clone). The 4b scope flip deleted the mock ticket server; **this phase's mock engine is new and unrelated**.
- [x] The `urmanac/chudmax-engine` and `urmanac/chudmax-web` repos exist and are **empty** (initial commit only, Helix-proxy remotes present) — `verified-here` (local clones). Phase 6 is their first content; they carry no LICENSE (flag rides in their PRs).
- [x] This sandbox has docker, kind and kubectl on PATH; podman and helm are **not** preinstalled (the phase-3 recipe installs them: helm from get.helm.sh, podman rootless) — `verified-here`.
- [x] The sandbox **cannot reach the engine host** (`curl` to the card's address exits 7) — `verified-here`. Every kind rehearsal therefore points the engine Service at the mock engine; nothing in phase 6 touches the box or assumes reachability.

## User stories

1. **As the human**, I want the engine chart to be a pure pointer — a Service without a selector and an EndpointSlice at the address I supply — so the cluster can reach the engine that stays on the box, with no workload pretending to be it.
2. **As the human**, I want "a pod reaching `/health` through the engine Service" to be a shipped, rerunnable test (Helm test hook), so the first question of any cluster — ours or the platform's — is answered by `helm test`, not by an ad-hoc curl.
3. **As a user installing the web chart**, I get a working install out of the box: the web Deployment, its Service, and a values-gated mock engine (default on) to talk to — mirroring the mcp chart's out-of-the-box pattern — with override values for the real engine later.
4. **As the rehearsal**, I want the umbrella to install all three charts on kind and prove the production shape: a web pod reaching the mock engine *through the engine Service* (Service → EndpointSlice → endpoint), which is exactly the path phase 11+ will use with the real address.
5. **As CI**, I want every push to re-prove the parts: chart lint/template (+ kubeconform on rendered templates) in all three repos, the mock-engine image built for both architectures under podman, and the kind install job running the umbrella end to end.
6. **As the human**, I want the box untouched, no registry push, no LAN address or private material in any public artifact, the three labels on every claim, and the missing-LICENSE flag riding in the two new repos' PR descriptions.

## Acceptance criteria

**Engine chart (`urmanac/chudmax-engine`)**
- [ ] `k8s/chart/chudmax-engine/` (apiVersion v2, version 0.1.0) renders **no workload**: a selectorless Service (port 8080, named `http`) and an EndpointSlice (`discovery.k8s.io/v1`, `addressType: IPv4`, the `kubernetes.io/service-name` label, one endpoint = `endpoint.host: endpoint.port`) rendered **only when `endpoint.host` is set**; the public default is empty (Service-only render + NOTES explaining the install-supplied address). No Deployment, no RBAC, no NetworkPolicy, no image.
- [ ] A Helm test hook pod curls `http://<engine-service>:8080/health` through the Service and passes on 200 — the reusable "first test of any cluster"; it is exercised in the kind rehearsal and left ready for phase 11's real run.
- [ ] `helm lint` and `helm template` pass in both variants (endpoint unset; endpoint set to a TEST-NET placeholder) and the rendered templates pass kubeconform — locally and in CI. Repo top-level README + chart README + NOTES written (first content of the repo).

**Web chart + mock engine (`urmanac/chudmax-web`)**
- [ ] `k8s/mock-engine/`: a single-file Python-stdlib HTTP server (the proven tickets-mcp pattern) answering `GET /health` with 200 and a documented permissive catch-all for other paths; COPY-only Dockerfile (no RUN → emulation-free builds), non-root, port 8080; dir README. One OCI image builds as a manifest list for `linux/amd64` and `linux/arm64` under podman (`ghcr.io/urmanac/chudmax/mock-engine:0.1.0`, unpublished until phase 10); amd64 `/health` smoke in-sandbox; arm64 runtime proof via host-side qemu best-effort, recorded honestly (the phase-3 precedent).
- [ ] `k8s/chart/chudmax-web/` (v2, 0.1.0): web Deployment (`web.image` default `ghcr.io/urmanac/chudmax/web:0.1.0` with the unpublished-until-phase-10 build-it-yourself note; serving port, engine URL and probe knobs — defaults are documented guesses, see Open Questions), web Service, pod-level `automountServiceAccountToken: false` + runAsNonRoot + dropped capabilities (the mcp chart's hardened pattern), and the values-gated **mock engine** (`mockEngine.enabled` default **true**, 4b's out-of-the-box precedent): mock-engine Deployment (+ `mockEngine.hostNetwork` knob, default false) and its Service on 8080; when the mock is off, `web.engineUrl` points the web wherever the installer says (in placement: the engine Service). A Helm test hook curls the web Service's health path.
- [ ] **No NetworkPolicies in this chart** — a recorded deviation from the mcp chart's pattern: egress rules to a node-addressed endpoint are CNI-dependent guesses (the F5/Cilium lesson); policies arrive with placement (phases 12/15) once the platform's CNI is inventoried. The README says so.
- [ ] `helm lint`/`helm template` pass in both variants (mock on; mock off + custom `web.engineUrl`), rendered templates pass kubeconform; repo top-level README + chart README + NOTES written; CI covers the chart job and the mock-engine image job (podman, both arches, no push, amd64 `/health` smoke).

**Umbrella (recommended home: `urmanac/chudmax-mcp` at `k8s/umbrella/chudmax/` — see Open Questions)**
- [ ] Umbrella chart (v2, 0.1.0) with three `file://` dependencies — `chudmax-engine`, `chudmax-web`, `chudmax-mcp` — condition-gated, all enabled; child charts are vendored at **pinned commits** by a fetch script (pinned SHAs recorded; vendored copies gitignored); README explains the pinning and that OCI publishing is phase 10.
- [ ] A kind smoke script: kind up (docker provider), vendored deps built, `helm install` one release with rehearsal values (mock on, engine endpoint = the kind node's IP:8080 resolved from the cluster, web → the engine Service), `helm test` runs, and the `/health`-through-the-engine-Service probe passes. Pod→node-IP reachability is the mechanism under test — alternatives (NodePort, pod-IP two-step) recorded in `design.md` if it frictions out.
- [ ] The rehearsal records the mcp pod's **expected waiting state** honestly: the fetcher retries its startup `Get` with backoff (4b's fix) because no ExternalArtifact exists in phase 6 — the data-path rehearsal is phase 5's business. The acceptance bar for the mcp release is "deployed + server container up", not fetcher-ready.
- [ ] CI: chart lint/template/kubeconform job plus the kind job on `ubuntu-latest` (docker provider — well-precedented; `speculation` until it runs). The kind job loads amd64-only images (mock-engine from the web repo, fetcher + tickets-mcp built from `k8s/image/Dockerfile` and `k8s/tickets-mcp/Dockerfile`); the both-arches rule stays re-proved per image in the image-owning repos' own CI.

**Local proofs (this sandbox)**
- [ ] podman + helm installed per the phase-3 recipe; the mock-engine image builds as a both-arch manifest list under podman; kind comes up with the docker provider; the umbrella rehearsal runs end to end in-sandbox with the `/health` probe passing — all `verified-here`.

**Flow and hygiene**
- [ ] Three feature branches, one per repo, three PRs via `propose_pull_request` (no approval wait); conventional commits; the three-labels rule on every claim; the box untouched; nothing pushed to any registry; no LAN address, credential or internal hostname in any public repo or doc; the missing-LICENSE flag rides in the engine and web PR descriptions; merge authority CoS/owner; `mark_task_complete` only after all PRs merge.

## Out of scope (owned by other phases or decisions)

- Publishing any image or chart to ghcr.io (cosign, credential-free pull) — phase 10.
- The repo-sync data-path rehearsal on kind (commit → `list_tickets`) — phase 5; phase 6's umbrella rehearses install only and hands phase 5 the same machinery.
- Canary (Flagger, phase 7), image automation (phase 8), Hermes chart (phase 9).
- Real-cluster placement, the real EndpointSlice address, NetworkPolicies for web/engine, the platform CNI inventory — phases 11–12.
- The web/engine split route (fork change vs `app/host` vs thin front) and any expansion of the mock engine's API surface — phase 15.
- Containerizing the engine — never; it stays on the box (the plan's design).

## Open Questions

1. **Umbrella home.** The card says "the umbrella installing all three" but names no repo, and the naming table lists only the three app repos. My recommendation: `k8s/umbrella/chudmax/` inside `urmanac/chudmax-mcp` (the established k8s workbench — CI patterns, kubeconform, phase-5 adjacency; moving it to a dedicated repo at phase 10 is a cheap `git mv` + workflow move if wanted). Alternatives: a new owner-created repo (e.g. `chudmax-deploy` — repo creation is a known human step), or inside `chudmax-web`. Say the word at review; the spec's shapes work in any home.
2. **The EndpointSlice's public default.** The card text says the EndpointSlice names the engine host's LAN address (recorded privately); the standing public-surface rule says no LAN addresses in public artifacts. I spec the address as **install-supplied** (public default empty, Service-only render). If you'd rather bake the card's literal address as the chart default (your repos, your call — the phase-4 ruling treated the private repo's URL as public-safe), it's a two-line values change at implementation.
3. **Mock-engine API surface.** Phase 6's only contractual endpoint is `/health`; I add a permissive catch-all so unknown engine-API calls don't hard-fail the rehearsal. If you already know more of the real engine's surface that the web needs *now*, name the endpoints and the mock grows; otherwise the mock's fidelity work waits for the phase-15 route decision.
4. **Web defaults are guesses.** The fork's serving port, health path and expected engine-URL variable are not visible from the public side (the fork's code is private until phase 10). The chart ships knobs (`web.port` default 8080, probe path default `/health`, `web.engineUrl`) labeled as guesses — correct them at review if you know better.
