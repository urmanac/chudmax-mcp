#!/usr/bin/env bash
# The phase-8 rehearsal orchestrator (T-0037): a throwaway kind cluster, Flux
# with the image-reflector and image-automation controllers, the in-cluster
# registry:2 stand-in, the authed Smart-HTTP test repo, and the card's proofs:
#
#   pre-flight (runner-side, no cluster): the authed gittestserver module, the
#     seeded bare repo (by CLONE — never an HTTP push to main), and the hook
#     mechanics proven before anything is applied: an unauthenticated ls-remote
#     is refused; a review push is accepted; a main push with the SAME
#     automation credential is DENIED by the pre-receive hook;
#   beat 1 (idle): a lone 0.1.0 resolves to exactly the seeded values — the
#     automation reports no change and NO review branch exists (writes are
#     policy-gated);
#   beat 2 (the headline): 0.1.1 tags land → scans see 2 tags → the policies
#     resolve 0.1.1 → ONE commit on review/image-updates whose diff carries
#     all three new refs; main's SHA is byte-unchanged;
#   beat 3 (repeat): 0.1.2 overwrites the review tip (the default
#     GitForcePushBranch semantics, receipted with both commit SHAs);
#   the one-branch control (final): the automation credential is denied for
#     refs/heads/main again, with main still on the seed SHA and exactly two
#     refs in the repo.
#
# The CI kind job is the authoritative run; the sandbox runs the pre-flight
# only (REHEARSAL_PREFLIGHT_ONLY=1 — kind cannot run there, the standing
# constraint) and records that honestly.
set -euo pipefail

CLUSTER=${KIND_CLUSTER:-chudmax-phase8}
RUNNER_TEMP=${RUNNER_TEMP:-/tmp}
LOGS=${REHEARSAL_LOGS:-/tmp/image-automation-logs}
SUMMARY=${REHEARSAL_SUMMARY:-/tmp/image-automation-summary.txt}
PROVIDER=${KIND_EXPERIMENTAL_PROVIDER:-docker}
HERE=$(cd "$(dirname "$0")" && pwd)
FIXTURES="$HERE/rehearsal"
KIND_CONFIG="$HERE/rehearsal/kind-config.yaml"   # phase-8's variant: the phase-5 pin, the default CNI ON (stock kindnet)
NS=flux-system
GIT_PORT=${GIT_PORT:-38080}
REG_NODEPORT=30500
GIT_ROOT=${REHEARSAL_GIT_ROOT:-/tmp/image-automation-git}
STRATA_PIN=de34ebaa521d8f628b4bb1884e5c34101730299a   # the umbrella README's pin — asserted below
SEED_TAG=0.1.0
TAG2=0.1.1
TAG3=0.1.2
GIT_SRV_PID=
KIND_UP=

mkdir -p "$LOGS"
: > "$SUMMARY"
# Every line the script emits (stdout+stderr) lands in the logs dir too —
# alongside the workflow's streamed tee (RUNNER_TEMP/smoke.log), which is the
# live record; this copy plus the check-run annotations are the diagnostic
# channel (GitHub job logs are sign-in-gated).
exec > >(tee -a "$LOGS/script-output.log") 2>&1

note() { echo "[rehearsal] $*" | tee -a "$SUMMARY" >&2; }
receipt() { echo "RECEIPT: $*" | tee -a "$SUMMARY"; }
fail() { echo "FAIL: $*" | tee -a "$SUMMARY" >&2; exit 1; }

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
  annotate automation "$LOGS/automation-describe.txt"
  sleep 1   # let the tee drain before the shell exits
}

cleanup() {
  rc=$?
  if [ -n "${GIT_SRV_PID:-}" ]; then kill "$GIT_SRV_PID" 2>/dev/null || true; fi
  cp -f "$SUMMARY" "$LOGS/image-automation-summary.txt" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    note "failure path: dumping the cluster state to $LOGS"
    kubectl get pods -A -o wide > "$LOGS/pods-all.txt" 2>/dev/null || true
    kubectl -n "$NS" get events --sort-by=.lastTimestamp > "$LOGS/events.txt" 2>/dev/null || true
    kubectl -n "$NS" describe imageupdateautomation/chudmax-image-updates > "$LOGS/automation-describe.txt" 2>/dev/null || true
    annotate_failure
  fi
  if [ -n "$KIND_UP" ]; then
    kind delete cluster --name "$CLUSTER" 2>/dev/null || true
    note "throwaway cluster deleted (always)"
  fi
  exit "$rc"
}
trap cleanup EXIT

