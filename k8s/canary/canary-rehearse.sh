#!/usr/bin/env bash
# The phase-7 canary rehearsal orchestrator (T-0037): a throwaway kind cluster,
# Cilium (the phase-5 recipe), Flux + source-watcher, the artifact chain (phase
# 5's, consumed by path), the umbrella under the rehearsal profile, Traefik as
# the Gateway API controller (ADR 001), Flagger (meshProvider gatewayapi:v1) +
# its ONE-pod Prometheus + the loadtester, and the card's two halves:
#   1. the GOOD upgrade: image retagged 0.1.1 -> the pre-rollout suite passes
#      (health, tool-count equality, one chat turn, the seven selftest
#      questions) -> the real metrics pass (Strata's native OpenMetrics:
#      vllm:request_success_total finish-rate + the e2e p99) -> the weight
#      steps 10->50 -> promotion recorded;
#   2. the BROKEN upgrade: ONE combined JSON patch (image 0.1.1-broken + the
#      mounted dead-URL hub config) -> the hub silently omits the unreachable
#      server (verified behavior) -> the pre-rollout webhook fails -> halt ->
#      rollback; the METRICS stay healthy (the engine works) — the webhook is
#      the broken upgrade's ONLY tripwire.
# CI is the authoritative run (kind cannot run in the development sandbox).
# LIVE STREAMING: every line the script emits lands in the job log as it
# happens (the exec-tee below) and in the logs artifact; each receipt/note is
# ALSO appended to $GITHUB_STEP_SUMMARY the moment it happens, so the run
# summary fills in live instead of at the end.
set -euo pipefail

