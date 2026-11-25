# Design: chudmax k8s phase 5 CI sync rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 5 is the first phase with a cluster: a throwaway kind cluster inside a CI job on a GitHub-hosted runner (settled policy — no gate), Flux installed into it, the chart installed with **default values** (fetcher + the REAL published canonical server), the repo-sync test manifests applied, **Cilium** enforcing NetworkPolicies, and the card's two proofs run to completion with nothing touched by hand. Requirements are in `requirements.md` in this directory.

## Shape

```
CI job (GitHub-hosted ubuntu runner — settled policy, no privileged machinery needed)
  git init --bare /srv/git/repo.git + git-daemon --export-all :9418   (the test repo)
  kind create cluster → Cilium (pinned; kindnet does not enforce NetworkPolicy)
  flux install -v v2.10.1 --components-extra=source-watcher   (shipped policies ON)
  build fetcher + server images (docker) → save → kind load image-archive   [no registry]
  helm install chudmax-mcp k8s/chart/chudmax-mcp   (default values — the REAL server)
      → fetcher WAITS (Running, not-ready, no crash-loop — the phase-4b behavior, for real)
  apply: gitrepository-test.yaml + artifactgenerator.yaml (-n chudmax-rehearsal)
         artifact-ingress.yaml (the admission fence)
  git push #1 → chain delivers v1 hands-off → push #2 → v2 served, NO restart
             → push #3 → retention prunes → the server still answers
  denials: rogue pod → RBAC 403 + tarball GET denied; controls prove the fences bite
  kind delete cluster (always)

  /srv/git/repo.git (runner) ──git://<gateway-ip>:9418──► GitRepository (interval 1m, no secretRef)
        │  source-controller (flux-system; unrestricted egress)
        ▼
  ArtifactGenerator (copy rules: the four narrowed entries) ──► ExternalArtifact chudmax-tickets
        │  get+watch — the phase-3 Role, resourceName-pinned
        ▼
  fetcher ──GET :9090──► source-watcher storage ◄── artifact-ingress.yaml ADMITS the release's pods
        │  unpack, swap /data/current
        ▼
  server (the published canonical tickets-mcp) — list_tickets over the Service: the answer
```

## The three-commit recipe (Fable's, owner-endorsed)

- **Commit #1** is pushed before the repo-sync manifests apply, so the FIRST reconciliation is itself the delivery event (the fetcher's wait → self-heal → swap is observable). After it: `list_tickets` shows the seed ticket; `repo_facts` captured.
- **Commit #2** is the Fable regression under real API load: the probe polls `list_tickets` continuously across the swap window; once v2 appears, no answer ever serves the stale v1 tree again; the server container's `startedAt` and `restartCount` are unchanged. (This is exactly what the canonical's per-call contract promises and what the pre-4b server got wrong.)
- **Commit #3** drives retention: the default `--keep 3` prunes the first revision dir on the third swap (`verified-here`, `k8s/fetcher/main.go`); after the prune the server still answers — the reread survives pruning.
- **`repo_facts` between every pair of commits**, asserted and recorded: `origin_revision` = `main@sha1:<pushed sha>` for each commit (the generator's fallback — phase 4b's verified finding: GitRepository sources populate no artifact metadata, so the fallback writes the GitRepository revision string), `revision` = the content hash (`latest@sha256:<hash>`) and it CHANGES with every commit. All three JSONs go to the CI step summary — phase 4's "records exactly what `repo_facts` surfaces" promise is kept.

## The two integration facts this rehearsal must handle

**1. The chart's egress selector points at labels the pods do not carry (fix here).** The chart's default `networkPolicy.egress.sourceController.selector` is `app.kubernetes.io/name: source-watcher`; the pinned v2.10.1 install bundle puts `app: source-watcher` (+ `app.kubernetes.io/component: source-watcher`) on the source-watcher pods — `verified-here` (bundle fetched and grepped, 2026-11-25). Phase 4b's F4 fix scoped the rule correctly, but the label itself was never checkable without a cluster or the rendered bundle. Phase 5 owns the one-line values fix + comment/readme updates; the chart CI re-proves lint/template/kubeconform. Without it the fetcher's GET has no egress allowance and the chain dies at the first fence.

