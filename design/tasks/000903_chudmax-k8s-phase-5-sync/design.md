# Design: chudmax k8s phase 5 CI sync rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 5 is the first phase with a cluster: a throwaway kind cluster inside a CI job, Flux installed into it, the chart + repo-sync test manifests applied, and the two proofs the card asks for run to completion with nothing touched by hand. Requirements are in `requirements.md` in this directory. **The GATE (runner capability) is the human's; this design assumes a "yes" for GitHub-hosted runners and states the k3d fallback, but builds nothing until the confirmation arrives.**

## Shape

```
CI job (GitHub-hosted ubuntu runner — the GATE's confirmed route)
  kind create cluster → Calico (kindnet does not enforce NetworkPolicy)
  flux install --components-extra=source-watcher  (pinned v2.10.1)
  build both images locally (docker) → kind load docker-image   [no registry]
  helm install chudmax-mcp (chart: fetcher + published server)  → fetcher WAITS (no ExternalArtifact yet)
  apply: gitrepository-test.yaml + artifactgenerator.yaml (k8s/repo-sync/, -n <release-ns>)
         artifact-ingress.yaml (the admission fence)
  git push seed → chain delivers v1 → git push v2 → list_tickets shows it  [nobody doing anything]
  git push v3 → retention + repo_facts record
  denials: rogue pod → RBAC 403 + tarball GET denied; controls prove the fences bite
  kind delete cluster (always)

  fixture branch (public repo, synthetic, force-reset each run)
        │  GitRepository (interval 1m, no secretRef — the test delta)
        ▼
  source-controller ──artifact──► ArtifactGenerator ──► ExternalArtifact chudmax-tickets
        (flux-system; Flux's own shipped policies stay ON)          │ get+watch (phase-3 Role)
                                                                    ▼
  fetcher ──GET :9090──► source-watcher storage ◄── artifact-ingress.yaml ADMITS the release's pods
                                                                    │
  server (tickets-mcp) ◄──/data/current swap──┘   list_tickets over the Service: the answer
```

## The two integration facts this rehearsal must handle

**1. The chart's egress selector points at labels the pods do not carry (fix here).** The chart's default `networkPolicy.egress.sourceController.selector` is `app.kubernetes.io/name: source-watcher`; the pinned v2.10.1 install bundle puts `app: source-watcher` (+ `app.kubernetes.io/component`) on the source-watcher pods — `verified-here` (bundle fetched and grepped, 2026-11-25). Phase 4b's F4 fix scoped the rule correctly but the label itself was never checkable without a cluster or the rendered bundle. Phase 5 owns the one-line values fix + comment/readme updates; the chart CI re-proves lint/template/kubeconform. Without it the fetcher's GET has no egress allowance and the chain dies at the first fence.

**2. Flux's own shipped policies deny the cross-namespace fetch (admission policy shipped with the rehearsal).** `flux install` ships NetworkPolicies: `allow-egress` selects every flux-system pod with same-namespace-only ingress, and the only cross-namespace openings are :8080 (`allow-scraping`) and notification's :9292 — `verified-here` (the three policy manifests, fetched 2026-11-25). Source-watcher's storage is :9090, so a fetcher in the release namespace is denied by Flux's own fence. `k8s/rehearsal/artifact-ingress.yaml` adds the additive allow (NetworkPolicy ingress rules merge across policies selecting the pod): ingress :9090 to pods labeled `app: source-watcher` from the release namespace's release-labeled pods. This policy is the denial proof's "policy" — and the README hands it to phase 12 as an install-time prerequisite on the real platform (or phase 12 places the release in flux-system instead; the note records both).

## The test repo route (Open Question 2 pending)