NS=chudmax
REL=chudmax
CLUSTER=phase7-canary
GIT_PORT=38081
GIT_ROOT=${REHEARSAL_GIT_ROOT:-/tmp/canary-git}
LOGS=${REHEARSAL_LOGS:-/tmp/canary-logs}
SUMMARY=${REHEARSAL_SUMMARY:-/tmp/canary-summary.txt}
PROVIDER=${KIND_EXPERIMENTAL_PROVIDER:-docker}
BUILDER=${REHEARSAL_BUILDER:-podman}
CHAIN_WAIT=${REHEARSAL_CHAIN_WAIT:-240}    # seconds a commit may take to show up
STRATA_REPO=${STRATA_REPO:-https://github.com/kingdonb/Strata}
STRATA_PIN=de34ebaa521d8f628b4bb1884e5c34101730299a   # v0.2.21-mbp.rtx.1 (the umbrella README's pin)
WEB_IMAGE=ghcr.io/urmanac/chudmax/web:0.1.0           # the chart's default tag (loaded, IfNotPresent)
WEB_GOOD=ghcr.io/urmanac/chudmax/web:0.1.1            # same bytes, retagged (the good upgrade)
WEB_BROKEN=ghcr.io/urmanac/chudmax/web:0.1.1-broken   # same bytes, retagged (the broken upgrade)
FETCHER_IMAGE=ghcr.io/urmanac/chudmax/fetcher:0.1.0
SERVER_IMAGE=ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0
CURL_IMAGE=curlimages/curl:8.12.1
ROUTE_HOST=chudmax.rehearsal                          # a rehearsal doc name, never a real domain
TRAEFIK_URL=http://traefik.$NS
METRICS_SERVER=${CANARY_METRICS_SERVER:-http://flagger-prometheus.flagger:9090}
FLAGGER_CHART=1.45.0
LOADTESTER_CHART=0.39.0
TRAEFIK_CHART=43.0.0
GATEWAY_API_REF=v1.7.0
CILIUM_VER=v1.18.1
FLUX_VER=v2.10.1
GIT_SRV_PID=
PROM_PF_PID=
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
mkdir -p "$LOGS"
: > "$SUMMARY"
# Every line (stdout+stderr) streams to the job log AND lands in the logs
# artifact — GitHub job logs are sign-in-gated; the artifact is the
# diagnostic channel (the phase-5 rehearsal's pattern).
exec > >(tee -a "$LOGS/script-output.log") 2>&1

# LIVE STREAMING: in CI each note/receipt ALSO lands in the run summary the
# moment it happens (GITHUB_STEP_SUMMARY) — the summary fills in live, not at
# the end.
live() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }
note() { local line="[canary] $*"; echo "$line" | tee -a "$SUMMARY" >&2; live "$line"; }
receipt() { local line="RECEIPT: $*"; echo "$line" | tee -a "$SUMMARY"; live "$line"; }
fail() { echo "FAIL: $*" | tee -a "$SUMMARY" >&2; exit 1; }
# CI-only diagnostics: the failure path re-emits each log tail as a check-run
# annotation (readable via the public API without artifact-download access).
annotate() { # $1 annotation title, $2 log file
  local msg
  [ -s "$2" ] || return 0
  msg=$(tail -c 900 "$2" | sed -e 's/%/%25/g' -e 's/\r//g' -e 's/]/%5D/g' -e 's/;/%3B/g' \
    | awk '{printf "%s%%0A", $0}')
  printf '::error title=%s::%s\n' "$1" "$msg"
}
annotate_failure() {
  [ "${CI:-}" = "true" ] || return 0
  annotate canary-output "$LOGS/script-output.log"
  annotate pods-all "$LOGS/pods-all.txt"
  annotate events-all "$LOGS/events-all.txt"
  annotate flagger-controller "$LOGS/flagger.log"
  annotate loadtester "$LOGS/loadtester.log"
  annotate web-pods "$LOGS/web.log"
  annotate mcp-pods "$LOGS/mcp.log"
  annotate traefik "$LOGS/traefik.log"
  annotate weight-timeline "$LOGS/weight-timeline.log"
  sleep 1   # let the tee drain before the shell exits
}

cleanup() {
  rc=$?
  if [ -n "${GIT_SRV_PID:-}" ]; then kill "$GIT_SRV_PID" 2>/dev/null || true; fi
  if [ -n "${PROM_PF_PID:-}" ]; then kill "$PROM_PF_PID" 2>/dev/null || true; fi
  cp -f "$SUMMARY" "$LOGS/canary-summary.txt" 2>/dev/null || true
  if [ "${rc}" -ne 0 ]; then
    note "failure path: exporting cluster logs to $LOGS"
    kind export logs --name "$CLUSTER" "$LOGS" 2>/dev/null || true
    kubectl get pods -A -o wide > "$LOGS/pods-all.txt" 2>/dev/null || true
    kubectl get events -A --sort-by=.lastTimestamp > "$LOGS/events-all.txt" 2>/dev/null || true
    kubectl -n flagger logs deploy/flagger > "$LOGS/flagger.log" 2>/dev/null || true
    kubectl -n "$NS" logs deploy/loadtester --all-containers > "$LOGS/loadtester.log" 2>/dev/null || true
    kubectl -n "$NS" logs -l app.kubernetes.io/name=web --all-containers > "$LOGS/web.log" 2>/dev/null || true
    kubectl -n "$NS" logs -l app.kubernetes.io/name=mcp --all-containers > "$LOGS/mcp.log" 2>/dev/null || true
    kubectl -n "$NS" logs deploy/traefik > "$LOGS/traefik.log" 2>/dev/null || true
    annotate_failure
  fi
  kind delete cluster --name "$CLUSTER" 2>/dev/null || true
  note "throwaway cluster deleted (always)"
  exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------- pre-flight
command -v kubectl >/dev/null || fail "kubectl not found"
command -v helm >/dev/null || fail "helm not found"
command -v kind >/dev/null || fail "kind not found"
command -v cilium >/dev/null || fail "cilium CLI not found"
command -v flux >/dev/null || fail "flux CLI not found"
command -v jq >/dev/null || fail "jq not found"
command -v curl >/dev/null || fail "curl not found"
command -v git >/dev/null || fail "git not found"
"$BUILDER" version >/dev/null 2>&1 || fail "builder '$BUILDER' not found"
export KIND_EXPERIMENTAL_PROVIDER="$PROVIDER"
receipt "pre-flight tools OK (kind $(kind version | cut -d' ' -f2), helm $(helm version --short), builder $BUILDER)"

note "pre-flight: building and starting the Smart-HTTP test server (phase 5's helper, by path)"
( cd "$REPO/k8s/rehearsal/gittestserver" && go build -o "$LOGS/gittestserver" . )
rm -rf "$GIT_ROOT"; mkdir -p "$GIT_ROOT"
REPO_GIT=$GIT_ROOT/repo.git
WT=$GIT_ROOT/worktree
git init -q --bare -b main "$REPO_GIT"
"$LOGS/gittestserver" -root "$GIT_ROOT" -addr "0.0.0.0:$GIT_PORT" > "$LOGS/gitserver.log" 2>&1 &
GIT_SRV_PID=$!
sleep 1
git ls-remote "http://127.0.0.1:$GIT_PORT/repo.git" >/dev/null \
  || fail "pre-flight git ls-remote failed — the Smart-HTTP server is not serving"
receipt "pre-flight git ls-remote OK over http://127.0.0.1:$GIT_PORT/repo.git"

# ------------------------------------------------------------ cluster + stack
note "creating the throwaway kind cluster ($PROVIDER provider, the phase-5 kind-config: default CNI disabled)"
kind create cluster --name "$CLUSTER" --config "$REPO/k8s/rehearsal/kind-config.yaml" --wait 0s
for _ in $(seq 1 60); do
  kubectl get --raw=/readyz >/dev/null 2>&1 && break
  sleep 2
done
kubectl get --raw=/readyz >/dev/null 2>&1 || fail "apiserver not ready 120s after kind create"
# The kind network may be dual-stack with IPv6 first (the phase-5 lesson) —
# the test-repo URL must use the IPv4 gateway.
GW=$("$PROVIDER" network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Gateway != null) | select(.Gateway | test("^[0-9]+[.]")) | .Gateway' | head -n1)
[ -n "$GW" ] || fail "no IPv4 gateway on the kind network"
GIT_URL="http://${GW}:${GIT_PORT}/repo.git"
receipt "runner gateway: $GW — the test repo URL the cluster will fetch: $GIT_URL"

note "installing Cilium $CILIUM_VER (the phase-5 recipe: ipam kubernetes; policy-cidr-match-mode=nodes)"
cilium install --version "$CILIUM_VER" --set ipam.mode=kubernetes --set policyCIDRMatchMode=nodes --wait --wait-duration 8m
cilium status --wait --wait-duration 3m >/dev/null
receipt "cilium ready (nodes match mode on)"

note "installing Flux $FLUX_VER (source-watcher extra — the artifact chain's ExternalArtifact producer)"
flux install --version "$FLUX_VER" --components-extra=source-watcher --namespace=flux-system
receipt "flux installed with source-watcher"

note "applying the Gateway API CRDs ($GATEWAY_API_REF — the tutorial's pin)"
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=$GATEWAY_API_REF" >/dev/null
for _ in $(seq 1 30); do
  EST=$(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true)
  [ "$EST" = "True" ] && break
  sleep 2
done
[ "$EST" = "True" ] || fail "the Gateway API CRDs never established"
receipt "Gateway API CRDs established ($GATEWAY_API_REF)"

note "building the images (Strata web at the pin + fetcher + the canonical server) and loading them"
rm -rf "$LOGS/strata"; mkdir -p "$LOGS/strata"
git init -q "$LOGS/strata"
git -C "$LOGS/strata" fetch -q --depth 1 "$STRATA_REPO" "$STRATA_PIN"
git -C "$LOGS/strata" checkout -q FETCH_HEAD
receipt "strata checked out at $STRATA_PIN"
pbuild() { # the phase-6 kind-smoke pattern: the shared anonymous buckets' pull transients
  local tag="$1" file="$2" ctx="$3" attempt
  for attempt in 1 2 3; do
    if "$BUILDER" build -q -t "$tag" -f "$file" "$ctx"; then return 0; fi
    echo "  build of $tag failed (attempt $attempt) - retrying after a pause"
    sleep $((attempt * 20))
  done
  fail "the build of $tag failed three times"
}
pbuild "$WEB_IMAGE" "$REPO/k8s/umbrella/chudmax/web-image/Dockerfile" "$LOGS/strata"
# The two upgrade tags are the SAME bytes retagged — one build, three tags.
"$BUILDER" tag "$WEB_IMAGE" "$WEB_GOOD"
"$BUILDER" tag "$WEB_IMAGE" "$WEB_BROKEN"
pbuild "$FETCHER_IMAGE" "$REPO/k8s/image/Dockerfile" "$REPO/k8s"
pbuild "$SERVER_IMAGE" "$REPO/k8s/tickets-mcp/Dockerfile" "$REPO/k8s/tickets-mcp"
if [ "$BUILDER" = "podman" ]; then
  podman pull --platform linux/amd64 -q "$CURL_IMAGE" >/dev/null
else
  "$BUILDER" pull -q "$CURL_IMAGE" >/dev/null
fi
for img in "$WEB_IMAGE" "$WEB_GOOD" "$WEB_BROKEN" "$FETCHER_IMAGE" "$SERVER_IMAGE" "$CURL_IMAGE"; do
  tar="/tmp/$(printf '%s' "$img" | tr '/:' '__').tar"
  rm -f "$tar"
  if [ "$BUILDER" = "podman" ]; then
    podman save --format docker-archive -o "$tar" "$img"
  else
    "$BUILDER" save -o "$tar" "$img"
  fi
  kind load image-archive --name "$CLUSTER" "$tar"
  rm -f "$tar"
  echo "  loaded: $img"
done
receipt "images built and loaded via archive (no registry): web 0.1.0/0.1.1/0.1.1-broken (same bytes), fetcher, tickets-mcp, curl"

# ------------------------------------------------------------------- Traefik
note "installing Traefik $TRAEFIK_CHART (the ADR-001 Gateway API controller)"
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1
helm repo update traefik >/dev/null 2>&1
# Verified against the pinned chart source (k8s/canary/README.md's pins):
# - providers.kubernetesGateway.enabled makes Traefik the Gateway API controller
# - gatewayClass.enabled (default true) auto-creates the GatewayClass "traefik"
# - gateway.enabled (default true) deploys an unwanted DEFAULT Gateway -> off
#   (the rehearsal's own chudmax-gateway is the only one)
# - metrics.prometheus is ON by default at the "metrics" entryPoint — the web
#   pods' scrape annotations are set by the chart wiring, Traefik's here (the
#   traefik_service_* receipt leg; bonus, not load-bearing)
# - the chart's unprivileged `web` entrypoint listens on :8000 (matching
#   gateway.yaml's listener port 8000), while the Service exposes port 80 ->
#   targetPort `web`.
helm upgrade --install traefik traefik/traefik -n "$NS" --create-namespace \
  --version "$TRAEFIK_CHART" \
  --set providers.kubernetesGateway.enabled=true \
  --set gateway.enabled=false \
  --set 'deployment.podAnnotations.prometheus\.io/scrape=true' \
  --set 'deployment.podAnnotations.prometheus\.io/port=9100' \
  --set 'deployment.podAnnotations.prometheus\.io/path=/metrics' \
  >/dev/null
kubectl -n "$NS" rollout status deploy/traefik --timeout=300s
GC=$(kubectl get gatewayclass traefik -o name 2>/dev/null || true)
if [ -z "$GC" ]; then
  note "the chart did not create the GatewayClass — applying the fallback manifest"
  kubectl apply -f - <<'EOF' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
EOF
fi
kubectl get gatewayclass traefik >/dev/null || fail "the GatewayClass traefik is missing"
receipt "Traefik up (GatewayClass traefik present; the Service dials in-cluster, no MetalLB)"

# ---------------------------------------------- the umbrella (rehearsal profile)
note "installing the umbrella with the rehearsal profile (engine off, chart Service off, the hub wiring on, the scrape annotations on)"
rm -rf "$REPO/k8s/umbrella/chudmax/charts"
helm dependency build "$REPO/k8s/umbrella/chudmax" >/dev/null
helm upgrade --install "$REL" "$REPO/k8s/umbrella/chudmax" -n "$NS" --create-namespace \
  --values "$HERE/values-rehearsal.yaml" >/dev/null
kubectl -n "$NS" rollout status deploy/chudmax-web --timeout=300s
kubectl -n "$NS" get deploy chudmax-web >/dev/null 2>&1 \
  || fail "the fullname drifted: deploy chudmax-web not found (the fixtures pin it via fullnameOverride)"
HOSTS=$(kubectl -n "$NS" get deploy chudmax-web -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="STRATA_ALLOWED_HOSTS")].value}')
receipt "allowedHosts rendered: $HOSTS"
kubectl -n "$NS" apply -f "$HERE/mcp-config-broken.yaml" >/dev/null
receipt "the broken hub config applied early (the patch stage only repoints the arg)"

