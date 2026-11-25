# Requirements: chudmax k8s phase 3 mcp image and chart

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 3 (`kubernetes/phases.md`): **the fetcher image for arm64 and amd64, plus a chart with the Deployment, the Role and the NetworkPolicies — built under podman first, `helm lint` and `helm template` pass, CI builds both architectures.** Revised by the CoS steering brief (2026-11-25): the card's original "fetcher sidecar + ticket server" wording predates the owner's re-home boundary — **the ticket server is bring-your-own; this repo does not ship one.** The installable bauble is therefore: a fetcher-only image, and a chart whose Deployment runs the fetcher sidecar with an **optional, values-driven second container for the user's own MCP server** (disabled by default, interface documented). The card's dependency on phase 1 (MR !18) dissolves with that boundary — the server's HTTP mode becomes the user's own concern.

Everything happens in the public repo `urmanac/chudmax-mcp` via the Helix proxy origin of the sandbox clone. Phase 2 is done and merged: `main` @ `cdf5095` carries the fetcher (`k8s/fetcher/`, module `github.com/urmanac/chudmax-mcp/k8s/fetcher`, GitHub Actions `fetcher-test.yml`, PR #1 merged — `verified-here`). The old GitLab repo stays out of scope. No registry push (ghcr.io is phase 10); local podman + CI build only. The box is untouched; nothing lands on `main` unreviewed.

## Preconditions (verified)

- [x] Phase 2 merged: the fetcher lives in `k8s/fetcher/` on public `main` @ `cdf5095` — `verified-here` (local clone, 2026-11-25).
- [x] CI on the public repo runs the `fetcher-test` workflow (vet, test, arm64 cross-build) — `verified-here` (`.github/workflows/fetcher-test.yml`).
- [x] The volume contract the chart documents is already written down: `k8s/fetcher/README.md` (revisions/, `current` symlink, `artifact.json` fields) — `verified-here`.

## User stories

1. **As a user installing the chart**, I get a pod whose fetcher sidecar keeps `/data/current` on the newest verified artifact, and I point it at my own MCP server — an optional values-driven second container reading the same volume — so my server answers from current data without git and without restarts.
2. **As the human**, I want the image built under podman first (both architectures, one manifest list) and smoke-tested in this sandbox, so the both-arches rule is proven locally before CI or any cluster depends on it.
3. **As the human**, I want a chart that manifests the Deployment (fetcher sidecar + optional server container), the namespaced Role (`get`, `watch` on the one ExternalArtifact) and the NetworkPolicies admitting the sidecar to source-controller (and DNS/apiserver) only, so the pod's wiring is reviewable and installable as one unit.
4. **As CI**, I want jobs that lint/template the chart and build the image for both architectures (no push), so every push re-proves the parts without a cluster or a registry.
5. **As the human**, I want the box untouched, nothing on `main` unreviewed, the three labels on every claim, and the LICENSE decision left deferred but flagged.

## Acceptance criteria

- [ ] One OCI image builds as a manifest list for `linux/amd64` and `linux/arm64` under podman in this sandbox; it contains **only the fetcher** (built from `k8s/fetcher/` on the branch), runs as non-root, and carries no ticket server and no private-repo material — no bundle, no lock file, no private-repo token in CI.
- [ ] Podman smoke test in-sandbox: the amd64 image runs and the fetcher `fetch`es a tarball over HTTP from a local server, swapping `current` and writing `artifact.json` per the volume contract (required); an arm64 `podman run` under qemu is best-effort and recorded honestly if skipped.
- [ ] Chart at `k8s/chart/chudmax-mcp/` (apiVersion v2) with: Deployment (fetcher `watch` container — namespace via Downward API, ExternalArtifact name from values — plus the optional server container from values: user image/command/args/env/port, disabled by default, shared `emptyDir` volume mounted in both), ServiceAccount, Role (namespaced, `source.toolkit.fluxcd.io` `externalartifacts`, verbs `get`+`watch`, `resourceNames` pinned to the one artifact), RoleBinding, a Service rendered only when the optional server is enabled, and NetworkPolicies (egress default-on: DNS 53, kube-apiserver 443, source-controller artifact port — values-gated with extra-egress passthrough; ingress only with the server, with extra-ingress passthrough).
- [ ] The optional server container does not automount the ServiceAccount token by default (knob provided); the interface contract users code against is documented by pointer to `k8s/fetcher/README.md` (reread per call through the `current` symlink).
- [ ] `helm lint` passes; `helm template` renders with default values (server disabled) and with a custom variant (server enabled, custom ExternalArtifact name/port); both proofs run locally and in CI.
- [ ] CI: a workflow adds a chart job (lint + template) and an image job (podman, both architectures, no registry push; qemu arm64 smoke best-effort); the existing `fetcher-test` workflow stays green.
- [ ] The repo README's "Bring your own MCP server" section is extended (not replaced): how to enable the optional container with example values, the volume-contract pointer, the note that the chart needs the ExternalArtifact to exist (phase 4), and the note that the default image tag is unpublished until phase 10.
- [ ] The box is untouched; nothing compiled on the box; work lands via PR to `main` only; the three-labels rule applies to all claims; **the repo's missing LICENSE is flagged in the PR description (decision deferred to the owner — no LICENSE file added in this phase).**

## Out of scope (owned by other phases or decisions)

- The `k8s/repo-sync/` manifests and the ExternalArtifact itself (the chart only needs its name); the "smallest Role" final answer — phase 4.
- Live cluster rehearsal (real field-selector watch, real RBAC/NetworkPolicy behavior) — phase 5, kind in CI.
- Pushing/publishing images (ghcr.io, cosign, credential-free pull) — phase 10. Engine/web/Hermes charts, umbrella, canary — phases 6–9. Placement — phases 11–14.
- The bundled ticket server idea from the original card text — superseded by the owner's bring-your-own boundary (recorded in `design.md`).
- LICENSE choice — deferred by the owner; flagged, not decided here.

## Open Questions

1. None on packaging — the steering brief settles the shape (fetcher-only image + optional values-driven server container). The one flagged item: **LICENSE** — the repo ships none; choosing one is the owner's deferred decision, flagged in the PR so it is not silently lost.
