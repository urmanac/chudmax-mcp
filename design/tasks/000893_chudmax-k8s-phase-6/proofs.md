# Phase 6 implementation proofs — chudmax k8s engine and web charts with umbrella

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

All claims carry the three labels (`chudmax/AGENTS.md`): `verified-here` (this sandbox ran it), `handoff-reported` (CoS/owner/reviewers said it), `speculation` (not yet exercised — first run pending in CI).

## Toolchain (`verified-here`, 2026-11-25)

- podman 5.4.2 (rootless), helm v3.16.4 (get.helm.sh tarball; gotcha: `tar -C /usr/local --strip-components=1` lands the binary at `/usr/local/helm` — move it to `/usr/local/bin`), kubeconform v0.6.7 (**the `yannh` release — the org the repo's CI uses; `kubernetes-sigs` 404s**), kind upgraded v0.27.0 → **v0.33.0** (phase 5's pin, verified real).

## Strata pin (`verified-here`)

- Clone `kingdonb/Strata` @ `de34ebaa521d8f628b4bb1884e5c34101730299a` (tag `v0.2.21-mbp.rtx.1`, MIT). Confirmed: `--engine` defaults `mock` (server.py:9218); `MockEngine` in-process (L471); `GET /health` (7660), `GET /mcp` (7640), `POST /v1/chat/completions` (7923); the DNS-rebinding guard without an API key (`parse_request` ~L7175; `STRATA_ALLOWED_HOSTS` read at 9667); `host_name()` strips the port + lowercases (http_api.py:145); nothing outside `terminal/` is imported (the image COPYs only `terminal/`).

## Charts (`verified-here`)

- **Engine**: `helm lint` clean; defaults render Service + hook only; the `203.0.113.10` variant adds the EndpointSlice (address quoted, port decoupled); kubeconform -strict clean on both.
- **Web**: `helm lint` clean; defaults render Service + Deployment + hook; `STRATA_ALLOWED_HOSTS` auto renders `rel-chudmax-web,rel-chudmax-web.default.svc,rel-chudmax-web.default.svc.cluster.local,localhost,127.0.0.1`; the custom variant (allowedHosts list + port 9090) flows verbatim; kubeconform -strict clean on both.
- **Umbrella**: `helm dependency build` saves 3 charts (the `file://` path is **two** ups — `../../chart/chudmax-mcp`; the first build failed until corrected); defaults render 2 Deployments, 2 NetworkPolicies (the mcp pair), 2 hook Pods, Role/RoleBinding/SA, 3 Services — no EndpointSlice, **no Cilium**; the variant adds the EndpointSlice; kubeconform -strict clean on both; `helm lint` clean.

## Images (`verified-here`)

- `ghcr.io/urmanac/chudmax/web:0.1.0` — built from the pinned Strata checkout, `python:3.12-slim` + runtime wheels only (262MB); non-root uid 65532.
- `ghcr.io/urmanac/chudmax/fetcher:0.1.0` (36.7MB) and `ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0` (51.2MB) — rebuilt from `k8s/image/Dockerfile` and `k8s/tickets-mcp/Dockerfile`.
- `podman save --format docker-archive` → `docker load` interop proven (the archive format `kind load image-archive` consumes; the rootless docker daemon and podman keep separate stores — the save/load step is required, not optional).

## The mock engine live (`verified-here`)

- `docker run … -e STRATA_ALLOWED_HOSTS="chudmax-engine,localhost,127.0.0.1" <web-image> --engine mock --host 0.0.0.0 --port 8080`:
  - `GET /health` → **200** (loopback Host);
  - `GET /health` with `Host: chudmax-engine:8080` (the short-name+port case an in-cluster hook actually sends) → **200**;
  - `GET /health` with `Host: evil.example` → **403** (the DNS-rebinding guard bites);
  - `GET /mcp` → **200**; `POST /v1/chat/completions` → the scripted turn: `"Hello from the mock engine."` (with `reasoning_content`).

## The kind constraint (`verified-here`)

- kind v0.33.0 cannot create a cluster in this sandbox: the docker daemon is rootless, PID 1 is `startup.sh` (no systemd), cgroup2 is mounted read-only — kind refuses verbatim: `failed to create cluster: running kind with rootless provider requires setting systemd property "Delegate=yes"`. No provider escape (podman rootless hits the same delegation requirement; a nested rootful dockerd cannot create cgroups under the ro mount). **The CI kind job (rootful ubuntu-latest runners, kind v0.33.0) is the authoritative receipt** — the phase-5 precedent applied verbatim.

## Pending in CI (`speculation` until the first green run; then `handoff-reported` from the checks page)