# ------------------------------------------------- the artifact chain (phase 5, by path)
apply_test_manifests() {
  sed "s|__RUNNER_HTTP__|${GW}:${GIT_PORT}|" "$REPO/k8s/rehearsal/gitrepository-test.yaml" | kubectl -n "$NS" apply -f - >/dev/null
  kubectl -n "$NS" apply -f "$REPO/k8s/repo-sync/artifactgenerator.yaml" >/dev/null
  # The policy lands in flux-system (a NetworkPolicy only selects pods in its
  # OWN namespace — the phase-5 lesson); rewrite the release namespace AND the
  # pod name label (`alias: mcp` in the umbrella sets app.kubernetes.io/name: mcp,
  # whereas standalone chudmax-mcp sets chudmax-mcp).
  sed -e 's|chudmax-releases|'"$NS"'|' \
      -e 's|app.kubernetes.io/name: chudmax-mcp|app.kubernetes.io/name: mcp|' \
      "$REPO/k8s/repo-sync/artifact-ingress.yaml" | kubectl -n flux-system apply -f - >/dev/null
}
note "the artifact chain: the test manifests + the seed push (the ready-gated mcp Service path)"
rm -rf "$WT"; git init -q -b main "$WT"
cp "$REPO/k8s/rehearsal/fixture/tickets.md" "$REPO/k8s/rehearsal/fixture/STATE.md" "$WT/"
cp -r "$REPO/k8s/rehearsal/fixture/docs" "$REPO/k8s/rehearsal/fixture/decisions" "$WT/"
( cd "$WT" && git add -A && git -c user.email=canary@test -c user.name=canary commit -qm "fixture seed (T-9001)" )
apply_test_manifests
receipt "test manifests applied (gitrepository-test rendered; artifact-ingress sed'd to $NS)"
( cd "$WT" && git push -q "$REPO_GIT" main )
ART_URL=""
for _ in $(seq 1 $(( CHAIN_WAIT / 5 ))); do
  ART_URL=$(kubectl -n "$NS" get externalartifact chudmax-tickets -o jsonpath='{.status.artifact.url}' 2>/dev/null || true)
  [ -n "$ART_URL" ] && break
  sleep 5
