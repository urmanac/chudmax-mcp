# Requirements: chudmax k8s phase 8 image automation rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 8 (`kubernetes/phases.md`, SPIKE row H; source `design/tasks/000888_fetch-mr-17/design.md`): **a new tag becomes a commit on a review branch without a person** — `ImageRepository` objects scan the images, `ImagePolicy` objects select by semver range, and one `ImageUpdateAutomation` writes the resolved tags into release values and pushes to a review branch, **never main**. Rehearsed in CI on kind with Flux's image-reflector and image-automation controllers. Depends on phase 6 (engine + web charts, umbrella — merged). Steering alignment (2026-11-25, `handoff-reported`): rehearse against an **in-cluster `registry:2`** plus the local Go Smart-HTTP git server pattern (ghcr.io is not published until phase 10); scan **all three** house-built images (`ghcr.io/urmanac/chudmax/fetcher`, `chudmax/tickets-mcp`, `chudmax/web` — hermes-agent excluded: it consumes upstream `nousresearch/hermes-agent` semver tags manually, phase 9's card); disjoint write set of **only** `k8s/image-automation/**` + `.github/workflows/image-automation.yml`; CI rehearsal logs stream synchronously (`set -o pipefail`, `2>&1 | tee "$RUNNER_TEMP/smoke.log"` — never a hidden redirect); strict public hygiene (no RFC1918 LAN IPs, no real credentials, LICENSE deferred).

## Preconditions (verified, 2026-11-26)

- [x] Phase 6 merged on public `main` @ `a757821`: the umbrella + the three image references live at `ghcr.io/urmanac/chudmax/{fetcher,tickets-mcp,web}:0.1.0` (`k8s/chart/chudmax-mcp/values.yaml`, `k8s/umbrella/chudmax/subcharts/chudmax-web/values.yaml`), the web Dockerfile at `k8s/umbrella/chudmax/web-image/`, the Strata pin (`de34ebaa…`, tag `v0.2.21-mbp.rtx.1`) in the umbrella README's pins table — `verified-here` (local clone).
- [x] Phase 7 (Flagger canary) and phase 9 (Hermes chart) are **active in parallel, unmerged** (branches `feature/000899…`, `feature/000895…` exist; neither tree is on `main`) — `verified-here`.
- [x] Phase 5's rehearsal machinery is merged and reusable by path: `k8s/rehearsal/gittestserver/` (Smart-HTTP wrapper driving `git-http-backend`), `k8s/rehearsal/kind-config.yaml`, the `__RUNNER_HTTP__` render convention, the `flux schema validate --schema-location default` CI pattern — `verified-here`.
- [x] Flux API receipts (docs fetched 2026-11-26, `verified-here`): `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation` are `image.toolkit.fluxcd.io/v1`; `ImageRepository.spec.insecure` allows a plain-HTTP registry; the setters strategy is driven by `# {"$imagepolicy": "ns:name"}` markers; with the default `GitForcePushBranch` feature gate the push branch is **overwritten** from the checkout branch each run; the automation pushes with the referenced `GitRepository`'s `secretRef` credentials; `ImagePolicy` changes trigger a run outside `spec.interval`.

## Parallel-work boundaries (hard)

- Phase 8's write set is exactly `k8s/image-automation/**` + `.github/workflows/image-automation.yml` + this task dir. **Do NOT write** `k8s/umbrella/`, `k8s/canary/`, `k8s/chart/`, `k8s/monitoring/`, `k8s/repo-sync/`, `k8s/rehearsal/`, the root README, or any other workflow.
- Phase 7 (canary) and phase 9 (Hermes) are active in parallel — their files (`k8s/canary/**`, `canary-kind.yml`, `k8s/chart/hermes-agent/**`, `hermes-chart.yml`, the hermes-agent repo) are untouched, and their branches are never a dependency. Helpers the phase-8 script needs are duplicated into `k8s/image-automation/`, never imported from an active branch.
- Merged-`main` trees are consumed **read-only by path**: `k8s/rehearsal/kind-config.yaml`, the three Dockerfiles (`k8s/image/`, `k8s/tickets-mcp/`, `k8s/umbrella/chudmax/web-image/`), the umbrella README's pins table.

## User stories

