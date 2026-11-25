#!/usr/bin/env bash
# The phase-6 umbrella rehearsal on kind (docker provider). One script, no
# registry, the box untouched. It proves, with the chart DEFAULTS on stock kind:
#
#   1. /health through the ENGINE Service: pod → selectorless Service →
#      EndpointSlice → EXTERNAL host — the exact production topology. The
#      external host is the mock engine: the same Strata image (--engine mock)
#      run OUTSIDE kind on the docker bridge (a ladder of candidate routes;
#      if pods cannot reach the bridge, the mock relaunches on the runner host
#      and the receipt records the route that won). HONEST FRAMING: this proves
#      the Service→EndpointSlice→external-host path, not the real engine — the
#      real address arrives with phase 11's private deployment values.
#   2. the WEB pod (Strata --engine mock) answering /health through its Service;
#      the curl's Host header is the Service name, so Strata's DNS-rebinding
#      guard and the allowedHosts auto default are proven too.
#   3. the MCP pod: Running; the published canonical server answering HTTP 200
#      (initialize) over its Service with the honest no-data body; the fetcher
#      WAITING — asserted from its LOGS (the apiserver 404 NotFound line), not
#      pod status: with kindnet enforcing NetworkPolicy (kind ≥ v0.24) a blocked
#      fetcher and a waiting one look identical. 404 = reached; 403 = RBAC;
#      neither = blocked in flight. If the defaults' apiserver rule blocks on
#      kind (post-DNAT port mismatch), the script re-renders with the cidr mode
#      + a 6443 passthrough entry (endpoint IPs discovered live — the phase-5
#      adopted approach) and re-asserts; both rungs are recorded.
#   4. phase 5's auto gate: NO Cilium CRDs rendered/installed on stock kind.
#
# NOT proven here: the commit→tickets data path (phase 5's rehearsal owns it).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHART="$HERE"
STRATA_REPO="${STRATA_REPO:-https://github.com/kingdonb/Strata}"
STRATA_PIN="${STRATA_PIN:-de34ebaa521d8f628b4bb1884e5c34101730299a}"
CLUSTER="${CLUSTER:-chudmax-phase6}"
NS=chudmax
WEB_IMAGE="ghcr.io/urmanac/chudmax/web:0.1.0"
FETCHER_IMAGE="ghcr.io/urmanac/chudmax/fetcher:0.1.0"
SERVER_IMAGE="ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0"
CURL_IMAGE="curlimages/curl:8.12.1"
WORK="$(mktemp -d)"
ENGINE_HOST=""

say() { printf '\n=== %s ===\n' "$*"; }
die() { echo "FAIL: $*" >&2; echo "::error::FAIL: $*" >&2; exit 1; }

cleanup() {
  say "teardown"
  docker rm -f chudmax-mock-engine >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "0. tools (kind $(kind version | cut -d' ' -f2), helm $(helm version --short), podman $(podman --version | cut -d' ' -f3))"
docker ps >/dev/null || die "the docker daemon is not running (kind runs on the docker provider)"

say "1. kind up: $CLUSTER (docker provider, stock kindnet - NetworkPolicies ARE enforced)"
kind create cluster --name "$CLUSTER" --wait 240s >/dev/null
kubectl config current-context | grep -q "kind-$CLUSTER" || die "the kind context is not current"
kubectl create namespace "$NS" >/dev/null 2>&1 || true   # the step-5 probes target it before helm creates it

say "2. Strata at the pin ($STRATA_PIN)"
git init -q "$WORK/strata"
git -C "$WORK/strata" fetch -q --depth 1 "$STRATA_REPO" "$STRATA_PIN"
git -C "$WORK/strata" checkout -q FETCH_HEAD
echo "  checked out: $(git -C "$WORK/strata" rev-parse HEAD)"

say "3. images: podman build → podman save → kind load image-archive (no registry)"
# A retry for the registry transient this repo's CI has hit before (the phase-3
# precedent): parallel jobs pull base images from the same shared anonymous
# buckets, and a pull can fail transiently (podman exits 125).
pbuild() {
  local tag="$1" file="$2" ctx="$3" attempt
  for attempt in 1 2 3; do
    if podman build -q -t "$tag" -f "$file" "$ctx"; then return 0; fi
    echo "  build of $tag failed (attempt $attempt) - retrying after a pause"
    sleep $((attempt * 20))
  done
  die "the build of $tag failed three times (see the podman output above)"
}
pbuild "$WEB_IMAGE" "$HERE/web-image/Dockerfile" "$WORK/strata"
pbuild "$FETCHER_IMAGE" "$REPO/k8s/image/Dockerfile" "$REPO/k8s"
pbuild "$SERVER_IMAGE" "$REPO/k8s/tickets-mcp/Dockerfile" "$REPO/k8s/tickets-mcp"
for img in "$WEB_IMAGE" "$FETCHER_IMAGE" "$SERVER_IMAGE" "$CURL_IMAGE"; do
  if [ "$img" = "$CURL_IMAGE" ]; then podman pull -q "$img" >/dev/null; fi
  tar="$WORK/$(printf '%s' "$img" | tr '/:' '__').tar"
  podman save --format docker-archive -o "$tar" "$img"
  docker load -i "$tar" >/dev/null
  kind load image-archive "$tar" --name "$CLUSTER"
  echo "  loaded: $img (host docker + kind node)"
done

say "4. the mock engine OUTSIDE kind, on the docker bridge"
ENGINE_DNS="chudmax-engine.$NS.svc"
docker run -d --name chudmax-mock-engine --network kind -p 8080:8080 \
  -e STRATA_ALLOWED_HOSTS="chudmax-engine,$ENGINE_DNS,$ENGINE_DNS.cluster.local,localhost,127.0.0.1" \
  "$WEB_IMAGE" --engine mock --host 0.0.0.0 --port 8080 >/dev/null
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:8080/health || true)
  [ "$code" = "200" ] && break
  sleep 1
