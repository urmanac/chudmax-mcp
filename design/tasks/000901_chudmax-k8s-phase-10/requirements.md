# Requirements: chudmax k8s phase 10 publishing split and flux mirror

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 10 (`kubernetes/phases.md`): **hand to publishing.** The workbench (`k8s/` in `urmanac/chudmax-mcp`) becomes installable surfaces: the engine and web subcharts plus the web image move to their already-created public repos (`urmanac/chudmax-engine`, `urmanac/chudmax-web`), the Hermes chart moves to `urmanac/hermes-agent`, and each publishing repo's CI builds, signs (cosign keyless under workflow identity) and pushes multi-arch images (fetcher, tickets-mcp, web) and OCI Helm charts to ghcr.io. The newly created GHCR org packages flip Private→Public so images and charts pull without credentials. A flux-mirror config plus its sync CI covers the third-party charts/images the stack consumes (kube-prometheus-stack, flagger, traefik, nousresearch/hermes-agent). Nothing is published from the private source-of-truth repo itself (`decisions/0007`). Depends on phases 2–9 + the monitoring card.

## Preconditions (verified, 2026-11-27)

- [x] `urmanac/chudmax-mcp` `main` @ `bf1fe40` carries phases 2–7, 9 and the monitoring card (`verified-here`). Phase 8 (`k8s/image-automation/`, branch `feature/000905-chudmax-k8s-phase-8`, tip `3c3b732`) is **not yet merged** — it merges before phase 10 starts (its `ImageRepository` set scans the same package names phase 10 publishes; the Public flip is what makes its anonymous scans work).
- [x] The three target repos exist and are empty (`verified-here`, sandbox clones with Helix proxy origins): `chudmax-engine`, `chudmax-web`, `hermes-agent` — each at "initial empty commit" on `main`.
- [x] The in-tree shapes (`verified-here`, local clone): the umbrella's `file://` deps (`k8s/umbrella/chudmax/Chart.yaml` — engine/web to flip, mcp stays in-tree); `k8s/umbrella/chudmax/web-image/Dockerfile` (the pip-install image — arm64 leg under qemu binfmt, the `umbrella-kind.yml` web-image job pattern); the hermes chart staged "until the phase-10 split to urmanac/hermes-agent" (`k8s/chart/hermes-agent/Chart.yaml`).
- [x] Third-party pins (`verified-here`): kube-prometheus-stack `semver: 69.x` as OCI (`oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack`, the monitoring module); flagger chart `1.45.0` + loadtester chart `0.39.0` from `https://flagger.app` (the canary rehearsal); Traefik chart `43.0.0` from `https://traefik.github.io/charts`; the hermes-agent image `nousresearch/hermes-agent:v0.23.4` (Docker Hub; manifest-list digest `sha256:ef0650d5…`, the phase-9 receipt).
- [x] **Flux Mirror** exists and is the right tool (`verified-here`, docs read 2026-11-27): the official Flux CLI plugin (`github.com/fluxcd/flux-mirror`, installed with `flux plugin install mirror`; CLI plugin system shipped in Flux v2.9+) — declarative Config (`mirror.plugin.fluxcd.io/v1beta2`) with `charts:` (HTTP/S repo → OCI) and `artifacts:` (OCI → OCI, whole multi-arch lists, byte-for-byte) entries, `flux mirror sync [--dry-run|--overwrite]`, idempotent per tag/version, opt-in referrer (signature) mirroring and cosign verification.
- [x] Human milestones (card, verified 2026-11-26): org Actions enabled; Package Creation allows Public (Members); the default `GITHUB_TOKEN` stays `read` — workflows request per-job `packages: write` + `id-token: write`; flux mirror is **GHCR-only** (`ghcr.io/urmanac/…`) for now, Docker Hub (`urmanac` account owned) earmarked as a later secondary; the no-force-push/no-deletion ruleset is active on `chudmax-mcp` `main` and gets applied to the 3 new repos once `main` is seeded (direct pushes NOT blocked unless ImageUpdateAutomation controls require it); LICENSE explicitly deferred.

