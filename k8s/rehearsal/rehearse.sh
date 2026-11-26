#!/usr/bin/env bash
# The phase-5 rehearsal orchestrator (T-0037): a throwaway kind cluster, Cilium
# (with --policy-cidr-match-mode=nodes), Flux + source-watcher, the REAL chart
# (default values — the published canonical ticket server), the repo-sync test
# manifests, and the card's two proofs:
#   1. commit → list_tickets with nobody doing anything — four commits: #1 the
#      hands-off delivery (after the fetcher's fresh-install wait), #2 the
#      no-restart per-call contract (continuous polling, no stale answer, the
#      server's startedAt/restartCount unchanged), #3 retention (the server
#      still answers after the prune), #4 the delivery AFTER the cidr-mode
#      upgrade (Fable: an established stream proves nothing — the fresh
#      connections are the evidence);
#   2. the denials: a rogue pod cannot learn (RBAC 403) nor fetch
#      (NetworkPolicy) the artifact, with positive controls proving the fences
#      bite (the fetcher's fetch, a labeled Role-less pod's fetch, the
#      port-scope probe).
# CI is the authoritative run. Locally, the podman kind provider is
# best-effort (rootless kind needs extra setup per the kind docs).
# Receipts land in $REHEARSAL_SUMMARY (the CI step summary) and, on failure,
# $REHEARSAL_LOGS (uploaded as a CI artifact).
set -euo pipefail

NS=chudmax-rehearsal
REL=rehearsal
CLUSTER=phase5-rehearsal
GIT_PORT=38080
GIT_ROOT=${REHEARSAL_GIT_ROOT:-/tmp/rehearsal-git}
LOGS=${REHEARSAL_LOGS:-/tmp/rehearsal-logs}
SUMMARY=${REHEARSAL_SUMMARY:-/tmp/rehearsal-summary.txt}
PROVIDER=${KIND_EXPERIMENTAL_PROVIDER:-docker}
BUILDER=${REHEARSAL_BUILDER:-$PROVIDER}
GIT_SRV_PID=
CHAIN_WAIT=${REHEARSAL_CHAIN_WAIT:-240}   # seconds a commit may take to show up
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$LOGS"
: > "$SUMMARY"
# Every line the script emits (stdout+stderr) lands in the logs artifact too —
# GitHub job logs are sign-in-gated; the artifact is the diagnostic channel.
exec > >(tee -a "$LOGS/script-output.log") 2>&1

note() { echo "[rehearsal] $*" | tee -a "$SUMMARY" >&2; }
receipt() { echo "RECEIPT: $*" | tee -a "$SUMMARY"; }
fail() { echo "FAIL: $*" | tee -a "$SUMMARY" >&2; exit 1; }

# CI-only diagnostics: GitHub job logs and step summaries are sign-in-gated,
# but check-run ANNOTATIONS are readable via the public API — so the failure
# path re-emits each log tail as a ::error annotation (a credential-less agent
# can then diagnose the run without artifact-download access).
annotate() { # $1 annotation title, $2 log file
  local msg
  [ -s "$2" ] || return 0
  msg=$(tail -c 900 "$2" | sed -e 's/%/%25/g' -e 's/\r//g' -e 's/]/%5D/g' -e 's/;/%3B/g' \
    | awk '{printf "%s%%0A", $0}')
  printf '::error title=%s::%s\n' "$1" "$msg"
}
annotate_failure() {
  [ "${CI:-}" = "true" ] || return 0
  annotate rehearsal-output "$LOGS/script-output.log"
  annotate gitserver "$LOGS/gitserver.log"
  annotate pods-all "$LOGS/pods-all.txt"
  annotate events "$LOGS/events.txt"
  annotate chudmax-pod "$LOGS/pod.log"
  annotate source-controller "$LOGS/source-controller.log"
  annotate source-watcher "$LOGS/source-watcher.log"
  sleep 1   # let the tee drain before the shell exits
}

