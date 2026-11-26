# hermes-agent — the chudmax Hermes chart (T-0037 phase 9)

Our own minimal chart for the upstream `nousresearch/hermes-agent` image: one
Deployment (`Recreate`), a persistent `HERMES_HOME` volume (`/opt/data`), and —
the one exposed interface — the keyed OpenAI-compatible API server on :8642.
Staged in `urmanac/chudmax-mcp` until the phase-10 split to
`urmanac/hermes-agent` (the chart name already matches the split target, so
publishing is a pure move). The community Hermes chart is **not** used: it
targets 0.8.0 and ships no LICENSE.

## The three questions this phase answers (receipts: 2026-11-26, upstream v0.23.4)

**1. Does upstream publish a semver-tagged multi-arch image? Yes.** Docker Hub
`nousresearch/hermes-agent` publishes immutable version tags as multi-arch
(amd64+arm64) manifest lists — `v0.23.4` (= the `stable` digest at writing,
manifest-list `sha256:ef0650d5…`; `-desktop` variant `sha256:d7f13dd6…`) — plus
`latest`, `main`, `canary.*`, per-arch and rc tags. The chart consumes the
upstream image; nothing is built here. `image.digest` pins exactly when set
(upstream's own deployment recommendation); the default stays the readable tag.
Upstream tag bumps are manual (chart tag + this README).

**2. Which interface do we expose? The OpenAI-compatible API server on 8642.**
`gateway run` + `API_SERVER_ENABLED=true` + `API_SERVER_HOST=0.0.0.0` +
`API_SERVER_KEY` (mandatory upstream for every deployment — the template guard
enforces it here). `GET /health` is the public cheap route — the probes and the
Helm test hook ride it; `/health/detailed` is the authenticated readiness check
(operators, not probes). The **dashboard** (`HERMES_DASHBOARD=1`, :9119) and the
**webapp** (:9120) fail closed on non-loopback binds without an auth provider
(the June 2026 hardening) — off by default here; enable recipes below. The
**TUI/CLI** is interactive-only: `kubectl exec <pod> -- hermes …` (the image's
exec shim drops root callers to UID 10000, so writes land with the right
ownership). The messaging gateway (Telegram etc.) is egress, not an ingress
surface — nothing to expose.

**3. What in HERMES_HOME must be backed up? The whole home minus the
regenerable trio.** `HERMES_HOME` is `/opt/data` in the container
(`~/.hermes` on host installs). **State:** `.env`, `config.yaml`, `SOUL.md`,
`memories/` (USER.md, MEMORY.md), `sessions/` + `state.db` (SQLite, WAL) +
`response_store.db`, `skills/`, `profiles/` (incl. per-profile `.env` and
`gateway_state.json`), `cron/`, `hooks/`, `skins/`, `home/` (per-profile HOME
for tool subprocesses — `.ssh`, `.gitconfig`, skill-CLI credentials),
`plugins/`, `auth.json`. **Regenerable, never backed up:** `cache/` (uv
re-seeds from the image), `installs/` (PM dependency generations re-resolved at
boot against the new image's lock), `logs/` (runtime). The mechanism is
upstream's own: `hermes backup -o <zip>` captures the whole home (profiles,
memory, persona, skills, conversations, scheduled jobs, settings, keys and
logins); `hermes import <zip>` restores it.

## Values

| Value | Default | Notes |
|---|---|---|
| `image.repository` / `tag` / `digest` | `nousresearch/hermes-agent` / `v0.23.4` / `""` | digest wins when set |
| `args` | `["gateway", "run"]` | the compose deployment shape (s6-supervised); rendered as container `args` so the image's entrypoint dispatcher stays — k8s `command` would replace it |
| `apiServer.enabled` | `true` | the one Service + the probes render only with it |
| `apiServer.port` | `8642` | Service + containerPort + probes |
| `apiServer.key` | `""` | literal key → chart-created Secret (rehearsals only) |
| `apiServer.existingSecret` / `existingSecretKey` | `""` / `API_SERVER_KEY` | the placement path; wins over `key` |
| `storage.size` / `storageClass` | `2Gi` / `""` | empty class = cluster default (kind: local-path) |
| `resources` | req 500m/1Gi, lim 4Gi | upstream minimums: 1 GB mem, 1 core |
| `terminationGracePeriodSeconds` | `60` | SIGTERM drain (runs persist as `interrupted`) |
| `extraEnv` | `[]` | HERMES_UID/GID, provider keys, CORS, dashboard vars |
| `securityContext` | `{}` | merged over `seccompProfile: RuntimeDefault` |
| `test.enabled` | `true` | the Helm test hook (`/health` + bearer `/v1/models`) |

A render guard fails the template when `apiServer.enabled` but neither
`apiServer.key` nor `apiServer.existingSecret` is set — the upstream API server
refuses to run without a key, so a silent broken render is worse than a loud one.

## Deliberate deviations (read before "fixing" the securityContext)

- **No `runAsNonRoot`.** The upstream image is root-then-drop by design: s6
  `/init` runs `stage2-hook.sh` as root (chowns the volume, applies the
  `HERMES_UID`/`HERMES_GID` remap, seeds `.env`/`config.yaml`/`SOUL.md` on
  first boot, syncs skills) and then every supervised service runs as UID
  10000 via `s6-setuidgid`. Forcing `runAsNonRoot: true` breaks the stage2
  window; `capabilities.drop: ALL` breaks chown/setuid. The chart keeps
  `seccompProfile: RuntimeDefault` (mergeable via `securityContext`) and
  `automountServiceAccountToken: false`.
- **No NetworkPolicy rendered by this chart.** Egress (DNS, the model
  providers on the internet) is CNI-dependent guessing — the mcp chart's
  policies cover its own pod; placement phases (12/15) own the rest.
- **No mounted `config.yaml`.** Hermes runs config migrations against that
  file and writes timestamped backups next to it — a ConfigMap mount would
  collide. Configure via env (`extraEnv`), via `hermes config set` exec, or
  by writing `$HERMES_HOME/config.yaml` once through exec.
- **`Recreate`, not `RollingUpdate`** — upstream forbids two gateways on one
  data directory (single-writer SQLite sessions/memory), and the PVC is RWO.

## Recipes

**Configure the model provider** (rehearsal against a mock engine shown):

```sh
kubectl exec <pod> -- hermes config set model.provider custom
kubectl exec <pod> -- hermes config set model.model mock
kubectl exec <pod> -- hermes config set model.base_url http://chudmax-engine:8080/v1
kubectl exec <pod> -- hermes config set model.api_key none
```

**Backup / restore** (the whole agent):

```sh
kubectl exec <pod> -- hermes backup -o /tmp/agent.zip
kubectl cp <ns>/<pod>:/tmp/agent.zip ./agent.zip
# onto an empty volume (stop the s6 gateway first so state.db has no live holder,
# import with --force over stage2's seeded defaults, then start it back up):
kubectl cp ./agent.zip <ns>/<pod>:/tmp/agent.zip
kubectl exec <pod> -- hermes gateway stop
kubectl exec <pod> -- hermes import /tmp/agent.zip --force
kubectl exec <pod> -- hermes gateway start
kubectl -n <ns> rollout restart deploy <name>
```

**Dashboard / webapp** (off by default — upstream fails closed without an auth
provider; pick one):

```sh
# username/password (self-hosted):
--set extraEnv[0].name=HERMES_DASHBOARD --set extraEnv[0].value=1
--set extraEnv[1].name=HERMES_DASHBOARD_BASIC_AUTH_USERNAME --set extraEnv[1].value=admin
--set extraEnv[2].name=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD --set extraEnv[2].value=<from-a-Secret-at-placement>
# (9119 dashboard / 9120 webapp; publish via a Service/Gateway at placement)
```

**Reachability:** the mcp chart's default ingress NetworkPolicy admits
same-namespace pods to the ticket server — install this chart into the mcp
release's namespace and hermes reaches `chudmax-mcp:<server-port>` with no
extra configuration. A foreign-namespace install adds the rule via that
chart's `networkPolicy.ingress.extra` passthrough instead.

**HERMES_UID / HERMES_GID:** default runtime UID 10000; local-path-style
provisioners hand the pod an empty dir and stage2 chowns it at boot. To match
a specific owner, pass `extraEnv` entries `HERMES_UID` / `HERMES_GID` (the
stage2 remap runs before services start).

## Why not the community chart?

It targets hermes-agent 0.8.0 (today's stable: 0.23.4) and ships no LICENSE —
neither is acceptable for a chart that must consume current upstream images and
be published (phase 10). Our chart is minimal on purpose: the image is upstream's
contract, the interface is one Service, the persistence story is upstream's own
`hermes backup`/`hermes import`.
