# Design: chudmax k8s phase 6 engine and web charts with umbrella

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 6 makes three installable chart surfaces and proves two of them together on kind. It adds no product logic: the engine chart is a pointer (the engine stays on the box and is never containerized), the web chart is a shell (its image is phase 10's), and the umbrella composes the three charts plus the rehearsal's stand-in. The one real mechanism under test is the production path — **test pod → selectorless Service → EndpointSlice → endpoint** — rehearsed against a stand-in because no rehearsal runner can reach the box (`verified-here`: sandbox curl to the engine address exits 7) and CI runners certainly can't. Requirements in `requirements.md`; the phase-6 row lives in `kubernetes/phases.md` on the private source-of-truth repo (source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row F); the steering brief (2026-11-25, `handoff-reported`) decides the deltas from this spec's first draft, recorded below.

## Shape (kind rehearsal)

```
 kind node (docker)                        chudmax-engine chart
 ┌──────────────────────────────────────┐  ┌───────────────────────────────────┐
 │ stand-in pod (hostNetwork :8080) ◄───┼──┤ Service (no selector, port 8080)  │
 │                                      │  │ EndpointSlice: <node IP>:8080     │
 │ mcp pod:                             │  └───────────────────────────────────┘
 │   server (tickets-mcp): up, answers  │                ▲
 │     HTTP 200 — honest no-data body   │    helm test hook: curl /health → 200
 │   fetcher: waiting for the           │
 │     ExternalArtifact (EXPECTED)      │    web: absent — web.enabled=false
 └──────────────────────────────────────┘         (image pending phase 10)
```

**The honest framing (printed on the receipt):** in CI this proves the Service→EndpointSlice→pod path against a stand-in `/health` endpoint — the real engine is external and unavailable in CI. The rehearsed shape and the real shape differ only in the endpoint address: phase 11 supplies the engine's real address as private deployment values and reruns the same hook.

## Layout (all inside `urmanac/chudmax-mcp` — the parallel-safe file set)

```
k8s/engine-chart/          chart root: Chart.yaml, values.yaml, README.md
                           templates/{_helpers,service,endpointslice,test-health,NOTES.txt}
k8s/web-chart/             chart root: Chart.yaml, values.yaml, README.md
                           templates/{_helpers,deployment,service,NOTES.txt}
k8s/umbrella/              chart root: Chart.yaml (file:// deps), values.yaml, README.md,
                           kind-smoke.sh, standin/{mock_engine.py,Dockerfile,README.md}
                           charts/           gitignored — helm dependency build output
.github/workflows/umbrella.yml   chart job + standin-image job + kind job
```

Phase 5 (parallel) owns `.github/workflows/rehearsal*` and its fixtures; the sets are disjoint by construction, helpers are duplicated rather than shared, and the top-level README is deliberately untouched.

## Key decisions

1. **All of phase 6 lives in chudmax-mcp** (the steering's file-ownership list). The empty `urmanac/chudmax-engine` / `chudmax-web` repos are phase-10 publishing targets, not phase-6 work surfaces — the sandbox clones of them exist but stay untouched. Consequence (simpler than this spec's first draft): the umbrella's dependencies are plain `file://` paths to sibling charts in the same checkout — **no cross-repo pins, no fetch script**; the phase-10 switch to published OCI chart references is a Chart.yaml edit.
2. **The LAN-address hard rule → TEST-NET-1 default.** `endpoint.host` defaults `192.0.2.1` (TEST-NET-1) with "set this to your engine's address" in values + NOTES; the CI's engine-address variant uses TEST-NET-2 (`198.51.100.10`) to prove the value flows through; the real address lives only in private deployment values (phase 11+). EndpointSlice (modern, `discovery.k8s.io/v1`) over legacy Endpoints — same semantics, the alternative noted in the README; endpoints must not be ClusterIPs (apiserver validation), hence a node IP in the rehearsal.
3. **The Service is the stable in-cluster name for the external engine** (the steering's alias note): installers point pods and config at `chudmax-engine.<ns>.svc` once; the EndpointSlice is the only thing that changes when the engine moves (phases 11/14). Nothing that resembles a workload ever renders in this chart.
4. **"First test of any cluster" ships as a values-gated Helm test hook.** `helm test` runs a curl pod against the Service (fail-fast, `helm.sh/test` labels; only ever runs on the explicit command, so the placeholder default never fires it spuriously). The umbrella's kind job runs it against the stand-in; phase 11 runs the identical hook with the real address. Hook image `curlimages/curl` pinned by tag, with the stand-in image (busybox `wget`) as the pull-free alternative.
5. **The stand-in is rehearsal scaffolding, not a chart workload.** `k8s/umbrella/standin/` — a python-stdlib single file answering `GET /health` with 200 plus a documented permissive catch-all; Dockerfile `FROM python:3.12-alpine`, COPY-only (no RUN → no emulation), uid 65532 — exactly the published tickets-mcp image's pattern. Local name `chudmax-engine-standin:0.1.0`, never published (not a `ghcr.io/urmanac/chudmax/*` reference — it is not a distribution artifact). Mechanism: hostNetwork :8080 on the kind node + node-IP endpoint = one-step install and port parity with the real engine; recorded alternatives if the first kind run frictions out: NodePort + node IP (no hostNetwork) and mock pod IP (two-step `helm upgrade --set`). Pod→node-IP under kindnet: `speculation` until run.
6. **Web chart = thin shell; the image-source answer is option (a).** Investigation (GitHub web UI, 2026-11-25, `verified-here`): `urmanac/chudmax-engine`, `chudmax-web` and `hermes-agent` are single-commit empty placeholders — no public source exists from which CI could build a web image, and inventing one is forbidden. So `web.image` is a values-driven reference (default = the unpublished phase-10 tag with a build-it-yourself comment — the mcp chart's own precedent for unpublished tags), the kind rehearsal runs `web.enabled=false`, and the web's kind exercise waits for phase 10. Port/probe defaults are labeled guesses with knobs ("revisit at phase 10").
7. **No NetworkPolicies in the new charts — a recorded deviation from the mcp chart's pattern.** CNI-dependent egress guesses were the F5/Cilium trap; the web's constraints wait for the phase-15 route and phase-12's CNI inventory; and kind's default CNI enforces no policies anyway, so the rehearsal would prove nothing about them.
8. **Rehearsal bar and honest mcp receipts.** All enabled releases `deployed`; the engine-Service `/health` hook passes; the mcp pod Running with the server answering 200 (initialize handshake over its Service) and the honest no-data body; the fetcher waiting for the ExternalArtifact is **expected** (4b's startup fix keeps it alive) and recorded as such. The commit→tickets data-path proof is phase 5's — the umbrella proves install + reachability, nothing more (steering: do not duplicate it).
9. **Toolchain mapping (steering 4 + 6).** Images build under podman, export via `podman save`, load via `kind load image-archive` — no registry. The both-arches proof: the stand-in builds as a manifest list in its own job; fetcher/tickets-mcp both-arches stay re-proved in the existing `image-chart.yml` (the umbrella's kind job loads amd64 only — the kind node's arch). Local kind = **docker provider** (docker is present; the podman provider's rootless-pasta caveats from phase 3 are not worth fighting); CI kind on `ubuntu-latest` is well-precedented — `speculation` until green, with docker buildx as the recorded podman fallback.
10. **Parallel-safety by construction.** The phase-6 file set is disjoint from phase 5's; branch off current `main`; phase-5's branch is never a dependency; if its spec (000914_*) lands with kind scaffolding, adopt the approach into your own copy only.

## Notes for future agents (learnings)

- **Steering deltas vs this spec's first draft (2026-11-25, `handoff-reported`):** umbrella home DECIDED (chudmax-mcp — not the empty repos); endpoint default DECIDED (TEST-NET-1 baked, not empty-with-required); the fake engine moved out of the web chart into the umbrella's rehearsal scaffolding; web image = option (a) after investigation; the kind proof's scope fixed at `/health` + mcp-pod receipts (not the data path).
- **Public-org facts (GitHub web UI, 2026-11-25, `verified-here`):** the `urmanac` org is public; `chudmax-mcp` carries the real work; `chudmax-engine`, `chudmax-web`, `hermes-agent` are empty placeholders awaiting phase 10. "Hermes Agent (for ChudMax)" is the phase-9 chart's subject — **not** the web harness; don't conflate them.
- **The published canonical's server facts** (for the mcp receipts): args `--http 8080 --host 0.0.0.0 --data-root /data`; Service port 8080; honest no-data answers before the first artifact; the fetcher's startup-`Get` NotFound retries with backoff (4b) — so "pod Up, server 200, fetcher waiting" is a stable, expected state on kind.
- **Sandbox facts:** docker, kind, kubectl on PATH; podman + helm absent (phase-3 recipe: helm tarball from get.helm.sh, rootless podman; binfmt_misc denied — arm64 *containers* can't run, host-side qemu exec is the arm64 proof route); curl to the engine address exits 7 — any design assuming box reachability is dead on arrival.
- **Chart-pattern sources to copy (patterns, not text):** `k8s/chart/chudmax-mcp/` (values comment style, unpublished-tag wording, pod-level securityContext/automount, kubeconform-on-rendered-templates CI, NOTES conventions, installer-facing values tables); `k8s/tickets-mcp/Dockerfile` (the COPY-only template the stand-in mirrors).
- **EndpointSlice shape facts:** `addressType: IPv4`; the `kubernetes.io/service-name` label matching the Service; `endpoints[].addresses` take plain IPs (service ClusterIPs are rejected — node IP in rehearsal); keep Service port and endpoint port equal (8080) for parity with the real engine.
- **Helm test hooks:** `helm.sh/hook: test` + fail-fast annotation; subchart hooks run under the parent release, so one `helm test` covers the umbrella.
- **Labels vocabulary** (`chudmax/AGENTS.md`): `verified-here` (this sandbox ran it), `handoff-reported` (CoS/owner said it), `speculation` (not yet exercised — kind-in-CI, pod→node-IP under kindnet, the web's default port/probe).
- **Docs rule:** this helix-specs branch and the code repos are public — the engine's real LAN address, credential names, and internal proxy hostnames never appear in any of them; the card's literal address is deliberately absent from these docs.

## What this settles

- The pointer chart, the web shell, and the umbrella + rehearsal scaffolding exist as reviewable units with CI re-proofs — the surfaces phases 7 (canary), 8 (image automation), 10 (publishing switch) and 11 (real pointer values) inherit.
- The cluster probe is written once (inside the engine chart, as a hook) and answers for rehearsal and reality alike; the honest framing is part of the artifact, not a footnote.
- Still `speculation` after this spec: kind-in-CI reliability, pod→node-IP under kindnet, the stand-in catch-all's adequacy — each gets its first exercise in the implementation run and is re-labeled from evidence.