# Bounded wait with a diagnose-on-timeout dump (the phase-9 discipline: never
# a bare kubectl wait without the state on the way out).
wait_until() { # $1 desc, $2.. the readiness command
  local desc="$1"; shift
  local i
  for i in $(seq 1 36); do
    if "$@" >/dev/null 2>&1; then
      receipt "$desc — ready on attempt $i"
      return 0
    fi
    sleep 5
  done
  note "timeout on: $desc — the state:"
  "$@" || true
  kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true
  fail "$desc not satisfied in 180s"
}

git_auth() { git -c http.sslCAInfo="$LOGS/ca.crt" -c http.extraHeader="Authorization: Basic ${AUTH_B64:?}" "$@"; }

start_git_server() { # $1 optional extra SAN IP (e.g. kind bridge gateway)
  local extra_ip="${1:-}" san="DNS:localhost,IP:127.0.0.1"
  [ -n "$extra_ip" ] && san="${san},IP:${extra_ip}"
  if [ -n "${GIT_SRV_PID:-}" ]; then
    kill "$GIT_SRV_PID" 2>/dev/null || true
    wait "$GIT_SRV_PID" 2>/dev/null || true
    GIT_SRV_PID=""
  fi
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$LOGS/git.key" -out "$LOGS/git.csr" -subj "/CN=gittestserver" >/dev/null 2>&1
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "$LOGS/git-ext.cnf"
  openssl x509 -req -in "$LOGS/git.csr" -CA "$LOGS/ca.crt" -CAkey "$LOGS/ca.key" \
    -CAcreateserial -out "$LOGS/git.crt" -days 1 -extfile "$LOGS/git-ext.cnf" >/dev/null 2>&1
  "$LOGS/gittestserver" -root "$GIT_ROOT" -addr "0.0.0.0:$GIT_PORT" -auth "fluxbot:$PASS" \
    -tls-cert "$LOGS/git.crt" -tls-key "$LOGS/git.key" >> "$LOGS/gitserver.log" 2>&1 &
  GIT_SRV_PID=$!
  for _ in $(seq 1 20); do
    curl -fsS --connect-timeout 2 --max-time 5 --cacert "$LOGS/ca.crt" -o /dev/null \
      -u "fluxbot:$PASS" "https://127.0.0.1:$GIT_PORT/repo.git/info/refs?service=git-upload-pack" && return 0
    sleep 0.5
  done
  fail "the HTTPS git server never became ready: $(tail -5 "$LOGS/gitserver.log")"
}

# The phase-6 pbuild (the phase-9 copy): transient base-image pulls exit 125 —
# retry, then die with the log.
pbuild() {
  local tag="$1" file="$2" ctx="$3" attempt
  for attempt in 1 2 3; do
    if podman build -q -t "$tag" -f "$file" "$ctx"; then return 0; fi
    note "build of $tag failed (attempt $attempt) — retrying after a pause"
    sleep $((attempt * 20))
  done
  note "the build of $tag failed three times"; exit 1
}

# ---------------------------------------------------------------------------
# pre-flight — everything that needs no cluster
# ---------------------------------------------------------------------------
note "pre-flight: building the authed gittestserver module (phase-8's own — phase-5's stays untouched)"
( cd "$FIXTURES/gittestserver" && go vet ./... && go build -o "$LOGS/gittestserver" . )

# The credential: generated here, used by the Flux secret and the runner-side
# controls, verified absent from every receipt before anything uploads.
# No git call may ever prompt (a non-interactive 401 must fail fast, not hang
# on the credential prompt).
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
PASS=$(openssl rand -hex 16)
AUTH_B64=$(printf 'fluxbot:%s' "$PASS" | base64 | tr -d '\n')
# shellcheck disable=SC2153
export AUTH_B64

rm -rf "$GIT_ROOT"; mkdir -p "$GIT_ROOT"
REPO_GIT=$GIT_ROOT/repo.git