cleanup() {
  rc=$?
  if [ -n "${GIT_SRV_PID:-}" ]; then kill "$GIT_SRV_PID" 2>/dev/null || true; fi
  cp -f "$SUMMARY" "$LOGS/rehearsal-summary.txt" 2>/dev/null || true
  if [ "${rc}" -ne 0 ]; then
    note "failure path: exporting cluster logs to $LOGS"
    kind export logs --name "$CLUSTER" "$LOGS" 2>/dev/null || true
    kubectl get pods -A -o wide > "$LOGS/pods-all.txt" 2>/dev/null || true
    kubectl -n "$NS" get events --sort-by=.lastTimestamp > "$LOGS/events.txt" 2>/dev/null || true
    kubectl -n "$NS" logs -l app.kubernetes.io/instance=$REL --all-containers > "$LOGS/pod.log" 2>/dev/null || true
    kubectl -n "$NS" logs alert-sink > "$LOGS/alert-sink.log" 2>/dev/null || true
    kubectl -n flux-system logs deploy/source-controller > "$LOGS/source-controller.log" 2>/dev/null || true
    kubectl -n flux-system logs deploy/source-watcher > "$LOGS/source-watcher.log" 2>/dev/null || true
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
"$BUILDER" version >/dev/null 2>&1 || fail "builder '$BUILDER' not found"
export KIND_EXPERIMENTAL_PROVIDER="$PROVIDER"

note "pre-flight: building and starting the Smart-HTTP test server"
( cd "$HERE/gittestserver" && go build -o "$LOGS/gittestserver" . )
rm -rf "$GIT_ROOT"; mkdir -p "$GIT_ROOT"
REPO_GIT=$GIT_ROOT/repo.git
WT=$GIT_ROOT/worktree
git init -q --bare -b main "$REPO_GIT"
"$LOGS/gittestserver" -root "$GIT_ROOT" -addr "0.0.0.0:$GIT_PORT" > "$LOGS/gitserver.log" 2>&1 &
GIT_SRV_PID=$!
sleep 1
# The runner-side receipt: the CRD-valid http:// URL must answer BEFORE the
# GitRepository is applied (the CRD pattern rejects git:// at the API server).
git ls-remote "http://127.0.0.1:$GIT_PORT/repo.git" >/dev/null \
  || fail "pre-flight git ls-remote failed — the Smart-HTTP server is not serving"
receipt "pre-flight git ls-remote OK over http://127.0.0.1:$GIT_PORT/repo.git"

# ------------------------------------------------------------ cluster + stack
note "creating the throwaway kind cluster ($PROVIDER provider, default CNI disabled)"
# disableDefaultCNI (in the config) means the node stays NotReady until Cilium
# is installed — a nonzero --wait would time out and fail the create. Wait for
# the apiserver itself instead (kind writes the kubeconfig before returning).
kind create cluster --name "$CLUSTER" --config "$HERE/kind-config.yaml" --wait 0s
for _ in $(seq 1 60); do
  kubectl get --raw=/readyz >/dev/null 2>&1 && break
  sleep 2
done
kubectl get --raw=/readyz >/dev/null 2>&1 || fail "apiserver not ready 120s after kind create"
# The kind network may be dual-stack with IPv6 FIRST in IPAM.Config (observed
# on the docker-29 GitHub runners: gateway fc00:…::1) — the test-repo URL must
# use the IPv4 gateway: an unbracketed v6 address is not a valid http URL for
# git, and the pod path to the runner is the node's IPv4 route anyway.
GW=$("$BUILDER" network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Gateway != null) | select(.Gateway | test("^[0-9]+[.]")) | .Gateway' | head -n1)
[ -n "$GW" ] || fail "no IPv4 gateway on the kind network (gateways seen: $("$BUILDER" network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}'))"
GIT_URL="http://${GW}:${GIT_PORT}/repo.git"
receipt "runner gateway: $GW — the test repo URL the cluster will fetch: $GIT_URL"

note "installing Cilium v1.18.1 (the official kind recipe: ipam kubernetes; policy-cidr-match-mode=nodes)"
cilium install --version v1.18.1 --set ipam.mode=kubernetes --set policyCIDRMatchMode=nodes --wait --wait-duration 8m
cilium status --wait --wait-duration 3m >/dev/null
receipt "cilium ready (nodes match mode on)"

note "installing Flux (source-watcher extra, shipped policies on)"
# NOTE: flux install has no --wait flag — waiting for the controllers is its
# default behavior (--timeout 5m); a --wait here dies with "unknown flag".
flux install --components-extra=source-watcher --namespace=flux-system
kubectl -n flux-system get pods -o name | tee -a "$SUMMARY"
receipt "flux installed with source-watcher"

note "building the REAL images (fetcher + the published canonical server) and loading them"
"$BUILDER" build -q -t rehearsal/fetcher:ci -f k8s/image/Dockerfile k8s > "$LOGS/build-fetcher.log"
"$BUILDER" build -q -t rehearsal/tickets-mcp:ci -f k8s/tickets-mcp/Dockerfile k8s/tickets-mcp > "$LOGS/build-server.log"
"$BUILDER" save -o "$LOGS/fetcher.tar" rehearsal/fetcher:ci
"$BUILDER" save -o "$LOGS/server.tar" rehearsal/tickets-mcp:ci
kind load image-archive --name "$CLUSTER" "$LOGS/fetcher.tar"
kind load image-archive --name "$CLUSTER" "$LOGS/server.tar"
receipt "both images built and loaded via archive (no registry)"

note "installing the chart with default values (auto mode resolves to the CNP on this Cilium cluster)"
helm install "$REL" k8s/chart/chudmax-mcp -n "$NS" --create-namespace \
  --set image.repository=rehearsal/fetcher --set image.tag=ci \
  --set server.image.repository=rehearsal/tickets-mcp --set server.image.tag=ci
kubectl -n "$NS" apply -f "$HERE/alert-sink.yaml"
kubectl -n "$NS" create secret generic chudmax-notifications-credentials \
  --from-literal=address=http://alert-sink.$NS.svc:80/ >/dev/null
kubectl -n "$NS" create secret generic webhook-token --from-literal=token=rehearsal-dummy >/dev/null
sleep 12   # the fetcher waits (no ExternalArtifact yet); the server container goes ready
POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance=$REL -o jsonpath='{.items[0].metadata.name}')
PHASE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')
FETCH_READY=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="fetcher")].ready}')
SERVER_READY=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="server")].ready}')
RESTARTS=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[*].restartCount}')
[ "$PHASE" = "Running" ] || fail "fresh install: pod phase $PHASE (want Running)"
[ "$FETCH_READY" = "false" ] || fail "fresh install: fetcher ready=$FETCH_READY (want false — it WAITS)"
[ "$SERVER_READY" = "true" ] || fail "fresh install: server ready=$SERVER_READY (its probe should answer pre-data)"
[ "$RESTARTS" = "0 0" ] || fail "fresh install: restarts '$RESTARTS' (want '0 0' — waiting, not crash-looping)"
CNP=$(kubectl -n "$NS" get cnp -o name 2>/dev/null || true)
[ -n "$CNP" ] || fail "auto mode: no CiliumNetworkPolicy on this Cilium cluster (auto did not resolve)"
receipt "fresh install: fetcher waits (Running, not-ready, 0 restarts); server READY via its probe; CNP: $CNP"

