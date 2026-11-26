# Design: chudmax k8s phase 9 Hermes chart with persistent home

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Phase 9 adds the Hermes chart as an installable part and proves it on kind: persistent HERMES_HOME, pod-delete survival, restore onto an empty volume, and a chat served through the mock engine. It builds **no image** — upstream publishes semver-tagged ones — and edits the mcp chart **nowhere**: the NetworkPolicy question is settled by namespace placement. Requirements in `requirements.md`; the phase-9 row lives in `kubernetes/phases.md` on the private source-of-truth repo (SPIKE row I). All upstream facts were verified against `github.com/NousResearch/hermes-agent` at tag `v0.23.4` and the Docker Hub registry API from this sandbox on 2026-11-26 (`verified-here`).

## Shape (kind rehearsal)

```
 chudmax release namespace (one namespace — the admission decision)
 ┌────────────────────────────────────────────────────────────────────┐
 │  hermes Deployment (Recreate)          mcp pod (server + fetcher)  │
 │  ┌──────────────────────────┐         ┌────────────────────────┐   │
 │  │ hermes-agent:v0.23.4     │         │ tickets-mcp :8080      │   │
 │  │ s6: gateway run          │──(200)─►│ ← ingress policy       │   │
 │  │ API server 0.0.0.0:8642  │  curl   │   admits SAME NAMESPACE│   │
 │  │ /health (no auth) probe  │         │   → web AND hermes     │   │
 │  │ HERMES_HOME=/opt/data    │         └────────────────────────┘   │
 │  └───────────┬──────────────┘                                      │
 │              │ PVC <release>-hermes-home (RWO, local-path on kind) │
 │  ┌───────────▼──────────────┐    model.provider: custom            │
 │  │ /opt/data  (state.db     │    base_url http://chudmax-engine:   │
 │  │  WAL, SOUL.md, memories, │              8080/v1                 │
 │  │  sessions, skills,       │         ┌────────────────────────┐   │
 │  │  profiles, cron, .env)   │         │ chudmax-engine Service │   │
 │  └──────────────────────────┘         │ (no selector) +        │   │
 │                                       │ EndpointSlice → bridge │   │
 │  Service :8642 → pod      Strata --engine mock (OUTSIDE kind, :8080)
 └────────────────────────────────────────────────────────────────────┘
```

The rehearsal reuses the phase-6 ladder wholesale (bridge gateway IP, `kind load image-archive`, the Host-header lesson); the only new pod is hermes.

## The mcp NetworkPolicy question — decided: shared release namespace