done
[ -n "$ART_URL" ] || fail "no ExternalArtifact after the seed push"
receipt "externalartifact URL: $ART_URL"
# The fetcher's readiness probe gates the pod (and the Service) until the
# artifact lands — the ready-gated Service path phase 6 pointed here.
for _ in $(seq 1 60); do
  READY=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=mcp -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="fetcher")].ready}' 2>/dev/null || true)
  [ "$READY" = "true" ] && break
  sleep 2
done
[ "$READY" = "true" ] || fail "the mcp pod's fetcher never went Ready (the artifact chain stalled)"
kubectl -n "$NS" get endpoints chudmax-mcp -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q . \
  || fail "the mcp Service has no endpoints"
receipt "mcp pod Ready, chudmax-mcp:8080 serving (the ready-gated Service path proven)"
mcp_list() { # one-shot canonical JSON-RPC tools/call through the Service
  local p="mcpq-$$-$RANDOM"
  kubectl -n "$NS" run "$p" --restart=Never --image="$CURL_IMAGE" -q \
    --overrides '{"spec":{"automountServiceAccountToken":false}}' \
    --command -- sh -c "sleep 2; curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_tickets\",\"arguments\":{}}}' \
    http://chudmax-mcp.$NS.svc:8080/mcp; sleep 1" >/dev/null 2>&1
  sleep 6
  kubectl -n "$NS" logs "$p" 2>/dev/null | grep -v '^$' | head -5 || true
  kubectl -n "$NS" delete pod "$p" --force --grace-period=0 >/dev/null 2>&1 || true
}
TICKET=""
for _ in $(seq 1 12); do
  TICKET=$(mcp_list | grep -o 'T-9001' | head -1 || true)
  [ -n "$TICKET" ] && break
  sleep 5
