# Requirements: chudmax k8s phase 5 CI sync rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 5 (`kubernetes/phases.md`; source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row E): **in CI, on a throwaway kind cluster with Flux — a commit to a test repo shows up in `list_tickets` with nobody doing anything, and a pod outside the policy cannot fetch the artifact.** Depends on phases 3 and 4 — both done and merged; public `main` @ `af65272` also carries phase 4b, which made the chart's default install run the fetcher sidecar plus the published canonical ticket server — exactly the pod this rehearsal deploys.

**GATE (blocking, from the card): this needs CI runners privileged enough to run kind, or self-hosted k3d — the human must confirm capability before this card starts.** Verified nuance for that confirmation: the public repo's CI is GitHub Actions, and GitHub-hosted `ubuntu-latest` runners run kind natively (Docker present, no privileged-runner machinery) — so the realistic choice is "GitHub-hosted runners" vs "self-hosted runner / k3d". Until the human confirms, nothing is built.

Everything happens in the public repo `urmanac/chudmax-mcp`: one chart-values fix the rehearsal's homework surfaced, a `k8s/rehearsal/` directory (config, fixture, admission policy, script, README), and one CI workflow. No registry push (phase 10), no placement (phase 11+), no box change, nothing lands on `main` unreviewed, no secrets in CI.

## Preconditions (verified)

- [x] Phases 3 and 4 merged on public `main` @ `67d8616`; phase 4b merged via PR #4 @ `af65272` (fetcher fixes, published canonical server at `k8s/tickets-mcp/`, hardened chart, kubeconform CI) — `verified-here` (local clone + git log, 2026-11-25).
- [x] The fetcher's retention default is `--keep 3` (`k8s/fetcher/main.go`), so a three-commit rehearsal prunes the first tree on the third swap with **default chart values** — no chart knob needed — `verified-here`.
- [x] `flux install --components-extra="source-watcher"` is an officially documented CLI path (docs fetched 2026-11-25) — `verified-here`.
- [x] In the pinned Flux v2.10.1 install bundle, source-watcher (v2.3.1) pods carry labels `app: source-watcher`, `app.kubernetes.io/component: source-watcher`, `app.kubernetes.io/instance: flux-system` — **not** `app.kubernetes.io/name: source-watcher`; the storage server listens on 9090 and the artifact URL is advertised at the source-watcher Service DNS name — `verified-here` (bundle fetched and grepped 2026-11-25).
- [x] Flux's shipped NetworkPolicies admit cross-namespace ingress to the toolkit controllers only on :8080 (`allow-scraping`) and notification's :9292 (`allow-webhooks`); `allow-egress` restricts same-namespace otherwise — so a fetcher in another namespace **cannot** reach source-watcher:9090 without an explicit admission policy — `verified-here` (policy manifests fetched 2026-11-25).
- [x] `GitRepository.spec.url` accepts HTTP/S or SSH addresses (docs fetched 2026-11-25) — the test repo is served over HTTPS, not `git://` — `verified-here`.
- [ ] **GATE: the human's CI-capability confirmation** (see Open Questions) — this box stays unchecked until the answer arrives; the card does not start before it.

## User stories

1. **As the human**, I confirm the CI capability once (GitHub-hosted runners vs self-hosted k3d) before the card starts, so the spike's flagged gap is closed by a decision, not by a stranded half-build.
2. **As the human**, I want the rehearsal to prove the whole chain hands-off on a throwaway kind cluster — commit to a test repo → GitRepository → ArtifactGenerator → ExternalArtifact → fetcher swap → the published server's `list_tickets` — with nobody running kubectl against Flux or the pod between the push and the answer.
3. **As the human**, I want the denial proven end-to-end: a pod outside the policies cannot learn the artifact (RBAC 403 on the ExternalArtifact) and cannot fetch the tarball (NetworkPolicy denial), each with a positive control proving the fence is enforced — not merely present.
4. **As the phase-12 installer**, I want the rehearsal's integration findings written down — the chart's egress selector fix and the artifact-store admission policy — so the real platform install inherits them instead of rediscovering them.
5. **As CI**, I want the rehearsal pinned, repeatable, and loud: fixed tool versions, a cluster created and deleted inside the job, images built and loaded locally (no registry), no secrets, and the `repo_facts` output recorded on the run.

## Acceptance criteria