# The seed work tree: the release-values miniature (with the rehearsal
# registry host substituted so beat 1's 0.1.0 scan matches the seeded lines
# byte-for-byte), then the bare repo by CLONE (the hook rejects main pushes,
# so setup never pushes over HTTPS).
mkdir -p "$GIT_ROOT/seed/values"
sed "s|ghcr.io/|registry.$NS.svc:5000/|g" "$FIXTURES/values-fixture.yaml" > "$GIT_ROOT/seed/values/images.yaml"
git -C "$GIT_ROOT/seed" init -q -b main
git -C "$GIT_ROOT/seed" add -A
git -C "$GIT_ROOT/seed" -c user.name="phase 8 seed" -c user.email="seed@chudmax.invalid" \
  commit -qm "seed: the release-values miniature at $SEED_TAG"
git clone -q --bare "$GIT_ROOT/seed" "$REPO_GIT"
install -m 0755 "$FIXTURES/main-protect-hook.sh" "$REPO_GIT/hooks/pre-receive"
MAIN_SHA=$(git --git-dir="$REPO_GIT" rev-parse refs/heads/main)
receipt "seed repo at $REPO_GIT — main=$MAIN_SHA (the SHA that must never move)"

openssl req -x509 -newkey rsa:2048 -days 1 -nodes \
  -keyout "$LOGS/ca.key" -out "$LOGS/ca.crt" -subj "/CN=chudmax-rehearsal-ca" >/dev/null 2>&1
: > "$LOGS/gitserver.log"
start_git_server ""
receipt "HTTPS git server up on :$GIT_PORT with ephemeral CA + required basic auth (identity fluxbot)"

# The negative AUTH control: no credentials → 401. GIT_TERMINAL_PROMPT=0 is
# exported for every git call, and set ON THE CHECK ITSELF: without it git
# opens /dev/tty and hangs the non-interactive run waiting for a username
# (the CI receipt of exactly that hang, killed after 90m on the terminal).
if GIT_TERMINAL_PROMPT=0 git -c http.sslCAInfo="$LOGS/ca.crt" ls-remote "https://127.0.0.1:$GIT_PORT/repo.git" >/dev/null 2>&1; then
  fail "the git server accepted an UNAUTHENTICATED ls-remote — the credential story would be fake"
fi
receipt "the auth fence bites: an unauthenticated ls-remote is refused"

note "pre-flight: the hook mechanics, runner-side, before anything is applied"
rm -rf "$GIT_ROOT/control"
git_auth clone -q "https://127.0.0.1:$GIT_PORT/repo.git" "$GIT_ROOT/control"
git -C "$GIT_ROOT/control" -c user.name=control -c user.email=control@chudmax.invalid \
  commit -q --allow-empty -m "control: the review push"
git_auth -C "$GIT_ROOT/control" push -q origin HEAD:refs/heads/review/image-updates
receipt "control push to review/image-updates: ACCEPTED (the branch the automation may write)"
git --git-dir="$REPO_GIT" update-ref -d refs/heads/review/image-updates
receipt "the review ref deleted after the control — the automation must create it itself"
OUT=$(git_auth -C "$GIT_ROOT/control" push origin HEAD:refs/heads/main 2>&1) \
  && fail "a main push with the automation credential was ACCEPTED — the fence does not bite" || true
echo "$OUT" | grep -q "denied:" \
  || fail "the main push failed but NOT via the hook (no denial text): $OUT"
receipt "control push to main with the SAME credential: DENIED by the pre-receive hook"

if [ "${REHEARSAL_PREFLIGHT_ONLY:-}" = "1" ]; then
  note "REHEARSAL_PREFLIGHT_ONLY=1 — the sandbox's pre-flight receipt ends here (kind cannot run: the standing constraint)"
  receipt "pre-flight complete: auth + hook mechanics proven without a cluster"
  exit 0
fi

# ---------------------------------------------------------------------------
# the cluster
# ---------------------------------------------------------------------------
note "creating the kind cluster ($CLUSTER, $PROVIDER provider)"
# kind writes the kubeconfig before returning; wait for the apiserver itself
# (a nonzero --wait would time out and fail the create — the phase-5 receipt).
kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG" --wait 0s
KIND_UP=1
for _ in $(seq 1 60); do
  kubectl get --raw=/readyz >/dev/null 2>&1 && break
  sleep 2
