# The phase-5 rehearsal — the sync chain proven on a real cluster

T-0037 phase 5: in CI, on a throwaway kind cluster with Flux, **a commit to a
test repo shows up in `list_tickets` with nobody doing anything, and a pod
outside the policy cannot fetch the artifact.** `rehearse.sh` runs the whole
thing: kind → Cilium → Flux (+ source-watcher) → the chart with DEFAULT values
(the REAL published canonical server, images loaded via archive — no
registry) → the repo-sync test manifests → the proofs.

CI is the authoritative run (`.github/workflows/rehearsal-sync.yml`). A local
podman-provider run is possible but best-effort — rootless kind needs the
extra setup the kind docs describe; the sandbox's honest outcome, whatever it
is, is recorded in the task's receipts.

## What is proven

- **Commit #1** (the fixture tree, seeded BEFORE the manifests apply): the
  fetcher's fresh-install wait → self-heal → swap is observable, then the
  chain (GitRepository 1m interval → ArtifactGenerator → ExternalArtifact →
  fetcher) delivers v1 with nobody doing anything — `list_tickets` over the
  Service shows T-9001.
- **Commit #2**: continuous `list_tickets` polling across the swap — T-9002
  appears, NO v1-only answer after the first v2 answer, and the server
  container's `startedAt`/`restartCount` are unchanged (the per-call contract,
  for real).
- **Commit #3**: the default `--keep 3` prunes the first revision dir; the
  server still answers; `repo_facts` shows `origin_revision` containing the
  pushed SHA (the exact string recorded) and a content-hash `revision` that
  changed with every commit.
- **The cidr-mode upgrade**: a policy-only `helm upgrade` (mode: cidr, the
  endpoint IP discovered via `kubectl get endpoints kubernetes`) — the CNP is
  gone, the pod untouched, a **FRESH** apiserver GET succeeds (an established
  stream surviving proves nothing), and **commit #4** delivers hands-off under
  the upgraded policy. Cilium runs with `--policy-cidr-match-mode=nodes` so
  its ipBlock rules can match node IPs at all (without the flag the rule
  silently drops).
- **The denials**: the rogue pod (release namespace, default ServiceAccount, no
  release labels) gets **403 Forbidden** on the ExternalArtifact GET (it cannot
  even learn the artifact URL — the phase-4 Role answer, proven) and its
  tarball GET to source-watcher:9090 is **denied**. Positive controls: the
  fetcher's fetch works, a **labeled, Role-less** pod CAN fetch the tarball
  (the ingress allowance's shape is what opens the path), and the port-scope
  probe from inside the release pod shows :9090 allowed / :8080 denied — the
  chart's egress policy bites under Cilium, not merely exists.
- **Alerts** are applied with a dummy in-cluster sink; the sink's event count
  is recorded (the live eventSources check — if `kind: ArtifactGenerator`
  events never arrive, `alerts.yaml` gains `ExternalArtifact`; the Receiver
  stays inert by design).

Every receipt lands in the CI step summary; on failure the job uploads the
cluster logs, the poll logs, and the controllers' logs.

## The test repo (zero secrets, zero remote pushes)

The runner hosts a bare repo (`/tmp/rehearsal-git/repo.git`) served over
**Smart HTTP** by [`gittestserver/`](gittestserver/) — a tiny Go helper that
execs git's own `http-backend` per request (`GIT_PROJECT_ROOT` +
`GIT_HTTP_EXPORT_ALL`), bound on `0.0.0.0:<port>` so the cluster's pods reach
it through the docker/podman network gateway. `git://` is NOT an option: the
GitRepository CRD's `^(http|https|ssh)://` pattern rejects it at the API
server. Flux's own `pkg/gittestserver` was the review's first choice and is
not usable here: its `StartHTTP` binds httptest's loopback with an ephemeral
port (unreachable from the cluster) — receipted against its source. The
`git ls-remote` pre-flight proves the URL BEFORE any manifest is applied.

The fixture ([`fixture/`](fixture/)) is invented content carrying all four
narrowed entries (the copy rules' `optional: false` must never fire); commits
#2–#4 append the rehearsal tickets the script asserts on.

## Deltas vs production (`k8s/repo-sync/gitrepository.yaml`)

| Field | Production | Rehearsal |
|---|---|---|
| `spec.url` | the private source-of-truth repo (HTTPS) | rendered `http://<gateway>:<port>/repo.git` (the runner) |
| `spec.secretRef` | `chudmax-repo-auth` | none (unauthenticated runner server) |

Everything else — `ref.branch: main`, `interval: 1m`, no `spec.ignore` — is
the production shape, applied from the same `k8s/repo-sync/` files.

## The :9090 ingress allowance

`k8s/repo-sync/artifact-ingress.yaml` is a first-class repo-sync file (any
cluster running Flux's shipped NetworkPolicies needs it — they deny
cross-namespace ingress to the storage port). The rehearsal seds its
`chudmax-releases` placeholder to the release namespace and applies it from
there.

## Running it

CI: automatic (path-scoped triggers on `k8s/**`, plus `workflow_dispatch`).
Locally (docker provider): `bash k8s/rehearsal/rehearse.sh`. Podman provider:
`KIND_EXPERIMENTAL_PROVIDER=podman REHEARSAL_BUILDER=podman bash
k8s/rehearsal/rehearse.sh` — best-effort; see the honest outcome in the task
receipts. Clean-up is unconditional: the cluster is deleted even on failure.

## What the run hands to phase 12

- the :9090 ingress allowance is an install-time prerequisite (or place the
  release in flux-system);
- `apiServer.mode` guidance: `auto` (CNP on Cilium via the APIVersions gate,
  plain fallback elsewhere), `cidr` under Cilium only with
  `--policy-cidr-match-mode=nodes`;
- the recorded `repo_facts` shapes (`origin_revision`'s exact live string, the
  content-hash `revision`).