done
[ "$code" = "200" ] || die "the mock engine never answered /health on the host side"
echo "  mock engine up (host-side /health: $code)"

probe() { # probe <url> — an in-cluster pod; prints the HTTP code and never hides why it missed
  local code
  code=$(kubectl run "probe-$(printf '%s' "$1" | md5sum | cut -c1-8)" --rm -i --restart=Never \
    --image="$CURL_IMAGE" -n "$NS" --quiet -- \
    curl -s -o /dev/null -m 5 -w '%{http_code}' "$1") || true
  [ "$code" = "200" ] || echo "  probe miss: $1 → ${code:-no-answer}"
  printf '%s' "$code"
}

say "5. the engine endpoint: a ladder of candidates, the first route pods can reach wins"
# docker network inspect may list the IPv6 IPAM block first — grep for an
# IPv4-shaped gateway specifically (CI hit fc00::/16 once). If no IPv4 gateway
# parses, die loudly — no private-LAN fallback literal is allowed in this file
# (the workflow's RFC1918 hygiene grep is the tripwire).
GW="$(docker network inspect kind | grep -o '"Gateway": *"[0-9.]*"' | head -1 | cut -d'"' -f4)"
[ -n "$GW" ] || die "no IPv4 gateway parsed from docker network inspect kind ($(docker network inspect kind | grep -c Gateway) Gateway entries)"
CIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' chudmax-mock-engine)"
echo "  bridge gateway: $GW   mock-engine bridge IP: $CIP"
ENGINE_HOST=""
EN_ROUTE=""
try_endpoint() { # try_endpoint <ip>: probe from a pod; on 200 pin ENGINE_HOST and return 0
  if [ "$(probe "http://$1:8080/health")" = "200" ]; then
    ENGINE_HOST="$1"; return 0
  fi
  return 1
}
if try_endpoint "$GW"; then
  EN_ROUTE="docker-bridge gateway (pod → gateway-ip → host-side userland-proxy → the mock)"
elif try_endpoint "$CIP"; then
  EN_ROUTE="mock container bridge IP (the gateway route was unreachable; recorded honestly)"
else
  echo "  neither the gateway nor the bridge IP is reachable from pods - relaunching the mock on the runner host"
  docker rm -f chudmax-mock-engine >/dev/null 2>&1 || true
  docker run -d --name chudmax-mock-engine --network host \
    -e STRATA_ALLOWED_HOSTS="chudmax-engine,$ENGINE_DNS,$ENGINE_DNS.cluster.local,localhost,127.0.0.1" \
    "$WEB_IMAGE" --engine mock --host 0.0.0.0 --port 8080 >/dev/null
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:8080/health || true)
    [ "$code" = "200" ] && break
    sleep 1
  done
  [ "$code" = "200" ] || die "the host-network mock never answered /health on the runner host"
  try_endpoint "$GW" || die "the mock engine is unreachable from pods at $GW, at $CIP, and host-networked at $GW"
  EN_ROUTE="docker-bridge gateway → host-network mock (bridge L2 was blocked from pods; recorded honestly)"
fi
echo "  route won: $EN_ROUTE"

