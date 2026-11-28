# image-automation — the Flux objects that turn a tag into a review-branch commit

Phase 8 of the Kubernetes plan (T-0037). Three `ImageRepository` objects scan
the house-built images, three `ImagePolicy` objects pick the latest stable tag
inside a semver range, and one `ImageUpdateAutomation` writes the resolved
references into the release values and pushes them to a review branch. **No
person and no push to `main`** — the human merges the review branch when they
want the bump.

    ImageRepository (scan) ──► ImagePolicy (semver) ──► ImageUpdateAutomation
                                                              │  Setters over the
                                                              │  {"$imagepolicy"} markers
                                                              ▼
                                     commit on review/image-updates (NEVER main)

## Files

| File | Object |
|---|---|
| `imagerepository.yaml` | 3× `ImageRepository` — the ghcr.io references (production; unpublished until phase 10) |
| `imagepolicy.yaml` | 3× `ImagePolicy` — `semver.range: '>=0.1.0 <1.0.0'` (stable 0.x line; prereleases excluded) |
| `imageupdateautomation.yaml` | `ImageUpdateAutomation chudmax-image-updates` — Setters, bot author, `review/image-updates` |
| `networkpolicy-allow-image-controllers-egress.yaml` | additive egress allow for the two image controllers (the registry scan / the git push) |
| `rehearsal/` | the CI rehearsal's stand-ins (in-cluster registry, authed test git server, test variants of the objects) |
| `image-automation-rehearse.sh` | the orchestrator — the CI kind job is its authoritative run |

## The three images, and the one exclusion

- `ghcr.io/urmanac/chudmax/fetcher` — the fetcher sidecar (`k8s/image/Dockerfile`).
- `ghcr.io/urmanac/chudmax/tickets-mcp` — the canonical ticket server (`k8s/tickets-mcp/Dockerfile`).
- `ghcr.io/urmanac/chudmax/web` — Strata built at the pinned SHA (`k8s/umbrella/chudmax/web-image/Dockerfile`; the pin lives in the umbrella README's pins table).
- **hermes-agent has no ImageRepository, on purpose**: the Hermes chart
  (`k8s/chart/hermes-agent/`) consumes upstream `nousresearch/hermes-agent`
  semver tags chosen manually. The automation loop is for the images we build.

## Rehearsal ↔ production mapping

| Rehearsal stand-in | Production (phase 10/12 wiring) |
|---|---|
| `registry:2` Deployment + NodePort :30500 in flux-system (`rehearsal/registry.yaml`) | ghcr.io/urmanac/chudmax/* — the phase-10 publish |
| `ImageRepository.spec.insecure: true` + in-cluster URLs (`rehearsal/imagerepository-rehearsal.yaml`) | the base manifests, `insecure` dropped |
| runner-hosted Smart-HTTP bare repo (`rehearsal/gittestserver/`) | the real git remote of `GitRepository chudmax-source` (`k8s/repo-sync/gitrepository.yaml`) |
| basic-auth Secret `chudmax-repo-auth` (username/password — the production secret's documented HTTPS-token form) | a **write-scoped** deploy key/token in the same-named Secret |
| `rehearsal/main-protect-hook.sh` (rejects every HTTP push to `refs/heads/main`) | GitLab protected `main` (the same fence, platform-enforced) |
| `update.path: values` | `update.path: ./kubernetes` — pinned at the phase-12 wiring |
| the runner-side `git push` denial receipt | the platform's own rejection of a main push with the automation credential |

## The credential finding (for the phase-12 milestone list)

The image-automation-controller pushes with the **GitRepository's secretRef
credentials**. The phase-12 plan's read-only deploy key can fetch `main` but
cannot push the review branch — image automation needs a **second,
write-enabled credential** whose effective write surface is the review branch
only (protected `main` enforcing the rest). The rehearsal receipts this shape:
the automation's review push succeeds with the credential and an explicit
`git push … main` with the SAME credential is denied by the hook.

## Production wiring notes

- **MR auto-creation is available but not wired.** GitLab honors push options —
  `merge_request.create: ""` under `git.push.options` would open an MR on every
  automation commit. Deliberately NOT set here (the rehearsal's git server does
  not advertise push options, and an unadvertised option fails the push); the
  phase-12 wiring decides. Until then: the review branch updates, the human
  opens (or reuses) the MR.
- **Review-branch history under Flux v2.10.1 (`GitAllBranchReferences=true`).**
  Since Flux enabled `GitAllBranchReferences=true` by default (`fluxcd/flux2#3384`),
  when `review/image-updates` already exists on the remote the controller checks
  out that push branch and appends each new resolution on top of it (reacting
  within seconds of each `ImagePolicy` update), while `main` never moves. To
  reset from `main` on every update instead, pass
  `--feature-gates=GitAllBranchReferences=false` on `image-automation-controller`.
- **Digest pinning** (`digestReflectionPolicy: IfNotPresent` + `:digest`
  markers) is a values decision deferred to the phase-10 wiring, where cosign
  signing makes digests meaningful.