started_at() { kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="server")].state.running.startedAt}'; }
restarts_now() { kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[*].restartCount}'; }
STARTED0=$(started_at)

# --------------------------------------------------------------- MCP plumbing
mcp_call() { # $1 = tool, $2 = arguments json (default {})
  local args="${2:-{\}}" name
  name="mcp-$$-$RANDOM"
  kubectl -n "$NS" run "$name" --restart=Never --image=curlimages/curl:8.14.1 -q \
    --overrides '{"spec":{"automountServiceAccountToken":false}}' \
    --command -- sh -c "sleep 3; curl -sS -X POST -H 'Content-Type: application/json' \
    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$args}}' \
    http://rehearsal-chudmax-mcp.$NS.svc:8080/mcp; sleep 1" >/dev/null 2>&1
  sleep 7
  kubectl -n "$NS" logs "$name" 2>/dev/null | grep -v '^$' | head -5 || true
}
start_poller() { # continuous list_tickets polling for $1 seconds — runs across the swap
  kubectl -n "$NS" delete pod poller --force --grace-period=0 >/dev/null 2>&1 || true
  kubectl -n "$NS" run poller --restart=Never --image=curlimages/curl:8.14.1 -q \
    --overrides '{"spec":{"automountServiceAccountToken":false}}' \
    --command -- sh -c "sleep 3; i=0; while [ \$i -lt $(( $1 / 2 )) ]; do \
      echo \"POLL \$i: \$(curl -sS --max-time 4 -X POST -H 'Content-Type: application/json' \
      -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_tickets\",\"arguments\":{}}}' \
      http://rehearsal-chudmax-mcp.$NS.svc:8080/mcp | head -c 600)\"; sleep 2; i=\$((i+1)); done" >/dev/null
}
wait_for_ticket() { # $1 = ticket id; polls the POLLER'S LOG only (nobody touches Flux or the pod)
  for _ in $(seq 1 $(( CHAIN_WAIT / 5 ))); do
    if kubectl -n "$NS" logs poller 2>/dev/null | grep -q "$1"; then return 0; fi
    sleep 5
  done
  return 1
}
capture_facts() { # $1 = label, $2 = the pushed SHA, $3 = the previous revision line
  local facts rev label="$1" sha="$2" prev="${3:-}"
  facts=$(mcp_call repo_facts)
  echo "=== after $label ===" >> "$LOGS/repo_facts.log"
  echo "$facts" >> "$LOGS/repo_facts.log"
  if ! grep -q 'origin revision:' <<<"$facts" \
     || ! grep 'origin revision:' <<<"$facts" | grep -q "$sha"; then
    fail "repo_facts after $label: origin_revision does not contain the pushed SHA $sha — got: $(grep 'origin revision:' <<<"$facts" || echo ABSENT)"
  fi
  rev=$(grep -o 'latest@sha256:[0-9a-f]*' <<<"$facts" | head -1) || true
  [ -n "$rev" ] || fail "repo_facts after $label: no content-hash revision — got: $facts"
  if [ -n "$prev" ] && [ "$rev" = "$prev" ]; then
    fail "repo_facts after $label: the content-hash revision did not change ($rev)"
  fi
  receipt "repo_facts after $label: revision $rev; origin_revision contains the pushed SHA $sha"
  echo "$rev"
}

