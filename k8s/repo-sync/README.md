# repo-sync — the Flux objects that move the narrowed artifact to the pod

The Flux half of "the repo reaches the ticket server" (the pod half is
`k8s/chart/chudmax-mcp/`). Five objects, one namespace, no cluster needed to
review them — `flux schema validate` stands in until the phase-5 kind
rehearsal.

```
GitLab push ──► Receiver (type gitlab) ──► triggers reconcile
GitRepository chudmax-source (main, interval 1m, auth Secret)
      │ FULL artifact tarball — stays complete for the cluster's own sync
      ▼
ArtifactGenerator chudmax-narrow (copy rules over the narrowed set)
      │ generates; watches its inputs; content-hash revision
      ▼
ExternalArtifact chudmax-tickets (created by source-watcher, same namespace)
      │  get+watch — the chart's Role, resourceName-pinned
      ▼
fetcher sidecar ─► GET the tarball (source-watcher's storage server) ─► /data/current

Alert (GitRepository + ArtifactGenerator events, info) ─► Provider ─► the human's channel
```

| File | Object |
|---|---|
| `gitrepository.yaml` | GitRepository `chudmax-source` — `main`, `interval: 1m`, `secretRef: chudmax-repo-auth`, no `spec.ignore` |
| `artifactgenerator.yaml` | ArtifactGenerator `chudmax-narrow` — generates the ExternalArtifact `chudmax-tickets` |
| `receiver.yaml` | Receiver `chudmax-repo` — `type: gitlab`, `events: ["Push Hook"]`, `secretRef: webhook-token` |
| `alerts.yaml` | Alert `chudmax-source-alerts` (info) + Provider `chudmax-notifications` (generic, address from Secret) |

## The source repo

The GitRepository points at the private source-of-truth repo's `main`:
`https://gitlab.com/kingdonb/chudmax.git` (a URL is metadata, not a
credential — public-safe in a manifest per the owner's ruling; the auth
Secret carries the credentials and is referenced by name only). The narrowed
paths the copy rules target were verified against `main`'s tree on
2026-11-25: `tickets.md` and `STATE.md` at the root, `docs/` (11 files) and
`decisions/` (7 records) as top-level trees — the head was `de442410`, the
same commit phase 2's fresh-clone check verified, so nothing has moved
between the two checks.

## Install

```sh
kubectl -n <release-namespace> apply -f k8s/repo-sync/
```

The manifests carry **no `metadata.namespace`** — they land in whatever
namespace you install them into, and that namespace must be the **chart
release's**: the fetcher's Role and the generated ExternalArtifact are
namespaced to it, and the ArtifactGenerator creates the artifact in its own
namespace.

