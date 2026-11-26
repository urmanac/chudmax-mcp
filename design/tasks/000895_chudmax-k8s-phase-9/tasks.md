# Implementation Tasks: chudmax k8s phase 9 Hermes chart with persistent home

- [ ] Verify preconditions: phases 5 & 6 merged on main @ `0787cfe`; branch off current `main`; confirm the phase-7 surfaces (`k8s/umbrella/**`, `k8s/canary/**`, phase-7 workflows) are untouched by this branch for its whole life
- [ ] Create `k8s/chart/hermes-agent/Chart.yaml` (v2, `hermes-agent` 0.1.0, appVersion `0.23.4` — named for the phase-10 split) and `values.yaml` (minimal: image `nousresearch/hermes-agent:v0.23.4` + digest knob, `apiServer` block, `storage` block, resources, `terminationGracePeriodSeconds`, `extraEnv`, `securityContext` passthrough)
- [ ] Templates: Deployment (`strategy: Recreate`, `automountServiceAccountToken: false`, `seccompProfile: RuntimeDefault`, NO `runAsNonRoot`, PVC mounted at `/opt/data`, `gateway run` args) — with a render guard failing loudly when `apiServer.enabled` but no key
- [ ] Templates: Service (8642), PVC (RWO, 2Gi default, `storageClass` empty = cluster default), optional Secret from `apiServer.key` / `existingSecret` reference
- [ ] Templates: Helm test hook (pinned `curlimages/curl`) — `/health` → 200 and authenticated `/v1/models` → 200 with the key from the Secret
- [ ] Probes: startup/readiness/liveness `httpGet /health:8642` (generous startup failureThreshold); no probes rendered when the API server is off
- [ ] Chart `README.md`: the three answered questions (image, interface, backup inventory), the `hermes backup`/`hermes import` recipe, the exec-drop note, the reachability note (engine via the model provider `base_url` — the chart stays engine-agnostic), the admission note (same-namespace default; mcp `extraIngress` passthrough for foreign namespaces), the WAL/local-path note, the runAsNonRoot deviation
- [ ] `helm lint` + `helm template` ×2 (defaults; rehearsal variant) + kubeconform — local proof, `verified-here`
- [ ] `.github/workflows/hermes-chart.yml` chart job: per-chart lint/template ×2/kubeconform; no image job (nothing built this phase)
- [ ] `.github/workflows/hermes-chart.yml` kind job — three releases in ONE namespace from read-only in-tree paths: engine pointer (`k8s/umbrella/chudmax/subcharts/chudmax-engine`, EndpointSlice → bridge gateway computed at runtime), mcp (`k8s/chart/chudmax-mcp`, pod images built with podman from the repo's Dockerfiles + `kind load image-archive`), hermes (pull `v0.23.4` + `kind load image-archive`)
- [ ] Kind job — pod-delete survival: `kubectl exec … hermes config set phase9.marker` + provider config → `hermes backup` + `kubectl cp` zip out → `kubectl delete pod` → new pod → marker reads back
- [ ] Kind job — restore onto empty volume: uninstall → fresh install (new PVC) → cp zip in → `hermes import` → restart → marker + provider config read back
- [ ] Kind job — mock-engine chat: `POST /v1/chat/completions` through the hermes Service with the bearer key → scripted turn from the mock engine (Host-header-correct diagnostics in the ladder)
- [ ] Kind job — mcp admission: request from the hermes pod to the tickets-mcp Service answers 200 (same-namespace default rule admits hermes; no mcp chart edits)
- [ ] Confirm existing CI (phase-5/6/7 workflows) stays green and untouched; zero LAN IPs anywhere in the write set
- [ ] Record proofs in this task dir with the three labels (`verified-here` renders; kind receipts labeled honestly, re-labeled after the first green run)
- [ ] One PR via `propose_pull_request` (conventional commits; box untouched; no registry push; no credentials in public artifacts; missing-LICENSE flag in the PR description); `mark_task_complete` after merge