apply_test_manifests() {
  sed "s|__RUNNER_HTTP__|${GW}:${GIT_PORT}|" "$HERE/gitrepository-test.yaml" | kubectl -n "$NS" apply -f -
  kubectl -n "$NS" apply -f "$HERE/../repo-sync/artifactgenerator.yaml"
  # The policy MUST land in flux-system: a NetworkPolicy only selects pods in
  # its OWN namespace, so applying it to the release namespace selects nothing
  # and source-watcher stays behind Flux's shipped default-deny (the fetch
  # then times out — the phase-5 rehearsal's run-#5 receipt). Only the
  # from-selector (the release namespace) is rewritten by the sed.
  sed 's|chudmax-releases|'"$NS"'|' "$HERE/../repo-sync/artifact-ingress.yaml" | kubectl -n flux-system apply -f -
  kubectl -n "$NS" apply -f "$HERE/../repo-sync/receiver.yaml"
  kubectl -n "$NS" apply -f "$HERE/../repo-sync/alerts.yaml"
  receipt "test manifests applied (gitrepository-test rendered; the :9090 ingress allowance sed'd to $NS; receiver inert; alerts to the sink)"
}

wait_artifact_url() {
  for _ in $(seq 1 30); do
    URL=$(kubectl -n "$NS" get externalartifact chudmax-tickets -o jsonpath='{.status.artifact.url}' 2>/dev/null || true)
    [ -n "$URL" ] && { echo "$URL"; return 0; }
    sleep 5
  done
  return 1
}
current_digest() { kubectl -n "$NS" exec "$POD" -c fetcher -- cat /data/current/artifact.json 2>/dev/null \
  | grep -o '"digest": *"[^"]*"' | head -1; }
revisions_dirs() { kubectl -n "$NS" exec "$POD" -c fetcher -- ls /data/revisions 2>/dev/null; }

# ------------------------------------------------- commit #1: the hands-off delivery
note "commit #1: seeding the test repo with the fixture tree"
rm -rf "$WT"; git init -q -b main "$WT"
cp "$HERE"/fixture/tickets.md "$HERE"/fixture/STATE.md "$WT/"
cp -r "$HERE"/fixture/docs "$HERE"/fixture/decisions "$WT/"
( cd "$WT" && git add -A && git -c user.email=rehearsal@test -c user.name=rehearsal commit -qm "fixture seed (T-9001)" )
SHA1=$(cd "$WT" && git rev-parse HEAD)
apply_test_manifests
start_poller "$CHAIN_WAIT"
sleep 6   # the poller is up and answering honestly pre-data
( cd "$WT" && git push -q "$REPO_GIT" main )
ART_URL=$(wait_artifact_url) || fail "no ExternalArtifact appeared after commit #1"
receipt "externalartifact URL: $ART_URL"
wait_for_ticket T-9001 || fail "commit #1: T-9001 never appeared in list_tickets (hands-off budget ${CHAIN_WAIT}s)"
receipt "commit #1 delivered hands-off: list_tickets shows T-9001"
FACTS_REV=$(capture_facts "#1" "$SHA1" "")
DIGEST1=$(current_digest)

