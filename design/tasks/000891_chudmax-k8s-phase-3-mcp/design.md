# Design: chudmax k8s phase 3 mcp image and chart

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 3 packages the fetcher (phase 2, merged on public `main` @ `cdf5095`) into the pod's image and manifests the pod wiring. It adds no new logic: the fetcher already keeps `/data/current` fresh, and the consumer reads through the symlink per call. **Steering revision (CoS brief, 2026-11-25):** the card's "fetcher sidecar + ticket server" wording predates the owner's boundary — the ticket server is bring-your-own and this repo ships none. The first draft of this spec proposed a pinned, digest-checked build-time bundle of the private server; that mechanism is dropped entirely (no bundle, no lock file, no private-repo token in CI). Requirements in `requirements.md` here; the phase-3 row and cross-cutting rules live in `kubernetes/phases.md` on the private source-of-truth repo's `main` (source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row C).

## Shape

```
 pod (chart)                        image: chudmax mcp fetcher (amd64 + arm64 manifest list)
 ┌─────────────────────────────┐   ┌──────────────────────────────┐
 │ Deployment                  │   │ fetcher (Go, CGO off)        │
 │  c1: fetcher watch ─────────┼──►│  GET/watch the ONE External- │
 │  c2 (optional, values-      │   │  Artifact; GET the tarball   │
 │      driven: user's own     │   │  from source-controller;     │
 │      MCP server, disabled   │   │  verify, unpack, swap        │
 │      by default) ───────────┼──►│  (only c1 uses this image)   │
 │  shared emptyDir  /data     │   └──────────────────────────────┘
 └──────────────┬──────────────┘        │                 ▲
                │        revisions/<hex>/ + current symlink + artifact.json
                │        (the volume contract, k8s/fetcher/README.md)
                ▼                                │
   Service :<port> — rendered only when c2 is enabled; consumers reach the user's server
        ▲                                        │
        │                    GET/watch ExternalArtifact (apiserver 443)
        │                    GET artifact tarball (source-controller :<port>)
 ┌──────┴───────────────────────────────────────┴──────────┐
 │ NetworkPolicies: egress = DNS 53 + apiserver 443 +      │
 │ source-controller artifact port (default-on); ingress = │
 │ server port, only when c2 is enabled                    │
 └─────────────────────────────────────────────────────────┘
```

The chart does **not** create the ExternalArtifact (phase 4 owns it). Until phase 4's objects exist, the fetcher's startup `Get` fails and the process exits (`verified-here` from `watch.go`/`main.go`: startup-`Get` error → `runWatch` returns → `log.Fatal`) — the container crash-loops with restart backoff until the artifact appears, then self-heals via the startup read. Honest for a parts-phase install; noted in the chart's NOTES.txt.

## Repo layout (public repo)

```
k8s/fetcher/                       (exists, phase 2 — untouched)
k8s/image/Dockerfile               multi-stage: golang builder (CGO_ENABLED=0,
                                   GOOS/GOARCH from TARGETOS/TARGETARCH) → alpine,
                                   non-root user; fetcher only
k8s/chart/chudmax-mcp/             Chart.yaml (v2, 0.1.0), values.yaml, templates/
                                   (sa, role, rolebinding, deployment, service,
                                   networkpolicy-egress, networkpolicy-ingress,
                                   _helpers, NOTES.txt)
.github/workflows/image-chart.yml  chart: helm lint + helm template;
                                   image: podman manifest-list build, both arches, no push
```

## Key decisions

