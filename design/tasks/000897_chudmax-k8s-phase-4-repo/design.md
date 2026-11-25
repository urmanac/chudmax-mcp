# Design: chudmax k8s phase 4 repo-sync manifests

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 4 writes the Flux half of "the repo reaches the ticket server" — the pod half is phase 3's chart. It adds manifests under `k8s/repo-sync/` in the public repo and answers the two questions the plan deferred. No cluster: flux-schema stands in for schema validation; phase 5 rehearses the chain on kind. Requirements are in `requirements.md` in this directory; the plan texts are `kubernetes/phases.md` and `kubernetes/repo-sync.md` on the private source-of-truth repo's `main` (`handoff-reported` from the task card — this session has no provider host in env).

## Shape

```
GitLab push ──► Receiver (type gitlab; X-Gitlab-Token checked against the Secret's token key)
                 │ triggers reconcile of the GitRepository
                 ▼
GitRepository chudmax-source (main, interval 1m, auth Secret)  ── Alert eventSources ─┐
                 │ FULL artifact tarball — stays complete for the phase-12 cluster sync│
                 ▼                                                                    │
ArtifactGenerator (copy rules: tickets.md, STATE.md, docs/decisions/**)               │
                 │ generates per-artifact; watches its inputs; content-hash revision  │
                 ▼                                                                    │
ExternalArtifact chudmax-tickets (created by source-watcher, same namespace)          │
                 │  get+watch — the phase-3 Role, resourceName-pinned                 │
                 ▼                                                                    │
fetcher watch ─► GET the artifact tarball (source-watcher's storage server)           │
                 └► unpack, swap /data/current (the volume contract, untouched)       │
                                                                                      │
Alert (GitRepository + ArtifactGenerator events, severity info) ─► Provider ─► the human's channel
```

## The two answers

**1. Copy rules fit the narrowed-artifact idea — they ARE the answer** (`verified-here` against the source-watcher `v1beta1` docs, 2026-11-25). `spec.artifacts[].copy` globs select exactly the three paths from the upstream GitRepository artifact, and the generated ExternalArtifact carries only them, named `chudmax-tickets` — exactly the name the chart's Role pins. What matters about it:

- **Content-hash revision** (`latest@sha256:<hash>`): the fetcher re-fetches only when the narrowed set changes; commits touching `tools/` or `kubernetes/` never churn the pod.
- **`originRevision: "@repo"`** keeps the original git commit in the artifact metadata for traceability.
- **`optional` stays false**: a missing narrowed file fails the generation loudly (and the Alert fires) instead of shipping an incomplete set silently.
- Two caveats, recorded in the README: (a) the route requires source-watcher on the platform (Flux ≥ 2.7.2, `--components-extra=source-watcher`) — the phase-12 platform inventory decides; (b) the revision the fetcher reports becomes the content hash, not `main@sha1:<commit>` — the git SHA stays visible on the GitRepository's status and in Alerts; phase 5 records exactly what `repo_facts` surfaces.

**2. Fallback (if the platform lacks source-watcher): ignore-narrowed GitRepository + a small fetcher addition.** Verified against the ExternalArtifact docs: `spec.sourceRef` is informational — stock Flux never writes `status.artifact` on a bare ExternalArtifact pointing at a GitRepository, so the fetcher's ExternalArtifact-only watch cannot consume a GitRepository artifact as-is. The fallback therefore has two halves: GitRepository `spec.ignore` narrowed to the data — but keeping `k8s/` in, because the same GitRepository artifact feeds the phase-12 cluster sync — and the fetcher's watch mode gaining `--kind GitRepository` (identical `status.artifact` shape; the unpack core is untouched). The mirror-shim alternative (a component copying GitRepository status into an ExternalArtifact) is rejected: it adds a component to save a flag. The fallback is written down, **not built** — it is chosen only if the phase-12 inventory rules out source-watcher.

