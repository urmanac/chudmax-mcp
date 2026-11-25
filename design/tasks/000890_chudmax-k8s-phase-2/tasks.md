# Implementation Tasks: chudmax k8s phase 2 fetcher sidecar

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

- [ ] Branch `feat/t0039-fetcher-sidecar` off `main` — the MR creates the phase-2 ticket in `tickets.md`; next free number after T-0038 is assumed (adjust branch name if it differs); conventional commits; selftest must stay 19/19
- [ ] Scaffold `k8s/fetcher/` Go module pinning `fluxcd/pkg/http/fetch@v0.32.0`, `fluxcd/pkg/tar@v1.4.0`, `source-controller/api@v1.10.2`, and the go-digest pseudo-version `v1.0.1-0.20220411205349-bde1400a84be` (BLAKE3 pin — spike-verified gotcha)
- [ ] Core: `fetch` one-shot mode — download via ArchiveFetcher, verify `sha256:` digest, unpack to `<root>/revisions/<digest-hex>/`, write `artifact.json` (url, revision, digest, produced, unpacked-at) into the dir, atomic symlink swap (`symlink` + `rename`) to `<root>/current`; same-digest no-op; retention keeps last 3
- [ ] Watch mode: get the named ExternalArtifact at startup (self-heal after restart), watch it (field selector `metadata.name=<name>`), 1-minute resync fallback, feed observed changes to the core
- [ ] Tests: tarball fixture over httptest — happy path, digest mismatch (previous tree untouched), second-revision swap, same-digest no-op, retention; fake-client watch test (change event drives the core)
- [ ] CI: a `fetcher-test` job running vet, tests and an arm64 cross-build — no cluster, no podman, no privileged runner (delivered on the private repo as a provider-CI job; re-homed as GitHub Actions `.github/workflows/fetcher-test.yml` in the public repo)
- [ ] Short `k8s/fetcher/README.md`: the two modes, the volume layout, and what phase 3 wires (chart, Role get+watch, shared volume, server reads `/data/current`)
- [ ] Record the proof in this task directory (helix-specs): selftest 19/19 on main, CI job green, three labels applied
- [ ] Open the MR; do not merge (the human reviews)
