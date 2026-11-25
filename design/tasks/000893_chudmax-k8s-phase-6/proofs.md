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

## Flow

- The write set held: `k8s/umbrella/**` + `.github/workflows/umbrella-kind.yml` only (plus this task dir). Phase 5's files (`k8s/chart/chudmax-mcp/`, `k8s/tickets-mcp/`, `k8s/repo-sync/`, `k8s/rehearsal/`, `rehearsal-sync.yml`) and the root README untouched — `verified-here` (`git diff --name-only origin/main…HEAD`).
- The missing-LICENSE flag rides in the PR description (Strata's MIT noted for the image). No registry push; the box untouched; conventional commits throughout.