## User stories

1. **As the human**, I want the four installable charts and three house images published from their own public repos so the workbench (`urmanac/chudmax-mcp`) stops being the install surface — `helm pull`/`docker pull` work for anyone, without credentials.
2. **As the owner**, I want publishing to be reproducible CI, not a laptop ritual: a version tag on a publishing repo builds, pushes and cosign-signs (keyless, under the workflow identity) its multi-arch images and OCI charts, and the run summary receipts the digests and signatures.
3. **As a user with no GitHub account**, I want every published package public so anonymous pulls just work — including Flux's anonymous `ImageRepository` scans (phase 8's set finally resolves against the real registry).
4. **As the fleet operator (phase 12 wiring)**, I want the third-party dependencies (kube-prometheus-stack, flagger + loadtester, traefik, hermes-agent) mirrored into `ghcr.io/urmanac/…` by a declarative Flux Mirror config with its sync CI, so reconcile-time pulls stop reaching upstream registries.
5. **As the rehearsals' maintainer**, I want the kind proofs (umbrella, canary, hermes) to keep working after the split with bounded ripple: the web image is pulled from the published registry instead of built from a moved Dockerfile, and cross-repo pieces are consumed at recorded pins.
6. **As the human**, I want the split's ripple in `urmanac/chudmax-mcp` confined to one reviewable PR: moved paths deleted, umbrella deps flipped to OCI, the "unpublished until phase 10" texts flipped to published references, and the mirror config added — while `fetcher`, `tickets-mcp`, `chudmax-mcp` chart, `repo-sync`, `umbrella`, `monitoring`, `canary` and `image-automation` stay put.

## Acceptance criteria

**The split (hard write sets)**
- [ ] `urmanac/chudmax-engine` is seeded with the engine chart verbatim (Chart.yaml, values.yaml, templates/, README re-rooted; no workload, no image — chart-only publisher) plus its publish workflow. No LICENSE file (deferred).
- [ ] `urmanac/chudmax-web` is seeded with the web chart at repo root (README/values/NOTES texts updated: the image is published) plus `web-image/` (Dockerfile + README carrying the Strata pin `de34ebaa…`, tag `v0.2.21-mbp.rtx.1`) plus its publish workflow (multi-arch image + chart).
- [ ] `urmanac/hermes-agent` is seeded with the hermes chart at repo root (the Chart.yaml description drops the "staged here until the phase-10 split" clause), its `kind-smoke.sh` (adapted — see design), and its publish workflow. Upstream image stays upstream (`nousresearch/hermes-agent`); nothing is built here.
- [ ] `urmanac/chudmax-mcp` keeps exactly: `k8s/fetcher`, `k8s/tickets-mcp`, `k8s/chart/chudmax-mcp`, `k8s/repo-sync`, `k8s/umbrella`, `k8s/monitoring`, `k8s/canary`, `k8s/image-automation` (on merge), and gains `k8s/mirror/`; it loses `k8s/umbrella/chudmax/subcharts/`, `k8s/umbrella/chudmax/web-image/`, `k8s/chart/hermes-agent/` and `.github/workflows/hermes-chart.yml`.

