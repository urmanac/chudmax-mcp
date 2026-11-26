#!/usr/bin/env bash
# The phase-9 kind rehearsal: the whole proof in one script.
#
# What it proves (the card's bar):
#   1. the hermes-agent chart installs on kind against the mock engine —
#      three releases in ONE namespace, all charts consumed READ-ONLY from
#      their in-tree paths (no umbrella edits: phase 7 runs in parallel);
#   2. the HERMES_HOME PVC survives a pod delete (state read back);
#   3. hermes backup -> a fresh PVC -> hermes import restores the whole agent
#      (state AND the model-provider config) onto an empty volume;
#   4. a chat completion through the hermes Service returns the mock engine's
#      scripted turn (hermes -> engine Service -> EndpointSlice -> bridge);
#   5. the mcp chart's default ingress NetworkPolicy admits hermes (the
#      same-namespace rule) — a 200 from the hermes pod to the mcp POD IP
#      (the Service has no endpoints pre-artifact — the phase-6 lesson).
#
# Honest framing (printed below): the "engine" is the phase-6 mock (Strata
# --engine mock, outside kind on the docker bridge) — NOT the real engine.
#
# Debugging lessons inherited from phases 5/6 (do not remove):
#   - every curl prints its http_code (-w) and surfaces errors (-sS);
#   - a probe against the bridge mock carries the Host header (a bare-IP
#     probe reads as the guard's 403, not a network failure);
#   - one-shot probe pods are read via kubectl logs, never the attach stream;
#   - assert on logs/HTTP answers, never pod status alone (kindnet enforces
#     NetworkPolicy since kind v0.24 — a blocked pod and a waiting pod look
#     identical on status).
set -euo pipefail

CLUSTER="${CLUSTER:-chudmax-phase9}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
NS="chudmax"
KEY="phase9-kind-rehearsal-key-not-a-secret"
HERMES_IMAGE="nousresearch/hermes-agent:v0.23.4"
STRATA_PIN="de34ebaa521d8f628b4bb1884e5c34101730299a"
MARKER="phase9-restore-proof-marker"

say() { echo "[phase9-smoke] $*"; }
receipt() { say "RECEIPT: $*"; }

hermes_pod() {
  kubectl -n "$NS" get pod -l app.kubernetes.io/name=hermes-agent \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
}

# kubectl exec with a retry (CI receipt, run #6): a pod can be Initialized
# before its container exists — the first exec raced the container's start
# ("unable to upgrade connection: container not found"). Retry ONLY the
# connection-race errors; a real command failure (an import refusal, a config
# rejection) surfaces IMMEDIATELY with its message so the receipt shows it.
hexec() {
  local attempt err=/tmp/hexec.err
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if kubectl -n "$NS" exec "$@" 2>"$err"; then return 0; fi
    if ! grep -qE 'unable to upgrade connection|container not found|error dialing backend|did not complete successfully' "$err"; then
      cat "$err" >&2
      return 1
    fi
    say "exec raced the container's start (attempt $attempt) — retrying in 5s"
    sleep 5
  done
  cat "$err" >&2
  say "exec did not succeed in 12 attempts — the pod's state:"
  kubectl -n "$NS" get pod -l app.kubernetes.io/name=hermes-agent -o wide || true
  kubectl -n "$NS" get pod -l app.kubernetes.io/name=hermes-agent \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].lastState.terminated.message}{"\n"}{end}' || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -25 || true
  kubectl -n "$NS" describe pod -l app.kubernetes.io/name=hermes-agent || true
  exit 1
}