- The kind rehearsal's cluster-side steps: hooks (engine + web), the mcp receipts (release deployed; pod Running; server 200 initialize; the honest no-data body), **the fetcher-log assertion** (the apiserver 404 NotFound — with the adopted phase-5 `cidr`+6443 fallback ready if the pre-fix chart's 443-only apiserver rule blocks on kindnet's post-DNAT evaluation), the endpoint-route ladder (gateway-ip vs bridge-container-ip), the both-arches manifest build of the web image (arm64 under qemu).
- The LAN-address hygiene grep (no RFC1918-shaped address in any phase-6 artifact) runs in CI's chart job too.

## CI iteration history (`handoff-reported`, from the run summaries — the anonymous checks-page read-path)

Each red run's receipt was read from the **run-summary page** (the workflow's step-summary tail renders there server-side; the annotations dialog needs sign-in and the REST API rate-limits this sandbox's shared IP).

1. **bash brace expansion** ate `--set allowedHosts={a,b}` → quoted (`f3d45b3`).
2. **namespace timing** — probe pods targeted `chudmax` before helm created it → `kubectl create namespace` right after kind up (`47890ae`).
3. **`docker run` could not find the web image** — `kind load image-archive` loads the NODE's containerd store, not the host docker store → added `docker load -i` per archive, plus a 3-attempt `pbuild` retry for registry transients (`6177b80`, `e1db539`).
4. **IPv6 gateway** — `docker network inspect` returned the IPv6 IPAM gateway (`fc00:…`) → parse an IPv4-shaped gateway; endpoint ladder added (gateway → bridge-IP → host-network relaunch) (`76e6182`).
5. **RFC1918 literal** — the ladder's fallback default `172.18.0.1` tripped the workflow's LAN-hygiene grep (it covers scripts, not just manifests) → the script now dies with diagnostics instead of carrying a private-LAN fallback (`1e8a161`).
6. **THE HOST-GUARD MASK (partially real, then overtaken):** the ladder's IP-literal probes sent the IP as the Host header — Strata's DNS-rebinding guard 403s unknown Hosts (`6f16ae0` fixed the probes to carry `Host: chudmax-engine`). But the die REMAINED — see 7-8: the guard fix was necessary but not sufficient.
7. **stderr diagnostics (`e0d3796`)** — the ladder's miss lines had been swallowed by the command substitution around probe() (stdout of a $() call is captured, not printed); miss diagnostics moved to STDERR and try_endpoint passes the bare code back. Receipt now readable: **all four rungs returned `no-answer` (empty)** — impossible for curl (it prints 000 on refusal, 403/200 otherwise) → the probes never produced output at all.
8. **THE ATTACH RACE (the real root cause of every "unreachable" reading):** `kubectl run --rm -i` attaches a stream; a fast container (curl answers in milliseconds — refused, 403 or 200 alike) exits before the stream opens and its stdout is lost. Every probe read as empty INCLUDING SUCCESSES — the network was never blocked. Fix (`cfe9eca`): a `podcurl()` helper — create the pod (no -i), poll it to completion, read `kubectl logs` (logs never race), delete. The ladder probes and BOTH mcp receipts switched to it (the helm-test hooks were always immune: helm test checks the pod's exit code, and the fetcher assertion reads logs).
9. **THE LADDER PASSED (receipt, `cfe9eca`'s run):** `route won: docker-bridge gateway (pod → gateway-ip → host-side userland-proxy → the mock; Host: the Service name)` — the FIRST rung answered 200 once the probes could see. The rehearsal then died on a NEW false positive at step 6.
10. **THE CILIUM-COMMENT FALSE POSITIVE (`0fbee80`):** the no-Cilium assertion grepped the bare word — the read-only mcp chart's egress template carries "Cilium" inside explanatory YAML comments that render verbatim into `helm template` output, so a FULL (dependency-built) umbrella render trips it. Both the smoke's and the chart job's assertions now grep the CRD shape (`kind: CiliumNetworkPolicy` / `apiVersion: cilium.io/`). The chart job went green on the same fix.
11. **THE ALIAS-LABEL (`8aea5b4`):** helm renders `.Chart.Name` inside a subchart as the dependency ALIAS — the mcp pod carries `app.kubernetes.io/name: mcp`, not `chudmax-mcp`; a selector on the chart name matched nothing and the pod-wait timed out. The deterministic `chudmax-mcp`/`chudmax-web`/`chudmax-engine` NAMES come from `fullnameOverride` (which the aliases conveniently spell); LABELS do not — select by the alias label.
12. **THE SERVICE'S READY-GATE (`ee2e53a`):** a Service admits only READY pods; the fetcher sidecar's readiness probe (`test -e /data/current`) fails pre-artifact BY DESIGN (the honest no-data state), so the mcp Service has NO endpoints in the rehearsal — a Service-URL receipt curl is refused, and `curl -s` (errors silenced, no -w) prints NOTHING to stdout → empty pod logs. The receipts now curl the POD IP (admitted by the ingress policy's same-namespace `podSelector: {}`), record the Service's empty endpoint set as the honest receipt, and use `curl -sS` so the error line lands in the pod logs; a failure also tails the server container's logs.
13. **THE FETCHER'S RESYNC CADENCE (`5337fdf`):** a NetworkPolicy upgrade restarts nothing — the fetcher's next dial waits out its resync (1m0s receipted from its logs), so the override's 5-second check saw nothing. The override now admits BOTH addresses (the kubernetes Service VIP on 443 — what the in-cluster config dials, which no endpoint rule matches if kindnet evaluates pre-DNAT; the control-plane endpoint on 443+6443 — the post-DNAT match) and RESTARTS the deployment so the fetcher's first list fires immediately; the assertion polls patiently and tails the fetcher's logs on failure.
14. **THE MAPPING FIXTURE → GREEN (`a855778`):** the fetcher's own log receipt (`unable to retrieve the complete list of server APIs: source.toolkit.fluxcd.io/v1: no matches`) showed it REACHING the apiserver but failing at DISCOVERY — without the Flux CRDs, `controller-runtime`'s Get never reaches its `IsNotFound` path, and the asserted line can never print. The smoke applies a minimal, schemaless ExternalArtifact CRD right after kind up; the fetcher's Get then answers the apiserver's real 404 → the line → the assertion → **all 8 jobs green, the kind rehearsal exit 0 in 3m 22s.**
- **Meta-lesson for the CI loop:** the receipt-in-step-summary design makes every failure diagnosable from the anonymous web UI — keep the ladder's probe misses printed (403 vs 000 vs empty distinguishes guard/routing/probe-defect in one glance), and never trust a streaming-attached container's stdout (attach races lose it; logs don't).

## Cluster receipts from the CI runs (`handoff-reported`, from the run summaries — 2026-11-25)

These are REAL kind-cluster receipts now (no longer speculation), read from run 45724227062's summary (`ee2e53a`) and its predecessors:

- **CI IS GREEN (`a855778`, run 45726606235): all 8 jobs succeeded; the kind rehearsal exited 0 in 3m 22s.** The green exit itself proves the fetcher-404 line appeared (the script dies otherwise); the full receipt text rides in the step summary (readable signed-in at the run URL).
- **The engine hook (the card's "first test of any cluster") PASSED:** `helm test` succeeded — a pod reached `/health` through the selectorless engine Service → EndpointSlice → external host (the docker-bridge gateway route; `route won` recorded in the receipt).
- **The web hook PASSED** (Strata's `/health` through the web Service, with the allowedHosts default proving the guard).
- **The mcp receipts LANDED:** `initialize → 200` with `serverInfo` (the published canonical server answering on its port), and `list_tickets` returned the honest no-data body (`{"text": "no tickets found in /data/current"}`). The Service's endpoint set shows the pod under `notReadyAddresses` — the ready-gate receipt, recorded verbatim.
- **The fetcher-log assertion PASSED (green run):** the defaults' apiserver rule blocks on kindnet (receipted — the pre-phase-5 chart's 443-only selector rule matches neither the VIP (a podSelector can't match a Service IP) nor the post-DNAT 6443 port); the both-stages override (the kubernetes Service VIP on 443 as the cidr rule + the control-plane endpoint on 443/6443 as the extra) admitted it; the fetcher's first list after the restart answered the apiserver's 404.
- **The ExternalArtifact mapping fixture (receipted):** without a served mapping the fetcher's client fails at DISCOVERY (`unable to retrieve the complete list of server APIs: source.toolkit.fluxcd.io/v1: no matches` — receipted verbatim from the fetcher's logs) and `IsNotFound` never fires; the smoke ships a minimal, schemaless CRD right after kind up, and the fetcher's Get then answers the apiserver's real 404. No Flux controller is installed (phase 5's rehearsal owns the artifact flow).
- **Steps proven along the way:** the images load (host docker + kind node), the mock engine runs outside kind and answers, the ladder's gateway route wins, the install renders no Cilium objects, the pods wait (web Ready; mcp Running with the fetcher not-ready by design).

## Flow

- **Merge order (CoS addendum, 2026-11-25, `handoff-reported`):** phase 5 merges first; the phase-6 branch is then **rebased onto `main`** at the CoS's instruction for the final CI run (the `file://` mcp dep consumes the auto-gated 443+6443 apiserver fix on the rebased head); the CoS merges — phase 6 never merges its own PR, and holds even if CI is green while phase 5 is still open. The workbench staging (everything in `chudmax-mcp`, the split to the empty `urmanac/chudmax-engine`/`-web` repos deferred to phase 10) is owner-confirmed.
- **The write set held**: `k8s/umbrella/**` + `.github/workflows/umbrella-kind.yml` only (plus this task dir). Phase 5's files (`k8s/chart/chudmax-mcp/`, `k8s/tickets-mcp/`, `k8s/repo-sync/`, `k8s/rehearsal/`, `rehearsal-sync.yml`) and the root README untouched — `verified-here` (`git diff --name-only origin/main…HEAD`).
- The missing-LICENSE flag rides in the PR description (Strata's MIT noted for the image). No registry push; the box untouched; conventional commits throughout.
