# Design: chudmax k8s phase 8 image automation rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

One kind cluster in one CI job rehearses the whole image-automation loop: a tag pushed to a runner-local registry is scanned by `ImageRepository`, resolved by `ImagePolicy` (semver), and committed into release values on `review/image-updates` — with `main` provably untouched and the automation's credential provably one-branch-scoped. The two mechanics prior phases left open (where tags come from before phase 10's ghcr publish; who pushes the commit) are settled by the steering: an **in-cluster `registry:2`** and the runner-hosted Smart-HTTP git server pattern, with a **basic-auth credential guarded by a server-side hook**.

## Shape

```
CI job (GitHub-hosted ubuntu runner — the phase-5/6/9 pattern)
  runner side:
    gittestserver-auth (k8s/image-automation/rehearsal/gittestserver/ — phase-8 module, 0 deps)
      -auth fluxbot:<random>  → 401 without creds; identity marker into the CGI env
      bare repo /srv/git/repo.git — seeded by CLONE (values/images.yaml: 3 marker lines @ 0.1.0)
      update hook (main-protect-hook.sh): refs/heads/main rejected over HTTP, always
  kind cluster (k8s/rehearsal/kind-config.yaml by path; STOCK kindnet — no Cilium)
    flux install -v v2.10.1 --components-extra=image-reflector-controller,image-automation-controller
    ns flux-system (shipped policies ON):
      registry:2 Deployment + NodePort Service :30500
      ImageRepository ×3   image: registry.flux-system.svc:5000/urmanac/chudmax/{fetcher,tickets-mcp,web}
                           interval 5m (production base), insecure: true, no secretRef
      ImagePolicy ×3       semver.range '>=0.1.0 <1.0.0'  → status.latestRef
      GitRepository chudmax-source (test variant: url __RUNNER_HTTP__, secretRef chudmax-repo-auth)
      ImageUpdateAutomation chudmax-image-updates
                           checkout: the GitRepository's ref (main) → setters over update.path
                           push.branch: review/image-updates  (NEVER main)
  runner → podman push --tls-verify=false <nodeIP>:30500/urmanac/chudmax/*:0.1.0 | 0.1.1 | 0.1.2
           (one real build @ 0.1.0; the later tags are the same bytes, retagged — the phase-7 way)
  beats:
    0.1.0 only  → scan tagCount 1; policies = the seeded values; automation: "no change";
                  refs/heads/review/image-updates DOES NOT EXIST
    0.1.1 tags  → scan tagCount 2 → policies 0.1.1 → ONE commit on review/image-updates
                  (diff = the three new full refs; message = the {{ .Changed.Summary }} arrows)
                  → main's SHA byte-unchanged
    0.1.2 tags  → the review tip is OVERWRITTEN with 0.1.2 (default GitForcePushBranch — docs-verified)
  controls (runner-side, same credential the automation uses):
    git push origin HEAD:refs/heads/main → DENIED by the hook (message receipted); main unchanged
    the automation's own review push     → accepted (the positive control on the same credential)
  kind delete cluster (always)
```

In production the same objects point at ghcr.io (the committed base manifests, `speculation`-free URLs) and the real git remote; the wiring is phase-10/12's.

## Write set