**3. Smallest Role: the phase-3 Role, unchanged — recorded as the final answer.** Namespaced, `get` + `watch` on `source.toolkit.fluxcd.io/externalartifacts`, `resourceNames: [chudmax-tickets]`. Why nothing can be added or removed: `get` covers the startup self-heal read and the 1m resync re-read; `watch` carries the live field-selector stream; `list` is unnecessary (the name is known and pinned); `patch`/`update` belong to source-watcher, which owns the object; no Secret access — the GitRepository's auth Secret is consumed by source-controller only, and the fetcher's tarball GET is unauthenticated in-cluster HTTP (mTLS is phase 17); no cross-namespace anything (generator and artifact are created in the pod's namespace). Only the fetcher container mounts the token. The README records this; no chart file changes.

## Manifest set (public-safe)

| File | Content |
|---|---|
| `gitrepository.yaml` | GitRepository `chudmax-source`: placeholder `spec.url`, `ref.branch: main`, `interval: 1m`, `secretRef: chudmax-repo-auth`; no `spec.ignore` |
| `artifactgenerator.yaml` | ArtifactGenerator: source alias `repo` → `chudmax-source`; artifact `chudmax-tickets`, `originRevision: "@repo"`, three copy rules (`tickets.md`, `STATE.md`, `docs/decisions/**`) |
| `receiver.yaml` | Receiver: `type: gitlab`, `events: ["Push Hook"]`, `secretRef: webhook-token`, `resources` → the GitRepository |
| `alerts.yaml` | Provider `chudmax-notifications` (`type: generic`, channel address from its Secret) + Alert: `eventSeverity: info`, eventSources GitRepository + ArtifactGenerator |
| `README.md` | install, namespace rule, secret-keys table, webhook path, channel options, both answers + the fallback |

- Manifests omit `metadata.namespace`; install with `kubectl -n <release-ns> apply -f k8s/repo-sync/`. The namespace must be the chart release's — the Role and the generated ExternalArtifact are namespaced to it.
- Secrets are never shipped: at phase 12 the human creates `chudmax-repo-auth` (SSH deploy key: `identity` + `known_hosts` with the pinned host key; or HTTPS `username`/`password`), `webhook-token` (key `token`, a random string — the same value goes into the GitLab webhook's "Secret token"), and the notifications Secret (key `address`; plus the provider's `token` key if the chosen type needs one) — the secrets-mechanism decision (open item 6) governs how.
- The Receiver is inert without an ingress path (the phase-12 webhook-route decision — open item 2 in `repo-sync.md`); the 1m interval keeps freshness without it. A feature-branch push triggers a reconcile that fetches `main` and no-ops — harmless.
- Egress: the generated artifact is served by **source-watcher's own storage server** (not source-controller), so the chart's `networkPolicy.egress.sourceController` values point at that Service (same knob, same namespace/port pattern as the Flux install; phase-12 inventory confirms). No chart change.
- The ArtifactGenerator has no `spec.interval` — its inputs are watched; drift repair defaults to 1h via the `source.extensions.fluxcd.io/reconcileEvery` annotation (knob noted in the README).

## Validation

`flux-schema` (`fluxcd/flux-schema`) is the card's "validated against the Flux schemas", literally: a Flux CLI plugin doing strict JSON-Schema + CEL validation with Kubernetes-API-server semantics; its built-in catalog covers every kind used here (extracted from Flux v2.10.1 CRDs). Locally: `flux plugin install schema`, then `flux schema validate k8s/repo-sync --schema-location default`. In CI: a small workflow using `fluxcd/flux2/action` (installs the CLI + `plugins: schema`) and the `fluxcd/flux-schema/actions/validate` composite action, pinned to a release tag. Fallback if the plugin fights the runner: a Go strict-decode test against the API modules (`source-controller/api` v1, `source-watcher/api` v1beta1, `notification-controller/api` v1) — noted, not built.

## Key decisions

1. ArtifactGenerator is the primary narrowed-artifact route (copy rules fit — verified against the API docs); ignore-narrowing is the documented fallback, unbuilt.
2. The fetcher's Role is final as phase 3 shipped it; phase 4 writes the justification and changes no chart file.
3. Manifests are plain YAML without `metadata.namespace` (installed with `-n`); no kustomization.yaml, no Helm — the chart stays the pod's single packaging.
4. flux-schema is the validator, pinned by release in CI; the Go strict-decode test is the noted fallback.
5. All deployment specifics (real URL, secrets, channel, ingress path) are phase-12 human values; the public manifests carry placeholders and names only.

## Notes for future agents (learnings)

- The generated artifact is served by source-watcher's storage server (`--storage-addr`, default :9090 behind its Service) — **not** source-controller. Whoever debugs the pod's egress must know which controller serves the URL in `status.artifact.url`; the chart's egress knob (namespace + port from values) covers either.
- Receiver v1 uses `.spec.resources` (the older `.spec.sourceRef` is gone); the webhook path is `/hook/sha256sum(token+name+namespace)`, in `.status.webhookPath` once Ready.
- GitLab Receiver events match the `X-Gitlab-Event` header value — `"Push Hook"` (that exact casing) for pushes; `"Tag Push Hook"` for tags.
- The ArtifactGenerator's periodic reconcile is **not** `spec.interval` — it is the `source.extensions.fluxcd.io/reconcileEvery` annotation (default 1h); changes propagate via watched inputs, not via polling.
- `ExternalArtifact.spec.sourceRef` is informational only — nothing in stock Flux auto-populates an ExternalArtifact from a GitRepository. Any future "just point an ExternalArtifact at the GitRepository" idea silently stalls with no artifact.
- flux-schema also offers `flux schema explain TYPE` (field docs without a cluster) and `flux schema discover` — handy during implementation and the phase-5 rehearsal.
- This sandbox had `GITLAB_SECRET_TOKEN` but no provider host — the private source-of-truth repo was not readable here. The implementing session should re-verify the narrowed paths (`tickets.md`, `STATE.md`, `docs/decisions`) against the real tree before finalizing the copy rules.
- Public-mirror discipline: the GitRepository URL is a placeholder; Secret names are fine (names, not credentials); no internal hostnames anywhere in the public repo.

## What this settles

- The Flux side exists as reviewable parts: five files + README + CI schema validation; both plan questions answered with evidence and explicit decision points.
- Nothing is placed anywhere: no cluster touched, no secrets created, no box change — phase 5 rehearses on kind, phase 12 places for real.
