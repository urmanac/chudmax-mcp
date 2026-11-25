# Requirements: chudmax k8s phase 2 fetcher sidecar

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 2 (`kubernetes/phases.md`): **a sidecar that takes an artifact URL and digest, verifies, unpacks and swaps; tested against a tarball in CI, no cluster needed.** It is the only new code in the plan, and it is not git code: Flux (source-controller) fetches and packs the repo; the sidecar only consumes what Flux serves. Per `kubernetes/repo-sync.md`, it learns the current artifact (URL, revision, digest) by watching the **one** ExternalArtifact it is allowed to read (namespaced Role: `get`, `watch`), downloads the tarball from source-controller over HTTP, checks the digest, unpacks beside the previous copy, and swaps a symlink so a reader never sees half a tree. Flux's own controllers do exactly this with the library in `fluxcd/pkg`; the sidecar uses the same library.

Phase 2 sits at the root of the "make the parts" half and runs parallel with phase 1, which is already delivered (MR !18 merged — verified in `design.md`). Phase 3 packages this binary into the mcp image and chart; phase 4 writes the manifests; phase 5 rehearses on kind. Phase 2 needs no cluster, no image, and touches nothing on the box.

## Preconditions (verified on merged main, this sandbox, 2026-11-25)

- [x] MR !17 merged: `main` @ `9950942f` carries the six `kubernetes/` plan files (`phases.md`, `repo-sync.md`, …) — `verified-here` (fresh GitLab clone, merge commit `21f8b3b` is an ancestor of `main`).
- [x] MR !18 merged: `ticket_mcp.py` has `--http` and pod-mode `--revision`/`--artifact-produced`/`--artifact-unpacked` — `verified-here` (same clone; merge commit `9950942f` = `main`).
- [x] `python3 tools/mcp/selftest.py` on `main` @ `9950942f`: **19/19 PASS, exit 0** — `verified-here`.

## User stories

1. **As the ticket server's pod (wired in phase 3)**, I want the sidecar to keep `current/` on the shared volume pointing at the newest verified artifact, so my next call reads the merged state without a restart and without git.
2. **As the sidecar**, I want to learn the current artifact (URL, revision, digest) by watching the one ExternalArtifact my Role allows, so a missed event after a restart self-heals on startup.
3. **As a reader (ticket server, human, script)**, I want the swap done by an atomic rename of a symlink, so I never see a half-unpacked tree.
4. **As CI**, I want the core loop tested against a tarball over plain HTTP, so the proof needs no cluster, no podman, no privileged runner.
5. **As the human**, I want nothing to change on the box and nothing to land on `main` unreviewed, and the proof recorded with the repo's three labels (`verified-here`, `handoff-reported`, `speculation`).

## Acceptance criteria

- [ ] Code lives in `k8s/fetcher/` (the repo's workbench per `kubernetes/architecture.md`) as a standalone Go module using `fluxcd/pkg/http/fetch`, `fluxcd/pkg/tar` and `source-controller/api` (ExternalArtifact types); no git code of any kind.
- [ ] **One-shot mode** (`fetch`): given artifact URL + digest + volume root, downloads, verifies the digest, unpacks, swaps — this is the phase card's literal contract and the thing CI proves.
- [ ] **Watch mode** (`watch`, the pod mode): given namespace + name of the one ExternalArtifact, reads it once at startup (covers a missed event after a restart), then watches it and repeats the fetch/verify/unpack/swap on every artifact change.
- [ ] Digest mismatch (or any fetch error) leaves the previous unpacked tree and symlink untouched — a reader keeps seeing the last good tree.
- [ ] Unpack target is a fresh content-addressed dir (`revisions/<digest-hex>`); the `current` symlink is swapped by `rename()` (atomic); same digest arriving again is a no-op (idempotent, incl. after restart).
- [ ] Each unpacked dir carries an `artifact.json` (URL, revision, digest, produced-at, unpacked-at) written by the sidecar before the swap, so the ticket server's `repo_facts` can report Flux's facts per call in phase 3 (no restart).
- [ ] CI: a `.gitlab-ci.yml` job runs `go vet`, `go test` (tarball fixture over httptest: happy path, digest mismatch, second-revision swap, same-digest no-op) and an arm64 cross-build check — no cluster, no podman needed in this phase.
- [ ] Unit tests cover the watch layer against a controller-runtime fake client (event on `status.artifact` change drives the core loop).
- [ ] The box is untouched; work lands via MR to `main` only; the three-labels rule applies to all claims.

## Out of scope (owned by other phases)

- Image build (arm64+amd64, podman first) and the chart with Deployment/Role/NetworkPolicies — phase 3.
- The `k8s/repo-sync/` manifests, narrowed-artifact question, and the "smallest Role" answer — phase 4.
- Live cluster watch/fetch rehearsal — phase 5. mTLS identity — phase 17.

## Open Questions

1. **`artifact.json` contract:** I assume the ticket server (phase 3 wiring) reads `/data/current/artifact.json` through the same symlink on every `repo_facts` call. Acceptable that the sidecar adds this one file to the unpacked tree, or should the metadata live beside the symlink (e.g. `artifact.json` swapped atomically with it) or be served another way?
2. **Watch resync:** I plan a 1-minute re-read of the ExternalArtifact in watch mode (matching the GitRepository interval) as a fallback if the watch stream drops silently. Overkill, or right?
3. **Retention:** keep the last 3 unpacked revisions (current + 2 predecessors) and prune older after each successful swap — or a different count?
4. **Download size caps:** default cap ~100 MiB download / 200 MiB unpacked (flag-overridable), rather than kustomize-controller's unlimited — sensible defaults for a text-only repo artifact?