done
[ -n "$TICKET" ] || fail "list_tickets never answered with the seed ticket T-9001"
receipt "list_tickets serves the seed ticket T-9001 (real data behind the canary)"

# ------------------------------------------------------------------- Flagger
note "installing Flagger $FLAGGER_CHART (meshProvider gatewayapi:v1, the ONE-pod Prometheus, the metricsServer knob)"
helm repo add flagger https://flagger.app >/dev/null 2>&1
helm repo update flagger >/dev/null 2>&1
helm upgrade --install flagger flagger/flagger -n flagger --create-namespace \
  --version "$FLAGGER_CHART" \
  --set meshProvider=gatewayapi:v1 \
  --set prometheus.install=true \
  --set metricsServer="$METRICS_SERVER" >/dev/null
kubectl -n flagger rollout status deploy/flagger --timeout=300s
kubectl -n flagger get svc flagger-prometheus >/dev/null 2>&1 \
  || fail "the tiny Prometheus's Service flagger-prometheus is missing"
receipt "Flagger up; the tiny Prometheus serving at $METRICS_SERVER"

note "installing the loadtester $LOADTESTER_CHART (release loadtester in $NS — the webhook url is http://loadtester.$NS/)"
helm upgrade --install loadtester flagger/loadtester -n "$NS" --create-namespace \
  --version "$LOADTESTER_CHART" >/dev/null