1. **As the operator**, when a new semver tag lands in the registry, Flux — not a person — notices it: the `ImageRepository` scan receipts the tag count, the `ImagePolicy` resolves the latest within its range, and the `ImageUpdateAutomation` commits the new image references into release values. The cluster never waits on a hand-run `git pull`-shaped step.
2. **As the human reviewer**, the review branch is my merge surface: a bot-authored commit whose message lists every bump (`<old> -> <new>` lines from the automation's `{{ .Changed.Summary }}`), rebased on main's tip each run. I merge it or ignore it; the machine never touches `main`.
3. **As the security owner**, the automation's credential is provably one-branch-scoped: a push to `main` **with that same credential is denied** by the git server (the rehearsal's stand-in for production's protected-branch rule) while the automation's review-branch push succeeds — proven by a negative control, not assumed. No credential, LAN address, or internal hostname appears in any public artifact.
4. **As the rehearsal**, everything is runner-local: the images come from a **in-cluster `registry:2`** (the ghcr stand-in — nothing is published until phase 10) and the git remote is the runner-hosted Smart-HTTP server; the rehearsal pushes images and commits only to these stand-ins.
5. **As the maintainer**, all three house-built images ride the same loop (fetcher, tickets-mcp, web) — one `ImageRepository`+`ImagePolicy` pair each — while hermes-agent is deliberately excluded (upstream `nousresearch/hermes-agent` tags, chosen manually by phase 9's chart).
6. **As CI**, I want `image-automation.yml` to validate the manifests against the Flux schemas (no cluster needed) and re-run the full rehearsal on kind; the kind job's log streams live to the runner log (`set -o pipefail` + `tee`) so a stuck run is watchable, with the receipts in the step summary and logs uploaded on failure.

## Acceptance criteria

**Write set and hygiene (hard)**
- [ ] Phase 8 touches only `k8s/image-automation/**`, `.github/workflows/image-automation.yml`, and this task dir; every exclusion listed above holds, including while phases 7/9 are active.
- [ ] Zero RFC1918 LAN IPs, zero real credentials anywhere in the write set (the registry URL, the git URL, and the bot identity are runner/runtime facts; the bot email uses a reserved domain, e.g. `@chudmax.invalid`; doc IPs are RFC 5737 `203.0.113.x`). The generated rehearsal password is never echoed and a receipt grep proves the smoke log and summary are credential-free before any artifact upload. No LICENSE file (deferred per steering).
- [ ] No push to any public registry and no push to any real remote (ghcr.io stays unpublished until phase 10 — the standing rule; the rehearsal's only pushes go to the runner-local registry and git server).

**The committed, production-shaped set (`k8s/image-automation/`)**
- [ ] `imagerepository.yaml` — three `ImageRepository` (`image.toolkit.fluxcd.io/v1`, flux-system convention, no in-manifest namespace): `ghcr.io/urmanac/chudmax/{fetcher,tickets-mcp,web}`, `interval: 5m`, no `secretRef` (anonymous scans until phase 10 wires auth), default exclusion list.
- [ ] `imagepolicy.yaml` — three `ImagePolicy`, one per repository, `policy.semver.range: '>=0.1.0 <1.0.0'` (stable 0.x line; prerelease tags excluded by the semver policy — documented).
- [ ] `imageupdateautomation.yaml` — one `ImageUpdateAutomation` (`chudmax-image-updates`): `sourceRef` → the production `GitRepository chudmax-source` (owned by `k8s/repo-sync/` — not re-committed), `git.push.branch: review/image-updates`, `git.commit` with the bot author + `messageTemplate` carrying `{{ .Changed.Summary }}`, `update.strategy: Setters`, `update.path` pointing at the production release-values tree (final path pinned at the phase-12 wiring — commented, `speculation`).
- [ ] `networkpolicy-allow-image-controllers-egress.yaml` — an additive allowance for the image-reflector + image-automation pods' external egress (the registry scan / the git push), the production shape phase 12 will need; the rehearsal records whether it was load-bearing under Flux's shipped policies.
- [ ] `README.md` — the rehearsal↔production mapping table (in-cluster registry ↔ ghcr.io; basic-auth secret ↔ the write-scoped deploy key/token in `chudmax-repo-auth`; the update hook ↔ GitLab protected `main`; the review branch ↔ the human's merge surface), the **finding that the phase-12 read-only deploy key alone cannot push** (image automation needs a write-enabled credential scoped to the review branch), the hermes-agent exclusion note, and the phase-10/12 wiring pointers.

**The rehearsal fixtures (`k8s/image-automation/rehearsal/`)**
- [ ] `gittestserver/` — the phase-8 wrapper module (a duplicate of the phase-5 helper, never a cross-branch reference, with zero module deps): optional basic auth (`-auth user:pass`) and a per-request identity marker in the CGI env; binds `0.0.0.0` so the cluster reaches it.
- [ ] `main-protect-hook.sh` — the bare repo's `update` hook: over HTTP, **every** push to `refs/heads/main` is rejected with a legible message; the review branch is writable. (Seeding never pushes `main` over HTTP — the bare repo is seeded by clone.)
- [ ] `registry.yaml` — `registry:2` (pinned 2.x tag) Deployment + NodePort Service in flux-system; reachable in-cluster at `registry.flux-system.svc:5000` and from the runner via the node IP.
- [ ] `gitrepository-rehearsal.yaml` — GitRepository `chudmax-source`, the test variant of the production shape with exactly two deltas (the documented phase-5 convention): `url: http://__RUNNER_HTTP__/repo.git` and the rehearsal-format `secretRef: chudmax-repo-auth` (username/password — the production secret's HTTPS-token form).
- [ ] `imagerepository-rehearsal.yaml`, `imageupdateautomation-rehearsal.yaml` — the rehearsal variants of the committed set (in-cluster registry URLs + `insecure: true`; `update.path: values`); the rehearsal-only `values/images.yaml` fixture with the three `# {"$imagepolicy": "flux-system:chudmax-*"}` marker lines seeded at `0.1.0`.
- [ ] `image-automation-rehearse.sh` — the orchestrator (see design); the CI kind job is its authoritative run.

**The rehearsal script's proof sequence**
- [ ] Pre-flight: the wrapper builds; `git ls-remote` proves the credentialed Smart-HTTP URL; the hook mechanics are exercised runner-side (allowed review push, denied main push) before anything is applied.
- [ ] Cluster up: kind (phase-5 config by path, stock kindnet), `flux install -v v2.10.1 --components-extra=image-reflector-controller,image-automation-controller` under shipped policies; registry ready; the rendered secret created out-of-band (`fluxbot` + a generated random password, never echoed).
- [ ] Images: the three real images built (amd64; fetcher + tickets-mcp + web from the pinned Strata SHA), fully-qualified names, then pushed into the rehearsal registry — `0.1.0` first.
- [ ] **Idle beat:** with only `0.1.0` present, the scan receipts `tagCount: 1`, the policies resolve `0.1.0` (= the seeded values), and the automation reports no change — **no review branch exists** (`git ls-remote` shows no such ref): the loop writes nothing when there is nothing to write.
- [ ] **Update beat (the headline):** `0.1.1` tags pushed (same bytes, retagged) → scans receipt `tagCount: 2` → all three policies resolve `0.1.1` → the automation pushes **one commit** to `review/image-updates` whose diff carries all three new full image refs; `main`'s SHA is byte-unchanged; `status.lastPushCommit` + the `pushed commit … to branch 'review/image-updates'` event + the rendered commit message are receipted.
- [ ] **Repeat beat:** `0.1.2` pushed → the review branch's tip is overwritten to `0.1.2` (the default push-branch semantics, receipted with both commit SHAs) — the loop keeps running.
- [ ] **The one-branch control:** with the automation's own credential, a runner-side `git push` to `main` is **denied** by the hook (its message receipted) and `main` stays unchanged; the automation's successful review-branch push is the positive control on the same credential.
- [ ] The record: scans, policy resolutions, the automation's status/events, the review diff, the main-SHA invariance, and the denial message go to the step summary; the honest framing line (rehearsal stand-ins ↔ the phase-10/12 production wiring) is printed.

**Workflow (`image-automation.yml`) and flow**
- [ ] Job `validate` (no cluster): `flux schema validate k8s/image-automation --schema-location default` (base + rehearsal sets), `bash -n` on the script and hook, the wrapper module builds, the base↔rehearsal lockstep greps (the three image paths present in both; the three markers present), the fixture YAML parses, and the hygiene grep (no RFC1918-shaped strings) — the `image-chart.yml` fixture-hygiene pattern.
- [ ] Job `rehearsal` (kind): the run step is exactly the streaming shape — `set -o pipefail`, then the script `2>&1 | tee "$RUNNER_TEMP/smoke.log"` — with the always-step appending the summary to `$GITHUB_STEP_SUMMARY` and failure uploading the logs; `permissions: contents: read`; no secrets; triggers `workflow_dispatch` / PR / push-on-main scoped to the write set. All other workflows stay green and untouched.
- [ ] Proofs recorded in this task dir (`proofs.md`) with the three labels; one PR via `propose_pull_request` from a feature branch off current `main`; conventional commits; merge authority CoS; `mark_task_complete` only after merge.

## Out of scope (owned by other phases or decisions)

- Publishing images/charts to ghcr.io, cosign signing, the `flux mirror` config — phase 10. The live cluster's GitRepository/secret wiring and the real deploy key — phase 12 (this card's README carries the write-credential finding to that milestone).
- Flagger, the canary, the mcp artifact chain (`k8s/canary/`, `k8s/repo-sync/` objects are not applied by this rehearsal) — phases 7/5.
- The Hermes chart and hermes-agent image handling — phase 9 (parallel; hermes-agent has no `ImageRepository` here by design).
- GitLab MR auto-creation via `push.options` (docs-supported production option — documented in the README, not rehearsed; the wrapper does not advertise push options).
- The box (untouched), MetalLB, mTLS, placement — later phases.

## Open Questions

1. **The review branch's name** — `review/image-updates` is this spec's choice. Is that the branch you want Flux to push in production (it becomes a standing branch on the private repo), or do you prefer a different name (`flux/image-updates`, per-image branches, …)?
2. **The production `update.path`** — this spec commits `./kubernetes` (the private repo's plan tree) as the release-values tree, flagged `speculation` with the final pin deferred to the phase-12 wiring. Correct, or is the release-values home somewhere else (e.g. the public repo's umbrella values via a different GitRepository)?
3. **The semver range** — `'>=0.1.0 <1.0.0'` holds the automation to the stable 0.x line. Do you want a different production policy (e.g. per-image minor pinning, `>=0.1.0 <0.2.0`)?
4. **Auto-opened MRs** — should the production automation open a GitLab MR automatically (push options) so "merge the review branch" is one click, or is a bare review branch + a manual MR the intended flow?
