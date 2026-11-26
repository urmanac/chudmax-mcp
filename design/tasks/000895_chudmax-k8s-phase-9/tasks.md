# Implementation Tasks: chudmax k8s phase 9 Hermes chart with persistent home

- [ ] Verify preconditions: phase 6 outputs on `main` (umbrella, engine/web subcharts, `umbrella-kind.yml`); rebase the feature branch onto current `main`
- [ ] Create `k8s/chart/chudmax-hermes/Chart.yaml` (v2, `chudmax-hermes` 0.1.0, appVersion `0.23.4`) and `values.yaml` (minimal: image `nousresearch/hermes-agent:v0.23.4` + digest knob, `apiServer` block, `storage` block, resources, `terminationGracePeriodSeconds`, `extraEnv`, `securityContext` passthrough)
- [ ] Templates: Deployment (`strategy: Recreate`, `automountServiceAccountToken: false`, `seccompProfile: RuntimeDefault`, NO `runAsNonRoot`, PVC mounted at `/opt/data`, `gateway run` args) — with a render guard failing loudly when `apiServer.enabled` but no key
- [ ] Templates: Service (8642), PVC (RWO, 2Gi default, `storageClass` empty = cluster default), optional Secret from `apiServer.key` / `existingSecret` reference
- [ ] Templates: Helm test hook (pinned `curlimages/curl`) — `/health` → 200 and authenticated `/v1/models` → 200 with the key from the Secret
- [ ] Probes: startup/readiness/liveness `httpGet /health:8642` (generous startup failureThreshold); no probes rendered when the API server is off
- [ ] Chart `README.md`: the three answered questions (image, interface, backup inventory), the `hermes backup`/`hermes import` recipe, the exec-drop note, the standalone-install admission recipe (mcp `extraIngress`), the WAL/local-path note, the runAsNonRoot deviation
- [ ] `helm lint` + `helm template` ×2 (defaults; rehearsal variant) + kubeconform — local proof, `verified-here`
- [ ] Umbrella: add the `file://../../chart/chudmax-hermes` dependency (condition `hermes.enabled`) to `Chart.yaml`, the `hermes:` block with `enabled: false` default to `values.yaml`, and the Hermes pins row to the README
- [ ] `.github/workflows/hermes-kind.yml`: chart job (lint/template ×2/kubeconform, umbrella renders with hermes enabled + disabled)
- [ ] `.github/workflows/hermes-kind.yml`: kind job — pull `v0.23.4`, `kind load image-archive`, umbrella install with `hermes.enabled=true` + rehearsal values (bridge-gateway engine endpoint, test API key), hermes pod ready
- [ ] Kind job — pod-delete survival: `kubectl exec … hermes config set phase9.marker` + provider config → `hermes backup` + `kubectl cp` zip out → `kubectl delete pod` → new pod → marker reads back
- [ ] Kind job — restore onto empty volume: uninstall → fresh install (new PVC) → cp zip in → `hermes import` → restart → marker + provider config read back
- [ ] Kind job — mock-engine chat: `POST /v1/chat/completions` through the hermes Service with the bearer key → scripted turn from the mock engine (Host-header-correct diagnostics in the ladder)
- [ ] Kind job — mcp admission: request from the hermes pod to the tickets-mcp Service answers 200 (same-namespace rule admits hermes; no mcp chart edits)
- [ ] Existing workflows stay green (phases 6/7/8 surfaces untouched — `hermes.enabled` defaults false)
- [ ] Record proofs in this task dir with the three labels (`verified-here` renders; kind receipts labeled honestly, re-labeled after the first green run)
- [ ] One PR via `propose_pull_request` (conventional commits; box untouched; no registry push; no credentials in public artifacts); `mark_task_complete` after merge