kubectl -n "$NS" rollout status deploy/loadtester --timeout=300s
receipt "loadtester up (in $NS: the suite's short-name curls resolve; no-type webhooks stream in the background)"

# --------------------------------------------------------- fixtures + canary
note "applying the canary fixtures (envsubst via sed — the one-knob provider address)"
sed "s|\${METRICS_SERVER}|${METRICS_SERVER}|g" "$HERE/metric-templates.yaml" | kubectl -n "$NS" apply -f - >/dev/null
sed "s|\${TRAEFIK_URL}|${TRAEFIK_URL}|g" "$HERE/canary.yaml" | kubectl -n "$NS" apply -f - >/dev/null
kubectl -n "$NS" apply -f "$HERE/gateway.yaml" >/dev/null
receipt "metric-templates + canary + gateway applied (METRICS_SERVER=$METRICS_SERVER, TRAEFIK_URL=$TRAEFIK_URL)"
for _ in $(seq 1 60); do
  P=$(kubectl -n "$NS" get deploy chudmax-web-primary -o name 2>/dev/null || true)
  R=$(kubectl -n "$NS" get httproute chudmax-web -o name 2>/dev/null || true)
  C=$(kubectl -n "$NS" get svc chudmax-web-canary -o name 2>/dev/null || true)
  [ -n "$P" ] && [ -n "$R" ] && [ -n "$C" ] && break
  sleep 3
done
[ -n "$P" ] && [ -n "$R" ] && [ -n "$C" ] \
  || fail "Flagger never generated the primary/canary Services + the HTTPRoute"
