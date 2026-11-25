# Design: chudmax k8s phase 5 CI sync rehearsal

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 5 is the first phase with a cluster: a throwaway kind cluster inside a CI job on a GitHub-hosted runner (settled policy — no gate), Flux installed into it, the chart installed with **default values** (fetcher + the REAL published canonical server), the repo-sync test manifests applied, **Cilium** enforcing NetworkPolicies, and the card's two proofs run to completion with nothing touched by hand. The Gemini spec review's two showstoppers and three fixes are folded in BEFORE implementation — they are this phase's homework, and without them the rehearsal cannot even start (the CRD rejects the old test URL; the broken apiserver rule blocks the fetcher's watch under Cilium). Requirements are in `requirements.md` in this directory.

## Shape

```
CI job (GitHub-hosted ubuntu runner — settled policy, no privileged machinery needed)
  /srv/git/repo.git + Smart HTTP server on the runner:
      git-http-backend (GIT_PROJECT_ROOT=/srv/git, GIT_HTTP_EXPORT_ALL=1)
      behind a Python CGIHTTPRequestHandler → http://<gateway-ip>:<port>/repo.git
      [pre-flight: git ls-remote proves the URL BEFORE the manifest is applied]
  kind create cluster → Cilium (pinned; kindnet does not enforce NetworkPolicy)
  flux install -v v2.10.1 --components-extra=source-watcher   (shipped policies ON)
  build fetcher + server images (docker) → save → kind load image-archive   [no registry]
  helm install chudmax-mcp k8s/chart/chudmax-mcp   (default values — the REAL server,
      apiserver mode: cilium → CiliumNetworkPolicy toEntities: [kube-apiserver])
      → fetcher WAITS (Running, not-ready, no crash-loop — the phase-4b behavior, for real)
  apply: gitrepository-test.yaml + artifactgenerator.yaml (-n chudmax-rehearsal)
         artifact-ingress.yaml (the admission fence)
  git push #1 → chain delivers v1 hands-off → push #2 → v2 served, NO restart
             → push #3 → retention prunes → the server still answers
  helm upgrade --set apiServer.mode=cidr --set cidrs=<discovered>  → fetcher keeps working, no restart
  denials: rogue pod → RBAC 403 + tarball GET denied; controls prove the fences bite
  kind delete cluster (always)

  http://<gw>:<port>/repo.git ──► GitRepository (interval 1m, no secretRef — http:// passes the CRD pattern)
        │  source-controller (flux-system; unrestricted egress)
        ▼
  ArtifactGenerator (copy rules: the four narrowed entries) ──► ExternalArtifact chudmax-tickets
        │  get+watch — the phase-3 Role, resourceName-pinned; watch needs the FIXED apiserver rule
        ▼
  fetcher ──GET :9090──► source-watcher storage ◄── artifact-ingress.yaml ADMITS the release's pods
        │  unpack, swap /data/current
        ▼
  server (the published canonical tickets-mcp, readiness-probed) — list_tickets over the Service
```

## The review fixes folded in (Gemini spec review, 2026-11-25)

**Showstopper 1 — the test repo is Smart HTTP, not git://** (`verified-here` against upstream `api/v1/gitrepository_types.go` v1.10.2: `+kubebuilder:validation:Pattern="^(http|https|ssh)://.*$"` on `spec.url` — the CRD rejects `git://` at kubectl apply / flux-schema, before go-git ever runs). The runner serves the same bare repo over smart HTTP: `git-http-backend` with `GIT_PROJECT_ROOT=/srv/git`, `GIT_HTTP_EXPORT_ALL=1`, behind Python's `CGIHTTPRequestHandler` (the wrapper layout — the classic `cgi-bin/git-http-backend` path so `PATH_INFO` resolves under `GIT_PROJECT_ROOT` — is settled at implementation; the pre-flight `git ls-remote` from the runner is what proves the exact rendered URL). Zero secrets, zero remote pushes — the workflow needs no push token at all. The fixture tree (`k8s/rehearsal/fixture/`) stays the repo content: all four narrowed entries present (the copy rules' `optional: false` must never fire), invented content, hygiene-checked.