1. **Fetcher-only image (bring-your-own server).** The owner's re-home boundary, confirmed by the CoS steering brief, supersedes the card's bundled-server wording. The image contains the fetcher and nothing else; the phase-1 dependency dissolves (the HTTP-mode server is the user's own). No private-repo material enters the public repo or the image.
2. **Optional values-driven server container.** `server.enabled: false` by default; when enabled, the user supplies `image`, `command`, `args`, `env`, `port`, `resources`; the chart mounts the shared volume into it and renders the Service + ingress policy. Token automount off for that container by default (knob provided); a user's server needing its own RBAC adds its own — documented, not built. The interface users code against is the volume contract in `k8s/fetcher/README.md`, restated nowhere else (pointer, not copy — one source of truth).
3. **Base image: alpine, non-root.** Multi-arch official base, tiny, and it has a shell — which the fetcher's `exec` readiness probe (`test -e /data/current`) and smoke tests want; `distroless/static:nonroot` is the tighter alternative and was rejected on the shell point. Swap-able detail (`speculation`-labeled taste call, flagged in the PR).
4. **Podman first — and podman in CI too.** Local proof: `podman build --platform linux/amd64,linux/arm64 --manifest <name>:<tag>` plus `podman run` smoke (amd64 required: fetch → `current` swap + `artifact.json`; arm64 under qemu best-effort). CI mirrors the same toolchain (podman on `ubuntu-latest`; qemu-user-static only for the optional arm64 smoke run) with Docker buildx recorded as the fallback if podman-in-Actions frictions out. Because the fetcher is pure Go with `CGO_ENABLED=0`, the per-arch stage cross-compiles and **the build itself needs no emulation**.
5. **One shared `emptyDir` volume.** The tree is fully regenerated from the Flux artifact on pod start (the fetcher's startup GET), so nothing needs persistence; size limit from values. Persistence questions belong to placement, not here.
6. **Role exactly as phase 2 prescribed:** namespaced Role on `source.toolkit.fluxcd.io/externalartifacts`, verbs `get`+`watch`, `resourceNames` pinned to the one artifact, bound to a chart-created ServiceAccount; only the fetcher container mounts the token. Phase 4 may revisit for the "smallest Role" answer.
7. **NetworkPolicies, pod-level, values-gated.** Egress policy default-on (it is the sidecar's promise): DNS to kube-system (UDP/TCP 53), TCP 443 to the cluster's service CIDR (the fetcher's controller-runtime client watches the **kube-apiserver** — the easy-to-miss rule), and TCP to source-controller's artifact port (namespace + port from values, defaults commented to match the phase-12 platform inventory). Plus `extraEgress` passthrough. Ingress policy rendered only when the server container is enabled: TCP to the server port from the release namespace + `extraIngress` passthrough. Caveat documented in values comments: NetworkPolicy podSelectors hit **all** containers in the pod — a user's server with other egress needs adjusts the passthroughs or disables the policies (knob provided).
8. **Service only with the server.** The card's literal list (Deployment, Role, NetworkPolicies) stands for the default install; the Service renders only when `server.enabled=true` — nothing points at a disabled pod.
9. **Probes:** fetcher container gets an `exec` readiness probe on `/data/current` existence (shell exists on alpine) and no liveness probe beyond Kubernetes' default process checks; the optional server container ships no probes by default (the user knows their server).
10. **Chart default image tag is unpublished** (`ghcr.io/urmanac/chudmax/mcp:0.1.0`): publishing is phase 10; until then NOTES.txt says to build/load the image yourself. `helm template` does not pull, so lint/template proofs are unaffected.

## Notes for future agents (learnings)

- Fetcher facts for the Dockerfile and chart: module `github.com/urmanac/chudmax-mcp/k8s/fetcher`, Go 1.27; `watch --namespace --name --root [--resync]` (startup `Get` failure is fatal to the process — CrashLoop-with-backoff is the designed pre-phase-4 state); `fetch --url --digest --root`. The namespace can come from the Downward API.
- The artifact URL in `status.artifact.url` points at source-controller's HTTP endpoint; the fetcher's egress must admit **both** that port and the kube-apiserver (watch stream). Forgetting the apiserver rule is the classic way a default-deny egress policy breaks a Flux consumer.
- fluxcd pins `go-digest` at the BLAKE3 pseudo-version (phase-2 gotcha) — the image's Go build inherits it via `k8s/fetcher/go.mod`; nothing extra in Docker. The Go build stage needs `go.mod`/`go.sum` copied before sources for layer caching.
- Docs rule (owner-confirmed): the public `helix-specs` branch is a fast-forward-only public record — never reset/force-push/delete public branches (they do not propagate through the proxy and only diverge the mirror); no LAN addresses, credential names/scopes/expiry, or internal proxy hostnames in public docs; design reasoning and contracts are welcome.
- PR flow (owner's standing delegation, 2026-11-25): PRs are proposed freely via `propose_pull_request`, no approval wait; merge authority is the CoS/owner; CI green + in-sandbox verification before anyone merges; the task is not complete until the PR is merged.
- Phase-2 precedent for labels: what this sandbox ran is `verified-here`; the steering brief's decisions are `handoff-reported` from the CoS; toolchain behavior not yet exercised (podman manifest builds in Actions, qemu arm64 smoke) stays `speculation` until run.

## Implementation notes (2026-11-25, sandbox)

- Toolchain installed in the sandbox: podman 5.4.2 (rootless, subuid/subgid present), helm 3.16.4 (`apt` has no helm package — installed from the get.helm.sh tarball), skopeo 1.18, qemu-user-static. **binfmt_misc mount is denied in this sandbox** — arm64 *containers* cannot run here at all.
- The Dockerfile ended **fully emulation-free** (better than the design's first claim): both the Go builder and a `users` stage are pinned to `--platform=$BUILDPLATFORM`; the final stage has no RUN at all (the nonroot user arrives as generated /etc/passwd + /etc/group COPY-ed from the same alpine:3.21 base, so no drift). Every RUN inside a `--platform a,b` manifest build otherwise executes target-arch binaries and wants qemu — the two-stage pin removes all of that. Correcting the design's "no emulation needed" note: true only *because* of the pin, not automatic.
- Podman quirks worth keeping: alpine 3.21's busybox has **no `httpd` applet** (in-container HTTP server needs another way); rootless pasta refuses container→host via the bridge gateway (10.89.0.1 connection refused) — smoke against a host-side server with `--network host` + host loopback; `podman create --platform linux/arm64 <manifest-list>` does **not** resolve the arm64 instance (it ran the amd64 binary); `podman save`/`manifest push` to an `oci:` dir write the full list as one blob whose top-level index lacks platform entries — the per-instance manifests (with correct platforms) live inside that blob; `skopeo copy --override-arch` failed to locate the instance manifest in podman 5.4's storage (naming quirk) — the oci-dir push route worked instead.
- **Arm64 runtime proof: done, not skipped.** The arm64 instance's config says `architecture: arm64`; its layer's `usr/local/bin/fetcher` is `ELF 64-bit LSB executable, ARM aarch64, statically linked`; executed host-side under `qemu-aarch64`: usage + exit 2 without args, and a **full fetch against the live tarball server → `swapped=true` + `artifact.json`**. amd64 proof in-container: fetch → swap, second run `swapped=false` (no-op), `current -> revisions/<hex>` relative symlink + artifact.json, all owned by uid 65532 — exactly the volume contract in `k8s/fetcher/README.md`.

## Proof (all `verified-here`, this sandbox, 2026-11-25)

- **Image:** `podman build --platform linux/amd64,linux/arm64 --manifest localhost/chudmax-mcp-fetcher:0.1.0 -f k8s/image/Dockerfile k8s` — succeeds; `podman manifest inspect` lists both instances; arm64 instance config `architecture: arm64`; its layer's fetcher is an ARM aarch64 static ELF (the extraction walk is recorded above).
- **amd64 smoke:** fetch → `swapped=true`; second run same digest → `swapped=false`; volume shows `current -> revisions/b3117ab5…` (relative symlink) and `artifact.json` (url, digest, unpacked, source=flag), all owned by uid 65532.
- **arm64 smoke:** `qemu-aarch64 <extracted fetcher>` with no args → usage, exit 2; with `fetch --url … --digest … --root …` → `swapped=true` and `artifact.json` written — a full functional run of the arm64 binary, no binfmt needed (host-level qemu exec).
- **Chart:** `helm lint k8s/chart/chudmax-mcp` → **0 charts failed** (only the cosmetic "icon is recommended"). `helm template rel …` (defaults): ServiceAccount, Role, RoleBinding, Deployment, egress NetworkPolicy — and **no Service and no ingress policy** (server disabled), matching the design. Custom variant (`--set server.enabled=true --set server.image.repository=example.com/my-server --set server.image.tag=1.0 --set server.command[0]=/bin/my-server --set externalArtifact.name=my-artifact --set server.port=9090`): additionally renders the ingress NetworkPolicy and the Service on 9090; Role `resourceNames: ["my-artifact"]`; server container `automountServiceAccountToken: false`, both containers mount `/data`.
- **CI:** `.github/workflows/image-chart.yml` (chart job: lint + both template variants; image job: podman manifest build both arches, instance verification, amd64 fetch smoke) — syntax-checked locally; its greenness on the runner is `speculation` until the PR's first CI run. The existing `fetcher-test` workflow is untouched (the fetcher source is untouched).
- **Hygiene:** no private-repo material anywhere in the repo or image (no bundle, no lock file, no token in CI); nothing pushed to any registry; the box untouched throughout.

## What this settles

- The pod exists as an installable unit: fetcher-only image (both arches), chart (wiring + documented optional server), CI (re-proof). Nothing is placed anywhere: no cluster touched, no registry push, no box change — the phase where the part becomes installable by someone else.
- What stays `speculation`: podman multi-platform manifest builds in Actions; qemu arm64 smoke reliability; real-API-server watch and real RBAC/NetworkPolicy behavior (phase 5); the narrowed artifact's tarball layout (phase 4); source-controller port/namespace on the real platform (phase 12); publishing/signing (phase 10).