done
kubectl get --raw=/readyz >/dev/null 2>&1 || fail "apiserver not ready 120s after kind create"
# The kind network may be dual-stack with IPv6 FIRST in IPAM.Config (observed
# on the docker-29 GitHub runners) — the cluster→runner route is IPv4.
GW=$(docker network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Gateway != null) | select(.Gateway | test("^[0-9]+[.]")) | .Gateway' | head -n1)
[ -n "$GW" ] || fail "no IPv4 gateway on the kind network (gateways seen: $(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}'))"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
[ -n "$NODE_IP" ] || fail "no node InternalIP discovered"
start_git_server "$GW"
receipt "runner gateway $GW (HTTPS git server re-signed with SAN IP:$GW); node IP $NODE_IP (the runner's route to the registry)"

note "installing Flux with the image controllers (shipped policies on)"
# NOTE: flux install has no --wait flag — waiting for the controllers is its
# default behavior; the CLI version pins the manifests bundle (v2.10.1 via the
# workflow's flux2 action).
flux install --components-extra=image-reflector-controller,image-automation-controller --namespace="$NS"
wait_until "the flux deployments available" \
  kubectl -n "$NS" wait --for=condition=available deployment --all --timeout=5s
receipt "flux controllers: $(kubectl -n "$NS" get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"

# ---------------------------------------------------------------------------
# the registry stand-in + the credential secret
# ---------------------------------------------------------------------------
note "applying the in-cluster registry:2 (the ghcr stand-in until phase 10)"
kubectl apply -n "$NS" -f "$FIXTURES/registry.yaml" >/dev/null
wait_until "the registry deployment available" \
  kubectl -n "$NS" wait --for=condition=available deployment/image-registry --timeout=5s
REG_TARGET="${NODE_IP}:${REG_NODEPORT}"
sudo mkdir -p /etc/containers/registries.conf.d
printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REG_TARGET" \
  | sudo tee /etc/containers/registries.conf.d/phase8-rehearsal.conf >/dev/null
for _ in $(seq 1 20); do
  curl -fsS --connect-timeout 2 --max-time 5 -o /dev/null "http://${REG_TARGET}/v2/" && break
  sleep 1
done
curl -fsS --connect-timeout 2 --max-time 5 -o /dev/null "http://${REG_TARGET}/v2/" \
  || fail "the registry is not reachable from the runner at http://${REG_TARGET}/v2/"
receipt "registry reachable from the runner at ${REG_TARGET}/v2/ (in-cluster name: registry.$NS.svc:5000)"

kubectl -n "$NS" create secret generic chudmax-repo-auth \
  --from-literal=username=fluxbot --from-literal=password="$PASS" \
  --from-file=ca.crt="$LOGS/ca.crt" >/dev/null
receipt "secret chudmax-repo-auth created (username + password + ca.crt; the password never leaves the env)"

# ---------------------------------------------------------------------------
# the images: ONE real build, the later tags are retags of the same bytes
# ---------------------------------------------------------------------------
note "building the three images (amd64 — the rehearsal proves the loop, not the manifest list)"
grep -q "$STRATA_PIN" k8s/umbrella/chudmax/README.md \
  || fail "the script's Strata pin is not in the umbrella README's pins table — drift between the script and the pin"
pbuild "ghcr.io/urmanac/chudmax/fetcher:$SEED_TAG" k8s/image/Dockerfile k8s
pbuild "ghcr.io/urmanac/chudmax/tickets-mcp:$SEED_TAG" k8s/tickets-mcp/Dockerfile k8s/tickets-mcp
git init -q "$RUNNER_TEMP/strata" 2>/dev/null || true
git -C "$RUNNER_TEMP/strata" fetch -q --depth 1 https://github.com/kingdonb/Strata "$STRATA_PIN"
git -C "$RUNNER_TEMP/strata" checkout -q FETCH_HEAD
pbuild "ghcr.io/urmanac/chudmax/web:$SEED_TAG" k8s/umbrella/chudmax/web-image/Dockerfile "$RUNNER_TEMP/strata"

rtag() { # $1 the fq image (name:tag), $2 the new tag — push through the node's NodePort
  local base
  base=$(basename "${1%%:*}")
  podman tag "$1" "$REG_TARGET/urmanac/chudmax/$base:$2"
  podman push --tls-verify=false "$REG_TARGET/urmanac/chudmax/$base:$2"
}
for img in fetcher tickets-mcp web; do
  rtag "ghcr.io/urmanac/chudmax/$img:$SEED_TAG" "$SEED_TAG"
