# Design: chudmax k8s phase 3 mcp image and chart

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 3 packages what phases 1 and 2 made into the pod's one image and manifests the pod wiring. It adds no new logic: the fetcher already keeps `/data/current` fresh and the server already reads through the symlink per call, so the pod is two containers from one image over one shared volume. Requirements in `requirements.md` here; the phase-3 row and cross-cutting rules live in `kubernetes/phases.md` on the private repo's `main` (source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE table row C). All decisions below assume the public repo `urmanac/chudmax-mcp` as the work site.

## Shape

```
                      one image: ghcr.io/urmanac/chudmax/mcp:<tag>   (arm64 + amd64 manifest list)
                      ┌──────────────────────────────────────────────┐
 pod (chart)          │  fetcher (Go, CGO off)   ticket_mcp.py (py3) │
 ┌──────────────────┐ │  watch mode              --http mode          │
 │ Deployment       │ │  Role: get,watch on      reads /data/current  │
 │  c1: fetcher ────┼─►  the ONE ExternalArt.  per call, answers   │
 │  c2: server  ────┼─►                          HTTP POSTs :8080   │
 │  shared emptyDir │ └──────────────────────────────────────────────┘
 │   /data          │        │                    ▲
 └──────────────────┘        │                    │ Service :8080 (values-gated)
        ▲                    ▼                    │
        │             GET/watch ExternalArt.  consumers (later phases:
        │             GET artifact tarball     engine via pointer Service,
        │             from source-controller   Gateway/MetalLB at 13/14)
        │                    │
 ┌──────┴────────────────────┴───────────┐
 │ NetworkPolicies: egress = DNS 53,     │
 │ kube-apiserver 443, source-controller │
 │ artifact port; ingress = server port  │
 └───────────────────────────────────────┘
```

The chart does **not** create the ExternalArtifact (phase 4 owns it); the Deployment only needs its name from values. Until phase 4's objects exist the fetcher sidecar retries its startup read — that is the "parts, not placement" state by design.

## Repo layout (public repo)

```
k8s/fetcher/            (exists, phase 2 — untouched)
k8s/image/Dockerfile    multi-stage: golang builder (CGO_ENABLED=0, GOARCH=$TARGETARCH)
                        → python:3.12-slim; fetcher + bundle + /data volume user
k8s/image/bundle.lock   pinned ticket-server commit SHA + sha256 of ticket_mcp.py
k8s/chart/chudmax-mcp/  Chart.yaml, values.yaml, templates/ (sa, role, rolebinding,
                        deployment, service, networkpolicy-egress, networkpolicy-ingress,
                        _helpers, NOTES.txt)
.github/workflows/image-chart.yml   chart: helm lint + helm template;
                                    image: build --platform linux/amd64,linux/arm64 (no push)
```

## Key decisions