- `k8s/image-automation/**` (new): the committed production-shaped set (`imagerepository.yaml`, `imagepolicy.yaml`, `imageupdateautomation.yaml`, `networkpolicy-allow-image-controllers-egress.yaml`, `README.md`) + the rehearsal fixtures (`rehearsal/registry.yaml`, `rehearsal/gitrepository-rehearsal.yaml`, `rehearsal/imagerepository-rehearsal.yaml`, `rehearsal/imageupdateautomation-rehearsal.yaml`, `rehearsal/values-fixture.yaml`, `rehearsal/main-protect-hook.sh`, `rehearsal/gittestserver/`) + `image-automation-rehearse.sh`.
- `.github/workflows/image-automation.yml` (new): the `validate` + `rehearsal` jobs.
- This task dir on helix-specs (the three docs + `proofs.md` at implementation).
- **STRICTLY out** (the steering's disjoint-workbench rule + the active-parallel guards): `k8s/umbrella/`, `k8s/canary/`, `k8s/chart/`, `k8s/monitoring/`, `k8s/repo-sync/`, `k8s/rehearsal/`, the root README, every other workflow, and the phase-7/9 branches. The gittestserver wrapper is **duplicated, not extended** — `k8s/rehearsal/gittestserver/` is phase-5's, merged, and stays as-is.
- Read-only by path from merged main: `k8s/rehearsal/kind-config.yaml`, `k8s/image/Dockerfile`, `k8s/tickets-mcp/Dockerfile`, `k8s/umbrella/chudmax/web-image/Dockerfile`, `k8s/umbrella/chudmax/README.md` (the pins table).

## Key decisions

1. **API v1 everywhere (docs-verified, `verified-here` 2026-11-26):** `image.toolkit.fluxcd.io/v1` for all three image objects, `source.toolkit.fluxcd.io/v1` for the GitRepository. `ImageRepository.spec.insecure: true` is the documented plain-HTTP-registry switch — no TLS, no `certSecretRef` for the rehearsal registry. The controllers arrive via `flux install --components-extra=image-reflector-controller,image-automation-controller` (NOT in the default set) — the same pinned flux v2.10.1 as phase 5.
2. **The registry is in-cluster and NodePort-published; the runner pushes through the node.** `registry:2` (pinned 2.x tag at implementation) as a Deployment + NodePort Service in flux-system: the image-**reflector** scans it in-cluster (`registry.flux-system.svc:5000/urmanac/chudmax/*` — same-namespace egress rides the shipped policies), and the **runner** pushes via the kind node's InternalIP + the NodePort (`podman push --tls-verify=false`) — the standard docker/podman push semantics, no `ctr` gymnastics, no kind-config copy. The `urmanac/chudmax/` path is kept inside the in-cluster URL so the base↔rehearsal mapping is a literal prefix swap. The images are never loaded into the node and never run — this phase proves the tag→commit loop, not a workload (phase 5/6/7 receipts carry the runtime proofs).
3. **One real build, retag beats.** The three images build once (amd64 — the rehearsal proves the loop, not the manifest list, per phase 5's decision 5; both-arches stays with the image jobs) at `0.1.0`; beats push `0.1.1`/`0.1.2` as retags of the same bytes (phase 7's precedent). Fully-qualified image names everywhere (the podman `localhost/` docker-archive lesson). The web image builds from the public Strata at the umbrella README's pin — a script grep asserts the script's pin literal matches the README's (drift guard); the recorded lighter fallback (tag-carrier stand-ins) is honest but costs the no-stand-in rule, so it is the fallback only.
4. **Setters via the `$imagepolicy` markers on full image lines** (`docs`-verified format): each fixture line is `image: <full ref> # {"$imagepolicy": "flux-system:chudmax-<name>"}` — the basic setter rewrites the whole reference. The seeded values carry the **production** `ghcr.io` refs, so the review diff literally reads `ghcr.io/urmanac/chudmax/web:0.1.0 -> registry.flux-system.svc:5000/urmanac/chudmax/web:0.1.1` — legible and honest about what the rehearsal registry is. The committed `messageTemplate` puts `{{ .Changed.Summary }}` in the body; the receipt is the rendered commit message with its three `<old> -> <new>` lines. `digestReflectionPolicy` stays `Never` (digest pinning is a phase-10 values decision, out of scope).
5. **Push-branch semantics are the docs' defaults, receipted, not fought.** With the default `GitForcePushBranch` gate the automation re-checks-out `main` each run and overwrites the push branch — so the review tip always reflects the latest resolution (exactly what "the human merges the review branch" wants; the append-only alternative — `--feature-gates=GitForcePushBranch=false` on the controller — is recorded in the README, not used). The repeat beat exists precisely to receipt this: `lastPushCommit` advances, the tip moves to `0.1.2`, and no `main` ref ever moves.
6. **The one-branch credential is enforced server-side by our own hook — the GitLab protected-branch stand-in.** The wrapper gains basic auth (one identity, `fluxbot`, with a generated random password) and passes a per-request identity marker into the CGI env; the bare repo's `update` hook rejects **every** HTTP push to `refs/heads/main` (identity-independent — the simplest hook that cannot drift) with a legible denial message. The negative control (automation creds → `main` push denied, `main` unchanged) is therefore about the SERVER's fence, which is what branch protection is. The hook-env mechanic (marker surviving `http-backend → receive-pack → hook`) is `speculation` until the sandbox pre-flight proves it; fallbacks recorded: read `REMOTE_USER` instead, or drop the marker and reject main unconditionally (the hook already is identity-independent, so the fallback is nearly free). Seeding never pushes over HTTP: the bare repo is created by `git clone --bare` from a seed work tree, so the hook never blocks setup.
7. **Credentials ride the `GitRepository`'s `secretRef` — the production secret format.** `chudmax-repo-auth` (the production secret's name) is created out-of-band by the script with the HTTPS-token key set (`username`, `password`) — the exact format the repo-sync README documents. Both source-controller (fetch) and image-automation-controller (commit + push) consume it. The **finding this card contributes to the phase-12 milestone list:** the read-only deploy key planned for phase 12 cannot push — production needs a second, write-enabled credential scoped to the review branch (protected `main` enforcing the rest); the rehearsal receipts this by construction.
8. **Our own wrapper module, not an edit to phase-5's helper.** The steering's write set forbids touching `k8s/rehearsal/`, and helpers are duplicated, never shared by reference (the standing rule for anything an active branch might move). The phase-8 module is the phase-5 wrapper (verified design: binds `0.0.0.0`, drives `git-http-backend`, streams bodies) + the `-auth` flag + the identity marker; zero module dependencies, `go 1.25`, `cache: false` in CI (no go.sum to cache — the phase-5 comment).
9. **Stock kindnet, no Cilium — a deliberate deviation, recorded.** This phase's surface exercises no CiliumNetworkPolicy (no `toEntities: kube-apiserver` story); kindnet has enforced NetworkPolicy since kind v0.24 (the standing corrected fact), so the shipped-policy receipts are non-vacuous. Cilium costs ~2–4 min per run for coverage nothing here consumes; the Cilium recipe returns in any phase that exercises CNPs. The committed egress fixture (`networkpolicy-allow-image-controllers-egress.yaml`, additive allow for the two image controllers' external egress — mirror of the source-controller shape phase 5 proved) is applied unconditionally and its load-bearing status (was the shipped per-controller policy blocking?) is receipted from the controller logs — `speculation` until run; the fixture is production-relevant regardless (phase 12 must let the reflector reach ghcr and the automation reach the git remote).
10. **The `validate` job keeps the base and the rehearsal variants in lockstep without a cluster.** `flux schema validate k8s/image-automation --schema-location default` covers both sets (the phase-5 CI pattern); greps assert the three image paths appear in BOTH the base (ghcr form) and the rehearsal variant (registry form), the three markers exist in the fixture, and the hygiene grep (the `image-chart.yml` tickets-test pattern, RFC1918-shaped strings) is clean. Runtime substitution shrinks to the single `__RUNNER_HTTP__` placeholder (the phase-5 convention) — everything else is committed, reviewable YAML.
11. **Streaming receipts (the steering's rule, verbatim shape):** the kind job's run step is `set -o pipefail` + `bash k8s/image-automation/image-automation-rehearse.sh 2>&1 | tee "$RUNNER_TEMP/smoke.log"` (after `bash -n`) — the log streams live AND lands in the file; `pipefail` makes the step fail with the script. The always-step appends the summary (the phase-5 `/tmp/rehearsal-summary.txt` pattern) to `$GITHUB_STEP_SUMMARY`; on failure the smoke log's tail is printed and the logs upload as an artifact. The script ends with a credential-hygiene grep over the smoke log + summary (the generated password literal must appear nowhere) **before** any upload — the fence that keeps the tee'd artifact clean. `${RUNNER_TEMP:-/tmp}` inside the script keeps the sandbox's non-cluster parts runnable (the phase-9 recipe).
12. **Timing budget:** kind ≈ 2 min (no Cilium), flux + extra controllers ≈ 1–2 min, registry ≈ 1 min, three builds + 9 pushes ≈ 3–5 min (the Strata clone/build dominates), scan + three beats + controls ≈ 6–8 min → **~15–20 min, `timeout-minutes: 45`** (the phase-5 figure). All waits are bounded with receipts (the phase-9 lesson: never a bare `kubectl wait` without a diagnose-on-timeout path).

## Notes for future agents (learnings)

- **The loop's three beats map onto Flux's own state machine:** the idle beat proves writes are policy-gated (an automation with nothing to do pushes NOTHING — the review branch not existing is the receipt); the update beat is the headline; the repeat beat receipts the default overwrite semantics. If a future phase wants append-only review history, the lever is the `GitForcePushBranch=false` feature gate (docs-verified) — record it, don't improvise.
- **`ImagePolicy` changes trigger the automation outside `spec.interval`** (docs-verified) — the rehearsal can drive everything with `flux reconcile image repository …` / `… image update …` and keep the committed intervals at production values (5m/10m/1m); no interval rendering, no sleeps.
- **The commit message's summary lines are the audit trail** — the basic setter renders `<old> -> <new>` per distinct change (docs table); assert on those lines, not on file bytes alone.
- **The `$imagepolicy` marker goes at end of line as a YAML comment** — the fixture stays valid YAML for the parse check; the setter machinery reads the comment.
- **Write-set discipline vs. convenience:** the wrapper duplication is deliberate (the phase-5 helper must not grow auth it never uses); if a later phase needs the authed wrapper too, promote it to `k8s/rehearsal/gittestserver/` as a NEW merged change — never via this card's branch.
- **Hygiene specifics:** the bot email `@chudmax.invalid` (RFC 2606), doc IPs `203.0.113.x` (RFC 5737) only, the password generated with `openssl rand -hex 16` and passed by env/extraheader (never a credentialed URL on a command line — `git -c http.extraheader="Authorization: Basic …"`), and the pre-upload credential grep. The rehearsal's registry/git pushes are runner-local; the standing "no registry push" rule means no PUBLIC registry — say so in the summary to prevent confusion.
- **Standing facts not to re-litigate:** kindnet enforces NetworkPolicy since kind v0.24; the mcp chart's apiserver key is `networkPolicy.egress.apiServer.cidrs` (a list); kind cannot run in this sandbox (the phase-6 verbatim reason) — the sandbox proves the wrapper/hook/render/hygiene parts and the kind receipts are CI-authoritative; FQDN image names for any podman save/load round-trip.

## What this settles

- The image-automation loop end to end — scan → semver selection → values commit → review-branch push — with a person removed and `main` fenced, at CI scale.
- The pre-phase-10 stand-in topology (in-cluster registry + runner git server) that phases 9–10's cards can reuse when they too need tags without a publish.
- The phase-12 credential finding (read-only key insufficient; write-scoped review-branch credential required) — surfaced early, receipted by the denial control.
- The committed production-shaped manifest set, schema-validated in CI, waiting for the phase-10/12 wiring.