done
receipt "the three images pushed to the rehearsal registry at $SEED_TAG (registry.$NS.svc:5000/urmanac/chudmax/*)"

# ---------------------------------------------------------------------------
# the Flux objects (test repo + the three repositories + the policies + the
# egress fixture + the automation). The imagepolicy.yaml needs NO rehearsal
# variant — names, range and refs are identical in both shapes.
# ---------------------------------------------------------------------------
sed "s|__RUNNER_HTTP__|${GW}:${GIT_PORT}|" "$FIXTURES/gitrepository-rehearsal.yaml" \
  > "$LOGS/gitrepository-rehearsal.rendered.yaml"
kubectl apply -n "$NS" -f "$LOGS/gitrepository-rehearsal.rendered.yaml" >/dev/null
wait_until "gitrepository chudmax-source ready" \
  kubectl -n "$NS" wait --for=condition=ready gitrepository/chudmax-source --timeout=5s
kubectl apply -n "$NS" -f "$FIXTURES/imagerepository-rehearsal.yaml" >/dev/null
kubectl apply -n "$NS" -f "$HERE/imagepolicy.yaml" >/dev/null
kubectl apply -n "$NS" -f "$HERE/networkpolicy-allow-image-controllers-egress.yaml" >/dev/null
kubectl apply -n "$NS" -f "$FIXTURES/imageupdateautomation-rehearsal.yaml" >/dev/null
receipt "the flux objects applied (test repo ready; 3 ImageRepositories insecure; 3 ImagePolicies; the egress fixture; the automation)"
receipt "the image controllers' shipped egress policies: $(kubectl -n "$NS" get networkpolicies -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"

repo_ready() { kubectl -n "$NS" get "imagerepository/chudmax-$1" -o jsonpath='{.status.lastScanResult.tagCount}' | grep -qx "$2"; }
policy_latest() { [ "$(kubectl -n "$NS" get "imagepolicy/chudmax-$1" -o jsonpath='{.status.latestRef.tag}')" = "$2" ]; }
pushed_yet() { [ -n "$(kubectl -n "$NS" get imageupdateautomation/chudmax-image-updates -o jsonpath='{.status.lastPushCommit}')" ]; }
branch_has_tag() {
  local sha tip img
  sha=$(git --git-dir="$REPO_GIT" rev-parse -q --verify refs/heads/review/image-updates 2>/dev/null) || return 1
  tip=$(git --git-dir="$REPO_GIT" show "$sha:values/images.yaml" 2>/dev/null) || return 1
  for img in fetcher tickets-mcp web; do
    echo "$tip" | grep -q "registry.$NS.svc:5000/urmanac/chudmax/$img:$1" || return 1
  done
  [ "$(kubectl -n "$NS" get imageupdateautomation/chudmax-image-updates -o jsonpath='{.status.lastPushCommit}')" = "$sha" ]
}

scan_and_resolve() { # $1 the expected tag, $2 the expected tagCount — one image cycle
  local img="$1" tag="$2" count="$3"
  flux reconcile image repository "chudmax-$img" --timeout=30s >/dev/null || true
  wait_until "imagerepository chudmax-$img scans $count tags" repo_ready "$img" "$count"
  flux reconcile image policy "chudmax-$img" --timeout=30s >/dev/null || true
  wait_until "imagepolicy chudmax-$img resolves $tag" policy_latest "$img" "$tag"
  receipt "chudmax-$img: scanned $count tag(s), policy latest=$tag"
}

# ---------------------------------------------------------------------------
# beat 1 — the idle beat: a lone 0.1.0 resolves to NOTHING TO DO
# ---------------------------------------------------------------------------
note "beat 1 — the idle beat: with only $SEED_TAG present, the automation must write NOTHING"
for img in fetcher tickets-mcp web; do
  scan_and_resolve "$img" "$SEED_TAG" 1
done
flux reconcile image update chudmax-image-updates --timeout=30s >/dev/null || true
wait_until "the automation settles on the idle beat" \
  kubectl -n "$NS" wait --for=condition=ready imageupdateautomation/chudmax-image-updates --timeout=5s
if pushed_yet; then
  fail "the automation PUSHED on the idle beat (lastPushCommit set) — writes are not policy-gated"
fi
if git --git-dir="$REPO_GIT" rev-parse --verify -q refs/heads/review/image-updates >/dev/null; then
  fail "the review branch exists after the idle beat — the automation wrote without a policy change"