1. **One image, two containers, one shared `emptyDir`.** The card says one image for both components. Two containers from the same image (different `command`) keeps one build/digest/security-context, lets Kubernetes restart or probe them independently, and avoids a supervisor process. The volume is `emptyDir` with a size limit: the tree is fully regenerated from the Flux artifact on pod start (fetcher's startup GET), so nothing needs persistence — persistence questions belong to placement, not here.
2. **Bundle mechanism (pending the Open Question):** per the re-home boundary the ticket MCP enters as a pinned, digest-checked build-time bundle. `k8s/image/bundle.lock` carries the private-repo commit SHA and the sha256 of `tools/mcp/ticket_mcp.py`; the build fetches that exact blob and fails loudly on mismatch. The public repo never carries the server source; the image does (accepted by design — phase 10 publishes the ticket server as a credential-free-pullable image, and it contains no data, only code). Fallback if a CI token on the public repo is unwanted: vendor the file now and delete the lock file.
3. **Podman first, buildx in CI.** The developer proof is `podman build --platform linux/amd64,linux/arm64 --manifest <name>:<tag>` on this sandbox plus a `podman run` smoke of both binaries. CI uses Docker buildx (preinstalled on `ubuntu-latest`, standard `setup-buildx` action) for the same platforms. Because the fetcher is pure Go with `CGO_ENABLED=0`, the per-arch stage cross-compiles and **no QEMU emulation is needed at build time** — only `podman run` of the arm64 image needs binfmt, which stays best-effort.
4. **Minimal image, non-root.** Final stage `python:3.12-slim` (multi-arch official base), stdlib-only server assumed (Open Question 2), non-root `USER`, no package installs if deps stay empty. The fetcher's tunables keep their phase-2 defaults; only `--resync` and the ExternalArtifact name are chart values.
5. **Role exactly as phase 2 prescribed:** namespaced Role on `source.toolkit.fluxcd.io/externalartifacts`, verbs `get`+`watch`, `resourceNames` pinned to the one artifact, bound to a chart-created ServiceAccount. Only the fetcher container mounts the token; the server container sets `automountServiceAccountToken: false`. Phase 4 may widen this to the "smallest Role" answer (its `list` question).
6. **NetworkPolicies, three directions in two objects.** Egress (policy type `Egress` on the pod): DNS to kube-system (UDP/TCP 53), TCP 443 to the cluster's service CIDR (the fetcher's controller-runtime client watches the **kube-apiserver** — an easy-to-miss rule), and TCP to source-controller's artifact port in `flux-system` (namespace + port from values, defaults commented to match the platform inventory in phase 12). Ingress (policy type `Ingress` on the pod): TCP to the server port from the release namespace plus values-listed extra namespaces. The card's "admit the sidecar to source-controller only" is honored by the egress policy; kubelet probes are node-originated and unaffected in the common CNIs (noted, not engineered around).
7. **A Service is added** (values-gated, on by default) beyond the card's literal list: the server's HTTP mode is unreachable without one, and phase 11's pointer Service needs a target. Small, harmless, flagged in the PR for review.
8. **Probes kept honest:** server container gets a `tcpSocket` probe on its port (the HTTP mode is POST-only and returns 405 to GET, which Kubernetes would read as a failure — so no `httpGet`); fetcher container gets an `exec` probe on `/data/current` existence once the first artifact lands. Liveness stays process-level on both.
9. **Chart defaults reference an unpublished image tag** (`ghcr.io/urmanac/chudmax/mcp:0.1.0`) — publishing is phase 10; until then the tag exists only in local podman and CI caches. `helm template` does not pull, so lint/template proofs are unaffected.

## Notes for future agents (learnings)

- The public repo's README currently says "This repo does not ship a ticket server" — phase 3 supersedes that paragraph (bundle default + override knob); update it in the same PR.
- Fetcher facts for the Dockerfile: module `github.com/urmanac/chudmax-mcp/k8s/fetcher`, Go 1.27, flags `watch --namespace --name --root [--resync]`; `fetch --url --digest --root`. The namespace can come from the Downward API (`metadata.namespace`).
- The artifact URL in `status.artifact.url` points at source-controller's HTTP endpoint; the fetcher's egress must admit **both** that port and the kube-apiserver (watch stream). Forgetting the apiserver rule is the classic way a default-deny egress policy breaks a Flux consumer.
- fluxcd pins `go-digest` at the BLAKE3 pseudo-version (phase-2 gotcha) — the image's Go build inherits it via `k8s/fetcher/go.mod`; nothing extra to do in Docker.
- The Go build in Docker needs the whole `k8s/fetcher/` directory (go.mod/go.sum copied first for layer caching, then sources).
- Phase-2 precedent for proof labels: everything checked in this sandbox is `verified-here` once run; bundle SHA/digest is `handoff-reported` from the private repo until the build verifies it; real-cluster RBAC/network behavior stays `speculation` until phase 5.

## What this settles

- The pod exists as a unit: image (both arches), chart (wiring), CI (re-proof). Nothing is placed anywhere: no cluster touched, no registry push, no box change — the first phase where the parts become installable.
- What stays `speculation`: real-API-server field-selector watch and real RBAC (phase 5), the narrowed artifact's tarball layout (phase 4), source-controller port/namespace on the real platform (phase 12 inventory), publishing/signing (phase 10).
