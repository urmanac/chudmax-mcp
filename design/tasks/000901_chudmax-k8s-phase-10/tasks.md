# Implementation Tasks: chudmax k8s phase 10 publishing split and flux mirror

## A. Seed `urmanac/chudmax-engine` (chart-only publisher)
- [~] Re-root `k8s/umbrella/chudmax/subcharts/chudmax-engine/` to the repo root (Chart.yaml, values.yaml, templates/, README — content verbatim, README adapted to the standalone repo + spec pointer); no LICENSE (deferred note in the PR description)
- [ ] Add `.github/workflows/publish.yml`: validate job (helm lint/template + kubeconform on push-main/PR, no push) + publish job (tag `v*`/dispatch: assert tag version == chart version, `helm package` + `helm push` to the flat prefix `oci://ghcr.io/urmanac`, cosign keyless sign + verify receipt); permissions `contents: read, packages: write, id-token: write`
- [ ] Merge the PR, push tag `v0.1.0`, confirm the publish receipt (chart ref `ghcr.io/urmanac/chudmax-engine:0.1.0`, cosign verify OK)

## B. Seed `urmanac/chudmax-web` (chart + web image)
- [~] Re-root `k8s/umbrella/chudmax/subcharts/chudmax-web/` to the repo root with the published-reality text flips (README/values/NOTES: image published at `ghcr.io/urmanac/chudmax/web:0.1.0`); move `k8s/umbrella/chudmax/web-image/` (Dockerfile + README with the Strata pin `de34ebaa…`)
- [ ] Add `.github/workflows/publish.yml`: validate job (chart lint/template/kubeconform + the multi-arch web image build check with qemu binfmt — the `umbrella-kind.yml` web-image job verbatim) + publish job (build + `podman manifest push --all` the image at the bare-semver tag, `helm package`/`helm push` the chart to `oci://ghcr.io/urmanac`, cosign keyless sign + verify both)
- [ ] Merge the PR, push tag `v0.1.0`, confirm the receipts (image manifest list amd64+arm64, chart, signatures)
- [ ] Human: flip packages `chudmax-web` (chart) and `chudmax/web` (image) Private→Public; anonymous `docker pull` + `helm pull` proof passes

## C. Seed `urmanac/hermes-agent` (chart-only publisher, rehearsal moves too)
- [~] Re-root `k8s/chart/hermes-agent/` to the repo root; Chart.yaml description drops the "staged here until the phase-10 split" clause; README points at the spec dir; move `kind-smoke.sh` adapted: clone `urmanac/chudmax-mcp` at the pinned `main` SHA for the mcp chart + pod images (build from the clone's Dockerfiles), pull the web image from ghcr (published in step B), drop the Strata clone+build
- [ ] Add `.github/workflows/publish.yml`: validate job (the phase-9 lint variants + the render-guard negative test + kubeconform + hygiene grep) + publish job (chart package/push/sign — no image build: upstream image stays upstream)
- [ ] Merge the PR, push tag `v0.1.0`, confirm the receipt
- [ ] Human: flip package `hermes-agent` Private→Public; apply the no-force-push/no-deletion ruleset to all 3 seeded repos (milestone 3 — direct pushes stay allowed)

## D. Flip + mirror in `urmanac/chudmax-mcp` (one PR)
- [ ] Delete the moved paths: `k8s/umbrella/chudmax/subcharts/`, `k8s/umbrella/chudmax/web-image/`, `k8s/chart/hermes-agent/`, `.github/workflows/hermes-chart.yml`
- [ ] `k8s/umbrella/chudmax/Chart.yaml`: engine + web deps → `oci://ghcr.io/urmanac/chudmax-engine` / `oci://ghcr.io/urmanac/chudmax-web` (aliases + conditions kept; mcp dep stays `file://`); regenerate `Chart.lock` via `helm dependency update` (works once the packages are public)
- [ ] `k8s/umbrella/chudmax/kind-smoke.sh`: pull `ghcr.io/urmanac/chudmax/web:0.1.0` from ghcr (drop the Strata clone+build), keep building fetcher/tickets-mcp in-repo, add `helm dependency update` before the install
- [ ] `k8s/canary/canary-rehearse.sh`: same web-image treatment (pull + retag `0.1.1`/broken unchanged), add the dep-update step
- [ ] `.github/workflows/umbrella-kind.yml`: remove the web-image build job + subchart lint paths; add the OCI dep-update step to the chart job; keep the kind job's proof intact
- [ ] Add `k8s/mirror/flux-mirror.yaml` (the Config per design §5: flagger + loadtester + traefik charts → `charts/` prefix; KPS OCI chart + flagger/flagger-loadtester/traefik/hermes-agent images → upstream-path destinations; semver selectors + small top-N; `includeReferrers: true`)
- [ ] Add `k8s/mirror/README.md`: the mirror↔consumer mapping (monitoring OCIRepository, canary sources, hermes image ref — flips land with phase-12 wiring), GHCR-only statement, Docker-Hub-secondary note, exclusion list
- [ ] Add `.github/workflows/mirror-sync.yml`: validate job (config parses, hygiene grep) + sync job (`schedule` weekly + `workflow_dispatch` + push-to-main on the config; flux CLI v2.10.1 + pinned `flux plugin install mirror`; `docker/login-action` GITHUB_TOKEN for ghcr.io; `flux mirror sync` receipts to the summary; pull-back digest check)
- [ ] Flip the "unpublished until phase 10" texts to the published reality: root README, `k8s/chart/chudmax-mcp/README.md` + `templates/NOTES.txt` + `values.yaml` comments, `k8s/umbrella/chudmax/README.md` (pins table + phase-10 note), `k8s/tickets-mcp/README.md`
- [ ] CI green on the PR (all workflows); merge

## E. Publish `chudmax-mcp` artifacts + close out
- [ ] Push tag `v0.1.0` on `chudmax-mcp`: the publish workflow builds + pushes + signs fetcher and tickets-mcp multi-arch images and the chudmax-mcp chart; receipts confirmed
- [ ] Human: flip `chudmax/fetcher`, `chudmax/tickets-mcp`, `chudmax-mcp` packages Private→Public; anonymous-pull proof (image + chart + umbrella `helm template` with OCI deps, no credentials); the phase-8 `ImageRepository` anonymous scans resolve
- [ ] Human: run the mirror sync once (or dispatch it); flip the mirror packages public
- [ ] Record the publish receipts (refs, digests, signatures, package visibility, branch-protection rulesets) in this task dir
- [ ] `mark_task_complete` after the phase-10 PR is merged and the publish tags have landed