One manifest needs a per-install edit: [`artifact-ingress.yaml`](artifact-ingress.yaml)
admits the chart's pods to source-watcher's storage port (:9090) — **required
whenever the cluster runs Flux's shipped NetworkPolicies** (`flux install
--network-policy`, on by default: they deny cross-namespace ingress to
:9090). Replace its `chudmax-releases` placeholder with your release's
namespace before applying. Without it the fetcher waits forever with the
policies on; with `--network-policy=false` it is not needed.

Unlike the other manifests in this directory, **this policy lives in
`flux-system`** (it is pinned there under `metadata.namespace`): a
NetworkPolicy only selects pods in its OWN namespace, so applying it to the
release namespace selects nothing and source-watcher stays behind Flux's
default-deny (the phase-5 rehearsal burned a run proving exactly that). The
installer therefore needs **write access in flux-system** — or the platform
team carries the equivalent rule in their Flux install (a phase-12
prerequisite; the inventory walks it).

## The two phase-4 answers

**1. The copy rules fit the narrowed-artifact idea — they are the primary
route.** `spec.artifacts[].copy` globs select exactly the narrowed set
(`tickets.md`, `STATE.md`, `docs/**`, `decisions/**`) from the upstream
GitRepository artifact; the generated ExternalArtifact carries only them,
named `chudmax-tickets` — the name the chart pins. Content-hash revision
(`latest@sha256:<hash>`) means the fetcher re-fetches only when the narrowed
set changes; `originRevision: "@repo"` keeps the git commit in the artifact
metadata; `optional` stays false, so a missing file fails the generation
loudly (and fires an Alert) instead of shipping an incomplete set silently.

Two caveats:

- **Platform requirement:** source-watcher must be on the cluster (Flux
  ≥ 2.7.2, bootstrapped with `--components-extra=source-watcher`). The
  phase-12 platform inventory decides; this route is chosen only if it is
  there.
- **Revision honesty:** with a generated artifact, the revision the fetcher
  reports is the content hash (`latest@sha256:<hash>`), not
  `main@sha1:<commit>`. The git SHA stays visible on the GitRepository's
  status and in the Alerts; the phase-5 rehearsal records exactly what
  `repo_facts` surfaces.

**2. The fallback (only if the platform lacks source-watcher): the
GitRepository's own artifact + `spec.ignore` narrowing.** Stock Flux never
auto-populates an ExternalArtifact from a GitRepository
(`ExternalArtifact.spec.sourceRef` is informational only — a producing
controller must write `status.artifact`), so the fallback has two halves:
narrow the GitRepository artifact with `spec.ignore` — keeping `k8s/` in,
because the same artifact feeds the cluster's own reconciliation — and extend
the fetcher's watch mode with a `--kind GitRepository` flag (identical
`status.artifact` shape; the unpack core is untouched), which means the
chart's Role gains a second rule (`get`, `watch` on `gitrepositories`,
resourceName-pinned). A mirror-shim component was considered and rejected:
it adds a component to save a flag. The fallback is documented, not built.

## The fetcher's Role — the smallest it can be, unchanged

Namespaced, `get` + `watch` on `source.toolkit.fluxcd.io/externalartifacts`,
`resourceNames: [chudmax-tickets]` — exactly what the chart shipped. `get`
covers the startup self-heal read and the 1m resync re-read; `watch` carries
the live field-selector stream; `list` is unnecessary (the name is known and
pinned); `patch`/`update` belong to source-watcher, which owns the object;
no Secret access — the GitRepository's auth Secret is consumed by
source-controller only, and the fetcher's tarball GET is unauthenticated
in-cluster HTTP (mTLS is a later phase); no cross-namespace anything. Only
the fetcher container mounts the ServiceAccount token.

## Secrets (created out-of-band, referenced by name only — never in manifests)

| Secret | Created by | Keys |
|---|---|---|
| `chudmax-repo-auth` | the installer | SSH deploy key: `identity`, `known_hosts` (with the pinned host key) — or HTTPS token: `username`, `password` |
| `webhook-token` | the installer | `token` (a random string; the same value goes into the GitLab webhook's "Secret token" field) |
| `chudmax-notifications-credentials` | the installer | `address` (the channel's webhook URL); plus `token` if the chosen provider type wants one |

An installer of this chart creates these on their **own** deployment with
**their own** provider credentials: a GitLab token that can read their source
repo, a random webhook token, and the webhook address of the chat channel
they want the alerts in. "Phase 12" is only how chudmax's own deployment
schedules the same step; how the Secrets get created (kubectl vs SOPS vs
External Secrets) is each deployment's choice.

## Webhook and channel (phase-12 decisions, knobs ready)

- **Receiver:** the webhook URL is
  `<notification-ingress-host>` + `.status.webhookPath` (the path is
  `/hook/sha256sum(token+name+namespace)`). Until an ingress path exists the
  Receiver is inert, and the 1m GitRepository interval carries freshness
  without it. A feature-branch push triggers a reconcile that fetches `main`
  and no-ops — harmless.
- **Alerts:** `eventSeverity: info` — artifact updates and failures both
  ping the channel. If it gets chatty, tune `eventSeverity` to `error` and/or
  add an `exclusionList` to the Alert.
- **Provider:** ships `type: generic` with the channel address in the Secret.
  To move to a chat service, set `type` to `slack`, `discord`, `teams`,
  `telegram`, ... and add the keys that provider wants (usually `token`) to
  `chudmax-notifications-credentials`.

## Egress note (for whoever debugs the pod)

The generated artifact is served by **source-watcher's own storage server** —
not source-controller — so the chart's `networkPolicy.egress.sourceController`
values (namespace + port) point at **that** Service. The knob is the same
either way (namespace + port of whatever controller serves the URL in
`status.artifact.url`); the kube-apiserver 443 rule (the fetcher's watch) and
DNS stay untouched.

## ArtifactGenerator mechanics worth knowing

- There is no `spec.interval` on an ArtifactGenerator: its sources are
  **watched**, so a new GitRepository artifact regenerates the narrowed
  artifact immediately; the periodic reconcile that repairs drift defaults to
  1h via the `source.extensions.fluxcd.io/reconcileEvery` annotation.
- Drift repair also restores a deleted `chudmax-tickets` ExternalArtifact on
  the next reconcile — the fetcher self-heals through its startup read when
  the object reappears.

## Validation

```sh
flux plugin install schema        # or download the flux-schema release binary
flux schema validate k8s/repo-sync --schema-location default
```

Strict JSON-Schema + CEL validation against the Flux CRDs (the built-in
catalog covers GitRepository, ExternalArtifact, ArtifactGenerator, Alert,
Provider, Receiver). CI runs the same check on every push and PR
(`.github/workflows/repo-sync-validate.yml`).