**Primary: a disposable fixture branch on the public repo.** The job force-pushes `k8s/rehearsal/fixture/` content to a `rehearsal-fixture` branch (the only credential is the checkout's implicit `GITHUB_TOKEN`, scoped `contents: write`; pushes by it do not re-trigger workflows). The test GitRepository points at the public repo URL with `ref.branch: rehearsal-fixture` and no `secretRef` — the two deltas vs the production manifest (`k8s/repo-sync/gitrepository.yaml`: real private repo + `main` + auth Secret), both documented in the rehearsal README. No git server to run, no port-forward, identical HTTP semantics to production.

**Fallback (only if the owner objects to branch noise): an in-cluster throwaway Gitea** (pinned image + digest, sqlite, single Service; setup and pushes via `kubectl port-forward`). Sketched, not built — it exists so a "no" to Open Question 2 does not stall the phase.

The fixture tree carries all four narrowed entries (the copy rules' `optional: false` turns a missing file into a loud failure — it must never fire); content is invented (the phase-4b fixture discipline: no real tickets, hygiene-checked).

## The proofs (the script's check sequence)

1. **Fresh install:** chart applied before the repo-sync manifests — pod Running, fetcher not-ready (waiting, not crash-looping — the phase-4b behavior, for real), restartCount 0.
2. **v1 arrives:** manifests applied → the ExternalArtifact is generated → the fetcher self-heals → pod ready → probe pod POSTs `list_tickets` over the Service → the seed ticket is in the answer.
3. **The headline:** push commit v2 → poll `list_tickets` (≤ ~3 min) → the new ticket appears; **no kubectl/flux interaction with Flux or the pod between push and answer**; restartCount still 0 (the per-call contract without a restart).
4. **Retention:** push v3 → `repo_facts` answers; revision = `latest@sha256:<content-hash>`, `origin_revision` = the v3 SHA (both asserted and recorded); `/data/revisions` holds ≤ keep=3 (v1 pruned) and the server still answers after the prune.
5. **Denial (RBAC):** rogue pod (release ns, default SA, no labels) GETs the ExternalArtifact through the API → 403 — it cannot even learn the artifact URL (the Role is resourceName-pinned; phase 4's answer, now proven).
6. **Denial (network):** the same rogue pod GETs `http://source-watcher.flux-system.svc:9090/<artifact path>` → denied, while (a) the fetcher's GET succeeds and (b) a label-carrying, Role-less pod **can** GET it — the fence is the admission policy and it is enforced, not present. Port-scope probe from inside the chudmax pod: :9090 allowed, an unlisted port (e.g. 8080) denied — the chart's egress policy bites under the enforcing CNI.
7. **The record:** `repo_facts` JSON, the artifact URL (host:port shape — `source-watcher.flux-system.svc…:9090`, trailing dot included as advertised), and probe outputs go to the step summary; on failure the job uploads logs + `kind export logs`.

Timing budget: kind + Calico ≈ 3 min, flux install ≈ 1 min, images + load ≈ 3 min, three pushes × ≤ 1.5 min ≈ 5 min, denials ≈ 2 min → ~15 min expected; job timeout 45 min.

## Key decisions

1. **kind, not k3d, is the primary** (the spike's row E wording); k3d on a self-hosted runner is the fallback the GATE's "no" branch selects. The script is provider-agnostic (`KIND_EXPERIMENTAL_PROVIDER`) so the local podman run is possible, but honest: rootless podman + kind is fiddly (the kind docs say so), the sandbox run is best-effort, and **CI is the authoritative proof**.
2. **NetworkPolicy enforcement needs a real CNI** — kindnet does not enforce (the standard kind constraint; the run itself proves it). Calico, the kind docs' standard recipe, pinned; Cilium parity is not separately rehearsed (the chart's F5 podSelector patterns are CNI-agnostic by design).
3. **Flux's shipped policies stay ON** (realistic); the admission policy is additive, rehearsal-owned, and handed to phase 12. `--network-policy=false` is documented as the escape hatch only.
4. **Images are built in the job and loaded** (`kind load docker-image`), never pulled from a registry — the default ghcr tags stay unpublished until phase 10. amd64 only in the rehearsal job (both-arches is already proven by the image jobs every push; the rehearsal proves the chain, not the manifest list).
5. **Pins:** flux v2.10.1 (`--components-extra=source-watcher` — the same family phase 4's CI pinned), kind v0.33.0 (current stable, docs fetched 2026-11-25), Calico recipe pinned by version, probe images pinned by tag/digest.
6. **No secrets in CI:** no repo credentials (public fixture branch), no channel, no tokens beyond the implicit `GITHUB_TOKEN`.
7. **The GATE is decision-blocking, not implementation-blocking-by-assumption:** the spec, script skeleton and docs may be reviewed; the implementing session starts only after the human's answer lands.

## Notes for future agents (learnings)

- **source-watcher's real pod labels** (flux v2.10.1 bundle): `app: source-watcher`, `app.kubernetes.io/component: source-watcher`, `app.kubernetes.io/instance: flux-system`, `app.kubernetes.io/part-of: flux` — there is no `app.kubernetes.io/name` label. Any policy (egress or ingress) targeting source-watcher must select `app: source-watcher` (or the component label). Receipt: the bundle was fetched and grepped in this planning session, 2026-11-25 — `verified-here`.
- **Flux's shipped policies** (`flux2/manifests/policies/`): `allow-egress` = all flux-system pods, ingress same-namespace only, egress unrestricted; `allow-scraping` = :8080 cross-namespace; `allow-webhooks` = notification-controller :9292. Cross-namespace access to anything else (storage :9090 included) needs an explicit allow — `verified-here`.
- **`flux install --components-extra="source-watcher"`** is the documented install path (CLI docs example) — `verified-here`. `flux install --network-policy` defaults true (the shipped policies above).
- **GitRepository URLs: HTTP/S or SSH** (docs) — `git://` is not a documented scheme; don't build on `git daemon`. Dumb-HTTP serving is also out (source-controller's client speaks smart HTTP). This is why the fixture-branch (real HTTPS) route won — `verified-here`.
- **The fetcher's `--keep` default is 3** (`k8s/fetcher/main.go`) — a three-commit rehearsal prunes v1 on the third swap with no values override; the chart has no keep knob and needs none — `verified-here`.
- **kind facts** (docs, 2026-11-25): auto-detects docker/podman/nerdctl; release binaries at `kind.sigs.k8s.io/dl/v0.33.0/…`; `kind load docker-image` for local images (don't use `:latest` — `IfNotPresent` semantics); podman provider is rootless by default and needs extra setup — `verified-here`.
- **GitHub-hosted runners run kind** as standard practice (Docker present, no privileges needed) — labeled `speculation` until the first run proves it; that run IS the GATE's capability receipt. If it fails for runner reasons, the k3d/self-hosted branch of the GATE activates.
- The published server's pod mode rereads `/data/current` and `artifact.json` on every call — the rehearsal's restartCount-0 assertion is what makes the phase-4b contract's cluster-scale claim stick. `repo_facts.origin_revision` comes from the artifact's `org.opencontainers.image.revision` metadata (phase 4b's verified finding) — the rehearsal asserts the git SHA round-trips through generator → fetcher → server.
- House discipline unchanged: PR to `main`, three labels on every claim, public-safe content only, the box untouched, `mark_task_complete` after the PR merges.

## What this settles

- The chain "commit → `list_tickets` with nobody doing anything" is proven on a real cluster with real policies — not asserted by schema checks — and the two fences (RBAC, NetworkPolicy) are proven enforced with positive controls.
- The chart leaves phase 5 with a selector that matches reality; phase 12 inherits a written admission-policy prerequisite for the artifact store.
- The GATE question is surfaced for a decision instead of being guessed at implementation time.
