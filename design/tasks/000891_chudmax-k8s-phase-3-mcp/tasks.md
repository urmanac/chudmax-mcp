# Implementation Tasks: chudmax k8s phase 3 mcp image and chart

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

- [ ] Create a feature branch off public `main` (`cdf5095`); conventional commits; nothing merges unreviewed; existing `fetcher-test` CI must stay green
- [ ] Resolve Open Question 1 (bundle mechanism) with the human before the Dockerfile: pinned build-time fetch vs vendoring `ticket_mcp.py` now
- [ ] `k8s/image/bundle.lock`: pin the private repo's `tools/mcp/ticket_mcp.py` (commit SHA + sha256); confirm the server's pod-mode CLI flags and dependency story (Open Questions 2–3) from the private `main` while the bundle is pinned
- [ ] `k8s/image/Dockerfile`: multi-stage — golang builder with `CGO_ENABLED=0`, `GOOS=$TARGETOS`, `GOARCH=$TARGETARCH` building `k8s/fetcher`; final stage `python:3.12-slim`, non-root user, fetcher + bundled server installed, no stray packages
- [ ] Podman-first proof (this sandbox): `podman build --platform linux/amd64,linux/arm64 --manifest` succeeds; `podman run` smoke — fetcher `fetch` swaps `current` against a local tarball server, bundled server answers one HTTP POST in `--http` mode; arm64 run under emulation best-effort (record honestly if skipped)
- [ ] Chart scaffold `k8s/chart/chudmax-mcp/`: Chart.yaml (apiVersion v2, `0.1.0`), values.yaml (image, `externalArtifact.name`, server port, volume size, network-policy targets), `_helpers.tpl`, NOTES.txt
- [ ] Templates: ServiceAccount; Role (`source.toolkit.fluxcd.io` `externalartifacts`, `get`+`watch`, `resourceNames` pinned); RoleBinding; Deployment (fetcher `watch` container with Downward-API namespace + token, server `--http` container with token mount off, shared `emptyDir` `/data`, honest probes — tcpSocket for the server); Service (values-gated); NetworkPolicy egress (DNS 53, apiserver 443, source-controller artifact port) and ingress (server port, narrow sources)
- [ ] `helm lint` passes; `helm template` renders with defaults and with a custom ExternalArtifact name/port/extra-namespace values — record both outputs in the proof
- [ ] CI `.github/workflows/image-chart.yml`: chart job (lint + template) and image job (build both architectures, no push); decide the CI bundle-fetch token story per Open Question 1
- [ ] Update the repo README: replace the "Bring your own MCP server" paragraph with the bundled-server default + override knob; add the chart install snippet and the phase-4 dependency note (chart needs the ExternalArtifact to exist)
- [ ] Record the proof in this task directory (helix-specs): podman build/run results, helm lint/template outputs, CI runs green, three labels applied
- [ ] Open the PR; do not merge (the human reviews)