fi
receipt "idle beat: lastPushCommit empty and refs/heads/review/image-updates absent — the loop writes only on a policy change"

# ---------------------------------------------------------------------------
# beat 2 — the update beat: 0.1.1 becomes a commit on review/image-updates
# ---------------------------------------------------------------------------
note "beat 2 — the update beat: $TAG2 becomes a commit on review/image-updates without a person"
for img in fetcher tickets-mcp web; do
  rtag "ghcr.io/urmanac/chudmax/$img:$SEED_TAG" "$TAG2"
done
receipt "$TAG2 tags pushed (the same bytes, retagged — the phase-7 way)"
for img in fetcher tickets-mcp web; do
  scan_and_resolve "$img" "$TAG2" 2
done
# The policy changes trigger the automation outside the interval (docs) — this
# forced reconcile is belt-and-braces; whichever path fires, the asserts below
# are on the git state and the status, not on the triggering invocation.
flux reconcile image update chudmax-image-updates --timeout=30s >/dev/null || true
wait_until "the automation pushes all three $TAG2 swaps" branch_has_tag "$TAG2"
wait_until "the automation settles after the push" \
  kubectl -n "$NS" wait --for=condition=ready imageupdateautomation/chudmax-image-updates --timeout=5s
PUSH1=$(kubectl -n "$NS" get imageupdateautomation/chudmax-image-updates -o jsonpath='{.status.lastPushCommit}')
REVIEW_SHA=$(git --git-dir="$REPO_GIT" rev-parse refs/heads/review/image-updates)
[ "$PUSH1" = "$REVIEW_SHA" ] || fail "status.lastPushCommit ($PUSH1) != the remote review tip ($REVIEW_SHA)"
receipt "automation event stream: $(kubectl -n "$NS" get events -o jsonpath='{range .items[*]}{.involvedObject.name}{"\t"}{.message}{"\n"}{end}' | grep chudmax-image-updates | tail -3 | tr '\n' ' |')"
TIP=$(git --git-dir="$REPO_GIT" show "$REVIEW_SHA:values/images.yaml")
for img in fetcher tickets-mcp web; do
  echo "$TIP" | grep -q "registry.$NS.svc:5000/urmanac/chudmax/$img:$TAG2" \
    || fail "the review tip misses the $img swap to $TAG2: $TIP"
done
[ "$(echo "$TIP" | grep -c '\$imagepolicy')" = 3 ] || fail "the markers did not survive the rewrite: $TIP"
if echo "$TIP" | grep -q 'ghcr.io'; then fail "the review tip still carries a ghcr.io ref — the setters missed a line: $TIP"; fi
# Flux's ImagePolicy watch reconciles reactively as each policy resolves (1..3
# commits on main..review/image-updates depending on batching); across the beat's
# range all three arrow lines and only the bot author must appear.
MSG=$(git --git-dir="$REPO_GIT" log --format=%B "$MAIN_SHA..$REVIEW_SHA")
[ "$(echo "$MSG" | grep -c -- ' -> ')" = 3 ] || fail "the beat-2 commit range does not carry all three arrow lines: $MSG"
AUTHORS=$(git --git-dir="$REPO_GIT" log --format='%an <%ae>' "$MAIN_SHA..$REVIEW_SHA" | sort -u)
[ "$AUTHORS" = "chudmax-flux-bot <flux-bot@chudmax.invalid>" ] || fail "unexpected commit author(s): $AUTHORS"
[ "$(git --git-dir="$REPO_GIT" rev-parse refs/heads/main)" = "$MAIN_SHA" ] || fail "MAIN MOVED during the update beat"
B2_COMMITS=$(git --git-dir="$REPO_GIT" rev-list --count "$MAIN_SHA..$REVIEW_SHA")
[ "$B2_COMMITS" -ge 1 ] && [ "$B2_COMMITS" -le 3 ] \
  || fail "unexpected beat-2 commit count on review/image-updates: $B2_COMMITS (want 1..3)"
receipt "review/image-updates @ ${REVIEW_SHA:0:12} carries all three $TAG2 swaps across $B2_COMMITS reactive commit(s)"
receipt "main still $MAIN_SHA — the machine never touched it"