**Showstopper 2 — the kube-apiserver egress rule is an F5 regression (fixed here, alongside the source-watcher label fix).** The current rule renders `podSelector {component: kube-apiserver}` on TCP 443 (`verified-here` — the template). Two independent bugs make it unable to carry the fetcher's watch traffic under the rehearsal's CNI (`handoff-reported` — Gemini review; the Cilium run receipts both): (a) NetworkPolicy evaluates **post-DNAT backend ports** — the apiserver listens on **6443**, not the Service's 443; (b) the apiserver is a **`hostNetwork: true` static pod**, so a podSelector-based NetworkPolicy resolves to an **empty set** under Cilium and Calico — the fetcher's watch is blocked immediately. The fix, in the chart (`values.yaml` + `templates/networkpolicy-egress.yaml`):

- the apiserver rule allows TCP **443 and 6443** (Service-port and backend-port CNI variants both covered);
- `apiServer.mode` gains **`cilium`** — renders a `CiliumNetworkPolicy` with `toEntities: [kube-apiserver]` — and becomes the **default** (the Cozystack platform's CNI; the CNP CRD requirement is documented loudly — on a non-Cilium cluster the install fails visibly rather than silently misrouting);
- **`cidr`** — an ipBlock list of control-plane endpoint IPs (values-driven; `rehearse.sh` discovers them via `kubectl get endpoints kubernetes`, then a `helm upgrade --set apiServer.mode=cidr --set ...cidrs` re-proves the chain across a policy-only upgrade with **no pod restart**);
- the existing `podSelector` mode is kept but documented as unable to match a `hostNetwork: true` apiserver (empty set — legacy, non-hostNetwork platforms only);
- values comment + chart README updated; the chart CI's schema check handles the CNP render (the Cilium CRD schema fetched in the validation job).

**Fix 3 — the server readinessProbe (architecture.md's requirement).** The server container has no readiness probe today (`verified-here`) and `GET /mcp` is a 405 — so a probe must speak the protocol: an **exec** probe POSTing `list_tickets` (or `initialize`) to `127.0.0.1:<server.port>/mcp` with `python3 -c` (the image is the Python server image) and asserting HTTP 200. Semantics: the probe tolerates the pre-data state (the tools answer honestly without a tree — the 4b contract), so it proves the MCP surface is alive (it would have caught the `--host` misbind the 4b smoke caught); the fetcher's `test -e current` probe still gates the POD's readiness until the first swap. Template renders in all three value variants; lint/kubeconform green.

**Fix 4 — the published server's docs-methods single-snapshot bug** (`verified-here` — published copy `ticket_mcp.py` L355–410). `list_docs`, `read_doc`, `search_docs` re-resolve the base repeatedly (in `readable()` and again in their loops), so a symlink swap mid-call can raise an unhandled `ValueError` (→ exception-as-text) or falsely refuse; `repo_facts` already binds once — the docs methods were missed. Fix: bind `base = self.base()` ONCE at the start of each method and pass it into `readable(base)`; the published selftest gains a regression check (a concurrent swap during docs calls never raises, never falsely refuses — either-tree answers are valid, crashes are not). **Byte-exactness is preserved the 4b way:** the identical fix + test go to the canonical via the private GitLab MR (held for the human; the public PR does not wait on it; a session without provider access flags that honestly instead of diverging silently). Plus the stale mock comment in `k8s/image/Dockerfile` L2–3 corrected to the published canonical.

**Fix 5 — rehearsal-check refinements.** (a) `repo_facts.origin_revision` is asserted to **contain** the pushed commit SHA — the exact string (e.g. `main@sha1:<sha>`, the generator's fallback per the 4b finding) is recorded from source-watcher v2.3.1's LIVE output rather than assumed. (b) The rehearsal verifies live whether notification-controller matches `kind: ArtifactGenerator` events from the `alerts.yaml` eventSources; if not, `eventSources` gains `ExternalArtifact` and the README records the finding; the delivered-event assertion to the dummy sink stays optional — dropped honestly if it fights the budget, never left flaky.

## The three-commit recipe (Fable's, owner-endorsed)

- **Commit #1** is pushed before the repo-sync manifests apply, so the FIRST reconciliation is itself the delivery event (the fetcher's wait → self-heal → swap is observable). After it: `list_tickets` shows the seed ticket; `repo_facts` captured.
- **Commit #2** is the Fable regression under real API load: the probe polls `list_tickets` continuously across the swap window; once v2 appears, no answer ever serves the stale v1 tree again; the server container's `startedAt` and `restartCount` are unchanged.
- **Commit #3** drives retention: the default `--keep 3` prunes the first revision dir on the third swap (`verified-here`, `k8s/fetcher/main.go`); after the prune the server still answers — the reread survives pruning.
- **`repo_facts` between every pair of commits**, asserted and recorded; all three JSONs go to the CI step summary — phase 4's "records exactly what `repo_facts` surfaces" promise is kept.

## The three integration facts (why the rehearsal exists)

**1. The chart's egress selector points at labels the pods do not carry.** Default `networkPolicy.egress.sourceController.selector` is `app.kubernetes.io/name: source-watcher`; the pinned v2.10.1 bundle puts `app: source-watcher` (+ `app.kubernetes.io/component`) on the pods — `verified-here` (bundle fetched and grepped, 2026-11-25). Phase 4b's F4 scoping was right; the label was never checkable without a cluster. Phase 5 owns the one-line fix; without it the fetcher's GET has no egress allowance.

**2. Flux's own shipped policies deny the cross-namespace fetch.** `allow-egress` selects every flux-system pod with same-namespace-only ingress; the only cross-namespace openings are :8080 and notification's :9292 — `verified-here`. Storage is :9090, so `k8s/rehearsal/artifact-ingress.yaml` adds the additive allow: ingress :9090 to `app: source-watcher` pods from the release namespace's release-labeled pods. The rogue pod is denied by BOTH fences; the fetcher is admitted by exactly the admission policy; the label-carrying Role-less control pod proves the admission shape is what opens the path. The README hands the manifest to phase 12 as an install-time prerequisite (or phase 12 places the release in flux-system; the note records both).

**3. The apiserver egress rule cannot match the real apiserver** — showstopper 2 above; the fix + the both-modes live proof are this phase's deliverable.

## The proofs (the script's check sequence)

1. **Pre-flight (runner-side, before the cluster):** the Smart-HTTP server is up and `git ls-remote` proves the rendered URL — the receipt that the CRD-valid `http://` route works before anything is applied.
2. **Fresh install:** chart applied before the repo-sync manifests — pod Running, fetcher not-ready (waiting, not crash-looping), restartCount 0; the server container READY (its new probe answers) even before data arrives.
3. **v1 arrives:** manifests applied → ExternalArtifact generated → the fetcher self-heals → pod ready → probe pod POSTs `list_tickets` over the Service → the seed ticket is in the answer.
4. **Commit #2:** continuous `list_tickets` polling across the swap; v2 served; no stale answer after the swap; `startedAt`/`restartCount` unchanged.
5. **Commit #3:** retention pruned (`/data/revisions` ≤ 3, v1's dir gone), the server still answers; the three `repo_facts` JSONs recorded (shapes asserted per Fix 5a).
6. **Denial (RBAC):** rogue pod (release ns, default SA, no labels) GETs the ExternalArtifact through the API → 403 — it cannot even learn the artifact URL (the Role is resourceName-pinned; phase 4's answer, now proven).
7. **Denial (network, Cilium-enforced):** the same rogue pod GETs `http://source-watcher.flux-system.svc:9090/<artifact path>` → denied, while (a) the fetcher's GET succeeds under the chart's egress policy (DNS 53, the FIXED apiserver rule, source-watcher :9090) and (b) a label-carrying, Role-less pod CAN GET the tarball. Port-scope probe from inside the chudmax pod: :9090 allowed, an unlisted port (e.g. :8080) denied.
8. **Policy-only upgrade:** `helm upgrade` to `apiServer.mode: cidr` (discovered endpoint IPs) — the fetcher keeps fetching and the watch stays connected with **no pod restart**.
9. **The record:** `repo_facts` JSONs, the artifact URL (host:port shape — `source-watcher.flux-system.svc…:9090`, trailing dot as advertised), the live `origin_revision` strings, and probe outputs go to the step summary; on failure the job uploads logs + `kind export logs`.

Timing budget: kind + Cilium ≈ 4 min, flux install ≈ 1 min, images + archive-load ≈ 3 min, three commits × ≤ ~1.5 min ≈ 5 min, denials + mode upgrade ≈ 3 min → ~16 min expected; `timeout-minutes: 45`.

## Key decisions

1. **GitHub-hosted runners run kind — settled policy.** The 2025-era "privileged GitLab runners or self-hosted k3d" flag is obsolete (CI moved to GitHub Actions); not flagged anywhere in this card's outputs. The first green rehearsal run is the standing receipt.
2. **Cilium is the CNI** (the steering's choice — the Cozystack-shaped answer): the F4/F5 fixes are exercised under the CNI family production actually uses; kindnet would have made the denial proof vacuous.
3. **Smart HTTP on the runner is the test-repo route** (the review's CRD-pattern finding corrected the steering's git-daemon instinct); zero secrets, `git ls-remote` pre-flight receipt, no push token in the workflow.
4. **The REAL server via chart defaults** — no stand-in; images loaded via archive (`docker/podman save` → `kind load image-archive`), never pulled (the default ghcr tags stay unpublished until phase 10). amd64 only in the rehearsal job — both-arches is already proven by the image jobs; the rehearsal proves the chain, not the manifest list.
5. **`apiServer.mode` default is `cilium`** (the platform's CNI; CNP with `toEntities: [kube-apiserver]`): on a non-Cilium cluster the install fails loudly and the README points at `cidr` (endpoint IPs, per-cluster values) — a loud documented failure beats silent misrouting; `podSelector` is kept for non-hostNetwork platforms with its limitation documented. The rehearsal live-proves cilium (default install) AND cidr (policy-only upgrade, no pod restart).
6. **Flux's shipped policies stay ON** (realistic); the admission policy is additive, rehearsal-owned, and handed to phase 12. `flux install --network-policy=false` is documented as the escape hatch only.
7. **Pins:** flux v2.10.1 (`--components-extra=source-watcher` — the same family phase 4's CI pinned), kind v0.33.0 (current stable, docs fetched 2026-11-25), Cilium pinned (CLI quick-install on kind), probe images pinned by tag/digest.
8. **Workflow boundary:** `.github/workflows/rehearsal-sync.yml` is this card's only workflow file; phase 6 owns `umbrella.yml` and the engine-chart/web-chart/umbrella dirs — this card edits none of them and duplicates any helper it needs into `k8s/rehearsal/`.
9. **Receiver untested in-cluster** (inert without an ingress path by design); **Alerts applied with the dummy sink** but the delivery assertion optional (Fix 5b).
10. **The server fix keeps the canonical byte-exact via the parallel private MR** (the 4b pattern: the canonical defines the contract; the public PR does not wait on the human's merge).

## Notes for future agents (learnings)

- **Settled (do not resurrect):** the CI capability question is closed policy — GitHub-hosted `ubuntu-latest` runners run kind natively; the spike's "privileged GitLab runners or self-hosted k3d" flag predates the GitHub move and must not be re-flagged in any spec, PR, or doc — `handoff-reported` (CoS, 2026-11-25).
- **GitRepository.spec.url is CRD-pattern-validated** `^(http|https|ssh)://.*$` (source-controller `api/v1/gitrepository_types.go`, checked at v1.10.2) — `git://` and any other scheme die at the API server, before go-git. Any "git-daemon serves the test repo" idea is dead on arrival; Smart HTTP (`git-http-backend`) is the local-test-repo route — `verified-here` (2026-11-25).
- **NetworkPolicy vs the apiserver (the F5 regression):** policies evaluate post-DNAT (backend port 6443, not the Service's 443), and a `hostNetwork: true` static pod is not selectable by podSelector (empty set under Cilium/Calico) — the podSelector apiserver rule can never carry the fetcher's watch on kubeadm/kind clusters. The portable answers are Cilium's `toEntities: [kube-apiserver]` (CNLP) or an ipBlock to the discovered endpoint IPs (`kubectl get endpoints kubernetes`) — `handoff-reported` (Gemini review); the rehearsal receipts both live.
- **source-watcher's real pod labels** (flux v2.10.1 bundle): `app: source-watcher`, `app.kubernetes.io/component: source-watcher`, `app.kubernetes.io/instance: flux-system`, `app.kubernetes.io/part-of: flux` — no `app.kubernetes.io/name` label exists. Any policy targeting source-watcher selects `app: source-watcher` (or the component label) — `verified-here`.
- **Flux's shipped policies** (`flux2/manifests/policies/`): `allow-egress` = all flux-system pods, ingress same-namespace only, egress unrestricted; `allow-scraping` = :8080 cross-namespace; `allow-webhooks` = notification-controller :9292. Cross-namespace access to anything else (storage :9090 included) needs an explicit allow — `verified-here`.
- **`flux install --components-extra="source-watcher"`** is the documented install path; `--network-policy` defaults true — `verified-here`.
- **The published server's docs methods had the single-snapshot bug the 4b fix left behind:** `list_docs`/`read_doc`/`search_docs` re-resolved `self.base()` mid-call (`ticket_mcp.py` L355–410); `repo_facts` was the only fully-bind-once method. Rule for future edits: every pod-mode method binds `base` once and threads it through helpers — `verified-here`.
- **The chart's server container had no readinessProbe** and `GET /mcp` is 405 — a probe must POST (initialize or list_tickets) via `python3 -c` exec; the fetcher's `test -e current` probe still gates pod readiness — `verified-here`.
- **The fetcher's `--keep` default is 3** (`k8s/fetcher/main.go`) — the three-commit recipe needs no values override — `verified-here`.
- **kind facts** (docs, 2026-11-25): auto-detects docker/podman/nerdctl; release binaries at `kind.sigs.k8s.io/dl/v0.33.0/…`; `kind load image-archive` takes a saved archive (provider-agnostic with `podman save`); pods reach runner-side servers via the docker/podman network gateway IP — `verified-here`.
- **Alert eventSources vs the ArtifactGenerator kind:** whether notification-controller v1 matches `kind: ArtifactGenerator` events is verified live in the rehearsal (the sink assertion is optional); if unmatched, `ExternalArtifact` is the working eventSource — the finding lands in the README — `speculation` until the run.
- **`origin_revision`'s exact string** (`main@sha1:<sha>` per the 4b fallback finding) is asserted by substring-containment and recorded verbatim from v2.3.1's live output — assumed prefixes are not asserted — `speculation` until the run, then recorded.
- House discipline unchanged: PR to `main`, conventional commits, three labels on every claim, public-safe content only, the box untouched, `mark_task_complete` after the PR merges.

## What this settles

- "Commit → `list_tickets` with nobody doing anything" is proven on a real cluster with real policies and the real published server — not asserted by schema checks.
- The chart leaves phase 5 with egress rules that match reality (source-watcher labels; an apiserver rule that carries the watch under Cilium) and a readiness-probed server; phase 12 inherits the admission-policy prerequisite and the mode notes in writing.
- The published server's docs methods are swap-safe (bind-once) with the canonical mirrored via the private MR — the per-call contract holds for every tool, not just `repo_facts`.