**2. Flux's own shipped policies deny the cross-namespace fetch (admission policy shipped with the rehearsal).** `flux install` ships NetworkPolicies: `allow-egress` selects every flux-system pod with same-namespace-only ingress, and the only cross-namespace openings are :8080 (`allow-scraping`) and notification's :9292 — `verified-here` (the three policy manifests, fetched 2026-11-25). Source-watcher's storage is :9090, so a fetcher in the release namespace is denied by Flux's own fence. `k8s/rehearsal/artifact-ingress.yaml` adds the additive allow (NetworkPolicy ingress rules merge across policies selecting the pod): ingress :9090 to pods labeled `app: source-watcher` from the release namespace's release-labeled pods. This policy is the denial proof's "policy" — the rogue pod is denied by BOTH fences (Flux's allow-egress and the admission policy), the fetcher is admitted by exactly the admission policy, and the label-carrying Role-less control pod proves the admission shape is what opens the path. The README hands the manifest to phase 12 as an install-time prerequisite on the real platform (or phase 12 places the release in flux-system instead; the note records both).

## The test repo (git-daemon on the runner — the steering's route)

The script creates a bare repo at `/srv/git/repo.git`, runs `git daemon --base-path=/srv/git --export-all --reuseaddr --listen=0.0.0.0 --port=9418`, and pushes commits from a work tree (edit → commit → push to the local bare path — instant, no network). The GitRepository URL is `git://<gateway-ip>:9418/repo.git`, where the gateway IP is discovered per provider (`docker network inspect kind` / `podman network inspect kind`) — the standard pod→host path on kind; source-controller's egress is unrestricted (Flux's `allow-egress` sets `egress: {}`), so it reaches the daemon freely.

