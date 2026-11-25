# Design: chudmax k8s phase 6 engine and web charts with umbrella

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 6 makes three installable parts and proves them together on kind. It adds no product logic: the engine chart is a pointer (the engine stays on the box), the web chart is a Deployment/Service shell with a stand-in mock engine, and the umbrella just composes the three existing charts. The one real mechanism under test is the production path: **web pod → selectorless Service → EndpointSlice → endpoint address** — rehearsed against the mock engine because no rehearsal runner can reach the box (`verified-here`: sandbox curl to the card's address exits 7). Requirements in `requirements.md`; the phase-6 row lives in `kubernetes/phases.md` on the private source-of-truth repo (source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row F).

## Shape (kind rehearsal)

```
 kind node (docker)                      address = node IP, resolved pre-install
 ┌───────────────────────────────────────────────────┐
 │  web pod (chudmax-web chart)                      │
 │    engineUrl = http://chudmax-engine:8080 ─────┐  │   ┌──────────────────────────┐
 │  mock-engine pod (hostNetwork :8080) ◄─────────┼──┼───│ chudmax-engine chart     │
 │  mcp pod (fetcher waiting + tickets-mcp server)│  └──►│ Service (no selector)    │
 └───────────────────────────────────────────────────┘     │ EndpointSlice            │
                                                           │  node IP : 8080          │
                 helm test hook: curl /health through the Service → 200
                 (identical probe later against the real engine, phase 11+)
```

The mock engine keeps the real engine's port (8080) so rehearsal values and placement values differ **only in the endpoint address** — the phase-11 cutover of this chart is a one-value change.

## Repo layouts

```
chudmax-engine/   (first content of the repo)
  README.md
  k8s/chart/chudmax-engine/
    Chart.yaml  values.yaml  templates/{_helpers,service,endpointslice,test-health,NOTES}
    README.md
  .github/workflows/chart.yml     lint + template ×2 + kubeconform(rendered)

chudmax-web/      (first content of the repo)
  README.md
  k8s/mock-engine/
    mock_engine.py                python stdlib; /health → 200, permissive catch-all
    Dockerfile                    COPY-only, non-root, alpine base off 3.21 (4b rule)
    README.md
  k8s/chart/chudmax-web/
    Chart.yaml  values.yaml  templates/{_helpers,deployment,service,
      mock-engine-deployment,mock-engine-service,test-health,NOTES}  README.md
  .github/workflows/chart.yml     lint + template ×2 + kubeconform(rendered)
  .github/workflows/mock-engine-image.yml   podman both arches + amd64 /health smoke

chudmax-mcp/      (umbrella's recommended home — Open Question 1)
  k8s/umbrella/chudmax/
    Chart.yaml                    deps: chudmax-engine, chudmax-web, chudmax-mcp (file://)
    values.yaml                   rehearsal defaults; alias-keyed overrides
    scripts/fetch-charts.sh       clone 3 repos at pinned SHAs → charts/ (gitignored)
    scripts/kind-smoke.sh         kind up → install → test → report
    README.md                     pins table + phase-10 OCI note
  .github/workflows/umbrella-kind.yml   chart job + kind job (ubuntu-latest, docker provider)
```

## Key decisions

1. **The engine chart renders no workload — on purpose.** The engine is never containerized (it stays on the GPU box; the box is untouched except phase 14's pointer edit). The chart is the docs' "Service without selector" pattern: Service + manual endpoints. **EndpointSlice** (the modern object, `discovery.k8s.io/v1`) over legacy Endpoints, with the `kubernetes.io/service-name` label. No RBAC (nothing watches anything), no NetworkPolicy (nothing to protect).
2. **Endpoint address is install-supplied.** `engine.endpoint.host` defaults empty → the chart renders the Service only, with NOTES telling the installer what to set. Rationale: the public-surface rule (no LAN addresses in public artifacts) beats the card's literal wording; the card's address is what phase 11+ supplies as a value. CI template proofs use a TEST-NET placeholder (`203.0.113.10`). The owner can flip this to a baked default (Open Question 2).
3. **"First test of any cluster" ships as a Helm test hook.** A hook pod curls `/health` through the engine Service (`failFast`, labeled `helm.sh/test`). Same hook, two lifetimes: kind rehearsal (mock endpoint) and phase 11's real run (box endpoint). The hook image is `curlimages/curl` pinned by tag, with the mock-engine image (busybox `wget`) as the pull-free alternative if the runner's egress is a problem.
4. **The mock engine: minimal, in the web chart, default on.** Python-stdlib single file (the proven tickets-mcp pattern — COPY-only image, no RUN, emulation-free), `/health` → 200 plus a documented catch-all so unmocked engine calls don't break the rehearsal. `mockEngine.enabled` defaults **true** (the 4b out-of-the-box precedent); `mockEngine.hostNetwork` defaults false and the rehearsal sets it true: the mock then listens on the node's :8080, the EndpointSlice names the **node IP** (resolvable before install → one-step `helm install`, no ClusterIP-in-endpoints rejection, port parity with the real engine). Recorded alternatives: NodePort + node IP (robust, no hostNetwork) and mock pod IP (two-step helm install, breaks on pod restart). Reachability pod→node-IP under kind's kindnet is `speculation` until the first run.
5. **The web Deployment's image default is the real, unpublished tag** (`ghcr.io/urmanac/chudmax/web:0.1.0`) — the mcp chart's exact precedent. The fork's code is private until phase 10, so the kind rehearsal overrides `web.image` with the **mock-engine image as a documented stand-in** (a generic HTTP server answering the probe) — this proves the chart's shape and the web→engine path, never the web app. All web knobs (`port`, `engineUrl`, probe path) are values with defaults labeled as guesses (the fork's facts are private).
6. **No NetworkPolicies in the engine/web charts this phase** — deliberate deviation from the mcp chart's hardened pattern. The mcp policies serve a known constraint (the fetcher's Flux egress); the web's constraints are unknown until the phase-15 route and the phase-12 CNI inventory, and CNI-dependent egress guesses were the F5 trap. Documented in the chart README; policies arrive with placement.
7. **Umbrella home: `k8s/umbrella/chudmax/` in chudmax-mcp** (recommended; Open Question 1). Every k8s artifact so far lives there with its CI; phase 5 rehearses beside it; moving to a dedicated repo at phase 10 is cheap. Children are `file://` dependencies (plain Helm cannot fetch from git; OCI chart publishing is phase 10), vendored by `scripts/fetch-charts.sh` at **pinned SHAs** recorded in the README and the workflow env; `charts/` is gitignored so pins live in exactly one place.
8. **Rehearsal bar.** All three releases `deployed`; web pod Ready (with the stand-in image); the engine-Service `/health` hook passes; the mcp pod's fetcher is **expected to be waiting** (no ExternalArtifact exists — phase 4b's startup fix keeps it alive and honest) and the smoke script records that as a pass-with-note. Phase 5 owns the data-path rehearsal and inherits this umbrella + kind machinery.
9. **Toolchain mapping.** Podman first for image builds (the standing rule): `podman build --platform linux/amd64,linux/arm64 --manifest …` locally and in the mock-engine image job (docker buildx stays the recorded fallback). The umbrella's kind job builds single-arch (amd64 — the kind node's arch) images to **load**, not publish; the both-arches rule is re-proved per image in the image-owning repos. Local kind runs on the **docker provider** (docker present in-sandbox; the podman provider's rootless-pasta caveats from phase 3 are not worth fighting); CI kind on `ubuntu-latest` is well-precedented and labeled `speculation` until green.

## Notes for future agents (learnings)

- **The 4b scope flip matters:** `k8s/tickets-mcp/` on chudmax-mcp `main` is the *published canonical ticket server* (image `ghcr.io/urmanac/chudmax/tickets-mcp`), and the old mock ticket server is deleted. Phase 6's "mock engine" is a different, new thing — the stand-in for the box's engine. Don't resurrect the deleted mock's files.
- **Sandbox facts (2026-11-25):** docker, kind, kubectl on PATH; podman and helm absent (install per phase-3 design.md's implementation notes — helm tarball from get.helm.sh, rootless podman); `curl` to the engine address exits 7 (unreachable) — every rehearsal design that assumed box reachability is dead on arrival; binfmt_misc is denied (arm64 *containers* can't run — phase-3's host-side qemu exec is the arm64 proof route).
- **Chart-pattern source of truth:** `k8s/chart/chudmax-mcp/` — values comment style, unpublished-tag note wording, pod-level securityContext/automount pattern, kubeconform-on-rendered-templates CI, NOTES.txt conventions. Copy the patterns, not the text.
- **EndpointSlice shape facts:** `addressType: IPv4`, the `kubernetes.io/service-name` label matching the Service, `endpoints[].addresses` = plain IPs (service ClusterIPs are rejected — hence node-IP endpoints), ports need name/protocol. Selectorless Service needs no `targetPort` gymnastics — keep service port and endpoint port equal (8080) everywhere.
- **Helm test hooks** (`helm.sh/hook: test`, `helm.sh/hook-weight`, fail-fast annotation) make the cluster probe a first-class artifact: `helm test <release>` after install, in-sandbox and in CI, reusable at phase 11 unchanged.
- **Labels vocabulary** (chudmax/AGENTS.md): `verified-here` (this sandbox ran it), `handoff-reported` (CoS/owner said it), `speculation` (not yet exercised — kind-in-CI, pod→node-IP under kindnet, the web's default port/probe).
- **Docs rule:** this helix-specs branch is public-safe by construction — no LAN addresses, no credential names, no internal proxy hostnames. The card's literal engine address is deliberately absent from these docs; implementation keeps it that way (install values only).

## What this settles

- The pointer chart, the web shell with its stand-in engine, and the umbrella exist as reviewable, installable units with CI re-proofs — the full install surface phase 7 (canary), 8 (image automation) and 12 (real placement) build on.
- The cluster probe ("pod reaches `/health` through the engine Service") is written once, inside the engine chart, and answers for rehearsal and reality alike.
- Still `speculation` after this spec: kind-in-CI reliability, pod→node-IP under kindnet, the mock's catch-all adequacy — each gets its first real exercise in the implementation run and is re-labeled from evidence.
