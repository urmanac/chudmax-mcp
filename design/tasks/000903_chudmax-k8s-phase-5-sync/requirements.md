# Requirements: chudmax k8s phase 5 CI sync rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 5 (`kubernetes/phases.md`; source `design/tasks/000888_fetch-mr-17/design.md`, SPIKE row E): **in CI, on a throwaway kind cluster with Flux — a commit to a test repo shows up in `list_tickets` with nobody doing anything, and a pod outside the policy cannot fetch the artifact.** Depends on phases 3 and 4 — both merged; public `main` @ `af65272` also carries phase 4b, whose default chart install runs the **published canonical ticket server** (`k8s/tickets-mcp/`) — the real server under rehearsal, not a stand-in.

**CoS steering (2026-11-25, `handoff-reported`) — this card's operative brief, supersedes the card's literal GATE text:** the runner-capability question is settled policy — GitHub-hosted `ubuntu-latest` runners run kind natively (kind-in-Actions is the standard pattern); there is no gate and nothing to re-flag anywhere. The proof recipe is Fable's three commits (owner-endorsed). The CNI is **Cilium** (the Cozystack-shaped answer). The test repo is served by **git-daemon on the runner**. The workflow file is **`rehearsal-sync.yml`**; phase 6's files (`umbrella.yml`, the engine-chart/web-chart/umbrella dirs) are outside this card's write set.

Everything happens in the public repo `urmanac/chudmax-mcp`: one chart-values fix the rehearsal's homework surfaced, a `k8s/rehearsal/` directory (config, fixture, admission policy, script, README), and one CI workflow. No registry push (phase 10), no placement (phase 11+), no box change, nothing lands on `main` unreviewed, no secrets in CI.

## Preconditions (verified)

- [x] Phases 3 and 4 merged on public `main` @ `67d8616`; phase 4b merged via PR #4 @ `af65272` (fetcher fixes, the published canonical server at `k8s/tickets-mcp/`, hardened chart, kubeconform CI) — `verified-here` (local clone + git log, 2026-11-25).
- [x] The chart's default install is fetcher + the published canonical server (`server.enabled: true`, `ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0`, `--http 8080 --host 0.0.0.0 --data-root /data`) — `verified-here` (`k8s/chart/chudmax-mcp/values.yaml`).
- [x] The fetcher's retention default is `--keep 3` (`k8s/fetcher/main.go`) — the three-commit recipe prunes the first tree on the third swap with **default chart values**, no knob needed — `verified-here`.
- [x] `flux install --components-extra="source-watcher"` is a documented CLI path; `--network-policy` defaults true (the shipped policies install with it) — `verified-here` (CLI docs fetched 2026-11-25).
- [x] In the pinned Flux v2.10.1 install bundle, source-watcher (v2.3.1) pods carry `app: source-watcher` (+ `app.kubernetes.io/component: source-watcher`) — **not** `app.kubernetes.io/name: source-watcher` — and serve the storage on :9090, advertised at the source-watcher Service DNS name — `verified-here` (bundle fetched and grepped 2026-11-25).
- [x] Flux's shipped NetworkPolicies admit cross-namespace ingress to the toolkit controllers only on :8080 (`allow-scraping`) and notification's :9292 (`allow-webhooks`); `allow-egress` restricts same-namespace otherwise — so a fetcher in the release namespace **cannot** reach source-watcher:9090 without an explicit admission policy — `verified-here` (policy manifests fetched 2026-11-25).
- [x] CI capability: GitHub-hosted `ubuntu-latest` runners run kind natively — settled policy per the steering brief — `handoff-reported`.

## User stories