receipt "Flagger generated: chudmax-web-primary + chudmax-web{-canary,-primary} Services + the HTTPRoute"
# The gateway's Programmed condition is best-effort (the remaining speculation
# — the REAL proof is the round-trip smoke below).
for _ in $(seq 1 30); do
  PROG=$(kubectl -n "$NS" get gateway chudmax-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  [ "$PROG" = "True" ] && break
  sleep 4
done
receipt "gateway chudmax-gateway Programmed=${PROG:-unknown} (status condition; the smoke is the binding proof)"

# the PRE-CANARY GATEWAY SMOKE: a round trip through the Traefik Service with
# the route host, BEFORE any upgrade — proves the gateway actually routes.
note "the pre-canary gateway round-trip smoke"
SMOKE=""
for _ in $(seq 1 24); do
  kubectl -n "$NS" delete pod canary-smoke --force --grace-period=0 >/dev/null 2>&1 || true
  kubectl -n "$NS" run canary-smoke --restart=Never --image="$CURL_IMAGE" -q \
    --overrides '{"spec":{"automountServiceAccountToken":false}}' \
    --command -- sh -c "sleep 2; curl -s -o /dev/null -m 8 -w '%{http_code}' -H 'Host: $ROUTE_HOST' $TRAEFIK_URL/health" >/dev/null 2>&1
  sleep 5
  PH=$(kubectl -n "$NS" get pod canary-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PH" = "Succeeded" ] || continue
  SMOKE=$(kubectl -n "$NS" logs canary-smoke 2>/dev/null | tail -1)
  [ "$SMOKE" = "200" ] && break
done
[ "$SMOKE" = "200" ] || fail "the gateway round-trip smoke never returned 200 (last: ${SMOKE:-none})"
kubectl -n "$NS" delete pod canary-smoke --force --grace-period=0 >/dev/null 2>&1 || true
receipt "gateway round-trip: /health with Host $ROUTE_HOST through the Traefik Service -> 200 (routes BEFORE any upgrade)"

# -------------------------------------------------------- the metric receipts
kubectl -n flagger port-forward svc/flagger-prometheus 19090:9090 >/dev/null 2>&1 &
PROM_PF_PID=$!
sleep 4
promq() { # instant-query the tiny Prometheus; prints the first sample's value
  curl -s http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // empty'
}
# ------------------------------------------------------------ the GOOD upgrade
note "the GOOD upgrade: image -> 0.1.1 (same bytes, retagged); one template change = one Flagger revision"
kubectl -n "$NS" set image deploy/chudmax-web web="$WEB_GOOD"
: > "$LOGS/weight-timeline.log"
GOOD_PHASE=""
GOOD_OK=""
for _ in $(seq 1 45); do
  W=$(kubectl -n "$NS" get httproute chudmax-web -o jsonpath='{range .spec.rules[*]}{range .backendRefs[*]}{.name}={.weight} {end}{end}' 2>/dev/null || true)
  GOOD_PHASE=$(kubectl -n "$NS" get canary chudmax-web -o jsonpath='{.status.phase}' 2>/dev/null || true)
  echo "$(date +%H:%M:%S) phase=$GOOD_PHASE weights: $W" | tee -a "$LOGS/weight-timeline.log"
  if [ "$GOOD_PHASE" = "Succeeded" ]; then GOOD_OK=1; break; fi
  sleep 20
done
[ -n "$GOOD_OK" ] || fail "the good upgrade never promoted in 15m (last phase: ${GOOD_PHASE:-none})"
STEPS=$(grep -oE 'chudmax-web-canary=[0-9]+' "$LOGS/weight-timeline.log" | sort -u | tr '\n' ' ' || true)
receipt "weight timeline steps: $STEPS (10% at a time to 50%)"
PRIMARY_IMG=$(kubectl -n "$NS" get deploy chudmax-web-primary -o jsonpath='{.spec.template.spec.containers[0].image}')
case "$PRIMARY_IMG" in *:0.1.1) ;; *) fail "promotion incomplete: the primary's image is $PRIMARY_IMG" ;; esac
receipt "promotion recorded: the primary's template carries $PRIMARY_IMG"
EV=$(kubectl -n "$NS" get events --field-selector involvedObject.name=chudmax-web --sort-by=.lastTimestamp 2>/dev/null \
  | grep -iE 'Advance canary|Promotion|Copying|pre-rollout' | tail -8 || true)
echo "$EV" | tee -a "$SUMMARY"
FR=$(promq 'sum(rate(vllm:request_success_total{kubernetes_namespace="'"$NS"'"}[5m]))')
[ -n "$FR" ] && awk "BEGIN{exit !($FR > 0)}" \
  || fail "the finish-rate instant-query returned no data (strata counter missing — $FR)"
receipt "metric receipt: vllm:request_success_total rate = $FR/s (>0 — the loadtest's chat turns feed the counter)"
E2E=$(promq 'count(vllm:e2e_request_latency_seconds_bucket{kubernetes_namespace="'"$NS"'"})')
[ -n "$E2E" ] && [ "$E2E" -gt 0 ] 2>/dev/null \
  || fail "the e2e histogram instant-query returned no series ($E2E)"
receipt "metric receipt: vllm:e2e_request_latency_seconds_bucket series present ($E2E)"
TSVC=$(curl -s http://127.0.0.1:19090/api/v1/query --data-urlencode 'query={__name__="traefik_service_requests_total"}' \
  | jq -r '[.data.result[].metric.service] | unique | .[]' 2>/dev/null | grep -E 'canary|primary' | tr '\n' ' ' || true)
if [ -n "$TSVC" ]; then
  receipt "metric receipt: Traefik's per-service metrics see: $TSVC (the clean-split labels)"
else
  note "traefik_service_* receipt leg empty (the bonus scrape; non-load-bearing)"
fi