**Publishing CI (every publishing repo; new repos get the same shape)**
- [ ] Build-only proof stays on push-main/PR (in `chudmax-mcp` the existing workflows are untouched — `image-chart.yml`, `umbrella-kind.yml` keep their no-push builds; the new repos' validation job lints/templates/kubeconforms the chart).
- [ ] Publish runs on a version tag (`v<semver>`, e.g. `v0.1.0`) and `workflow_dispatch`: the tag version is asserted equal to the chart version(s); image tags carry the bare semver (`0.1.0` — the chart values' pinned tags); the chart is packaged (`helm package`) and pushed to the flat destination prefix `oci://ghcr.io/urmanac` (artifact ref `ghcr.io/urmanac/<chart-name>:<version>`).
- [ ] Multi-arch stays the podman manifest-list pattern (amd64 + arm64, emulation-free cross-compile for the fetcher, no-RUN for tickets-mcp, qemu binfmt for the web's pip arm64 leg); the manifest is pushed with `--all`.
- [ ] Registry auth is per-job elevated only: `permissions: {contents: read, packages: write, id-token: write}` — the org default `GITHUB_TOKEN` read setting is preserved (human milestone 1).
- [ ] **cosign keyless signing**: every pushed image and chart is signed by digest with `cosign sign --yes` under the runner's OIDC identity (Fulcio/Rekor); the workflow immediately runs `cosign verify` with `--certificate-oidc-issuer https://token.actions.githubusercontent.com` and a `--certificate-identity-regexp` pinned to that repo+workflow — the verify receipt (digest + identity) lands in the step summary.
- [ ] Publish receipts (pushed refs, digests, verify output) are recorded in the run summary and in the task dir's notes.

**Packages public (human actions, enumerated)**
- [ ] After first push, each new GHCR org package flips Private→Public via its package settings (Admin): images `chudmax/fetcher`, `chudmax/tickets-mcp`, `chudmax/web`; house charts `chudmax-mcp`, `chudmax-engine`, `chudmax-web`, `hermes-agent`; mirror packages (the `charts/*` set + the mirrored images) after the first sync.
- [ ] The anonymous-pull proof passes: from a clean host, `docker pull ghcr.io/urmanac/chudmax/fetcher:0.1.0` and `helm pull oci://ghcr.io/urmanac/chudmax-engine --version 0.1.0` succeed with no login; `helm template` of the umbrella resolves its OCI deps with no credentials.
- [ ] The human applies the no-force-push/no-deletion ruleset to the 3 new repos once their `main` is seeded (milestone 3 — not blocking direct pushes).

**Flux mirror (`chudmax-mcp`)**
- [ ] `k8s/mirror/flux-mirror.yaml` — a `mirror.plugin.fluxcd.io/v1beta2` Config: `charts:` entries for flagger, loadtester (`https://flagger.app`) and traefik (`https://traefik.github.io/charts`) with destination prefix `oci://ghcr.io/urmanac/charts`; `artifacts:` entries for the kube-prometheus-stack OCI chart (`oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack` → `ghcr.io/urmanac/charts/kube-prometheus-stack`) and images `ghcr.io/fluxcd/flagger`, `ghcr.io/fluxcd/flagger-loadtester`, `docker.io/library/traefik`, `docker.io/nousresearch/hermes-agent` → `ghcr.io/urmanac/<upstream-path>`; semver selectors matching the in-repo pins with a small top-N; `includeReferrers: true`.
- [ ] `k8s/mirror/README.md` — the mirror↔consumer mapping (monitoring's KPS OCIRepository, the canary rehearsal's flagger/traefik installs, the hermes chart's image reference — each a documented flip that lands with the phase-12 wiring, not in this phase), the GHCR-only statement, the Docker-Hub-secondary note, and what is deliberately excluded (cilium and other rehearsal-only tooling).
- [ ] `.github/workflows/mirror-sync.yml` — a validate job (config parses; hygiene grep) and a sync job (`schedule` weekly + `workflow_dispatch` + push-to-main scoped to the config): flux CLI pinned at v2.10.1, `flux plugin install mirror` (pinned version), `docker/login-action` with `GITHUB_TOKEN` for the ghcr.io destination, `flux mirror sync` with structured receipts to the step summary, and a pull-back check (one mirrored chart + one mirrored image, digest equality against source).

**Ripple edits (`chudmax-mcp`, one PR)**
- [ ] `k8s/umbrella/chudmax/Chart.yaml`: engine + web deps flip `file://subcharts/…` → `oci://ghcr.io/urmanac/chudmax-engine` / `oci://ghcr.io/urmanac/chudmax-web` (aliases `engine`/`web` and `condition:` keys kept; the mcp dep stays `file://../../chart/chudmax-mcp`); `Chart.lock` regenerated by `helm dependency update`.
- [ ] `k8s/umbrella/chudmax/kind-smoke.sh` and `k8s/canary/canary-rehearse.sh`: the web image is **pulled** from `ghcr.io/urmanac/chudmax/web:0.1.0` (the Strata clone+build steps drop out; the retag mechanics for the canary's good/broken upgrades are unchanged); fetcher + tickets-mcp are still built in-repo (their Dockerfiles stay); a `helm dependency update` step precedes the umbrella install.
- [ ] `.github/workflows/umbrella-kind.yml`: the web-image build job and the subchart lint paths are removed (the build proof moves to `chudmax-web`'s CI); the chart job gains the OCI dep update; the kind job keeps its proof.
- [ ] The "unpublished until phase 10" texts flip to the published reality across: the root README (install section), `k8s/chart/chudmax-mcp/README.md` + `templates/NOTES.txt` + `values.yaml` comments, `k8s/umbrella/chudmax/README.md` (pins table + the phase-10 note), `k8s/tickets-mcp/README.md`.
- [ ] All existing workflows stay green on `main`; no other paths change.

**Flow**
- [ ] One PR per target repo (seed) + one PR in `chudmax-mcp` (flip + mirror) via `propose_pull_request` (repository parameter per repo); conventional commits; three labels on every claim; box untouched; the LICENSE-deferred note in every PR description; merge authority CoS; publish tags are pushed only after each repo's PR merges; `mark_task_complete` only after the `chudmax-mcp` PR merges and the publish tags land.

## Out of scope (owned by other phases or decisions)

- Pointing the consumers at the mirror (the monitoring OCIRepository's URL, the canary rehearsal's flagger/traefik sources, the hermes chart's `image.repository`) — the phase-12 fleet wiring; this phase ships the mirror + its mapping documentation only.
- The Docker Hub secondary mirror — later (GHCR-only per milestone 2).
- LICENSE files in any repo — explicitly deferred (owner).
- mTLS, MetalLB, the real cluster's GitRepository/secret wiring, `kube-prometheus-stack` placement — phases 12/15.
- Version bumps beyond the first `0.1.0` publish and any release cadence policy — the owner's later choice (the tag-triggered pipeline supports it).

## Open Questions

1. **Chart package naming** — this spec publishes house charts flat (`helm push` to the bare `oci://ghcr.io/urmanac` prefix → packages `chudmax-engine`, `chudmax-web`, `hermes-agent`, `chudmax-mcp`) and puts mirrored third-party charts under the `charts/` prefix (packages `charts/flagger`, …). Confirm — or would you rather have the umbrella README's old promise (`ghcr.io/urmanac/chudmax/*` for everything) apply to charts too?
2. **Image package names** — kept as-is (`ghcr.io/urmanac/chudmax/{fetcher,tickets-mcp,web}`), now pushed from `chudmax-mcp` and `chudmax-web` respectively; per-repo image namespaces (e.g. `ghcr.io/urmanac/chudmax-web/web`) would ripple through every chart, rehearsal and the image-automation set. Confirm keep.
3. **Publish trigger** — version tags (`v<semver>`, lockstep per repo: one tag publishes all that repo's artifacts) + manual dispatch; nothing auto-publishes on main merges. Confirm, or do you want publish-on-merge?
4. **Mirror consumer flips** — confirmed out of this phase (config + sync only), landing with the phase-12 wiring. Say the word if you want the monitoring OCIRepository flipped now.
5. **Mirror list** — the four named dependencies plus flagger-loadtester (the flagger rehearsal's companion chart/image); cilium and other rehearsal-only tooling excluded. Confirm the list.
6. **The hermes repo's kind rehearsal pre-first-publish** — it clones `chudmax-mcp` at a pinned SHA for the mcp chart + pod images (builds them from the clone's Dockerfiles) and pulls the web image; a later flip to pulled published artifacts stays optional. OK?
