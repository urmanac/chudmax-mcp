# k8s/mirror — the flux mirror (T-0037 phase 10)

`flux-mirror.yaml` feeds the org's own GHCR with the third-party charts/images
the ChudMax stack consumes, so clusters never reach upstream registries at
reconcile time. The tool is the **Flux Mirror CLI plugin**
(`github.com/fluxcd/flux-mirror` — a CLI, not a controller): the sync is
idempotent, and CI runs it (`.github/workflows/mirror-sync.yml`, weekly
schedule + dispatch; a human rerun is the same command):

    flux mirror sync k8s/mirror/flux-mirror.yaml

## What is mirrored (GHCR-only for now)

| What | Source | Destination | Why |
|---|---|---|---|
| kube-prometheus-stack (chart) | `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack` | `ghcr.io/urmanac/charts/kube-prometheus-stack` | the monitoring module's OCIRepository (semver 69.x) |
| flagger (chart) | `https://flagger.app` | `ghcr.io/urmanac/charts/flagger` | the phase-7 canary (chart pin 1.45.0) |
| loadtester (chart) | `https://flagger.app` | `ghcr.io/urmanac/charts/loadtester` | flagger's load-test webhook (chart pin 0.39.0) |
| traefik (chart) | `https://traefik.github.io/charts` | `ghcr.io/urmanac/charts/traefik` | the Gateway API controller (ADR 001; chart pin 43.0.0) |
| flagger (image) | `ghcr.io/fluxcd/flagger` | `ghcr.io/urmanac/fluxcd/flagger` | the flagger pods' image |
| flagger-loadtester (image) | `ghcr.io/fluxcd/flagger-loadtester` | `ghcr.io/urmanac/fluxcd/flagger-loadtester` | the loadtester pods' image |
| traefik (image) | `docker.io/library/traefik` | `ghcr.io/urmanac/library/traefik` | the traefik chart's image |
| hermes-agent (image) | `docker.io/nousresearch/hermes-agent` | `ghcr.io/urmanac/nousresearch/hermes-agent` | the hermes-agent chart's upstream image (phase-9 pin v0.23.4) |

Mirrored charts land under the `charts/` prefix (packages `charts/<name>`) —
visibly third-party, distinct from the house charts (each house repo publishes
its own flat package). Mirrored images keep the upstream path
(`ghcr.io/urmanac/fluxcd/flagger`, `…/library/traefik`, `…/nousresearch/hermes-agent`)
so provenance reads straight off the reference. `includeReferrers: true`
carries upstream signatures/attestations where they exist.

Deliberately **excluded**: cilium and other rehearsal-only tooling (kind,
Cilium's own charts) — they are CI-time installs, not reconcile-time
dependencies of any fleet install.

Docker Hub (the `urmanac` personal account, registered and owned) is a later
**secondary destination** — GHCR-only for now (milestone note, 2026-11-26).

## The house artifacts (NOT mirrored — published by their own repos)

| Artifact | Published from | Reference |
|---|---|---|
| chudmax-engine chart | `urmanac/chudmax-engine` | `oci://ghcr.io/urmanac/chudmax-engine` |
| chudmax-web chart | `urmanac/chudmax-web` | `oci://ghcr.io/urmanac/chudmax-web` |
| chudmax-mcp chart | `urmanac/chudmax-mcp` | `oci://ghcr.io/urmanac/chudmax-mcp` |
| hermes-agent chart | `urmanac/hermes-agent` | `oci://ghcr.io/urmanac/hermes-agent` |
| fetcher / tickets-mcp images | `urmanac/chudmax-mcp` | `ghcr.io/urmanac/chudmax/{fetcher,tickets-mcp}` |
| web image | `urmanac/chudmax-web` | `ghcr.io/urmanac/chudmax/web` |

## Consumers to flip at the phase-12 wiring (documented, NOT wired here)

The mirror exists in phase 10; pointing consumers at it is the phase-12 fleet
wiring (one-line changes each, after the mirrored packages go public):

- **monitoring** (`k8s/monitoring/controllers/kube-prometheus-stack/repository.yaml`):
  the OCIRepository's `url` → `oci://ghcr.io/urmanac/charts/kube-prometheus-stack`.
- **canary rehearsal** (`k8s/canary/canary-rehearse.sh`): the `helm repo add
  flagger https://flagger.app` / `traefik https://traefik.github.io/charts`
  installs → `helm upgrade --install oci://ghcr.io/urmanac/charts/{flagger,loadtester,traefik}`.
- **hermes chart** (`urmanac/hermes-agent` values): `image.repository: nousresearch/hermes-agent`
  → `ghcr.io/urmanac/nousresearch/hermes-agent`.

## Phase-16 note (the Hermes community chart, recorded at phase 10)

`urmanac/hermes-agent` publishes our minimal Phase-9 MVP wrapper chart for
Phase 10. **Phase 16 ("Hermes beside it")** evaluates adopting the actively
maintained MIT community chart
[`jyje/hermes-agent-helm`](https://github.com/jyje/hermes-agent-helm)
(`oci://ghcr.io/jyje/hermes-agent-helm/hermes-agent`) — mirrored via this
config into `oci://ghcr.io/urmanac/charts/hermes-agent` — instead of
maintaining a custom Hermes chart fork long-term. The evaluation must verify
the community chart's PVC posture (`helm.sh/resource-policy: keep` — our
delete-on-uninstall PVC behavior differs) and its :8642 bearer-key shape
against our chart's contract.
