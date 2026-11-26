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
KEY_DESC="rehearsal-only non-secret test key"

say() { echo "[phase9-smoke] $*"; }
receipt() { say "RECEIPT: $*"; }

hermes_pod() {
  kubectl -n "$NS" get pod -l app.kubernetes.io/name=hermes-agent \
    -o jsonpath='{.items[0].metadata.name}'
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

# ---------- 1. images: upstream pull + the mcp pod's two, podman-first ----------
say "pulling the upstream image (${HERMES_IMAGE})..."
docker pull "$HERMES_IMAGE"
kind load docker-image "$HERMES_IMAGE" --name "$CLUSTER"
receipt "upstream image pulled and loaded (${HERMES_IMAGE})"

say "building the mcp pod's images with podman (the chart-default tags)..."
podman build --platform linux/amd64 -t ghcr.io/urmanac/chudmax/fetcher:0.1.0 \
  -f k8s/image/Dockerfile k8s
podman build --platform linux/amd64 -t ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0 \
  -f k8s/tickets-mcp/Dockerfile k8s/tickets-mcp
for img in ghcr.io/urmanac/chudmax/fetcher:0.1.0 ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0; do
  podman save --format docker-archive -o /tmp/img.tar "$img"
  docker load --input /tmp/img.tar
  kind load docker-image "$img" --name "$CLUSTER"
done
receipt "mcp pod images built (podman) and loaded"

# ---------- 2. the mock engine OUTSIDE kind on the bridge (read-only pin) ----------
say "cloning Strata at the phase-6 pin and building the mock engine image..."
git init -q "$RUNNER_TEMP/strata" 2>/dev/null || true
git -C "$RUNNER_TEMP/strata" fetch -q --depth 1 https://github.com/kingdonb/Strata "$STRATA_PIN"
git -C "$RUNNER_TEMP/strata" checkout -q FETCH_HEAD
podman build --platform linux/amd64 -t web-ci:0.1.0 \
  -f k8s/umbrella/chudmax/web-image/Dockerfile "$RUNNER_TEMP/strata"
podman save --format docker-archive -o /tmp/web.tar web-ci:0.1.0
docker load --input /tmp/web.tar
docker rm -f hermes-mock-engine >/dev/null 2>&1 || true
docker run -d --name hermes-mock-engine --network kind -p 8080:8080 \
  -e STRATA_ALLOWED_HOSTS="chudmax-engine,localhost,127.0.0.1" \
  web-ci:0.1.0 --engine mock --host 0.0.0.0 --port 8080 >/dev/null
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
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
receipt "hermes pod ready (startup probe through s6 stage2 passed)"
helm test hermes -n "$NS"
receipt "helm test hook: /health 200 + bearer /v1/models 200 through the Service"
# The engine pointer's own hook: /health through the Service -> the bridge mock.
helm test engine -n "$NS"
receipt "engine pointer hook: /health through the Service -> the bridge mock 200"

# ---------- 4. seed state (config via exec; the exec shim drops to UID 10000) ----------
say "seeding model-provider config + the SOUL.md marker (real agent state)..."
kubectl -n "$NS" exec deploy/hermes -- hermes config set model.provider custom
kubectl -n "$NS" exec deploy/hermes -- hermes config set model.model mock
kubectl -n "$NS" exec deploy/hermes -- hermes config set model.base_url http://chudmax-engine:8080/v1
kubectl -n "$NS" exec deploy/hermes -- hermes config set model.api_key none
kubectl -n "$NS" exec deploy/hermes -- \
  sh -c "printf '%s\n' '${MARKER}' >> /opt/data/SOUL.md"
grep -q "$MARKER" \
  <(kubectl -n "$NS" exec deploy/hermes -- cat /opt/data/SOUL.md)
receipt "seeded: provider config (4 config keys) + the SOUL.md marker"

# ---------- 5. backup the whole agent, copy the zip to the runner ----------
POD=$(hermes_pod)
kubectl -n "$NS" exec "$POD" -- hermes backup -o /tmp/agent.zip
kubectl -n "$NS" cp "$POD:/tmp/agent.zip" /tmp/agent.zip
say "backup zip: $(stat -c%s /tmp/agent.zip) bytes"
[ -s /tmp/agent.zip ]
receipt "hermes backup captured the home and reached the runner"

# ---------- 6. pod delete: the PVC survives ----------
kubectl -n "$NS" delete pod "$POD"
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
POD2=$(hermes_pod); [ "$POD2" != "$POD" ] || say "note: same pod name returned (statefulset-like naming)"
grep -q "$MARKER" <(kubectl -n "$NS" exec "$POD2" -- cat /opt/data/SOUL.md)
BASE_URL_READBACK=$(kubectl -n "$NS" exec "$POD2" -- hermes config get model.base_url)
say "config readback after pod delete: model.base_url=${BASE_URL_READBACK}"
receipt "pod delete survived: marker + provider config on the same PVC (new pod ${POD2})"

# ---------- 7. restore onto an EMPTY volume ----------
VOL_BEFORE=$(kubectl -n "$NS" get pvc hermes -o jsonpath='{.spec.volumeName}')
kubectl -n "$NS" get pvc hermes
helm uninstall hermes -n "$NS"
kubectl -n "$NS" get pvc hermes 2>/dev/null \
  && { say "PVC survived uninstall — not the empty-volume case"; exit 1; } \
  || receipt "uninstall deleted the release AND its PVC"
helm install hermes k8s/chart/hermes-agent -n "$NS" \
  --set fullnameOverride=hermes --set apiServer.key="$KEY"
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
VOL_AFTER=$(kubectl -n "$NS" get pvc hermes -o jsonpath='{.spec.volumeName}')
say "volume: ${VOL_BEFORE} -> ${VOL_AFTER}"
[ -n "$VOL_BEFORE" ] && [ -n "$VOL_AFTER" ] && [ "$VOL_BEFORE" != "$VOL_AFTER" ]
receipt "fresh PVC, fresh volume (${VOL_AFTER}) — empty by construction"
kubectl -n "$NS" cp /tmp/agent.zip "$(hermes_pod):/tmp/agent.zip"
if kubectl -n "$NS" exec deploy/hermes -- hermes import /tmp/agent.zip; then
  say "import: plain form accepted"
else
  say "import: plain form refused — retrying with --force"
  kubectl -n "$NS" exec deploy/hermes -- hermes import /tmp/agent.zip --force
fi
kubectl -n "$NS" rollout restart deploy/hermes
kubectl -n "$NS" rollout status deploy/hermes --timeout=360s
grep -q "$MARKER" <(kubectl -n "$NS" exec deploy/hermes -- cat /opt/data/SOUL.md)
BASE_URL_RESTORED=$(kubectl -n "$NS" exec deploy/hermes -- hermes config get model.base_url)
say "config readback after restore: model.base_url=${BASE_URL_RESTORED}"
[ "$BASE_URL_RESTORED" = "$BASE_URL_READBACK" ]
receipt "restore onto the empty volume: marker + provider config back (hermes import)"

# ---------- 8. chat through the Service -> the mock engine's scripted turn ----------
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

# ---------- 9. the mcp chart's ingress policy admits hermes (same namespace) ----------
MCP_POD_IP=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=chudmax-mcp \
  -o jsonpath='{.items[0].status.podIP}')
say "mcp pod IP: ${MCP_POD_IP} (the Service is endpoint-less pre-artifact — the phase-6 lesson)"
CODE=$(kubectl -n "$NS" exec deploy/hermes -- curl -s -o /dev/null -m 10 -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "http://${MCP_POD_IP}:8080/mcp")
say "hermes -> mcp pod POST /mcp (initialize) -> ${CODE}"
[ "$CODE" = "200" ]
receipt "mcp ingress NetworkPolicy admits hermes (same-namespace rule, 200)"

echo
echo "RECEIPT: all phase-9 checks passed (install+hook, pod-delete, restore-onto-empty-volume, mock-engine chat, mcp admission)"
