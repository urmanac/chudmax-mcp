# Requirements: chudmax k8s phase 4 repo-sync manifests

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 4 (`kubernetes/phases.md`; source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row D): **`k8s/repo-sync/` — the Flux objects that move the narrowed artifact from the source repo to the ticket server's pod: a GitRepository on `main` (interval 1m), the narrowed artifact (source-watcher's ArtifactGenerator over `tickets.md`, `STATE.md`, `docs/`, `decisions/`), a Receiver (type gitlab, token Secret), and Alerts to a channel the human chooses — validated against the Flux schemas.** The phase must also answer the two questions the plan left open: whether ArtifactGenerator's copy rules fit the narrowed-artifact idea (`speculation` in `repo-sync.md`; fallback = the GitRepository's own artifact + ignore-rule narrowing), and what the smallest Role the fetcher can live with is. Depends on phase 3 (done and merged).

Everything happens in the public repo `urmanac/chudmax-mcp`: manifests + README under `k8s/repo-sync/` and one CI validation job. No cluster (that is phase 5's kind rehearsal), no registry push, no box change, nothing lands on `main` unreviewed.

## Preconditions (verified)

- [x] **Steering brief (CoS, 2026-11-25) — `handoff-reported`:** the narrowed set is `tickets.md`, `STATE.md`, `docs/`, `decisions/` — two top-level dirs, not `docs/decisions` (resolves this doc's former Open Question 1); the GitRepository may carry the real private-repo URL in the public repo (a URL is public-safe; credentials never are; the Receiver token Secret is created out-of-band, referenced by name only); validation is "kubeconform with the fluxcd source-controller CRDs fetched in the workflow, **or equivalent**"; the phase-5 CI-capability decision (privileged GitHub runners vs self-hosted k3d, undecided by the owner) is flagged with one clear line in the PR description.

- [x] Phase 3 merged on public `main` @ `67d8616`: chart at `k8s/chart/chudmax-mcp/` watches the ONE ExternalArtifact named `chudmax-tickets` (values `externalArtifact.name`), Role pins `get`+`watch` on it with `resourceNames`, egress admits DNS + kube-apiserver + the artifact-serving controller; the chart's values comment says the repo-sync work owns the ExternalArtifact — `verified-here` (local clone, 2026-11-25).
- [x] ArtifactGenerator API (`source.extensions.fluxcd.io/v1beta1`): `spec.sources` (alias/kind/name) + `spec.artifacts` (name, `copy` from/to globs, `exclude`, `strategy`, `optional`) generate ExternalArtifacts named after `artifacts[].name` **in the generator's namespace**, with content-based revision `latest@sha256:<hash>`; sources are watched (no `spec.interval` field — drift repair is the `source.extensions.fluxcd.io/reconcileEvery` annotation, default 1h) — `verified-here` (upstream docs fetched 2026-11-25).
- [x] Receiver API (`notification.toolkit.fluxcd.io/v1`): type `gitlab` validates the `X-Gitlab-Token` header against the referenced Secret's `token` key; `.spec.resources` (not `.spec.sourceRef`) lists the reconciled objects; the webhook path is reported in `.status.webhookPath` — `verified-here` (upstream docs fetched 2026-11-25).
- [x] `flux-schema` (`fluxcd/flux-schema`, Flux CLI plugin): strict JSON-Schema + CEL manifest validation; its built-in catalog covers `GitRepository`, `ExternalArtifact`, `ArtifactGenerator` (`source.extensions.fluxcd.io`), and `Alert`, `Provider`, `Receiver` (`notification.toolkit.fluxcd.io`), extracted from Flux v2.10.1 CRDs; GitHub Actions composite actions exist — `verified-here` (upstream docs fetched 2026-11-25).
- [x] Stock Flux does **not** mirror a GitRepository's artifact into an ExternalArtifact: `ExternalArtifact.spec.sourceRef` is informational (a pointer to the CR a 3rd-party controller built it from); only a producing controller writes `status.artifact` — this is the fallback's real cost — `verified-here` (upstream ExternalArtifact docs fetched 2026-11-25).

## User stories

1. **As the human**, I want the two open questions answered with evidence — copy rules vs ignore-narrowing (with the fallback's real cost written down) and the smallest fetcher Role — so phases 5 and 12 stand on decided ground.
2. **As the human**, I want `k8s/repo-sync/` as one reviewable install (GitRepository 1m, narrowed ArtifactGenerator, gitlab Receiver, Alert + Provider) so phase 5 can rehearse the whole chain on kind and phase 12 can install it for real.
3. **As the human**, I want the manifests public-safe (placeholder source URL, no secrets, no internal hostnames) and a README that names exactly the Secrets I create at phase 12, so the public repo leaks nothing.
4. **As CI**, I want every push to validate the manifests against the Flux schemas (flux-schema, strict) so schema drift is caught in PRs, not on a cluster.
5. **As the human**, I want the webhook path and the alert channel left as my phase-12 decisions with the knobs ready: the Receiver is inert until an ingress path exists, and the 1m interval keeps the sync fresh without one.

## Acceptance criteria

- [ ] `k8s/repo-sync/gitrepository.yaml`: GitRepository `chudmax-source` — `spec.url` = the private source-of-truth repo's HTTPS URL (public-safe per the steering brief; a placeholder only if the implementing session lacks provider access, then flagged in the PR), `spec.ref.branch: main`, `spec.interval: 1m`, `spec.secretRef.name: chudmax-repo-auth`; **no** `spec.ignore` (the primary route narrows per-consumer).
- [ ] `k8s/repo-sync/artifactgenerator.yaml`: one source (alias `repo` → GitRepository `chudmax-source`); one artifact named `chudmax-tickets` with `originRevision: "@repo"` and copy rules selecting exactly `tickets.md`, `STATE.md`, `docs/**`, `decisions/**`; `optional` stays unset (a missing narrowed file is a loud failure, not a silent skip).
- [ ] `k8s/repo-sync/receiver.yaml`: Receiver — `type: gitlab`, `events: ["Push Hook"]`, `secretRef.name: webhook-token`, `resources` → the GitRepository.
- [ ] `k8s/repo-sync/alerts.yaml`: Alert (`providerRef`, `eventSeverity: info` — confirmed by the human, 2026-11-25, eventSources GitRepository + ArtifactGenerator) + Provider (`type: generic`, the channel address read from its Secret).
- [ ] `k8s/repo-sync/README.md` answers both questions in writing: (a) copy rules fit — the primary route, with its two caveats (source-watcher must be on the platform — phase 12 inventory decides; the fetcher-reported revision becomes the content hash, not the git SHA) and the fallback (ignore-narrowing that keeps `k8s/` in the artifact for the phase-12 sync, plus a small fetcher `--kind` addition — built only if the fallback is chosen); (b) the smallest Role is the phase-3 Role unchanged, with the reasoning.
- [ ] README also covers: install (`kubectl -n <ns> apply -f k8s/repo-sync/` — manifests carry no `metadata.namespace`), the same-namespace rule with the chart release, the secret-keys table (`chudmax-repo-auth`, `webhook-token`, the notifications Secret), the webhook-path note (`status.webhookPath`, GitLab "Secret token"), the channel options (generic/slack/discord/teams/telegram — swap `type` + Secret keys), and the egress note (the generated artifact is served by source-watcher's storage server — the chart's `networkPolicy.egress.sourceController` values point at that Service).
- [ ] `flux schema validate k8s/repo-sync --schema-location default` passes locally and in CI (new workflow, actions pinned to a release; existing workflows stay green) — or the steering brief's equivalent (kubeconform over schemas extracted from the fluxcd CRDs, fetched in the workflow) if flux-schema fights the runner.
- [ ] No changes to `k8s/fetcher/`, `k8s/chart/`, or `k8s/image/` (the Role answer is "as phase 3 shipped it"; the ExternalArtifact is source-watcher's output, not a shipped manifest).
- [ ] The box is untouched; work lands via PR to `main` only; the three-labels rule on all claims; no secrets, no real repo URLs, no internal hostnames in the public repo.

## Out of scope (owned by other phases or decisions)

- Cluster placement, real credentials, the webhook ingress path (DMZ vs Tailscale Funnel vs relay vs interval-only) — phases 11–12.
- The kind rehearsal (commit → fetcher swap → `list_tickets`; policy denial proof) — phase 5.
- The fallback fetcher `--kind` change — built only if phase 12's inventory rules out source-watcher.
- mTLS (phase 17), publishing (phase 10), the secrets-mechanism choice (open item 6).

## Open Questions

None. *(The narrowed paths and the alert severity — `info` — were both resolved by the human/CoS, 2026-11-25.)*
