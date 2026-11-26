# Proofs: chudmax k8s phase 9 Hermes chart with persistent home

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Labels follow `chudmax/AGENTS.md`: `verified-here` (run in this sandbox), `handoff-reported` (the CoS/Gemini steering), `speculation` (not yet exercised).

## CI receipts (2026-11-26)

- **Run #1 (`verified-here`, PR #7):** `chart` job **green in CI** — all steps (lint ×2, template variants + guard negative test, shape checks, LAN hygiene) — the local battery transferred. `kind` job **failed at 2m25s** in the smoke's image section: the manifest-list pull succeeded (digest `sha256:ef0650d5…` recorded) but `kind load docker-image` failed on ctr's `--all-platforms` import — the arm64 blob (`sha256:2223ae…`, the arm64 instance digest from the Docker Hub receipt) was never pulled by the docker daemon.
- **Run #2 (`verified-here`):** the per-arch-tag fix died at the pull — **`v0.23.4-amd64` is not pullable** (per-arch tags exist for rc/canary builds only; the final release publishes only list tags). Correction recorded; the requirements/design no longer claim final-release per-arch tags.
- **Settled route (9ac4e24; `speculation` until the rerun): the node pre-pull via `crictl pull`** — containerd resolves the multi-arch list natively (the production path); the kubelet pull under `pullPolicy: IfNotPresent` is the fallback.

## Local render proofs (2026-11-26, `verified-here`, sandbox; helm 3.16.4 + kubeconform 0.6.7 installed to ~/.local/bin — `/usr/local/bin` is not writable in this sandbox, a deviation from the phase-3 recipe worth remembering)

- **Chart authoring:** `k8s/chart/hermes-agent/` (Chart.yaml v2 `hermes-agent` 0.1.0 appVersion `0.23.4`; values.yaml; templates: `_helpers.tpl`, `deployment.yaml`, `service.yaml`, `pvc.yaml`, `secret.yaml`, `test-hook.yaml`, `NOTES.txt`; README.md; `kind-smoke.sh`).
- **`helm lint` ×2:** literal-key variant (`--set apiServer.key=phase9-kind-rehearsal-key-not-a-secret`) → **0 charts failed** (cosmetic icon notice only); existingSecret variant (`--set apiServer.existingSecret=hermes-prod`) → **0 charts failed**.
- **The render guard as a NEGATIVE test:** bare-defaults `helm template` → **fails** with the guard's message (`hermes-agent: apiServer.enabled requires apiServer.key … or apiServer.existingSecret`) — exactly the loud failure the design wanted; verified both directions (`if template; then GUARD FAILED; else ok; fi`).
- **`helm template` ×2 + kubeconform -strict:** **9/9 resources valid** in BOTH renders (Deployment, Service, PVC, test-hook Pod + the Secret in the literal-key variant only — confirmed present in variant A, **absent** in variant B by grep).
- **Deployment shape (parsed from the render):** `strategy: Recreate`; `automountServiceAccountToken: false`; pod securityContext = `seccompProfile: RuntimeDefault` **only — no runAsNonRoot** (the documented root-then-drop deviation); `terminationGracePeriodSeconds: 60`; startup/readiness/liveness `httpGet /health` on the named `http` port; PVC `claimName` == fullname; env wiring `API_SERVER_ENABLED/HOST/PORT/KEY` (key via `secretKeyRef`).
- **securityContext passthrough merge:** `--set securityContext.runAsUser=65532` renders BOTH keys (`runAsUser` + the seccomp default) — the merge-over-default behavior the values comment promises.
- **Test hook shape:** `curlimages/curl:8.12.1` (the engine subchart's existing pin — aligned), `restartPolicy: Never`, `automountServiceAccountToken: false`, hook annotations `helm.sh/hook: test` + delete-policy `before-hook-creation,hook-succeeded`, hardened (`runAsNonRoot: true`, drop ALL, seccomp, readOnlyRootFilesystem — a curl pod needs none of the hermes concessions).
- **LAN-address hygiene:** `! grep -RInE '\b(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+\b' k8s/chart/hermes-agent .github/workflows/hermes-chart.yml` → clean (the only IP-shaped string anywhere is the digest hex, which does not match the dotted-quad pattern; TEST-NET-3 never needed in this chart).
- **Script + workflow syntax:** `bash -n kind-smoke.sh` clean; the workflow YAML parses (checked with python-yaml); the script's `RUNNER_TEMP` defaults to `/tmp` so the sandbox can run its non-cluster parts.

## What could NOT run here (`speculation` until the CI kind job greens it)

- kind itself (rootless docker daemon, read-only cgroup2 — the phase-6 finding, re-confirmed by the tooling inventory of this sandbox: kind/kubectl/docker present, but the daemon is rootless). The kind job on GitHub's rootful runners is the authoritative receipt, per the phase-5/6 precedent.
- The upstream image pull (~1.15 GB per arch) and its `kind load` timing — CI-only; the first run times it.
- The mock-engine ladder, pod-delete survival, `hermes backup`/`hermes import` onto the fresh PVC, the chat turn, the mcp admission probe — all scripted (`kind-smoke.sh`, every step receipted with `RECEIPT:` lines) but not yet executed.

## Steering receipts (`handoff-reported`)

- Gemini brief (2026-11-26): phases 5 & 6 merged on main @ `0787cfe`; stage at `k8s/chart/hermes-agent/` + `.github/workflows/hermes-chart.yml`; split to `urmanac/hermes-agent` at phase 10; phase 7 (Flagger canary) parallel — `k8s/umbrella/`, `k8s/canary/`, phase-7 workflows write-off-limits; kindnet enforces NetworkPolicy since kind v0.24; the mcp chart's default ingress admits same-namespace pods; LICENSE deferred; zero LAN IPs; podman first if an image were built (none is).
- Reviewer approval notes (2026-11-26): v0.23.4 digest verification, the s6 UID-10000 drop reasoning (correctly omitting pod-level runAsNonRoot), the fail-closed API_SERVER_KEY guard, same-namespace admission, the kind backup/restore persistence proof — "touch only k8s/chart/hermes-agent/** and .github/workflows/hermes-chart.yml".

## Upstream receipts (`verified-here`, 2026-11-26 — re-stated from the spec phase; the evidence base for the chart's defaults)

- Docker Hub `nousresearch/hermes-agent`: `v0.23.4` manifest-list digest `sha256:ef0650d523ee1b5ab32c779acabc446d9936869a9932591553688a62bcf0c42f` (amd64+arm64), `v0.23.4-desktop` `sha256:d7f13dd6…`; `stable` == the `v0.23.4` digest; 388 tags, actively published (last pushes 2026-11-24/25).
- `website/docs/user-guide/docker.md` + `features/api-server.md` + `backup-and-transfer.md` at tag `v0.23.4`: the env contract (`API_SERVER_ENABLED/HOST/PORT/KEY/CORS_ORIGINS/MODEL_NAME`), the public `GET /health` + authenticated `/health/detailed`, the dashboard/webapp fail-closed hardening, `hermes backup`/`hermes import` as the whole-home mechanism, the never-two-gateways-on-one-data-dir rule, the WAL-on-native-filesystems note.