1. **As the human**, I want the rehearsal to deploy the REAL published server via the chart's default install — not a hand-rolled stand-in — so what CI proves is byte-identical to what `helm install` gives any user.
2. **As the human**, I want the three-commit proof (Fable's, owner-endorsed): commit #1 → the chain delivers hands-off; commit #2 → the server serves the SECOND revision without restarting (the per-call contract under real API load — the regression Fable caught, proven explicitly); commit #3 → retention prunes → the server still answers.
3. **As the human**, I want `repo_facts` asserted between commits: `origin_revision` tracks the pushed git SHAs (`main@sha1:<sha>` via the generator's fallback) and `revision` is the content hash, which CHANGES per commit — all captured on the run.
4. **As the human**, I want the denial proven under a policy-enforcing CNI (Cilium): the fetcher's egress policy (DNS 53, apiserver 443 via the podSelector pattern, artifact server 9090 to source-watcher's pods) is exercised for real — the fetcher still succeeds — while a rogue pod outside the policies is denied the artifact URL; this also validates the phase-4b chart fixes under a Cilium-like CNI.
5. **As CI**, I want the rehearsal pinned, repeatable, and loud: fixed tool versions, a cluster created and deleted inside the job, images loaded via archive (no registry), no secrets, receipts on the run — in a workflow file that phase 6's parallel work cannot collide with.

## Acceptance criteria

- [ ] **The real server:** the rehearsal installs the chart with default values — server image built from `k8s/tickets-mcp/Dockerfile`, fetcher from `k8s/image/Dockerfile`, both loaded into kind via archive; no hand-rolled stand-in server exists anywhere in the rehearsal.
- [ ] **The chart fix:** `networkPolicy.egress.sourceController.selector` default corrected from `app.kubernetes.io/name: source-watcher` to the labels the install bundle actually puts on the pods (`app: source-watcher` — `verified-here`); values comment + chart README updated; existing chart CI (lint/template/kubeconform, both variants) stays green.
- [ ] `k8s/rehearsal/` added with: `kind-config.yaml` (single node), `fixture/` (synthetic tree carrying all four narrowed entries — `tickets.md`, `STATE.md`, `docs/`, `decisions/` — invented content only; the copy rules' `optional: false` must never fire), `gitrepository-test.yaml` (URL `git://<runner-gateway>:9418/<repo>.git` rendered by the script, **no** `secretRef` — the deltas vs production documented), `artifact-ingress.yaml` (admission NetworkPolicy: ingress :9090 to `app: source-watcher` pods from the release namespace's release-labeled pods — with the phase-12 note), `rehearse.sh` (the orchestrator), and `README.md` (what is proven, how to run, the findings, the handoff note).
- [ ] **Commit #1:** pushed before the manifests apply; the chain (GitRepository 1m interval → ArtifactGenerator → ExternalArtifact → fetcher swap) delivers v1 with **nobody doing anything** — `list_tickets` over the Service shows the seed ticket; the fresh-install wait → self-heal is observable and asserted on the way.
- [ ] **Commit #2 (the Fable regression, explicit):** pushed; the probe keeps polling `list_tickets` across the swap window; the answer shows v2, every answer after the swap serves the new tree (no stale v1-after-v2), and the server container's `startedAt`/`restartCount` are UNCHANGED — the second revision served without a restart.
- [ ] **Commit #3 (retention):** pushed; the server still answers after the prune (`/data/revisions` ≤ keep=3, v1's dir gone); `repo_facts` captured after EVERY commit and asserted (see story 3); all three JSONs land in the CI step summary — phase 4's promise "the phase-5 rehearsal records exactly what `repo_facts` surfaces" is kept.
- [ ] **The denials (Cilium-enforced):** the fetcher succeeds with the egress policy ON (positive path under enforcement); a rogue pod (release ns, default ServiceAccount, no labels) GETs the ExternalArtifact via the API → 403 (it cannot even learn the artifact URL — the phase-4 Role answer, now proven) and GETs the artifact tarball from source-watcher:9090 → denied; positive controls: the fetcher's fetch, a label-carrying Role-less pod CAN fetch the tarball (the admission policy's shape is what admits), and the port-scope probe from inside the chudmax pod (:9090 allowed, an unlisted port denied) — the fences bite, not merely exist.
- [ ] **CI shape:** `.github/workflows/rehearsal-sync.yml` (pinned kind, flux, Cilium, probe-image refs; `workflow_dispatch` plus path-scoped triggers on `k8s/**`; minimal permissions — nothing is pushed to any remote); the cluster is created and deleted inside the job (cleanup `if: always()`); no secrets; the four existing workflows stay green; **this card edits NO phase-6 file** (`umbrella.yml`, engine-chart/web-chart/umbrella dirs) — a needed helper is duplicated into `k8s/rehearsal/`, not shared.
- [ ] **Alerts optional with a dummy sink:** `alerts.yaml` applied with the Provider pointing at an in-cluster sink pod; asserting at least one delivered event is optional — dropped honestly if it fights the budget, never left flaky.
- [ ] **House rules:** work lands via PR to `main` only; conventional commits; the three labels on all claims; the box untouched; fixture content invented (no real tickets, no LAN hostnames, no tokens); in-sandbox proofs recorded with receipts (CI is the authoritative full-chain proof).

## Out of scope (owned by other phases or decisions)

- The Receiver in-cluster (inert without an ingress path by design; schema-validated in phase 4; exercised at phase 12's webhook decision).
- Image publishing (phase 10); placement, secrets, MetalLB, cutover (phases 11–14); canary (7), image automation (8), engine/web charts + umbrella (6), Hermes (9), mTLS (17).
- Any change to the fetcher or the server code (exercised as shipped; findings that need code changes get their own ticket).

## Open Questions

None. *(Both questions raised during planning are resolved by the CoS steering, 2026-11-25: the runner capability is settled policy — GitHub-hosted runners, no gate; the test repo is the git-daemon-on-runner route — no fixture branch, no in-cluster git server.)*