# ---------------------------------------------------------------------------
# beat 3 — the repeat beat: 0.1.2 advances review/image-updates cleanly
# ---------------------------------------------------------------------------
note "beat 3 — the repeat beat: $TAG3 advances review/image-updates (Flux GitAllBranchReferences=true appends onto existing push branch)"
for img in fetcher tickets-mcp web; do
  rtag "ghcr.io/urmanac/chudmax/$img:$SEED_TAG" "$TAG3"
done
for img in fetcher tickets-mcp web; do
  scan_and_resolve "$img" "$TAG3" 3
done
flux reconcile image update chudmax-image-updates --timeout=30s >/dev/null || true
wait_until "the automation pushes all three $TAG3 swaps" branch_has_tag "$TAG3"
wait_until "the automation settles after the repeat" \
  kubectl -n "$NS" wait --for=condition=ready imageupdateautomation/chudmax-image-updates --timeout=5s
REVIEW2=$(git --git-dir="$REPO_GIT" rev-parse refs/heads/review/image-updates)
[ "$REVIEW2" != "$REVIEW_SHA" ] || fail "the review tip did not move on the repeat beat"
TIP2=$(git --git-dir="$REPO_GIT" show "$REVIEW2:values/images.yaml")
for img in fetcher tickets-mcp web; do
  echo "$TIP2" | grep -q "registry.$NS.svc:5000/urmanac/chudmax/$img:$TAG3" \
    || fail "the repeat tip misses the $img swap to $TAG3: $TIP2"
done
MSG3=$(git --git-dir="$REPO_GIT" log --format=%B "$REVIEW_SHA..$REVIEW2")
[ "$(echo "$MSG3" | grep -c -- ' -> ')" = 3 ] || fail "the beat-3 commit range does not carry all three arrow lines: $MSG3"
B3_COMMITS=$(git --git-dir="$REPO_GIT" rev-list --count "$REVIEW_SHA..$REVIEW2")
[ "$B3_COMMITS" -ge 1 ] && [ "$B3_COMMITS" -le 3 ] \
  || fail "unexpected beat-3 commit count: $B3_COMMITS (want 1..3)"
[ "$(git --git-dir="$REPO_GIT" rev-parse refs/heads/main)" = "$MAIN_SHA" ] || fail "MAIN MOVED during the repeat beat"
receipt "repeat beat: review/image-updates advanced ${REVIEW_SHA:0:12} -> ${REVIEW2:0:12} (+$B3_COMMITS commit(s), all three $TAG3 swaps); main still $MAIN_SHA"

# ---------------------------------------------------------------------------
# the one-branch control — final, against the settled repo state
# ---------------------------------------------------------------------------
note "the one-branch control: the automation credential vs refs/heads/main, one more time"
git -C "$GIT_ROOT/control" -c user.name=control -c user.email=control@chudmax.invalid \
  commit -q --allow-empty -m "control: an attempted main push after the beats"
OUT=$(git_auth -C "$GIT_ROOT/control" push origin HEAD:refs/heads/main 2>&1) \
  && fail "a main push with the automation credential was ACCEPTED after the beats" || true
echo "$OUT" | grep -q "denied:" || fail "the final main push failed but NOT via the hook: $OUT"
[ "$(git --git-dir="$REPO_GIT" rev-parse refs/heads/main)" = "$MAIN_SHA" ] || fail "MAIN MOVED on the denied push"
REFS=$(git --git-dir="$REPO_GIT" for-each-ref --format='%(refname)' | sort | xargs)
[ "$REFS" = "refs/heads/main refs/heads/review/image-updates" ] || fail "unexpected refs after the beats: $REFS"
receipt "final control: main-push DENIED ($(echo "$OUT" | grep denied: | head -1)); refs exactly: $REFS"

# ---------------------------------------------------------------------------
# the record
# ---------------------------------------------------------------------------
receipt "framing: the registry and the git server are runner-local stand-ins — ghcr.io scans and the real git remote wire up at the phase-10/12 wiring with a write-scoped credential (README: the credential finding)"
receipt "the scanned image set: fetcher, tickets-mcp, web — hermes-agent deliberately excluded (upstream tags, manual)"
if grep -q "$PASS" "$SUMMARY"; then fail "the SUMMARY carries the credential — refusing to finish"; fi
if grep -q "$PASS" "$LOGS/script-output.log" 2>/dev/null; then fail "the streamed log carries the credential"; fi
note "the phase-8 rehearsal: GREEN — a tag became a review-branch commit without a person, and main never moved"