# --------------------------- commit #2: the per-call contract under real API load
note "commit #2: the no-restart proof (continuous polling across the swap)"
start_poller "$CHAIN_WAIT"
sleep 6
( cd "$WT" && cat >> tickets.md <<'EOF'

## T-9002 - Example: the second revision, served without a restart

**Status:** in-progress
**Owner:** rehearsal-fixture
**Priority:** next

**Purpose:**
The per-call contract's cluster-scale proof: the published server rereads
/data/current on every call, so this ticket appears with nobody doing
anything and the server container's startedAt/restartCount unchanged.

---
EOF
  git add -A && git -c user.email=rehearsal@test -c user.name=rehearsal commit -qm "T-9002" && git push -q "$REPO_GIT" main )
SHA2=$(cd "$WT" && git rev-parse HEAD)
wait_for_ticket T-9002 || fail "commit #2: T-9002 never appeared"
sleep 2; kubectl -n "$NS" logs poller > "$LOGS/poll2.log" 2>/dev/null || true
FIRST_V2=$(grep -n 'T-9002' "$LOGS/poll2.log" | head -1 | cut -d: -f1)
[ -n "$FIRST_V2" ] || fail "poll log: no v2 answer recorded"
STALE=$(awk -v fv="$FIRST_V2" 'NR > fv && /T-9001/ && !/T-9002/' "$LOGS/poll2.log" | wc -l | tr -d ' ')
[ "$STALE" = "0" ] || fail "stale answers: a v1-only answer AFTER v2 first appeared ($STALE) — the mid-call contract broke"
STARTED1=$(started_at); RC1=$(restarts_now)
[ "$STARTED1" = "$STARTED0" ] || fail "the server container's startedAt changed across the swap (a restart happened)"
[ "$RC1" = "0 0" ] || fail "restartCount changed across the swap: $RC1"
receipt "commit #2 delivered: T-9002 served, no v1-only answer after the swap, server startedAt/restartCount unchanged"
capture_facts "#2" "$SHA2" "$FACTS_REV" >/dev/null

# ------------------- commit #3: the third revision; within keep=3, the server answers
note "commit #3: the third revision (within keep=3); the server keeps answering"
start_poller "$CHAIN_WAIT"
sleep 6
( cd "$WT" && printf '\n## T-9003 - Example: retention kept the newest trees\n\n**Purpose:**\nthe default keep=3 prunes the first revision dir; the reread survives the prune.\n\n---\n' >> tickets.md \
  && git add -A && git -c user.email=rehearsal@test -c user.name=rehearsal commit -qm "T-9003" && git push -q "$REPO_GIT" main )
SHA3=$(cd "$WT" && git rev-parse HEAD)
wait_for_ticket T-9003 || fail "commit #3: T-9003 never appeared"
sleep 2; kubectl -n "$NS" logs poller > "$LOGS/poll3.log" 2>/dev/null || true
DIRS=$(revisions_dirs)
COUNT=$(printf '%s\n' "$DIRS" | grep -c . || true)
[ "$COUNT" -le 3 ] || fail "retention: $COUNT revision dirs (want <= 3)"
tail -3 "$LOGS/poll3.log" | grep -q T-9003 || fail "after the third revision the server stopped answering"
receipt "commit #3 delivered: T-9003 served; $COUNT revision dirs (<= keep=3); the server still answers"
FACTS3_REV=$(capture_facts "#3" "$SHA3" "$FACTS_REV")

# --------------------- the cidr-mode exercise: fresh connections, then commit #4
note "the cidr-mode upgrade: policy-only helm upgrade, fresh API connection, commit #4"
EP=$(kubectl -n default get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}')
[ -n "$EP" ] || fail "could not discover the apiserver endpoint IP"
helm upgrade "$REL" k8s/chart/chudmax-mcp -n "$NS" \
  --set image.repository=rehearsal/fetcher --set image.tag=ci \
  --set server.image.repository=rehearsal/tickets-mcp --set server.image.tag=ci \
  --set networkPolicy.egress.apiServer.mode=cidr \
  --set networkPolicy.egress.apiServer.cidrs[0]="${EP}/32" >/dev/null