- The test variant drops `secretRef` (git:// is unauthenticated) and points at the rendered URL — the two deltas vs `k8s/repo-sync/gitrepository.yaml` (real private repo + `main` + auth Secret) are documented in the manifest header.
- **Caveat recorded honestly:** the GitRepository docs advertise HTTP/S or SSH URLs; `git://` is not in the documented set but is native to source-controller's git client (go-git). The steering chose this route; the FIRST reconciliation going Ready is the receipt. If the scheme is ever refused, the documented fallback is serving the same bare repo over smart HTTP (`git http-backend` behind a CGI-capable server on the runner) — noted, unbuilt.
- The fixture tree (`k8s/rehearsal/fixture/`) is the repo content: all four narrowed entries present (the copy rules' `optional: false` turns a missing file into a loud failure — it must never fire); content invented (the phase-4b fixture discipline; hygiene-checked like `k8s/tickets-mcp`'s fixtures).
- Nothing in the workflow needs a push token — permissions are minimal (checkout only).

## The proofs (the script's check sequence)

1. **Fresh install:** chart applied before the repo-sync manifests — pod Running, fetcher not-ready (waiting, not crash-looping — the phase-4b behavior, for real), restartCount 0.
2. **v1 arrives:** manifests applied → ExternalArtifact generated → the fetcher self-heals → pod ready → probe pod POSTs `list_tickets` over the Service → the seed ticket is in the answer.
3. **The headline (commit #1 → hands-off):** see the recipe above — no kubectl/flux interaction with Flux or the pod between push and answer.
4. **Commit #2:** continuous `list_tickets` polling across the swap; v2 served; no stale answer after the swap; `startedAt`/`restartCount` unchanged.
5. **Commit #3:** retention pruned (`/data/revisions` ≤ 3, v1's dir gone), the server still answers; the three `repo_facts` JSONs recorded (shapes asserted per the recipe).
6. **Denial (RBAC):** rogue pod (release ns, default SA, no labels) GETs the ExternalArtifact through the API → 403 — it cannot even learn the artifact URL (the Role is resourceName-pinned; phase 4's answer, now proven).
7. **Denial (network, Cilium-enforced):** the same rogue pod GETs `http://source-watcher.flux-system.svc:9090/<artifact path>` → denied, while (a) the fetcher's GET succeeds under the chart's egress policy (DNS 53, apiserver 443 podSelector, source-watcher :9090 — the F4/F5 fixes exercised under a Cilium-like CNI) and (b) a label-carrying, Role-less pod CAN GET the tarball — the fence is the admission policy and it is enforced, not present. Port-scope probe from inside the chudmax pod: :9090 allowed, an unlisted port (e.g. :8080) denied — the chart's egress policy bites.
8. **The record:** `repo_facts` JSONs, the artifact URL (host:port shape — `source-watcher.flux-system.svc…:9090`, trailing dot as advertised), and probe outputs go to the step summary; on failure the job uploads logs + `kind export logs`.

Timing budget: kind + Cilium ≈ 4 min, flux install ≈ 1 min, images + archive-load ≈ 3 min, three commits × ≤ ~1.5 min ≈ 5 min, denials ≈ 2 min → ~15 min expected; `timeout-minutes: 45`.

## Key decisions

1. **GitHub-hosted runners run kind — settled policy.** The 2025-era "privileged GitLab runners or self-hosted k3d" flag is obsolete (CI moved to GitHub Actions); it is not flagged anywhere in this card's outputs. The first green rehearsal run is the standing receipt.
2. **Cilium is the CNI** (the steering's choice — the Cozystack-shaped answer): the chart's podSelector-based apiserver rule (F5) and the source-watcher pod rule (F4) are exercised under the CNI family production actually uses; kindnet would have made the denial proof vacuous.
3. **git-daemon on the runner is the test-repo route** (the steering's choice; the git:// caveat + one-line fallback recorded above).
4. **The REAL server via chart defaults** — no stand-in; images loaded via archive (`docker/podman save` → `kind load image-archive`), never pulled (the default ghcr tags stay unpublished until phase 10). amd64 only in the rehearsal job — both-arches is already proven by the image jobs on every push; the rehearsal proves the chain, not the manifest list.
5. **Flux's shipped policies stay ON** (realistic); the admission policy is additive, rehearsal-owned, and handed to phase 12. `flux install --network-policy=false` is documented as the escape hatch only.
6. **Pins:** flux v2.10.1 (`--components-extra=source-watcher` — the same family phase 4's CI pinned), kind v0.33.0 (current stable, docs fetched 2026-11-25), Cilium pinned (the CLI's quick-install on kind), probe images pinned by tag/digest.
7. **Workflow boundary:** `.github/workflows/rehearsal-sync.yml` is this card's only workflow file; phase 6 owns `umbrella.yml` and the engine-chart/web-chart/umbrella dirs — this card edits none of them and duplicates any helper it needs into `k8s/rehearsal/`.
8. **Receiver untested in-cluster** (inert without an ingress path by design); **Alerts optional** with a dummy in-cluster sink — the delivery assertion is dropped honestly if it fights the budget, never left flaky.

## Notes for future agents (learnings)

- **Settled (do not resurrect):** the CI capability question is closed policy — GitHub-hosted `ubuntu-latest` runners run kind natively; the "privileged GitLab runners or self-hosted k3d" flag from the spike predates the GitHub move and must not be re-flagged in any spec, PR, or doc — `handoff-reported` (CoS, 2026-11-25).
- **source-watcher's real pod labels** (flux v2.10.1 bundle): `app: source-watcher`, `app.kubernetes.io/component: source-watcher`, `app.kubernetes.io/instance: flux-system`, `app.kubernetes.io/part-of: flux` — there is no `app.kubernetes.io/name` label. Any policy targeting source-watcher selects `app: source-watcher` (or the component label) — `verified-here` (bundle fetched + grepped in this planning session, 2026-11-25).
- **Flux's shipped policies** (`flux2/manifests/policies/`): `allow-egress` = all flux-system pods, ingress same-namespace only, egress unrestricted; `allow-scraping` = :8080 cross-namespace; `allow-webhooks` = notification-controller :9292. Cross-namespace access to anything else (storage :9090 included) needs an explicit allow — `verified-here`.
- **`flux install --components-extra="source-watcher"`** is the documented install path; `--network-policy` defaults true — `verified-here`.
- **GitRepository URLs:** the docs advertise HTTP/S or SSH; `git://` is undocumented but go-git-native — the steering's route, receipted by the first Ready reconciliation. Fallback if refused: smart HTTP via `git http-backend` on the runner. Dumb-HTTP (static file server) is NOT a fallback — go-git speaks the smart protocol. `verified-here` (docs) + `handoff-reported` (the route).
- **The fetcher's `--keep` default is 3** (`k8s/fetcher/main.go`) — the three-commit recipe needs no values override; the chart has no keep knob and needs none — `verified-here`.
- **kind facts** (docs, 2026-11-25): auto-detects docker/podman/nerdctl; release binaries at `kind.sigs.k8s.io/dl/v0.33.0/…`; `kind load image-archive` takes a saved archive (provider-agnostic with `podman save`); pods reach runner-side servers via the docker/podman network gateway IP — `verified-here`.
- **Cilium on kind** is the standard enforcing-CNI recipe for CI (the steering's pick; the chart's F5 podSelector pattern is the Cilium-portable form by design) — `handoff-reported`; the run receipts the recipe.
- **The per-call contract's cluster-scale assertion is sharper than restartCount:** the server container's `startedAt` unchanged + continuous polling with no stale answer after the swap. That is the exact regression shape Fable caught pre-4b — `verified-here` (phase-4b task record).
- House discipline unchanged: PR to `main`, conventional commits, three labels on every claim, public-safe content only, the box untouched, `mark_task_complete` after the PR merges.

## What this settles

- "Commit → `list_tickets` with nobody doing anything" is proven on a real cluster with real policies and the real published server — not asserted by schema checks.
- The chart leaves phase 5 with a selector that matches reality; phase 12 inherits a written admission-policy prerequisite for the artifact store.
- The phase-4b chart fixes (F4/F5) and the per-call contract are validated under a Cilium-like CNI — the Cozystack-shaped rehearsal the plan's later phases stand on.
