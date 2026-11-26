# Requirements: chudmax k8s phase 9 Hermes chart with persistent home

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 9 (`kubernetes/phases.md`, SPIKE row I; source `design/tasks/000888_fetch-mr-17/design.md`): **our own Hermes chart — minimal values; installs on kind against the mock engine; its HERMES_HOME volume (local-path provisioner) survives a pod delete; a restore onto an empty volume works.** One Deployment with `Recreate`, no k8s API token, no host mounts. Depends on phase 6 (engine + web charts, umbrella, kind rehearsal). The community Hermes chart is **not used** (targets 0.8.0, no LICENSE — `handoff-reported`): the chart is ours, minimal, and consumes the **upstream-published image**. This phase must answer three questions, all answered below with upstream receipts (2026-11-26, `verified-here` from this sandbox against `github.com/NousResearch/hermes-agent` at tag `v0.23.4` and the Docker Hub registry API).

## The three questions, answered

1. **Does upstream publish a semver-tagged image? Yes.** Docker Hub `nousresearch/hermes-agent` publishes immutable version tags as multi-arch (amd64+arm64) manifest lists — `v0.23.4` pushed 2026-11-24, manifest-list digest `sha256:ef0650d5…` (slim) and `v0.23.4-desktop` digest `sha256:d7f13dd6…` — plus channel tags `stable` (= `v0.23.4` digest), `latest`, `main`, `canary.<stamp>-vX.Y.Z`, per-arch (`v0.23.4-amd64`/`-arm64`) and rc tags (`rc.2-v0.23.4`). The v0.23.4 tree carries the Dockerfile and the s6-overlay supervision layout; the release path publishes tested, never-rebuilt archives. The chart therefore consumes `nousresearch/hermes-agent:v0.23.4` directly — **no image is built in this phase** (the first parts-phase with no image of its own). The chart carries a digest-pinning knob (upstream docs: "use a digest for an exact deployment pin").
2. **Which interface to expose? The OpenAI-compatible API server on port 8642** — the one programmatic HTTP surface designed for external clients (Open WebUI, LobeChat, any `/v1/` client), gated by `API_SERVER_ENABLED=true` + `API_SERVER_HOST=0.0.0.0` + a mandatory `API_SERVER_KEY` (min 8 chars, required for every deployment), with an **unauthenticated `GET /health`** for probes. The dashboard (9119) and the webapp (9120) are browser surfaces that **fail closed** on non-loopback binds without an auth provider (the June 2026 hardening — an unauthenticated dashboard was the entry point of the MCP-config persistence campaign) — chart-default **off**, documented knobs. The TUI/CLI is interactive only: reached via `kubectl exec` (the image's exec shim drops to UID 10000), never a Service. The messaging gateway (Telegram etc.) is an egress surface, not an ingress one — nothing to expose.
3. **What exactly in HERMES_HOME must be backed up?** `HERMES_HOME` is `/opt/data` in the container (`~/.hermes` on a host install). **State that must survive: the whole agent home minus the regenerable trio.** Sanctioned mechanism (used by the proof): `hermes backup -o <zip>` → `hermes import <zip>` — the upstream backup captures "the whole Hermes home: every profile, memory, persona, skills, conversations, scheduled jobs, settings, and your keys and logins (`.env`, `auth.json`)". Inventory: `.env`, `config.yaml`, `SOUL.md`, `memories/` (USER.md, MEMORY.md), `sessions/` + `state.db` (SQLite, WAL) + `response_store.db`, `skills/`, `profiles/` (incl. per-profile `.env` and `gateway_state.json`), `cron/`, `hooks/`, `skins/`, `home/` (per-profile HOME for tool subprocesses — `.ssh`, `.gitconfig`, skill-CLI credentials), `plugins/`, `auth.json`. **Regenerable, not backed up:** `cache/` (uv cache re-seeded from the image), `installs/` (PM dependency generations re-resolved at boot against the new image's lock), `logs/` (runtime).

## Preconditions

- [x] Phase 6 delivered per its task record (`000893`): umbrella `k8s/umbrella/chudmax/` with in-tree engine/web subcharts, the `file://` mcp reference, `umbrella-kind.yml`, the mock-engine-on-the-bridge rehearsal pattern — assume on `main`; verify at implementation start and rebase if the branch is still open.
- [x] Upstream receipts (`verified-here`, 2026-11-26): Docker Hub `nousresearch/hermes-agent` tags as listed above (388 tags total, actively published); `v0.23.4` = `stable`; repo MIT; image is stateless with all user state in `/opt/data`; runtime user UID 10000; s6-overlay supervision; API-server env contract as listed in design.md.
- [x] `hermes backup` / `hermes import` contract (`verified-here` from `website/docs/user-guide/backup-and-transfer.md` at v0.23.4).
- [x] kind ships the `local-path` StorageClass (`standard`, provisioner `rancher.io/local-path`) — the rehearsal's provisioner is the card's named one; the chart takes a `storageClass` values knob (empty = cluster default).
- [ ] The sandbox cannot host kind (rootless docker, read-only cgroup2 — the phase-6 finding) — the kind steps' authoritative receipt is the CI kind job, everything renderable proven locally. Plan accordingly.

## Parallel-work boundaries (hard)

- Phases 7 (canary rehearsal) and 8 (image automation rehearsal) may run in parallel (spike order: I ∥ G/H). Phase 9's write set — `k8s/chart/chudmax-hermes/**`, a new `.github/workflows/hermes-kind.yml`, minimal additions to `k8s/umbrella/chudmax/Chart.yaml` + `values.yaml` + README, and this task dir — is disjoint from any canary/automation rehearsal set. The umbrella Chart.yaml/values are the only shared-ish surface: keep the addition to one dependency entry + one values block; rebase if a conflict arises.
- The umbrella's default values keep `hermes.enabled: false` — phases 6/7/8's installs and proofs are byte-identical before and after this phase.
- `k8s/chart/chudmax-mcp/` is **read-only** (the mcp chart's NetworkPolicy question is settled by placement, not by editing the chart — see the mcp-admission decision).

## User stories

1. **As the human**, I want the Hermes chart to consume the upstream semver-tagged image (`nousresearch/hermes-agent:v0.23.4`) so chudmax's agent rides upstream releases instead of a fork we maintain — with a digest knob for exact pins, and the community chart's non-license recorded as the reason we didn't take it.
2. **As the human**, I want exactly one HTTP surface exposed — the keyed OpenAI-compatible API server on 8642 — because that is the interface chudmax's ecosystem (and phase 16's "answering from chudmax's model") actually speaks, while the auth-gated dashboard/webapp stay off by default and the TUI stays reachable only by exec.
3. **As the human**, I want HERMES_HOME on a PVC (local-path in rehearsal) that survives a pod delete, and a documented backup/restore story (`hermes backup` → `hermes import`) proven onto an empty volume — so an agent's soul, memory, sessions, skills and credentials outlive any pod.
4. **As the rehearsal**, I want the umbrella to install hermes beside the mock engine on kind, hermes configured (rehearsal-only) to answer through the engine Service (`http://chudmax-engine:8080/v1`), and a chat completion through the hermes API server to return the mock engine's scripted turn — the production shape (pod → Service → external engine) exercised end to end.
5. **As the rehearsal**, I want the mcp chart's ingress NetworkPolicy to admit hermes **by construction** — hermes installs into the same release namespace the policy already admits — with a proof (a request from the hermes pod to the tickets-mcp Service) and no edits to the mcp chart.
6. **As CI**, I want `hermes-kind.yml` to re-prove everything: lint/template/kubeconform (defaults + rehearsal variant), the umbrella install with hermes enabled, the pod-delete survival, the restore-onto-empty-volume, the mock-engine chat, and the mcp-admission check.
7. **As the human**, I want the standing hygiene: box untouched, no registry push, no credential or LAN address in any public artifact (the API key is a rehearsal-only non-secret in CI values, real keys enter via Secrets at placement), three labels on every claim, conventional commits, merge authority CoS.

## Acceptance criteria

**Write set and hygiene (hard)**
- [ ] Phase 9 touches only `k8s/chart/chudmax-hermes/**`, `.github/workflows/hermes-kind.yml`, the umbrella's `Chart.yaml`/`values.yaml`/`README.md` (one dep + one values block + pins note), and this task dir. `k8s/chart/chudmax-mcp/`, the engine/web subcharts, and every other workflow untouched.
- [ ] No API key, no LAN address, no credential material in any chart default, README, workflow, or test assertion. The rehearsal's key is a clearly-labeled non-secret test string; real keys enter via `apiServer.existingSecret` at placement.
- [ ] Pod-level `automountServiceAccountToken: false`; no `hostPath`/host mounts anywhere; no RBAC objects.

**Hermes chart (`k8s/chart/chudmax-hermes/`)**
- [ ] Chart.yaml (v2, `chudmax-hermes`, 0.1.0, appVersion `0.23.4`): one Deployment (`strategy.type: Recreate`; documented why — never two gateways on one data directory; SQLite WAL + single-writer state), one Service (port 8642 → `apiServer.port`), one PVC (RWO, default 2Gi, `storageClass` empty = cluster default), an optional chart-created Secret for the API key, and a Helm test hook (pinned `curlimages/curl`) hitting `/health` → 200 plus authenticated `/v1/models` → 200 with the key from the Secret.
- [ ] Image values: `repository nousresearch/hermes-agent`, tag `v0.23.4`, `pullPolicy: IfNotPresent`, optional `digest` knob (empty default — documented for exact pins). No image build anywhere in this phase.
- [ ] Env wiring: `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, `API_SERVER_PORT=8642`, `API_SERVER_KEY` from the Secret — only when `apiServer.enabled: true` (default true with the key required; a template guard fails the render with a clear message when the key is missing); `extraEnv` passthrough for everything else (HERMES_UID/GID, provider keys, `API_SERVER_CORS_ORIGINS`).
- [ ] Probes: startup + readiness + liveness `httpGet /health` on 8642 (the public cheap route, no auth) — only when the API server is enabled; no probes rendered when it is off (documented).
- [ ] **No `runAsNonRoot`** — the documented deviation from the 4b pattern: the image is root-then-drop by design (s6 stage2 chowns the volume and remaps UID at boot, then every supervised service runs as UID 10000). `seccompProfile: RuntimeDefault` kept; no `capabilities.drop: ALL` (it would break the stage2 chown/setuid window); `securityContext` passthrough for operators who accept the consequences.
- [ ] Values stay minimal: image, apiServer (enabled/port/key/existingSecret), storage (size/storageClass), resources (requests 500m/1Gi, limits 4Gi), `terminationGracePeriodSeconds` (default 60 — SIGTERM drain), `extraEnv`, `securityContext` passthrough. Dashboard/webapp exposed as documented `extraEnv` recipes, not first-class knobs.
- [ ] README: the three answered questions, the HERMES_HOME inventory (state vs regenerable), the backup/restore recipe (`hermes backup` / `hermes import` via exec), the exec-drop note, the namespace/admission note for standalone installs.
- [ ] `helm lint` + `helm template` ×2 (defaults; rehearsal variant with key + storage class) + kubeconform — locally and in CI.

**Umbrella integration**
- [ ] `Chart.yaml`: one `file://../../chart/chudmax-hermes` dependency, condition `hermes.enabled` — **default false** in values (existing proofs unchanged); the phase-9 CI enables it.
- [ ] README pins table gains the Hermes row: upstream image `v0.23.4` + digest, the namespace/admission note, and the phase-16 pointer (Hermes beside the real engine, answering from chudmax's model).

**Kind rehearsal (`hermes-kind.yml`, CI-authoritative)**
- [ ] Chart job: per the lint/template/kubeconform bar above.
- [ ] Kind job: pull the upstream image → `kind load image-archive` (no registry dependency at install time beyond the pull) → full umbrella install with `hermes.enabled=true`, engine endpoint = the docker-bridge gateway (the phase-6 ladder), rehearsal API key set → hermes pod ready (probe passing) → **state + pod-delete**: `kubectl exec hermes config set phase9.marker …` → backup zip exec'd + `kubectl cp` out → `kubectl delete pod` → new pod ready → marker reads back (volume survived) → **restore onto empty volume**: uninstall hermes → fresh install (new PVC) → `kubectl cp` zip in → `hermes import` → restart → marker reads back AND the provider config survived (the import carried it) → **mock-engine chat**: `POST /v1/chat/completions` through the hermes Service with the bearer key → a non-empty assistant turn sourced from the mock engine → **mcp admission**: a request from the hermes pod to the tickets-mcp Service answers 200 (the same-namespace rule admits hermes).
- [ ] The mock-engine reachability ladder uses the Host-header lesson (`Host: chudmax-engine` — a bare-IP probe reads as a guard 403, not a network failure).

**Proofs and flow**
- [ ] Proofs recorded in this task dir with the three labels: render receipts; the kind receipts (install, pod-delete, restore, chat, admission); honest `speculation` labels on first-run mechanics (hermes' custom-provider shape against the Strata mock; CI pull/load timing of the ~1.15 GB image).
- [ ] One PR via `propose_pull_request` (no approval wait) from a feature branch off current `main`; conventional commits; box untouched; no registry push; merge authority CoS; `mark_task_complete` only after merge.

## Out of scope (owned by other phases or decisions)

- Any image build or fork of hermes-agent (upstream image consumed as published).
- The dashboard/webapp auth-provider wiring and any browser surface — knobs documented only.
- Wiring hermes' MCP hub to the tickets-mcp server, and phase 16's real placement (Hermes beside the real engine on the human's cluster).
- Publishing the chart/image (phase 10 — the human names the hermes repo); image automation for the upstream tag (phase 8's automation is for chudmax images; upstream tag bumps are manual).
- The secrets mechanism for real API keys (SOPS/External Secrets — open item 6, human decision); NetworkPolicies on the hermes chart (placement, phases 12/15 — same reasoning as the web chart).
- The box (untouched), mTLS (17), the web/engine split (15).

## Open Questions

1. **Upstream tag bump cadence** — hermes' image tag moves fast (`canary.*` stamps daily; `stable` = `v0.23.4` as of 2026-11-26). Is a manual, human-driven tag bump (chart values + README pin) the accepted policy, or should phase 10's image-automation be extended to propose upstream-tag bumps as review branches too? Not blocking phase 9 (manual default).
2. **Dashboard/webapp at phase 16** — the chart ships them off by default with documented enable recipes. If the human wants the dashboard reachable at placement, an auth provider (basic-auth or OIDC) must be chosen then — chart knob, not this phase's decision.
3. **Chart repo name for phase 10** — the spike leaves "the hermes repo" to be named by the human (publishing milestone). Phase 9's in-tree chart name (`chudmax-hermes`) assumes the published chart follows; confirm at phase 10.