sleep 8
STARTED2=$(started_at); RC2=$(restarts_now)
[ "$STARTED2" = "$STARTED0" ] && [ "$RC2" = "0 0" ] \
  || fail "the policy-only upgrade restarted the pod (startedAt $STARTED2, restarts $RC2)"
CNP_AFTER=$(kubectl -n "$NS" get cnp -o name 2>/dev/null || true)
[ -z "$CNP_AFTER" ] || fail "the CNP survived the upgrade to cidr mode: $CNP_AFTER"
# NOTE: kubectl 1.33+ removed `run --serviceaccount` — the SA and the token
# mount go through --overrides (placed BEFORE the -- so kubectl parses them;
# anything after -- is the container's argv, not flags).
kubectl -n "$NS" run apiprobe --restart=Never --image=curlimages/curl:8.14.1 \
  --labels app.kubernetes.io/name=chudmax-mcp -q \
  --overrides '{"spec":{"serviceAccountName":"rehearsal-chudmax-mcp","automountServiceAccountToken":true}}' \
  --command -- sh -c "sleep 3; curl -sS --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H \"Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \
  https://kubernetes.default.svc/apis/source.toolkit.fluxcd.io/v1/namespaces/$NS/externalartifacts/chudmax-tickets; sleep 1" \
  >/dev/null 2>&1
sleep 8
APIPROBE=$(kubectl -n "$NS" logs apiprobe 2>/dev/null || true)
grep -q '"kind": *"ExternalArtifact"' <<<"$APIPROBE" \
  || fail "the fresh API GET under the cidr rule failed — got: ${APIPROBE:0:200}"
kubectl -n "$NS" delete pod apiprobe --force --grace-period=0 >/dev/null 2>&1 || true
receipt "cidr mode: the CNP is gone, the pod untouched, a FRESH apiserver GET succeeds (endpoint ${EP}/32)"
start_poller "$CHAIN_WAIT"
sleep 6
( cd "$WT" && printf '\n## T-9004 - Example: delivered after the policy upgrade\n\n**Purpose:**\nthe whole chain re-proven hands-off under the cidr-mode egress policy.\n\n---\n' >> tickets.md \
  && git add -A && git -c user.email=rehearsal@test -c user.name=rehearsal commit -qm "T-9004" && git push -q "$REPO_GIT" main )
SHA4=$(cd "$WT" && git rev-parse HEAD)
wait_for_ticket T-9004 || fail "commit #4: T-9004 never appeared after the cidr upgrade"
receipt "commit #4 delivered hands-off under the upgraded policy: T-9004 served"
capture_facts "#4" "$SHA4" "$FACTS3_REV" >/dev/null

# retention's real receipt: keep=3 prunes exactly at the FOURTH revision —
# the first revision's dir must be gone and the server must still answer
# (the reread survives the prune).
DIRS4=$(revisions_dirs)
COUNT4=$(printf '%s\n' "$DIRS4" | grep -c . || true)
[ "$COUNT4" -le 3 ] || fail "retention: $COUNT4 revision dirs after the 4th (want <= 3)"
DIGEST1_HEX=$(grep -o '[0-9a-f]\{64\}' <<<"$DIGEST1" | head -1)
if printf '%s\n' "$DIRS4" | grep -q "$DIGEST1_HEX"; then
  fail "retention: the first revision's dir ($DIGEST1_HEX) survived the 4th revision"
fi
kubectl -n "$NS" logs poller 2>/dev/null | tail -3 | grep -q T-9004 \
  || fail "after the prune the server stopped answering"
receipt "retention proven: $COUNT4 dirs (<=3) after the 4th revision; the first tree ($DIGEST1_HEX) pruned; the server still answers"

# ------------------------------------------------------------- the denials
note "the denials: a rogue pod (default SA, no release labels)"
kubectl -n "$NS" run rogue --restart=Never --image=curlimages/curl:8.14.1 -q \
  --overrides '{"spec":{"automountServiceAccountToken":true}}' \
  --command -- sh -c "sleep infinity" >/dev/null
