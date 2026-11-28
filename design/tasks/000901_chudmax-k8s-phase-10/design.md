# Design: chudmax k8s phase 10 publishing split and flux mirror

The charts were written split-ready ("publishing happens elsewhere", `decisions/0007`; every phase spec's out-of-scope said "ghcr.io, cosign — phase 10"), so phase 10 is mostly moves plus one publishing pipeline shape reused four times. This design settles: what moves where, the registry package layout, the per-repo publish pipeline (cosign keyless), the flux-mirror config and its sync CI, the ripple in `urmanac/chudmax-mcp`, and the sequencing that keeps every CI run green at each step. Requirements are in `requirements.md` in this directory.

## 1. The split

| Source (in `urmanac/chudmax-mcp`) | Target repo | What the target publishes |
|---|---|---|
| `k8s/umbrella/chudmax/subcharts/chudmax-engine/` | `urmanac/chudmax-engine` (root) | OCI chart only (no workload, no image) |
| `k8s/umbrella/chudmax/subcharts/chudmax-web/` | `urmanac/chudmax-web` (root) | OCI chart + the web image |
| `k8s/umbrella/chudmax/web-image/` | `urmanac/chudmax-web` `web-image/` | — (build source for the web image) |
| `k8s/chart/hermes-agent/` | `urmanac/hermes-agent` (root) | OCI chart only (upstream image) |
| `k8s/fetcher`, `k8s/tickets-mcp`, `k8s/chart/chudmax-mcp`, `k8s/repo-sync`, `k8s/umbrella`, `k8s/monitoring`, `k8s/canary`, `k8s/image-automation` | stay in `urmanac/chudmax-mcp` | 2 images + 1 chart (fetcher, tickets-mcp, chudmax-mcp) |

Each move is a pure re-root (no chart content edits) except the text flips: every "unpublished until phase 10" note in the moved charts becomes the published reference, and the hermes Chart.yaml description drops its "staged here" clause. Layout per target repo: the chart at repo root, `web-image/` beside it in `chudmax-web`, `.github/workflows/publish.yml`, plus each repo's own README pointer to the spec dir. The hermes repo also carries `kind-smoke.sh` (see §6).

## 2. Registry package layout

GHCR's package name is the path after `ghcr.io/`; `helm push <chart>.tgz oci://<prefix>` appends the chart NAME to the prefix. Therefore:

| Artifact | Published from | Reference | GHCR package |
|---|---|---|---|
| fetcher image | `chudmax-mcp` | `ghcr.io/urmanac/chudmax/fetcher:0.1.0` | `chudmax/fetcher` |
| tickets-mcp image | `chudmax-mcp` | `ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0` | `chudmax/tickets-mcp` |
| web image | `chudmax-web` | `ghcr.io/urmanac/chudmax/web:0.1.0` | `chudmax/web` |
| chudmax-mcp chart | `chudmax-mcp` | `oci://ghcr.io/urmanac/chudmax-mcp:0.1.0` | `chudmax-mcp` |
| chudmax-engine chart | `chudmax-engine` | `oci://ghcr.io/urmanac/chudmax-engine:0.1.0` | `chudmax-engine` |
| chudmax-web chart | `chudmax-web` | `oci://ghcr.io/urmanac/chudmax-web:0.1.0` | `chudmax-web` |
| hermes-agent chart | `hermes-agent` | `oci://ghcr.io/urmanac/hermes-agent:0.1.0` | `hermes-agent` |
| mirrored third-party charts | `chudmax-mcp` (mirror sync) | `oci://ghcr.io/urmanac/charts/<name>:<ver>` | `charts/<name>` |
| mirrored third-party images | `chudmax-mcp` (mirror sync) | `ghcr.io/urmanac/<upstream-path>:<tag>` | `<upstream-path>` |

**Decisions:** image package names are unchanged — every chart, rehearsal and the phase-8 `ImageRepository` set already pins `ghcr.io/urmanac/chudmax/{fetcher,tickets-mcp,web}`, and renaming would ripple for zero gain. House charts publish flat (package name = chart name = repo name — a 1:1 repo↔package mapping) while mirrored third-party charts deliberately live under the `charts/` prefix so provenance is legible in the reference. The umbrella's old "phase-10 note" (`ghcr.io/urmanac/chudmax/*` for all charts) predates the split and is rewritten.

## 3. The publish pipeline (one shape, four instances)

`publish.yml` per publishing repo, two jobs:

- **validate** (push-main/PR): what the workbench CI already proved, re-rooted — `helm lint` (+ the hermes variants), `helm template` + kubeconform `-strict`; for `chudmax-web`, the multi-arch image build check (`podman build --platform linux/amd64,linux/arm64 --manifest`, `docker/setup-qemu-action` for the pip arm64 leg — the `umbrella-kind.yml` web-image job verbatim). No push.
- **publish** (tag `v*` + `workflow_dispatch`): extract `${GITHUB_REF_NAME#v}`, assert it equals the chart version(s); `podman login ghcr.io` (GITHUB_TOKEN); build + `podman manifest push --all` the images at the bare-semver tag; `helm package` + `helm push` the chart(s) to the flat prefix; then cosign (below). Permissions: `contents: read, packages: write, id-token: write` — exactly the per-job elevation milestone 1 allows.

Triggers are tag-gated on purpose: GHCR tags are mutable, and re-pushing `0.1.0` with different bytes would silently drift what charts, the image-automation semver range and cosign digests point at. Main merges never publish; a re-publish is a new version or an explicit dispatch. Lockstep versioning per repo (one tag publishes all that repo's artifacts) is fine at 0.x — the chart's `appVersion` ties the pieces, and per-artifact versioning can split later if the owner wants it.

## 4. cosign keyless

`sigstore/cosign-installer@v3`, then `cosign sign --yes <artifact>@<digest>` for every pushed image (the manifest-list index digest) and chart. Keyless means the runner's OIDC token is the signing identity — no keys, no secrets stored; the workflow needs `id-token: write` and nothing else beyond `packages: write`. Immediately after signing, the same job runs the verify receipt:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/urmanac/<repo>/.github/workflows/publish.yml@refs/tags/v.*' \
  <artifact>@<digest>
```

Both sign and verify output land in the step summary. This is the supply-chain contract the mirror's `includeReferrers` then propagates for house artifacts and (where upstream signs) for mirrored ones. Signing the OCI chart works because a pushed Helm chart is just an OCI artifact — same cosign path as images.

## 5. The flux mirror

Flux Mirror is a **CLI plugin, not a controller** — the sync runs where the config runs (this repo's CI on a weekly schedule + dispatch; a human rerun is `flux mirror sync k8s/mirror/flux-mirror.yaml`). Config shape (docs verified 2026-11-27):

```yaml
apiVersion: mirror.plugin.fluxcd.io/v1beta2
kind: Config
charts:
  - name: flagger            # https://flagger.app  → ghcr.io/urmanac/charts/flagger
    source: https://flagger.app
    destination: oci://ghcr.io/urmanac/charts
    version: ">=1.45.0 <2.0.0"
    limit: 3
  # loadtester (same source, >=0.39.0 <1.0.0), traefik (https://traefik.github.io/charts, >=43.0.0 <44.0.0)
artifacts:
  - source: oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack   # OCI→OCI chart
    destination: ghcr.io/urmanac/charts/kube-prometheus-stack
    selector: { semver: ">=69.0.0 <70.0.0", limit: 3 }
  - source: ghcr.io/fluxcd/flagger            # → ghcr.io/urmanac/fluxcd/flagger
    destination: ghcr.io/urmanac/fluxcd/flagger
    selector: { semver: ">=1.45.0", limit: 3 }
  # ghcr.io/fluxcd/flagger-loadtester, docker.io/library/traefik (>=3.0.0), docker.io/nousresearch/hermes-agent (>=0.23.4)
  # includeReferrers: true on each
```

Selectors carry the same semver shapes the consumers use today (KPS `69.x`, the phase-7 chart pins, the phase-9 image floor) with a small top-N; exact pinning stays the consumers' job. Destination auth = `docker/login-action@v3` with `GITHUB_TOKEN` (packages: write); sources are anonymous (public upstreams; Docker Hub at the weekly cadence is fine — and Docker Hub remains a **future secondary destination**, GHCR-only now per milestone 2). The sync job's receipts: the plugin's structured yaml output to the step summary plus a pull-back check (`helm pull` one mirrored chart, `podman pull` one mirrored image, digest equality vs source). `includeReferrers: true` carries upstream signatures/attestations where they exist — recorded per entry, not assumed.

## 6. The ripple in `urmanac/chudmax-mcp` (one PR)

- **Umbrella deps flip**: engine + web deps → `oci://ghcr.io/urmanac/chudmax-engine` / `-web` (aliases + conditions kept); the mcp dep stays `file://../../chart/chudmax-mcp` (the chart remains in-tree in this repo). `helm dependency update` regenerates `Chart.lock` — credential-free once the packages are public.
- **Rehearsals**: the web image is now **pulled** from `ghcr.io/urmanac/chudmax/web:0.1.0` and loaded into kind — the Strata clone+build steps drop out of `umbrella/kind-smoke.sh` and `canary/canary-rehearse.sh` (the canary's retag-to-`0.1.1`/broken mechanics are unchanged; the pin note stays in the `chudmax-web` README). Fetcher + tickets-mcp are still built in-repo (their Dockerfiles stay). Both scripts gain `helm dependency update` before the umbrella install (canary installs it the same way).
- **Workflows**: `umbrella-kind.yml` loses the web-image build job (moved to `chudmax-web`) and the subchart lint paths, gains the dep-update step; `hermes-chart.yml` is deleted (moved); `image-chart.yml`, `canary-kind.yml`'s chart job, and the monitoring/repo-sync/rehearsal-sync workflows are untouched.
- **Texts**: root README's build-it-yourself section → the pull-anonymous-published story; chart README/NOTES/values comments (`k8s/chart/chudmax-mcp/`), tickets README, umbrella README (pins table + the phase-10 note).
- **New**: `k8s/mirror/` + `mirror-sync.yml` per §5.

**The hermes repo's rehearsal**: the moved `kind-smoke.sh` needs the mcp chart + the two mcp pod images, which publish from `chudmax-mcp` later in the sequence. Until then it **clones `urmanac/chudmax-mcp` at the pinned `main` SHA** (the established clone-at-pin pattern — the script already fetches Strata this way) for the mcp chart and builds the two pod images from the clone's Dockerfiles (the same bytes the tag will publish), and pulls the web image from ghcr. A later flip to pulled published artifacts is a documented option, not required.

## 7. Sequencing

1. Seed `chudmax-engine` (PR) → merge → tag `v0.1.0` → chart published + signed.
2. Seed `chudmax-web` (PR) → merge → tag `v0.1.0` → web image + chart published + signed.
3. Human: flip the three packages so far (`chudmax-engine`, `chudmax-web` chart + `chudmax/web` image) public.
4. Seed `hermes-agent` (PR) → merge → tag `v0.1.0` → chart published + signed.
5. `chudmax-mcp` flip PR (§6) → its CI now pulls the published web image and OCI deps → merge.
6. Tag `chudmax-mcp` `v0.1.0` → fetcher + tickets-mcp images + mcp chart published + signed.
7. Human: flip the remaining packages public (mcp images + chart; mirror packages after the first sync); run the mirror sync once; anonymous-pull proofs; apply the branch-protection ruleset to the 3 new repos.
8. Record the receipts (digests, signatures, visibility) in the task dir.

Steps 1–2 first because step 5's CI consumes their artifacts; step 6 last because nothing in `chudmax-mcp` CI consumes the mcp chart's published form (the umbrella keeps it `file://`).

## 8. Key decisions

1. **Pure re-root moves** — the charts move verbatim (modulo the text flips); no rename, no restructure, no version bump. The "split-ready" design (phase-6/9) pays off here.
2. **Flat chart packages, `charts/` prefix for mirrored ones** (§2) — package name = chart name for house charts; mirrored third-party charts are visibly third-party in their references. *(Speculation — the owner may prefer the umbrella's old `chudmax/*` promise; open question 1.)*
3. **Image names unchanged** (§2) — renaming is pure ripple; the split changes *who publishes*, not *what is named*.
4. **Tag-gated publishing, lockstep versions** (§3) — immutable-ish tags protect the cosign digests and the image-automation semver range from silent drift.
5. **cosign keyless under workflow identity** (§4) — no stored keys at all; the verify receipt (identity regexp per repo+workflow) is the audit trail; aligns with the "nothing published from the private repo" boundary because the signing identity is always a public repo's Actions run.
6. **Rehearsals pull the published web image** (§6) — honest post-publish shape, one less moving part (no Strata checkout) in the three kind proofs; in-repo builds stay only for this repo's own two images, which keeps `chudmax-mcp` CI hermetic before its own tag lands.
7. **Mirror = config + sync CI in the retained repo** (§5) — the plugin is a CLI, so CI is the runner; the consumer flips are phase-12 wiring and are documented, not wired, to keep this PR's blast radius inside the split.
8. **GHCR-only mirror** (milestone 2) — the config gains the Docker Hub secondary later; nothing in the config shape needs to change for it (a second destination per entry).
9. **No LICENSE anywhere in this phase** (milestone 4) — noted in every PR description; the repos stay license-less until the owner decides.
10. **Publishing repos are public; the private source-of-truth repo never publishes** (`decisions/0007`) — the narrowed artifact reaches pods through Flux's artifact flow, never through the registry; the registry carries code artifacts only.

## Implementation notes (2026-11-27, the implementing session)

- **Review answers locked in** (all 6 open questions at the recommended defaults): flat house-chart packages (`oci://ghcr.io/urmanac/<repo>`), unchanged image names, tag-gated `v<semver>` + dispatch publishes, mirror consumer flips stay phase-12, the confirmed mirror list, and the hermes repo's pinned-clone rehearsal.
- **Review execution notes applied**: origin/main pulled first (phase 8 = PR #10 + the canary-kind opt-in = PR #11 merged at `58b2688` — the opt-in touched only `canary-kind.yml`, not the rehearsal script); the Phase-16 hermes community-chart note (`jyje/hermes-agent-helm`, flux-mirrored to `oci://ghcr.io/urmanac/charts/hermes-agent` — PVC `helm.sh/resource-policy: keep` + :8642 bearer-key posture to verify) documented in BOTH `hermes-agent/README.md` and `k8s/mirror/README.md`; `org.opencontainers.image.source` labels/annotations on every Dockerfile and Chart.yaml (the seeds point at their own repos, the mcp ones at `chudmax-mcp`); hermes `publish.yml`'s validate job is chart-only (no kind job, no image pulls — passes before the GHCR flips).
- **Second web-image consumer found during implementation**: the phase-8 `image-automation-rehearse.sh` ALSO built the web image from the moved path — it now pulls `ghcr.io/urmanac/chudmax/web:0.1.0` and retags to the seed tag; the Strata-pin drift check stays (the pin row remains in the umbrella README's pins table).
- **GitHub Actions gotcha (fixed in all three seed workflows)**: with `publish` doing `needs: validate` while `validate` skipped on tag events (the original `if:` gate), the skipped needed job would silently skip publish too — validate now runs on EVERY event (a lint on a tag checkout is the same content as its main commit; harmless), publish stays tag/dispatch-gated.
- **`Chart.lock` deleted, not regenerated, in the flip PR**: the OCI digests do not exist until the coordinator pushes the tags, so the lock is regenerated by `helm dependency update` post-flip and re-added in the follow-up commit (tracked-lock convention restored then).
- **cosign sign/verify reference choice**: the chart signs/verifies BY DIGEST (captured from `helm push`'s `Digest:` output — one signature, no duplicate); the images sign/verify by the just-pushed tag ref (cosign anchors the signature to the digest under it either way; a digest-sign needs the push output parsed and podman's `manifest push` output format is not stable enough to grep safely).
- **Identity regexp** in every verify: `^https://github.com/urmanac/<repo>/\.github/workflows/publish\.yml@refs/(tags/v|heads/main)` — covers the tag-triggered and the dispatch paths in one pattern.
- **The mirror sync's plugin pin**: `flux plugin install mirror` installs latest (no version flag verified for the plugin subcommand) — the installed version is receipted into the step summary; pin the plugin once a version flag is confirmed.
- **Commit shape**: the flip landed as one comprehensive commit on `feature/000901-chudmax-k8s-phase-10` (commit-msg hook appends the `Spec-Ref:` trailer automatically).

## Notes for future agents (learnings)

- **GHCR packaging mechanics**: `helm push appends the chart name to the destination prefix` — a flat package (`chudmax-engine`) requires pushing to the bare org prefix `oci://ghcr.io/urmanac`; pushing to `oci://ghcr.io/urmanac/<repo>` yields the nested package `<repo>/<chart>`. Image pushes (podman/build) push the exact ref — that's why the images are flat and the chart destination prefix must be the bare org.
- **GHCR new packages are Private by default** and there is no GITHUB_TOKEN path to flip visibility (the packages API's visibility change needs an org-admin PAT) — the flip is a per-package human action via the package settings page. Budget for it in the sequencing; the anonymous-pull proof only passes after it.
- **The Private→Public flip is what completes phase 8**: the `ImageRepository` objects scan anonymously (`no secretRef until phase 10 wires auth`), so public packages make those scans resolve — the phase-8 README's phase-10 pointer is satisfied by this phase's flip, not by new manifests.
- **Flux Mirror is a CLI plugin** (`flux plugin install mirror`; plugin system from Flux v2.9), not a controller — there is no in-cluster reconcile of the mirror; the sync is idempotent and safe to schedule. Config: `mirror.plugin.fluxcd.io/v1beta2`, `charts:` (HTTP/S→OCI) + `artifacts:` (OCI→OCI) entries, `--dry-run` for previews, `--overwrite` only for deliberate drift.
- **cosign keyless in Actions** needs only `id-token: write` (+ push perms); sign by manifest-list digest for multi-arch; `cosign sign` works identically on Helm-OCI artifacts (they are plain OCI artifacts).
- **The podman-in-Actions pattern** (established phases 3–7) carries over: `podman build --platform linux/amd64,linux/arm64 --manifest <ref>` + `podman manifest push --all`; the web image's pip arm64 leg needs `docker/setup-qemu-action@v3`; fetcher cross-compiles (`$BUILDPLATFORM`-pinned RUN stages), tickets-mcp has no RUN. buildx is the documented fallback if podman frictions.
- **Cross-repo consumption at pins** is this project's standing pattern (Strata at `de34ebaa…` since phase 6) — extend it: the hermes rehearsal clones `chudmax-mcp` at a pinned SHA until the mcp artifacts are published; after that, pull-from-registry is the cleaner shape.
- **"The private repo"** = the private source-of-truth repo (GitLab; holds `kubernetes/phases.md`, the real tickets, `decisions/0007`) — `urmanac/chudmax-mcp` on GitHub is public and is where ALL phases and ALL publishing land.
- **Version provenance of the first publish**: every artifact publishes at `0.1.0` — the charts' existing `version:`/`appVersion:` and the chart values' pinned image tags are already consistent, so no chart edits are needed for the first publish (only the trigger assertion tag-version == chart-version).