# ---------- 0. cluster + bridge gateway ----------
say "cluster: $(kubectl config current-context)"
# The kind network's IPv4 gateway (docker may list the IPv6 IPAM block first —
# grep for an IPv4-shaped gateway; never a hardcoded fallback).
GW=$(docker network inspect kind | python3 -c "
import json,sys
cfg=json.load(sys.stdin)[0]['IPAM']['Config']
print(next(c['Gateway'] for c in cfg if c.get('Gateway','').count('.')==3))")
say "docker bridge gateway: $GW"

# ---------- 1. images: the node pre-warm + the mcp pod's two, podman-first ----------
say "pre-warming the node's containerd store with the upstream image (${HERMES_IMAGE})..."
# CI receipts (runs #1 and #2): the docker-daemon intermediary fails both ways —
# the manifest LIST fails `kind load docker-image` (ctr's --all-platforms import
# hits the arm64 blob the daemon never pulled: "content digest sha256:2223ae…:
# not found"), and the per-arch tag `v0.23.4-amd64` is NOT pullable (the per-arch
# tags exist for rc/canary builds; the final release publishes only list tags).
# The node's containerd resolves multi-arch lists natively — the production path:
# crictl pre-pull, with the kubelet's own pull (pullPolicy: IfNotPresent) as the
# fallback when crictl is unavailable.
if docker exec "${CLUSTER}-control-plane" crictl pull "$HERMES_IMAGE"; then
  receipt "node pre-pulled ${HERMES_IMAGE} via crictl (multi-arch resolved natively)"
else
  say "crictl pre-pull failed — the kubelet will pull at schedule time (IfNotPresent)"
fi
docker exec "${CLUSTER}-control-plane" crictl images | grep hermes-agent || say "the image is NOT in the node's store yet"

say "building the mcp pod's images with podman (the chart-default tags)..."
# The phase-6 pbuild: parallel jobs pull base images from shared anonymous
# buckets and a pull can fail transiently (podman exits 125) — retry, then die.
pbuild() {
  local tag="$1" file="$2" ctx="$3" attempt
  for attempt in 1 2 3; do
    if podman build -q -t "$tag" -f "$file" "$ctx"; then return 0; fi
    say "build of $tag failed (attempt $attempt) — retrying after a pause"
    sleep $((attempt * 20))
  done
  say "the build of $tag failed three times"; exit 1
}
pbuild ghcr.io/urmanac/chudmax/fetcher:0.1.0 k8s/image/Dockerfile k8s
pbuild ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0 k8s/tickets-mcp/Dockerfile k8s/tickets-mcp
for img in ghcr.io/urmanac/chudmax/fetcher:0.1.0 ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0; do
  # A UNIQUE archive per image (CI receipt run #4): reusing one path makes the
  # second podman save APPEND to the existing docker-archive — podman refuses:
  # "docker-archive doesn't support modifying existing images" (exit 125).
  tar="/tmp/$(printf '%s' "$img" | tr '/:' '__').tar"
  podman save --format docker-archive -o "$tar" "$img"
  docker load --input "$tar" >/dev/null
  # The phase-6 proven route: load the SAME archive via image-archive
  # (`kind load docker-image` re-saves through docker and ctr rejects it).
  kind load image-archive "$tar" --name "$CLUSTER"
  # Disk hygiene: the archives are ~GB-class; the node's create-stage failure
  # window (runc snapshot prep) tightens with every stray copy.
  rm -f "$tar"
done
receipt "mcp pod images built (podman) and loaded (the phase-6 image-archive route)"

# ---------- 2. the mock engine OUTSIDE kind on the bridge (read-only pin) ----------
say "cloning Strata at the phase-6 pin and building the mock engine image..."
git init -q "$RUNNER_TEMP/strata" 2>/dev/null || true
git -C "$RUNNER_TEMP/strata" fetch -q --depth 1 https://github.com/kingdonb/Strata "$STRATA_PIN"
git -C "$RUNNER_TEMP/strata" checkout -q FETCH_HEAD
pbuild ghcr.io/urmanac/chudmax/web:0.1.0 k8s/umbrella/chudmax/web-image/Dockerfile "$RUNNER_TEMP/strata"
podman save --format docker-archive -o /tmp/web.tar ghcr.io/urmanac/chudmax/web:0.1.0
docker load --input /tmp/web.tar >/dev/null
rm -f /tmp/web.tar
docker rm -f hermes-mock-engine >/dev/null 2>&1 || true
docker run -d --name hermes-mock-engine --network kind -p 8080:8080 \
  -e STRATA_ALLOWED_HOSTS="chudmax-engine,chudmax-engine.chudmax.svc,chudmax-engine.chudmax.svc.cluster.local,localhost,127.0.0.1" \
  ghcr.io/urmanac/chudmax/web:0.1.0 --engine mock --host 0.0.0.0 --port 8080 >/dev/null
code=""
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' \
    -H 'Host: chudmax-engine' http://127.0.0.1:8080/health || true)
  [ "$code" = "200" ] && break
  sleep 1
done
[ "$code" = "200" ] || { docker logs hermes-mock-engine; exit 1; }
receipt "mock engine live on the bridge gateway (${GW}:8080)"

# ---------- 3. three releases, ONE namespace (charts consumed read-only) ----------
kubectl create namespace "$NS" || true
helm install engine k8s/umbrella/chudmax/subcharts/chudmax-engine -n "$NS" \
  --set fullnameOverride=chudmax-engine \
  --set endpoint.host="$GW" --set endpoint.port=8080
helm install mcp k8s/chart/chudmax-mcp -n "$NS" --set fullnameOverride=chudmax-mcp
helm install hermes k8s/chart/hermes-agent -n "$NS" \
  --set fullnameOverride=hermes --set apiServer.key="$KEY"
if kubectl -n "$NS" wait --for=condition=initialized pod -l app.kubernetes.io/name=hermes-agent --timeout=180s; then
  :
else
  # Diagnose, then retry longer: a slow kubelet image pull (the crictl pre-pull
  # fallback path) can eat the first window; a stuck pod names itself here.
  say "the initialized wait timed out once — the state:"
  kubectl -n "$NS" get pods -o wide || true
  kubectl -n "$NS" get pvc || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -25 || true
  if ! kubectl -n "$NS" wait --for=condition=initialized pod -l app.kubernetes.io/name=hermes-agent --timeout=300s; then
    kubectl -n "$NS" describe pod -l app.kubernetes.io/name=hermes-agent || true
    exit 1
  fi
  say "initialized on the extended wait"
fi
# Seed the provider config as soon as the container is initialized — BEFORE
# waiting for readiness: a gateway that refuses to boot without a provider
# gets its config at the next s6 restart instead of wedging the wait below.
say "seeding model-provider config + the SOUL.md marker (real agent state)..."
hexec deploy/hermes -- hermes config set model.provider custom
hexec deploy/hermes -- hermes config set model.model mock
hexec deploy/hermes -- hermes config set model.base_url http://chudmax-engine:8080/v1
# The mock advertises model id anthropic/claude-opus-4.6, whose registry window is
# 32,768 — below hermes' 64,000 floor (_enforce_minimum_context, agent_init.py).
# model.ollama_num_ctx is the upstream-sanctioned override for LOCAL servers, and
# the unqualified host here (chudmax-engine, no dots) is local by definition — so
# max(32,768, 65,536) clears the floor. Rides in the backup: present after restore.
hexec deploy/hermes -- hermes config set model.ollama_num_ctx 65536
# Second 64K guard, same model id: the auxiliary compression model defaults to the
# main model and (same model, same route) inherits the compressor's 32,768 window
# (check_compression_model_feasibility, conversation_compression.py). The config
# override short-circuits detection — get_model_context_length returns a positive
# config_context_length before any catalog lookup. Also rides in the backup.
hexec deploy/hermes -- hermes config set auxiliary.compression.context_length 65536
hexec deploy/hermes -- hermes config set model.api_key none
hexec deploy/hermes -- \
  sh -c "printf '%s\n' '${MARKER}' >> /opt/data/SOUL.md"
grep -q "$MARKER" \
  <(hexec deploy/hermes -- cat /opt/data/SOUL.md)
receipt "seeded: provider config (6 config keys) + the SOUL.md marker"
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
receipt "hermes pod ready (startup probe through s6 stage2 passed)"
helm test hermes -n "$NS"
receipt "helm test hook: /health 200 + bearer /v1/models 200 through the Service"
# The engine pointer's own hook: /health through the Service -> the bridge mock.
helm test engine -n "$NS"
receipt "engine pointer hook: /health through the Service -> the bridge mock 200"

# ---------- 4. backup the whole agent, copy the zip to the runner ----------
POD=$(hermes_pod)
hexec "$POD" -- hermes backup -o /tmp/agent.zip
kubectl cp "${NS}/${POD}:/tmp/agent.zip" /tmp/agent.zip
say "backup zip: $(stat -c%s /tmp/agent.zip) bytes"
[ -s /tmp/agent.zip ]
receipt "hermes backup captured the home and reached the runner"

# ---------- 5. pod delete: the PVC survives ----------
kubectl -n "$NS" delete pod "$POD"
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
POD2=$(hermes_pod); [ "$POD2" != "$POD" ] || say "note: same pod name returned (statefulset-like naming)"
grep -q "$MARKER" <(hexec "$POD2" -- cat /opt/data/SOUL.md)
BASE_URL_READBACK=$(hexec "$POD2" -- hermes config get model.base_url)
say "config readback after pod delete: model.base_url=${BASE_URL_READBACK}"
receipt "pod delete survived: marker + provider config on the same PVC (new pod ${POD2})"

# ---------- 6. restore onto an EMPTY volume ----------
VOL_BEFORE=$(kubectl -n "$NS" get pvc hermes -o jsonpath='{.spec.volumeName}')
kubectl -n "$NS" get pvc hermes
helm uninstall hermes -n "$NS"
# CI receipt (run #11): uninstall returns while the PVC is still Terminating —
# an immediate get reads it as "survived". Poll until the object is gone.
say "waiting for the PVC to finish terminating (async deletion)..."
pvc_gone=""
for _ in $(seq 1 60); do
  if ! kubectl -n "$NS" get pvc hermes >/dev/null 2>&1; then pvc_gone=1; break; fi
  sleep 2
done
if [ "$pvc_gone" = "1" ]; then
  receipt "uninstall deleted the release AND its PVC"
else
  kubectl -n "$NS" get pvc
  say "PVC still present after 120s — not the empty-volume case"
  exit 1
fi
helm install hermes k8s/chart/hermes-agent -n "$NS" \
  --set fullnameOverride=hermes --set apiServer.key="$KEY"
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
VOL_AFTER=$(kubectl -n "$NS" get pvc hermes -o jsonpath='{.spec.volumeName}')
say "volume: ${VOL_BEFORE} -> ${VOL_AFTER}"
[ -n "$VOL_BEFORE" ] && [ -n "$VOL_AFTER" ] && [ "$VOL_BEFORE" != "$VOL_AFTER" ]
receipt "fresh PVC, fresh volume (${VOL_AFTER}) — empty by construction"
kubectl cp /tmp/agent.zip "${NS}/$(hermes_pod):/tmp/agent.zip"
# Inside the s6 image the running gateway holds state.db open, and stage2 has
# already seeded config.yaml/.env on the fresh volume: stop the s6 gateway so
# state.db has no live holder, pass --force for non-interactive overwrite, and
# mark desired_state back up (`hermes gateway start`) before the rollout restart.
hexec deploy/hermes -- hermes gateway stop
hexec deploy/hermes -- hermes import /tmp/agent.zip --force
hexec deploy/hermes -- hermes gateway start
kubectl -n "$NS" rollout restart deploy/hermes
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
grep -q "$MARKER" <(hexec deploy/hermes -- cat /opt/data/SOUL.md)
BASE_URL_RESTORED=$(hexec deploy/hermes -- hermes config get model.base_url)
say "config readback after restore: model.base_url=${BASE_URL_RESTORED}"
[ "$BASE_URL_RESTORED" = "$BASE_URL_READBACK" ]
receipt "restore onto the empty volume: marker + provider config back (hermes import)"

# ---------- 7. chat through the Service -> the mock engine's scripted turn ----------
say "chat completion through the hermes Service (port-forward)..."
kubectl -n "$NS" port-forward svc/hermes 18642:8642 >/tmp/pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true; docker rm -f hermes-mock-engine >/dev/null 2>&1 || true' EXIT
sleep 3
CHAT_OK=""
for _ in $(seq 1 5); do
  CHAT_OK=$(curl -sS -m 120 -X POST \
    -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
    -d '{"model":"hermes-agent","messages":[{"role":"user","content":"Say hi"}]}' \
    http://127.0.0.1:18642/v1/chat/completions | python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)
    print(r['choices'][0]['message']['content'])
except Exception as e:
    print(f'ERR {e}')") || CHAT_OK=""
  echo "$CHAT_OK" | grep -q "Hello from the mock engine" && break
  sleep 5
done
echo "$CHAT_OK" | grep -q "Hello from the mock engine" \
  || { say "chat failed; hermes logs:"; kubectl -n "$NS" logs deploy/hermes --tail=80 || true; exit 1; }
receipt "chat through the Service -> the mock engine's scripted turn"

# ---------- 8. the mcp chart's ingress policy admits hermes (same namespace) ----------
MCP_POD_IP=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=chudmax-mcp \
  -o jsonpath='{.items[0].status.podIP}')
say "mcp pod IP: ${MCP_POD_IP} (the Service is endpoint-less pre-artifact — the phase-6 lesson)"
CODE=$(hexec deploy/hermes -- curl -s -o /dev/null -m 10 -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "http://${MCP_POD_IP}:8080/mcp")
say "hermes -> mcp pod POST /mcp (initialize) -> ${CODE}"
[ "$CODE" = "200" ]
receipt "mcp ingress NetworkPolicy admits hermes (same-namespace rule, 200)"

echo
echo "RECEIPT: all phase-9 checks passed (install+hook, pod-delete, restore-onto-empty-volume, mock-engine chat, mcp admission)"