sleep 6
RBAC=$(kubectl -n "$NS" exec rogue -- sh -c "curl -sS --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H \"Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" \
  https://kubernetes.default.svc/apis/source.toolkit.fluxcd.io/v1/namespaces/$NS/externalartifacts/chudmax-tickets" 2>/dev/null || true)
grep -q '"reason": *"Forbidden"' <<<"$RBAC" \
  || fail "RBAC denial: the rogue pod's GET did not 403 — got: ${RBAC:0:200}"
receipt "RBAC denial: the rogue pod's ExternalArtifact GET -> 403 Forbidden (it cannot even learn the URL)"
TARBALL=$(kubectl -n "$NS" exec rogue -- curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "$ART_URL" 2>"$LOGS/rogue-curl.err"; echo "exit=$?")
grep -qE 'exit=(7|28|35)' <<<"$TARBALL" \
  || fail "network denial: the rogue pod REACHED the artifact server — $TARBALL"
receipt "network denial: the rogue pod's tarball GET denied ($TARBALL) — the fences bite"
kubectl -n "$NS" delete pod rogue --force --grace-period=0 >/dev/null 2>&1 || true
kubectl -n "$NS" run control --restart=Never --image=curlimages/curl:8.14.1 \
  --labels app.kubernetes.io/name=chudmax-mcp -q \
  --overrides '{"spec":{"automountServiceAccountToken":false}}' \
  --command -- sh -c "sleep infinity" >/dev/null
sleep 6
CTRL=$(kubectl -n "$NS" exec control -- curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$ART_URL" 2>&1; echo "exit=$?")
grep -q 'exit=0' <<<"$CTRL" \
  || fail "control: the labeled Role-less pod could NOT fetch (the allowance shape is what admits) — $CTRL"
receipt "positive control: the labeled Role-less pod fetched the tarball ($CTRL) — the ingress allowance is what opens the path"
kubectl -n "$NS" delete pod control --force --grace-period=0 >/dev/null 2>&1 || true
# The port-scope probe dials the source-watcher POD directly: the Service
# exposes ports 80/443 only (source-watcher v2.3.1's manifest, both →
# targetPort 9090), so a Service :9090 dial would refuse even with no policy.
# Allowed: the storage port 9090 (the egress rule lists it; the ingress
# allowance admits the release pods). Denied: the metrics port 8080 — a REAL
# listener the egress rule does not list, so CONNECT-FAIL is the policy biting.
SWIP=$(kubectl -n flux-system get endpoints source-watcher -o jsonpath='{.subsets[0].addresses[0].ip}')
[ -n "$SWIP" ] || fail "no source-watcher endpoint IP for the port-scope probe"
PORT_OK=$(kubectl -n "$NS" exec "$POD" -c server -- python3 -c "import urllib.request as u
try:
  r = u.urlopen('http://${SWIP}:9090/', timeout=6); print('HTTP', r.status)
except Exception as e:
  print('CONNECT-FAIL') if 'HTTPError' not in type(e).__name__ else print('HTTP', getattr(e, 'code', ''))" 2>/dev/null || true)
grep -q 'HTTP' <<<"$PORT_OK" \
  || fail "port-scope probe: the storage port :9090 denied from the release pod (the egress rule is broken) — $PORT_OK"
PORT_BAD=$(kubectl -n "$NS" exec "$POD" -c server -- python3 -c "import urllib.request as u
try:
  r = u.urlopen('http://${SWIP}:8080/', timeout=6); print('HTTP', r.status)
except Exception as e:
  print('CONNECT-FAIL') if 'HTTPError' not in type(e).__name__ else print('HTTP', getattr(e, 'code', ''))" 2>/dev/null || true)
grep -q 'CONNECT-FAIL' <<<"$PORT_BAD" \
  || fail "port-scope probe: the unlisted metrics port :8080 was REACHED from the release pod — the egress rule does not bite — $PORT_BAD"
receipt "port-scope probe: pod $SWIP — :9090 allowed ($PORT_OK), :8080 denied ($PORT_BAD) — the chart's egress policy is enforced by Cilium"

# ----------------------------------------------------- alerts + the eventSources check
SINK_EVENTS=$(kubectl -n "$NS" logs alert-sink 2>/dev/null | grep -c SINK-EVENT || true)
receipt "alert sink received $SINK_EVENTS events (the live eventSources check — if 0, alerts.yaml gains ExternalArtifact; recorded in the README)"

note "ALL CHECKS PASSED"
receipt "the phase-5 rehearsal passed: 4 hands-off deliveries, the per-call contract, retention, both modes, the denials, $SINK_EVENTS sink events"
