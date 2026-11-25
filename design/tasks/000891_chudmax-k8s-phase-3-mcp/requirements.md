# Requirements: chudmax k8s phase 3 mcp image and chart

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 3 (`kubernetes/phases.md`): **one image for arm64 and amd64 — the fetcher sidecar plus the ticket server (the server's HTTP mode from MR !18) — and a Helm chart with the Deployment, the Role and the NetworkPolicies.** Built under podman first; `helm lint` and `helm template` pass; CI builds both architectures. It is the join point of the "make the parts" half: phase 1 delivered the server's HTTP + pod mode (MR !18, merged), phase 2 delivered the fetcher (on `main` @ `cdf5095`); phase 3 packages both into the one pod image and manifests the pod wiring. No cluster, no publishing (phase 10), no `k8s/repo-sync/` objects (phase 4).

Work lands in the public repo `urmanac/chudmax-mcp` (the packaging home per the re-home directive): the image build, the chart, and the CI jobs. The box is untouched; nothing lands on `main` unreviewed.

## Preconditions (verified)

- [x] Phase 1 (MR !18) merged: `ticket_mcp.py` has `--http` mode and pod mode — verified in `design/tasks/000888_fetch-mr-17/design.md` (2026-11-25).
- [x] Phase 2 (MR !19, re-homed) merged: the fetcher lives in `k8s/fetcher/` on public `main` @ `cdf5095` — `verified-here` (local clone, 2026-11-25).
- [x] CI on the public repo runs the `fetcher-test` workflow (vet, test, arm64 cross-build) — `verified-here` (`.github/workflows/fetcher-test.yml`).

## User stories

1. **As the mcp pod**, I want one image that carries both the fetcher and the ticket server, so one build, one digest and one SecurityContext cover the whole pod — the fetcher keeps `/data/current` fresh, the server answers HTTP from it, and nothing restarts on an artifact change.
2. **As the human**, I want the image built under podman first (both architectures, one manifest list), so the both-arches rule is proven locally before CI or any cluster depends on it.
3. **As the human**, I want a chart that manifests the Deployment, the namespaced Role (`get`, `watch` on the one ExternalArtifact) and the NetworkPolicies, so the pod's wiring is reviewable and installable as one unit.
4. **As CI**, I want jobs that lint/template the chart and build the image for both architectures, so every push re-proves the parts without a cluster or a registry push.
5. **As a future installer** (phases 11+), I want `helm install` to produce a working pod shape — ServiceAccount, Role, RoleBinding, Service, NetworkPolicies — so placement phases only have to point at it.

## Acceptance criteria

- [ ] One OCI image builds for `linux/amd64` and `linux/arm64` from a single manifest list, under podman on this sandbox — no emulation needed for the build itself (Go cross-compiles per `TARGETARCH`; the Python runtime layer is arch-independent).
- [ ] The image contains: the fetcher binary (built from `k8s/fetcher/` on the branch), the ticket server (`ticket_mcp.py` from the private repo, pinned commit + sha256 checked at build time against a committed lock file — the build-time bundle from the re-home boundary), and a Python 3 slim runtime; runs as non-root; the server runs with its HTTP mode from MR !18.
- [ ] Podman smoke test: the image runs; the fetcher fetches a tarball over HTTP and swaps `current`; the bundled server answers at least one HTTP request in `--http` mode (amd64 required; arm64 run under emulation best-effort, recorded honestly if skipped).
- [ ] Chart at `k8s/chart/chudmax-mcp/` (apiVersion v2) with: Deployment (two containers from the one image — `fetcher watch` and the server in HTTP mode — sharing one `emptyDir` volume at `/data`; server port and ExternalArtifact name from values), ServiceAccount, Role (namespaced, `source.toolkit.fluxcd.io` `externalartifacts`, verbs `get`+`watch`, `resourceNames` pinned to the one artifact), RoleBinding, a Service for the server's HTTP port, and NetworkPolicies (egress: DNS + source-controller artifact port + kube-apiserver 443; ingress: server port from narrowly selected sources).
- [ ] `helm lint` passes; `helm template` renders with default values and with a custom ExternalArtifact name/port; both proofs run locally and in CI.
- [ ] CI: a workflow adds a chart job (lint + template) and an image job (build both architectures, no push — publishing is phase 10); existing `fetcher-test` stays green.
- [ ] The repo README's "Bring your own MCP server" section is updated: the image bundles the server by default, with a values knob to override the server command (the fetcher still keeps the files current either way).
- [ ] The box is untouched; nothing compiled on the box; work lands via PR to `main` only; the three-labels rule applies to all claims.

## Out of scope (owned by other phases)

- The `k8s/repo-sync/` manifests and the ExternalArtifact itself (chart only needs its name) — phase 4. The "smallest Role" final answer revisits this Role then.
- Live cluster rehearsal (real field-selector watch, real RBAC) — phase 5, kind in CI.
- Pushing/publishing images (ghcr.io, cosign, credential-free pull) and the repos handoff — phase 10.
- Engine/web/Hermes charts, umbrella, canary — phases 6–9. Placement (Gateway, MetalLB, cutover) — phases 11–14.

## Open Questions

1. **Ticket-server bundle mechanism (the one real decision):** the re-home boundary says the ticket MCP enters as a "pinned, digest-checked build-time bundle until it moves in". My plan: the image build fetches `tools/mcp/ticket_mcp.py` from the private repo at a pinned commit and checks its sha256 against a committed lock file (`k8s/image/bundle.lock`). Local podman builds use the session's private-repo access; CI needs a read-only token stored as a GitHub secret. Alternatives: (a) vendor `ticket_mcp.py` into the public repo now ("moves in" early — simplest, no secrets, but the server still evolves in the private repo so a sync step appears), or (b) CI builds a fetcher-only image and the bundled build stays local-only (weakest — violates "CI builds both architectures" for the real image). Which do you want?
2. **Server dependencies:** I assume `ticket_mcp.py` is Python stdlib-only (the private repo runs it with bare `python3`). If it has pip dependencies, the image pins and installs them — confirm either way if known.
3. **Server pod-mode CLI:** phase 1 added `--http` plus pod mode (`--revision` / `--artifact-produced` / `--artifact-unpacked`), and the fetcher README says the server reads `<root>/current/artifact.json` per call. I cannot read the private repo from this session, so the exact flags the chart passes get confirmed from `tools/mcp/ticket_mcp.py` on the private `main` at implementation time — the chart command template is written to be adjusted. Sound?
4. **A Service beyond the card's literal list:** the card names Deployment, Role, NetworkPolicies. A chart exposing an HTTP server is unusable without a Service (phase 11's pointer Service also needs something to point at), so I add one (values-gated, on by default). Acceptable, or strictly card-literal?