# -------------------------------------------------------- the BROKEN upgrade
note "the BROKEN upgrade: ONE combined JSON patch (image 0.1.1-broken + the dead-URL hub config) = one Flagger revision"
ARGS_JSON=$(kubectl -n "$NS" get deploy chudmax-web -o jsonpath='{.spec.template.spec.containers[0].args}')
PATCH_IDX=$(printf '%s\n' "$ARGS_JSON" | jq -r 'to_entries[] | select(.value == "--mcp-config") | .key + 1' 2>/dev/null | head -1 || true)
[ -n "$PATCH_IDX" ] || fail "could not derive the --mcp-config args index from the rendered template"
cat > "$LOGS/broken-patch.json" <<EOF
[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"$WEB_BROKEN"},
  {"op":"replace","path":"/spec/template/spec/containers/0/args/$PATCH_IDX","value":"/etc/strata/mcp-config-broken.json"},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"mcp-config-broken","mountPath":"/etc/strata/mcp-config-broken.json","subPath":"config.json","readOnly":true}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"mcp-config-broken","configMap":{"name":"chudmax-web-mcp-config-broken"}}}
]
EOF
kubectl -n "$NS" patch deploy chudmax-web --type=json -p "$(cat "$LOGS/broken-patch.json")" >/dev/null
receipt "combined patch applied (image + arg index $PATCH_IDX + volume + mount — ONE template change, ONE revision)"
BROKEN_PHASE=""
BROKEN_OK=""
MAX_CANARY_WEIGHT=0
for _ in $(seq 1 45); do
  W=$(kubectl -n "$NS" get httproute chudmax-web -o jsonpath='{range .spec.rules[*]}{range .backendRefs[*]}{.name}={.weight} {end}{end}' 2>/dev/null || true)
  CW=$(printf '%s' "$W" | grep -oE 'chudmax-web-canary=[0-9]+' | grep -oE '[0-9]+' || echo 0)
  [ "$CW" -gt "$MAX_CANARY_WEIGHT" ] && MAX_CANARY_WEIGHT=$CW
  BROKEN_PHASE=$(kubectl -n "$NS" get canary chudmax-web -o jsonpath='{.status.phase}' 2>/dev/null || true)
  echo "$(date +%H:%M:%S) phase=$BROKEN_PHASE weights: $W" | tee -a "$LOGS/weight-timeline.log"
  if [ "$BROKEN_PHASE" = "Failed" ]; then BROKEN_OK=1; break; fi
  # Keep user chat traffic ticking through the Gateway (100% on primary) while
  # the broken canary fails pre-rollout, so the post-rollback metric receipt
  # proves primary stayed healthy throughout.
  kubectl -n "$NS" exec deploy/loadtester -- curl -fsS -m 5 -X POST \
    -H 'Content-Type: application/json' -H "Host: $ROUTE_HOST" \
    -d '{"messages":[{"role":"user","content":"hi"}]}' \
    "$TRAEFIK_URL/v1/chat/completions" >/dev/null 2>&1 || true
  sleep 20
done
[ -n "$BROKEN_OK" ] || fail "the broken upgrade never halted in 15m (last phase: ${BROKEN_PHASE:-none})"
[ "$MAX_CANARY_WEIGHT" = "0" ] \
  || fail "the broken canary's weight left the primary (max sampled canary weight: $MAX_CANARY_WEIGHT)"
receipt "rollback recorded: phase Failed, the canary weight NEVER left 0 (max sampled: $MAX_CANARY_WEIGHT)"
BEV=$(kubectl -n "$NS" get events --field-selector involvedObject.name=chudmax-web --sort-by=.lastTimestamp 2>/dev/null \
  | grep -iE 'Halt|Canary failed|pre-rollout|rollback' | tail -8 || true)
echo "$BEV" | tee -a "$SUMMARY"
TIMG=$(kubectl -n "$NS" get deploy chudmax-web -o jsonpath='{.spec.template.spec.containers[0].image}')
case "$TIMG" in *:0.1.0) ;; *) note "post-rollback target image: $TIMG (Flagger restores the primary's template)" ;; esac
CREPS=$(kubectl -n "$NS" get deploy chudmax-web -o jsonpath='{.spec.replicas}')
receipt "post-rollback: the target's template image ${TIMG}; the canary Deployment scaled to ${CREPS:-?}"
BMETRIC=$(promq 'sum(rate(vllm:request_success_total{kubernetes_namespace="'"$NS"'"}[5m]))')
if [ -n "$BMETRIC" ] && awk "BEGIN{exit !($BMETRIC > 0)}"; then
  receipt "consistency receipt: the metrics stayed HEALTHY through the broken upgrade (rate $BMETRIC/s) — the webhook was the only tripwire"
fi

receipt "the phase-7 rehearsal complete: one promotion, one webhook-caught rollback, both recorded"