The mcp chart's ingress policy admits TCP to the server port from **the release namespace** (a same-namespace `podSelector` + `extraIngress` passthrough). Decision: **the umbrella installs every component into one namespace, so hermes pods are admitted by the existing rule with zero new configuration** — no extraIngress, no chart edit, nothing rendered. The proof asserts it (a 200 from the hermes pod to the tickets-mcp Service). A **standalone** hermes install outside the umbrella's namespace is the documented alternative: it must add the rule itself via the mcp chart's `extraIngress` passthrough — documented in the hermes chart README, never rendered by default. Same reasoning as phase 6's no-policies stance: this phase renders no NetworkPolicy on the hermes chart itself (CNI-dependent egress guesses wait for phases 12/15; hermes' real egress — model providers on the internet — is exactly that).

## Layout (the phase-9 write set)

```
k8s/chart/chudmax-hermes/
  Chart.yaml            v2, chudmax-hermes 0.1.0, appVersion 0.23.4
  values.yaml           minimal: image, apiServer, storage, resources,
                        extraEnv, securityContext passthrough
  templates/            _helpers, deployment (Recreate), service, pvc,
                        secret (optional), NOTES.txt, test-hook
  README.md             the three answered questions, HERMES_HOME
                        inventory, backup/restore recipe, admission note
.github/workflows/hermes-kind.yml   chart job + kind rehearsal job
k8s/umbrella/chudmax/Chart.yaml     +1 dep (file://, hermes.enabled)
k8s/umbrella/chudmax/values.yaml    +hermes block (enabled: false default)
k8s/umbrella/chudmax/README.md      +Hermes pins row
```

## Key decisions

1. **Upstream image, no build.** `nousresearch/hermes-agent:v0.23.4` (manifest list `sha256:ef0650d5…`, amd64+arm64; `stable` shares the digest). The `digest` values knob exists because upstream's own docs recommend digest pins for deployments; default stays the readable tag. The community chart (0.8.0, no LICENSE) is rejected on those two facts; upstream's MIT repo + registry-published images need no fork. Consequence: phase 9 is the first parts-phase whose CI has no image job — it pulls instead (~1.15 GB per arch; `kind load image-archive` after the pull, the established no-registry-at-install pattern).
2. **One Deployment, Recreate — and never runAsNonRoot.** Upstream forbids two gateways on one data directory (concurrent SQLite/session writes), so `strategy: Recreate` with an RWO PVC. The image is **root-then-drop by design**: s6-overlay's `/init` runs `stage2-hook.sh` as root (remaps `HERMES_UID`/`HERMES_GID`, chowns the volume, seeds `.env`/`config.yaml`/`SOUL.md` on first boot, syncs skills) and then every supervised service drops to UID 10000 via `s6-setuidgid`. Forcing `runAsNonRoot: true` (the 4b pattern) would break the stage2 chown window; `capabilities.drop: ALL` would break chown/setuid. The chart therefore applies only `seccompProfile: RuntimeDefault` + `automountServiceAccountToken: false` and documents the deviation loudly — the trust boundary moves to "we trust the upstream image's bootstrap," which is the same trust already extended by consuming the image itself.
3. **The exposed interface is the API server.** `gateway run` (the compose-defined deployment command) with `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, `API_SERVER_PORT=8642`, `API_SERVER_KEY` from a Secret. Reasons: it is the only programmatic surface designed for external clients; the bearer key is mandatory upstream (even loopback); `/health` is the public cheap probe route (`/health/detailed` is the authenticated readiness check — not used by probes, documented for operators). The dashboard (`HERMES_DASHBOARD=1`, :9119) and webapp (:9120) fail closed on non-loopback binds without an auth provider — the June 2026 hardening — so they stay off; enabling them is an operator recipe in the README, not a chart default. The TUI/CLI is exec-only (the image's exec shim drops root callers to UID 10000, so `kubectl exec … hermes config set` writes as the right user).
4. **HERMES_HOME = the PVC; the backup story is upstream's own.** Mount the PVC at `/opt/data` (`VOLUME` in the image; `HERMES_HOME` env already points there). Backup/restore uses `hermes backup -o <zip>` / `hermes import <zip>` — the upstream-sanctioned whole-home mechanism (profiles, memory, persona, skills, conversations, scheduled jobs, settings, keys/logins). Documented inventory: state = `.env`, `config.yaml`, `SOUL.md`, `memories/`, `sessions/` + `state.db` + `response_store.db`, `skills/`, `profiles/`, `cron/`, `hooks/`, `skins/`, `home/`, `plugins/`, `auth.json`; regenerable = `cache/` (uv re-seeds), `installs/` (PM re-resolves against each new image at boot), `logs/`. No chart-side snapshot logic — the PVC survives pod deletes (PVC ≠ pod), and import covers the disaster case.
5. **SQLite WAL is safe here.** `state.db` opens in WAL mode; upstream documents corruption only on virtiofs/9p/NFS-class mounts. local-path is node-local ext4 (both kind and the box's provisioner class) → WAL applies unchanged. Documented in the README so nobody "fixes" it later.
6. **Probes from the public route.** Startup/readiness/liveness `httpGet /health:8642` — unauthenticated by design, so no probe needs the key. The API server boots inside the s6 tree (stage2 + config migrations can take tens of seconds) → startup probe with a generous failureThreshold (30 × 10 s). When `apiServer.enabled: false` no probes render (no HTTP surface) — documented, and that mode is not the chart default.
7. **Config injection: none by default; env first, exec second.** Hermes reads config from `$HERMES_HOME/config.yaml` + `.env`; stage2 seeds starters on first boot and never overwrites existing files. The chart does **not** mount `config.yaml` (a ConfigMap mount would collide with Hermes' own config migrations, which write timestamped backups next to the file). Secrets/keys flow via `extraEnv` (direct `-e` overrides `.env`, documented upstream); model-provider config flows via `hermes config set` through exec — in the rehearsal the smoke script does this (provider `custom`, `base_url http://chudmax-engine:8080/v1`, key `none`), and real installs repeat it or write `.env` via a Secret. Minimal values is the card's word; this is where it is honored.
8. **Umbrella: `hermes.enabled: false` by default.** The dependency is wired (one `file://` entry + one values block) so the umbrella is the home, but every existing phase-6/7/8 install and proof is unchanged until hermes is explicitly enabled (phase 9's CI, phase 16's deployment values). The rehearsal installs the full umbrella with hermes enabled — which is what exercises the mcp admission rule for real.
9. **The rehearsal's proof sequence** (CI kind job, the authoritative receipt): install → ready (probe) → `config set phase9.marker` + provider config → `hermes backup` + `kubectl cp` the zip out → `kubectl delete pod` → new pod ready → marker survives → uninstall + fresh install (new PVC) → cp zip in → `hermes import` → restart → marker + provider config read back (the restore carried the whole config) → `POST /v1/chat/completions` through the Service with the bearer key → a scripted turn from the mock engine → hermes pod → tickets-mcp Service 200 (admission). Diagnostics honor the phase-6 lessons: Host header on any bridge-facing curl; one-shot pods read via `kubectl logs`, never the attach stream; `-sS -w '%{http_code}'`.
10. **Pins.** kind v0.33.0, helm 3.16.x, kubeconform (yannh) — the phase-5/6 pins; `curlimages/curl` pinned by tag for the hook; upstream image tag `v0.23.4` + digest recorded in the umbrella README pins table.

## Notes for future agents (learnings)

- **Upstream image facts (`verified-here`, v0.23.4):** Debian trixie base; s6-overlay 3.2.3.0 supervision (main-hermes, dashboard, per-profile gateways under `/run/hermes-service/`); UID 10000 default (`HERMES_UID`/`HERMES_GID` remap at boot; `PUID`/`PGID` aliases); `HERMES_HOME=/opt/data` is the `VOLUME`; `/opt/hermes` is the immutable install tree (root-owned, read-only to the runtime user; `hermes update` refuses image-owned code — replace the image); lazy installs land in `/opt/data/installs` (`security.allow_lazy_installs: false` to refuse); provenance at `/etc/hermes/image-provenance.json`; ENTRYPOINT is `entrypoint-dispatch.sh` (PID-1 → full s6; wrapped-PID-1 platforms get a degraded fallback without supervised services — in k8s the container is PID 1, so the full path applies). `CMD []` + `main-wrapper.sh` arg routing: `gateway run` as the chart's args matches the compose deployment pattern.
- **The API-server surface (v0.23.4 docs):** `POST /v1/chat/completions`, `/v1/responses`, `/v1/runs`, `/v1/models`, `/v1/capabilities`, `GET /health` (+`/v1/health`) public, `/health/detailed` authenticated. Key mandatory for every deployment. `API_SERVER_*` are env vars, not `config.yaml` keys (per-profile keys live in each profile's `.env`).
- **The Host-guard lesson transfers:** any curl against the bridge mock needs `Host: chudmax-engine`; hermes' own requests carry the Service DNS name naturally, so the config-driven path is the honest probe.
- **kubectl exec drops to UID 10000** via the image's `/opt/hermes/bin/hermes` shim — backup zips, config writes and imports from exec land with the right ownership; opt out only with `HERMES_DOCKER_EXEC_AS_ROOT=1` (never needed here).
- **Sandbox constraints:** kind cannot run in this sandbox (rootless docker, ro cgroup2 — phase 6's finding); local proofs are helm lint/template/kubeconform only; the kind job in CI is authoritative (the established precedent). The image is large — budget CI time for the pull; label the timing `speculation` until the first green run.
- **Labels:** upstream research and local renders are `verified-here`; the kind receipts are `speculation` until the CI run greens them (then re-label in proofs.md); the CoS steering, when it arrives, is `handoff-reported`.
- **Do not resurrect:** the community chart (no license, targets 0.8.0); a `runAsNonRoot` securityContext on this pod; a mounted `config.yaml`; a chart-side backup job (upstream's `hermes backup` is the mechanism); any edit to the mcp chart for admission.

## What this settles

- The three questions the card posed are answered with receipts: upstream publishes semver images (consume `v0.23.4`); the interface is the keyed OpenAI-compatible API server on 8642; the backup inventory is the whole home minus `cache/`, `installs/`, `logs/` with `hermes backup`/`import` as the mechanism.
- The mcp-chart admission question is settled by placement (one release namespace) and proven by assertion, with the standalone-install recipe documented.
- Still `speculation` after this spec: hermes' custom-provider shape against the Strata mock's `/v1/chat/completions`; CI pull/load timing for the ~1.15 GB image; `hermes import` accepting a live-gateway restart cadence — first exercised in the implementation run, re-labeled from evidence.
