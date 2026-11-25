# Design: chudmax k8s phase 4b mock ticket server

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

Scope after the major steering update (Fable's review, Kingdon's fix-before-phase-5): **one contract fixed in both places** — the canonical server (private MR) and the mock (public PR) both move to per-call reads through `current` with `repo_facts` facts from `artifact.json` read per call — plus chart hardening (F3–F6), the mock becoming the chart's default server, fetcher fixes, and CI kubeconform. Sequence: **the canonical fix defines the contract; the mock mirrors it.**

## The per-call contract (the central constraint)

```
Broken today (canonical, verified at de442410):
  main(): store = Tickets(Path(a.tickets).resolve(), revision=a.revision, …)   # L440
  - .resolve() follows current -> revisions/<hex> ONCE at startup
  - after a fetcher swap: current points at a NEW hex; the server still reads the OLD dir
  - retention (keep 3) deletes the old dir -> reads die; repo_facts still reports launch-time flags

Fixed contract (what every doc already promised — k8s/fetcher/README.md, chart values comments):
  - files open through <root>/current on EVERY call (open the path WITH the symlink, never resolved)
  - repo_facts reads <root>/current/artifact.json on every call
  - no restarts; retention pruning an old revision is invisible to a serving reader
```

**Private MR (canonical fix)** — `tools/mcp/ticket_mcp.py`: add `--data-root DIR` pod mode (per-call rereads of `DIR/current/tickets.md` + docs + `DIR/current/artifact.json`; facts from artifact.json); the resolve-at-startup is replaced by per-call opens; the old flags stay accepted (`--tickets <plain file>`, `--revision/--artifact-produced/--artifact-unpacked`) and are documented as fallbacks/overrides for a no-fetcher setup. `tools/mcp/selftest.py` stays green (the flags path is untouched) and gains a fixture-root per-call check (build revisions/ + current + artifact.json, swap, assert new facts). Same MR, docs: `kubernetes/repo-sync.md` — the narrowed artifact is served by **source-watcher's storage** (`--storage-addr`, default :9090), not source-controller (the public phase-4 README already states this correctly — the plan doc is the wrong one); the phase-5 evaluation text drops the stale "privileged runner" flag; one STATE/tickets line notes the fetcher's home is `urmanac/chudmax-mcp` (the private `k8s/fetcher` copy is frozen history — no drift management).

**Public mock** implements the same contract from day one (below); its suite carries this card's per-call proof.

## The mock (public)

Fresh single-file Python 3 stdlib implementation at `k8s/tickets-mcp-mock/ticket_mcp_mock.py` — **not a copy** of the canonical (the private source is code-only reference; no copied text; no data files). Signatures and behavioral fingerprints reproduced exactly:

- Seven tools, verbatim inputSchemas (incl. `default N` max_chars descriptions — load-bearing: the canonical selftest cross-checks advertised vs actual caps): `list_tickets`; `get_ticket(id, max_chars=3000)` middle-trim 40/60 line-aligned with omission note + `max_chars=<len> returns all`; `search_tickets(query)`; `repo_facts()`; `list_docs()`; `read_doc(name, max_chars=1500)` end-trim, resolve-based readable-set enforcement (README.md, AGENTS.md, tickets.md, docs/, decisions/, plans/); `search_docs(query, max_hits=12)`.
- `initialize` → `protocolVersion: 2024-11-05`, `capabilities.tools.listChanged: false`, `serverInfo.name: "chudmax-tickets"` (the canonical selftest asserts it), instructions. `tools/list` AND `resources/list` both answer the tools. `tools/call` → text content; unknown tool → `isError: true`; exceptions → `error: …` text; unknown method → `-32601`; notifications get no stdio reply.
- stdio: one JSON object per line; blank/unparsable lines skipped silently. HTTP: `--http PORT` (0 = OS picks), ThreadingHTTPServer, HTTP/1.1, Content-Length always; POST (any path; `/mcp` documented) → first-line-then-whole-body JSON parse; malformed → **400** `-32700`; no `id` → **202, empty body**; else **200** one object + newline; GET → **405** `Allow: POST`; startup prints `listening on <host>:<port>`.
- **Fixed contract built in:** `--data-root <root>` → per-call rereads of `<root>/current/` (tickets, docs) and `<root>/current/artifact.json` for `repo_facts` — it reports url, revision, digest, produced, unpacked, source (+ `origin_revision` when the fetcher recorded it) + tickets by status; honest answers when absent. Legacy flags accepted as fallbacks/overrides; `--data-root` wins.
- **Bearer-token option** (mcp.md specifies it; phase 1 didn't; the mock implements it as a values-driven option, default off): `--bearer-token-file PATH` — HTTP only (stdio is a local pipe); the file is read PER REQUEST (rotation without restart — same per-call spirit); `Authorization: Bearer <token>` required on POST once enabled; missing/wrong/unreadable-file → **401** (fail-closed); 202/405/400 semantics unaffected otherwise.
- CLI: `--tickets PATH` (default: bundled fixture), `--http PORT`, `--host`, `--data-root`, `--bearer-token-file`, legacy revision flags.

**Fixture** (`fixture/`, ships inside the image): synthetic `tickets.md` (canonical grammar — `## T-XXXX - Title`, `**Status/Owner/Priority/Due/Tags/Depends on/Coordination:**`, `**Purpose:**`, diary blocks; a few tickets across done/in-progress/open/blocked/wont-do, one long enough to trim), mock `STATE.md`, a couple of mock `docs/` + `decisions/` records, small `README.md`. All invented; zero original tickets; no LAN addresses/credential names/proxy hostnames (hygiene test asserts a denylist).

**Test suite** (`test_tickets_mcp_mock.py`, canonical selftest style — real subprocess, keyed-by-call results): all seven tools over both transports; 202-empty/405/400; trim fingerprints + advertised-default cross-check; per-call proof (fixture root v1 → swap to v2 without restart → prune v1 → still answers); bearer-token option (401 without/with wrong token, pass with right token, rotation); hygiene denylist.

**Dockerfile:** `python:3.12-alpine`, COPY-only (no RUN → no emulation in the manifest build), numeric non-root USER, stdio-over-fixture default entrypoint. Build: `podman build --platform linux/amd64,linux/arm64 --manifest localhost/chudmax-tickets-mock:0.1.0 -f k8s/tickets-mcp-mock/Dockerfile k8s/tickets-mcp-mock`.

## Chart hardening (public, same PR)

- **F3:** pod-level `automountServiceAccountToken: false` (the values knob moves from `server.automountServiceAccountToken` to pod level — pre-release rename, flagged in the PR); the invalid container-level field is deleted; the FETCHER container mounts a **projected volume**: `serviceAccountToken` (`path: token`, `expirationSeconds: ~3600` — short-lived, kubelet-refreshed) + the `kube-root-ca.crt` ConfigMap source (`ca.crt`) so `rest.InClusterConfig` keeps finding token + CA at `/var/run/secrets/kubernetes.io/serviceaccount`; only the fetcher mounts it. The BYO server gets no token unless the user adds one.
- **F4:** `networkPolicy.egress.sourceController.port` default 80 → **9090** (source-watcher's storage serves the generated artifact); the rule gains a **podSelector** (the serving controller's pods) alongside the namespace knob — pods of the controller, not the whole namespace.
- **F5:** apiserver egress rule defaults to the **Cilium-compatible podSelector** (apiserver static pods: namespace `kube-system` + `component: kube-apiserver` — Cilium matches policy on the resolved backend); the `ipBlock` on the service CIDR stays as a values alternative (`apiServer.mode: podSelector|cidr`, default podSelector); both documented in values comments + chart README.
- **Deviation (owner):** the mock is part of the install — `server.enabled: true` default; `server.image` defaults `ghcr.io/urmanac/chudmax/tickets-mock:0.1.0`; working default `command`/`args` (`python3 /app/ticket_mcp_mock.py`, `--http 8080 --data-root /data`); `server.port: 8080` unchanged. Fetcher image default renamed `ghcr.io/urmanac/chudmax/fetcher:0.1.0` (the `chudmax/mcp` name was confusing). BYO = override `server.*` values. README + NOTES.txt rewritten accordingly; `values.yaml` comments updated (naming, defaults, the auth option).
- **Auth option (values-driven):** `server.auth: {enabled: false, secretName: "", secretKey: "token"}` — when enabled, the chart mounts the Secret (readOnly, `/var/run/mcp-auth`) and appends `--bearer-token-file /var/run/mcp-auth/<key>`; the mock validates per request. Token VALUES never enter values — only the Secret's name.
- **Image hygiene:** pod-level securityContext (`runAsNonRoot: true`, `seccompProfile: RuntimeDefault`); both containers get `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]` (both images run uid 65532 — non-root holds). The fetcher image's alpine:3.21 bases bump to 3.22 (EOL); the CI smoke's alpine:3.21 helper likewise.
- **Kinder startup (NOTES.txt):** the fetcher no longer crash-loops pre-artifact — startup-Get NotFound retries with backoff and stays up; the chart README/NOTES say "waiting for the ExternalArtifact" instead of "exits and restarts".
- **Probes/interface:** unchanged (fetcher exec readiness on `/data/current`; no server probes — the default install's mock reads the volume; Service + ingress NetworkPolicy now render by default).

## Fetcher fixes (public, same PR)

- **F6:** `coreFlags(fs)` builds CoreOpts from pointers dereferenced BEFORE `fs.Parse` — assign after Parse (capture the pointers, parse, then fill the struct). Regression test: parse real flags (`--retries 5 --keep 2 --max-download-bytes … --max-untar-bytes …`) and assert the values reach CoreOpts.
- **Kinder startup:** in `watch.go`, the startup `Get` returns its error → `exitOn` → log.Fatal. Fix: on `apierrors.IsNotFound` retry with backoff (the resync period is the natural unit) and stay up; any other error still exits loudly. A fake-client test covers the NotFound-then-success path.
- **Origin revision → artifact.json:** watch mode already holds the ExternalArtifact object; read `ea.Status.Artifact.Metadata["org.opencontainers.image.revision"]` (verified: that is where the ArtifactGenerator writes it — `setArtifactRevisions` in source-watcher's controller; readable with the existing get/watch RBAC; for GitRepository sources the value is the revision string `main@sha1:<sha>` via the generator's fallback, so the git commit stays visible) and thread it through CoreOpts → `ArtifactMeta` gains `OriginRevision string \`json:"origin_revision,omitempty"\`` (fetch/one-shot mode has no object → omitted). `k8s/fetcher/README.md`'s contract section documents the field. Unit test: artifact.json contains `origin_revision` when set, absent when not.

## CI (public, image-chart.yml extended)

- **kubeconform** (with default k8s schemas + Flux CRD schemas) on the RENDERED chart in both value variants (mock-enabled defaults; fetcher-only) — the check that would have caught F3. Mechanics: `helm template … | kubeconform` with the Flux schemas supplied (CRD fetch or the phase-4 `flux-schema` precedent as fallback if the runner fights kubeconform's CRD handling).
- Python job: the mock suite (setup-python pinned 3.12). `mock-image` job: both-arches manifest build, arch-count verification, HTTP smoke (initialize 200 / notification 202 / GET 405 / malformed 400). Chart job: template the two variants. Go jobs: fetcher vet/test (gains the new regression tests) + both-arches build — all existing jobs stay green. No push anywhere.

## The two PR-description answers (Fable's questions, pre-drafted)

**(a) The bearer token:** `kubernetes/mcp.md` DOES specify it ("A bearer token in the hub's `headers`, from a Secret, so reaching the port is not enough by itself. It identifies a caller (the harness), not a person"). Phase 1 did NOT implement it — the canonical HTTP handler and selftest have no auth check (`verified-here`, code read). The mock implements it as a values-driven option (`server.auth.*` → Secret-mounted file read per request; default off), so the out-of-the-box install is unchanged and a hub-facing deployment can turn it on.

**(b) The narrowed artifact's revision:** it is the content hash (phase-4's recorded caveat). The git commit is NOT lost: source-watcher exposes the origin revision as `status.artifact.metadata["org.opencontainers.image.revision"]` on the generated ExternalArtifact (readable with the fetcher's existing get/watch RBAC — no new verbs), and for a GitRepository source the generator's fallback writes the GitRepository revision string (`main@sha1:<sha>`) when the upstream artifact carries no such annotation (current source-controller does not). The fetcher now records it in artifact.json as `origin_revision`; `repo_facts` surfaces it. If a future platform drops the annotation, the field is simply absent — the limitation is documented, not silent.

## Repo layout (public)

```
k8s/tickets-mcp-mock/            NEW: ticket_mcp_mock.py, fixture/, test suite, Dockerfile, README.md
k8s/fetcher/main.go, watch.go, core.go, core_test.go, watch_test.go, README.md   F6 + kinder startup + origin_revision + contract field
k8s/image/Dockerfile             alpine 3.21 -> 3.22
k8s/chart/chudmax-mcp/           values.yaml (defaults: mock on, naming, auth knob, egress fixes), templates
                                 (deployment F3 + securityContext, networkpolicy-egress F4/F5, NOTES.txt), NEW README.md
README.md                        naming, mock-by-default, build commands
.github/workflows/image-chart.yml  kubeconform rendered (both variants), mock test + image jobs
```

## Notes for future agents (learnings)

- **The canonical quirks are the signature — keep them:** resources/list answers with the tools list; POST accepted on any path; protocolVersion `2024-11-05`; 202 bodies truly empty; tickets trim MIDDLE (40/60), docs trim END; the `default N` schema wording is load-bearing; `serverInfo.name == "chudmax-tickets"` is asserted by the canonical selftest.
- **The per-call contract is THE contract:** never `Path.resolve()` a `current` path at startup; open the symlink path per call; artifact.json per call. The proof shape (v1 → swap v2 no restart → prune → still answers) is this card's test; phase 5 repeats it with real commits.
- **Origin revision:** annotation key `org.opencontainers.image.revision`, in `status.artifact.metadata` (source-watcher `setArtifactRevisions`; code falls back to the source's Revision string — the API doc comment's "field is ignored" is stale); object-level annotations carry only commonMetadata; get/watch RBAC suffices to read it.
- **F3's CA gotcha:** with pod-level automount off, a projected `serviceAccountToken` alone is not enough for `rest.InClusterConfig` — it reads token + ca.crt from the standard dir; add the `kube-root-ca.crt` ConfigMap source to the projection and mount at `/var/run/secrets/kubernetes.io/serviceaccount`.
- **Egress under Cilium:** ipBlock on the service CIDR is unreliable (Cilium resolves the apiserver to backends); the podSelector-on-static-pods pattern is the default; ipBlock stays as the alternative knob.
- Public-mirror discipline: no LAN addresses, credential names, or internal proxy hostnames in the public repo (Secret NAMES are metadata; token VALUES never enter values); three labels on every claim; `helix-specs` is fast-forward-only.
- PR flow: propose freely via `propose_pull_request` (no approval wait); CI green + in-sandbox verification before merge; merge authority CoS/owner; `mark_task_complete` only after the public PR merges; conventional commits; LICENSE flag rides in the PR description.

## Implementation notes (2026-11-25, sandbox — all `verified-here`)

- **My own suite caught a real bug in my first mock draft:** `ticket_text()` read the bundled
  fixture path even in `--data-root` mode — after a swap, `repo_facts` updated but the ticket
  CONTENT stayed stale. The per-call test (swap → assert content change) found it before any
  commit left the sandbox. Lesson: the contract test must assert on BOTH the facts and the
  content across a swap, not the facts alone.
- **The `--host 0.0.0.0` deployment gotcha:** the mock's default HTTP host is 127.0.0.1
  (canonical-compatible for local dev), which is unreachable through a port forward — and in a
  pod, the Service reaches the POD IP, not the container's localhost. The chart's default args
  pass `--host 0.0.0.0`; any BYO HTTP server needs the same. Caught by the amd64 container smoke
  (curl through `-p` got connection-refused until the host was widened).
- **kubeconform is the F3 check, proven:** `kubeconform -strict` on the rendered chart validates
  7 + 5 resources in the two variants; the negative probe (the old container-level
  `automountServiceAccountToken` shape) is rejected with `additionalProperties not allowed`. The
  chart renders ONLY core k8s kinds, so default schemas suffice — no Flux CRD schema plumbing
  needed for the chart (the repo-sync manifests' flux-schema validation is its own workflow).
- **Sandbox toolchain does not persist between sessions:** podman/skopeo/qemu were gone; podman
  5.4.2 + qemu-user-static reinstalled via apt in minutes. The phase-3 gotchas reproduced
  exactly: binfmt denied (no arm64 containers run), `podman create --platform <manifest-list>`
  grabs the amd64 instance (dodge: create from the image ID that `podman pull --platform`
  recorded, then export). Arm64 runtime proof for the mock: `qemu-aarch64 -L <arm64-rootfs>
  <rootfs>/usr/local/bin/python3.12 ticket_mcp_mock.py` — a full stdio tools/list run, no binfmt
  needed for DIRECT qemu invocation.
- **The private MR via the GitLab commits API:** one POST per commit with `actions: [{action:
  update, file_path, content}]` — and the JSON body NEEDS `Content-Type: application/json`
  (without it the API parses the body as form fields and answers `branch is missing`). Branch
  content re-fetched afterward and diffed byte-identical against the locally validated tree.
- **Boundary gotcha for trim assertions:** the server's parsed ticket block ends at the next
  heading's LINE START (keeping the newline), while a naive `find("\n## ")` helper cuts before
  it — the fixture-side reader must use `nxt + 1` or the `max_chars=N returns all` fingerprint
  mismatches by exactly one character.
- **The canonical selftest's checks transfer cleanly** to a fresh implementation: keyed-by-id
  results, the trim-note regex, the advertised-default cross-check — the mock's suite is the
  same species with pod-mode + auth + hygiene checks added.
- **Integration-shaped testing catches what unit tests with absolute paths miss** (Fable's
  method, now proven twice): the read_doc pod-mode bug survived the first wave's suites because
  both exercised pod mode with fixture roots in absolute paths and checked FACTS across the
  swap — but the bug lived in the `relative_to` between an unresolved base and a resolved
  candidate, i.e. in `read_doc`, and only showed when a scratch copy + fake fetcher volume +
  the REAL launch flags were run. The suites now carry the two shapes forever: (1) a
  relative-launch case — cwd = repo root, relative `--tickets tickets.md` (the `.pi/mcp.json`
  shape) — exercising `read_doc AGENTS.md` + `list_docs`; (2) pod-mode `read_doc` before/after
  a revision swap and after the prune, with the doc CONTENT asserted and the refusal asserted
  absent. The canonical fresh-clone run is the stronger receipt: the relative-launch check
  answered with the REAL AGENTS.md content and indexed 31 real docs — the scratch-copy run
  only proved the shape.
- **Per-call snapshot shape (Fable's, both servers now):** resolve `current` ONCE at the START
  of each call and read the whole call through that resolved directory — one call never mixes
  two revisions, a mid-call swap is invisible until the next call, and `relative_to` works
  because base and candidate resolve the same way. Plain-file mode is the opposite: resolve
  at STARTUP (no symlink churn behind a plain path — and the startup resolve is exactly what
  makes a relative `--tickets` work from any cwd).
- **Scope flip (owner, 2026-11-25): publish the canonical, drop the mock.** The public
  `k8s/tickets-mcp/` carries the private server's `ticket_mcp.py` + `selftest.py`
  BYTE-EXACT — which forced the canonical dir shape to transplant (`tools/mcp/` under
  `k8s/tickets-mcp/`, because the selftest hardcodes `ROOT = parents[2]` and
  `SERVER = ROOT/tools/mcp/ticket_mcp.py`), plus synthetic test-only fixtures at the
  subtree root. Sequence honored: every canonical change landed in MR !20 FIRST
  (bearer `8c5a1929`, freeze note `e83a3c4c`, _find_root `82775933`, 202 framing
  `7e7375d4`), then was re-published byte-exact (hash-verified) — the canonical defines
  the contract; the public copy never diverges.
- **The published subtree broke `_find_root` — and the fix is a marker, not a copy:**
  `_find_root` walked up to the first `.git`, so a fixture subtree inside the public
  checkout resolved its readable set to the ENCLOSING repo root (1-doc index, AGENTS.md
  refused). Fix (canonical `82775933`): the walk also stops at `STATE.md` beside
  `tickets.md` — the complete-chudmax-tree marker. The private repo root carries both
  markers, so private behavior is unchanged (32→33 checks green on both trees). Lesson:
  any published subtree of a git repo needs its own tree marker, and the selftest's
  relative-launch + list_docs checks are exactly what caught it.
- **The unframed HTTP 202 hung every keep-alive client — and the urllib selftest could
  not see it:** the canonical answered a notification POST with a bare `202` (no
  Content-Length); HTTP/1.1 keep-alive clients read an unframed body until close and
  hang (curl did, in the container smoke). The selftest never caught it because urllib
  sends `Connection: close` and reads to EOF happily. Fix (canonical `7e7375d4`): the
  202 now carries `Content-Length: 0`; the regression probe uses `http.client` (which
  speaks keep-alive) and asserts the framing — a probe the old check structurally could
  not be. The mock had the framing right all along; the divergence only became visible
  when one contract replaced two.
- **Podman manifest pollution:** rebuilding an image while a container still holds the
  old one makes `podman rmi <manifest>` fail SILENTLY (output redirected), the rebuild
  then ADDS instances to the existing manifest (2x amd64 + 2x arm64), and
  `podman run <manifest>` grabs the STALE instance — the smoke then proves the OLD
  code while `podman exec` greps the NEW file (the contradiction that ate an hour).
  Clean procedure: `podman rm -f` the holder, `rmi -f` the manifest by ID, rmi every
  `<none>` instance, ONE fresh build, then verify the manifest lists exactly one
  instance per arch BEFORE running anything. And for arch-specific runs, resolve the
  instance image in local storage by `podman inspect --format {{.Architecture}}` —
  `podman pull --platform localhost/...` hits the registry (localhost is a registry
  hostname) and fails rootless.