say "6. helm install (chart defaults + the engine endpoint)"
rm -rf "$CHART/charts"
helm dependency build "$CHART" >/dev/null
helm template "$CLUSTER-defaults" "$CHART" > "$WORK/rendered.yaml"
if grep -qi cilium "$WORK/rendered.yaml"; then die "Cilium CRDs rendered with the chart defaults on stock kind (phase 5's auto gate broken?)"; fi
echo "  no Cilium CRDs in the defaults render ✓"
helm upgrade --install chudmax "$CHART" -n "$NS" --create-namespace \
  --set engine.endpoint.host="$ENGINE_HOST" >/dev/null

say "7. wait for the pods"
kubectl rollout status deploy/chudmax-web -n "$NS" --timeout=300s
for i in $(seq 1 60); do
  phase=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=chudmax-mcp -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [ "$phase" = "Running" ] && break
  sleep 2
done
[ "$phase" = "Running" ] || die "the mcp pod never reached Running"
echo "  web: Ready;  mcp: Running (the fetcher not-ready is EXPECTED pre-artifact)"

say "8. helm test (the engine hook through the Service + the web hook)"
helm test chudmax -n "$NS"

say "9. mcp receipts (HTTP over the Service, from a pod in the release namespace)"
INIT=$(kubectl run mcp-init --rm -i --restart=Never --image="$CURL_IMAGE" -n "$NS" --quiet -- \
  curl -s -m 10 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  http://chudmax-mcp:8080/mcp)
echo "$INIT" | grep -q '"chudmax-tickets"' || die "initialize did not answer chudmax-tickets: $INIT"
echo "  initialize → 200, serverInfo: $(echo "$INIT" | grep -o '"serverInfo":{[^}]*}')"
LIST=$(kubectl run mcp-list --rm -i --restart=Never --image="$CURL_IMAGE" -n "$NS" --quiet -- \
  curl -s -m 10 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_tickets","arguments":{}}}' \
  http://chudmax-mcp:8080/mcp)
echo "  list_tickets (the honest no-data body): $LIST"

say "10. the fetcher-log assertion: an apiserver round-trip, not a policy block"
fetcher_404() {
  kubectl logs deploy/chudmax-mcp -n "$NS" -c fetcher 2>/dev/null | grep -F "does not exist yet, waiting" | head -1
}
if LOG=$(fetcher_404); then
  echo "  apiserver 404 in the fetcher's logs (defaults' policy admits it): $LOG"
  RUNG="defaults"
else
  echo "  the defaults' apiserver rule blocks on kindnet - applying the adopted phase-5 route:"
  EP="$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}')"
  echo "  discovered control-plane endpoint: $EP (cidr mode + a 6443 passthrough entry)"
  helm upgrade chudmax "$CHART" -n "$NS" \
    --set engine.endpoint.host="$ENGINE_HOST" \
    --set mcp.networkPolicy.egress.apiServer.mode=cidr \
    --set mcp.networkPolicy.egress.apiServer.cidr="$EP/32" \
    --set mcp.networkPolicy.egress.extra[0].to[0].ipBlock.cidr="$EP/32" \
    --set mcp.networkPolicy.egress.extra[0].ports[0].protocol=TCP \
    --set mcp.networkPolicy.egress.extra[0].ports[0].port=6443 >/dev/null
  sleep 5
  LOG=$(fetcher_404) || die "the fetcher still shows no apiserver 404 even under the cidr+6443 override"
  echo "  apiserver 404 in the fetcher's logs (the override admits it): $LOG"
  RUNG="cidr+6443 override (the pre-phase-5 chart's 443-only rule blocked on kindnet)"
fi

say "11. the stock-kind auto-gate check (installed state)"
kubectl get crd 2>/dev/null | grep -qi cilium && die "Cilium CRDs exist on a stock kind cluster"
echo "  no Cilium CRDs installed ✓ (the CNP render path never engaged)"

say "RECEIPT"
echo "  kind: $(kind version | cut -d' ' -f2) (docker provider)   helm: $(helm version --short)"
echo "  images loaded: $WEB_IMAGE $FETCHER_IMAGE $SERVER_IMAGE (amd64; no registry)"
echo "  engine endpoint: $ENGINE_HOST:8080 (route: $EN_ROUTE)"
echo "  policy rung: $RUNG"
echo "  hooks: engine /health via the Service = PASS; web /health via the Service = PASS"
echo "  HONEST FRAMING: this proves the Service→EndpointSlice→external-host path against a mock engine"
echo "  (the same Strata image, --engine mock, outside kind on the docker bridge) - NOT the real engine;"
echo "  the real address arrives with phase 11's private deployment values and reruns the same hook."
echo "  NOT proven here: the commit→tickets data path (phase 5's rehearsal)."