- [ ] **GATE honored:** the human's confirmation (which runner route) is recorded before implementation starts and stated in the PR description; if unconfirmed, no implementation work happens.
- [ ] **The chart fix:** `networkPolicy.egress.sourceController.selector` default corrected from `app.kubernetes.io/name: source-watcher` to the labels Flux's install bundle actually puts on the pods (`app: source-watcher` — `verified-here` from the v2.10.1 bundle); values comment + chart README updated; existing chart CI (lint/template/kubeconform, both variants) stays green.
- [ ] `k8s/rehearsal/` added with: `kind-config.yaml` (single node), `fixture/` (synthetic tree carrying all four narrowed entries — `tickets.md`, `STATE.md`, `docs/`, `decisions/` — invented content only), `gitrepository-test.yaml` (the test variant: public fixture branch, no `secretRef` — the two deltas vs production documented), `artifact-ingress.yaml` (admission NetworkPolicy: source-watcher pods, :9090, from the release namespace's release-labeled pods — with the phase-12 note), `rehearse.sh` (the orchestrator), and `README.md` (what is proven, how to run, the findings, the handoff note).
- [ ] **Proof 1 — the headline:** the fixture's seed commit is pushed before the manifests are applied; after install the chain delivers v1 (the fetcher's fresh-install wait → self-heal is observable and asserted); a second commit is pushed and `list_tickets` — called over the Service from an in-cluster probe pod — shows the new ticket within the interval budget (≤ ~3 min) with **no kubectl interaction with Flux or the pod in between**; the pod's restartCount stays 0 across every swap (the per-call contract, for real).
- [ ] **Proof 2 — the denials:** a rogue pod (release namespace, default ServiceAccount, no release labels) (a) GETs the ExternalArtifact via the API → 403, and (b) GETs the artifact tarball from source-watcher:9090 → denied; positive controls: the fetcher fetches (the chain works) and a label-carrying, Role-less pod in the same namespace **can** GET the tarball — proving the fence is the admission policy and it is enforced. Plus the port-scope probe from inside the chudmax pod (:9090 allowed, an unlisted port denied) proving the chart's egress policy bites under the enforcing CNI.
- [ ] **Retention proof:** a third commit → `repo_facts` still answers after the prune; its recorded revision is the content hash (`latest@sha256:<hash>`) and `origin_revision` is the pushed commit SHA; the pruned revision's directory is gone (`/data/revisions` ≤ keep) and the server answers on the next call anyway — the phase-4b contract, exercised for real.
- [ ] **The record:** `repo_facts` JSON, the artifact URL shape, and the probe outputs are captured into the CI step summary (and uploaded as an artifact on failure) — phase 4's promise "the phase-5 rehearsal records exactly what `repo_facts` surfaces" is kept.
- [ ] **CI shape:** a new workflow (pinned kind, flux, CNI and image refs; `workflow_dispatch` plus path-scoped triggers on `k8s/**`); the cluster is created and deleted inside the job (cleanup on failure too); no secrets used; the three existing workflows stay green; job budget stated and honored.
- [ ] **House rules:** work lands via PR to `main` only; the box is untouched; the three labels on all claims; the fixture is invented content (no real tickets, no LAN hostnames, no tokens); the local-sandbox run is best-effort and recorded honestly (CI is the authoritative proof).

## Out of scope (owned by other phases or decisions)

- The Receiver and Alert objects in-cluster (webhook path is phase 12's decision; they stay schema-validated-only, as phase 4 left them).
- Image publishing, cosign, credential-free pulls — phase 10. Real placement, secrets, MetalLB, cutover — phases 11–14.
- Canary (7), image automation (8), engine/web charts (6), Hermes (9), mTLS (17).
- Any change to the fetcher or the server (the rehearsal exercises them as shipped; findings that need code changes get their own ticket).

## Open Questions

1. **The GATE — the human's CI-capability confirmation, required before this card starts:** is the authorized route (a) GitHub-hosted `ubuntu-latest` runners for the kind rehearsal (they run kind natively; nothing privileged to provision), or (b) a self-hosted runner (with kind or k3d)? The card's "GitLab CI runners" phrasing predates the public repo's GitHub-Actions home — the confirmation is yours either way.
2. **The test repo's home:** the design proposes CI force-pushing a disposable fixture branch (synthetic content) on this public repo — zero extra infrastructure, but it adds one noisy branch. If stray branches on `urmanac/chudmax-mcp` are unwelcome, the fallback is a throwaway in-cluster git server (Gitea, pinned image — sketched in `design.md`, unbuilt). Which do you want?
