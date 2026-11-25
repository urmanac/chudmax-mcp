# Implementation Tasks: chudmax k8s phase 4b mock ticket server

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

**Setup + contract verification**

- [x] Branch off public `main` — **done: `feature/000908-chudmax-k8s-phase-4b`** (the Helix task branch; the harness's naming), created off the CURRENT `main` — **phase 4 merged while planning: `main` = `4a414d7`** (repo-sync manifests + flux-schema workflow landed); `origin/main` merged in, `mergeable` — conventional commits; the box untouched
- [x] Re-verify the canonical, code-only — **done (`verified-here`, 2026-11-25, twice during planning):** `kingdonb/chudmax` `main` head = `de442410` (API commit check at implementation start); `tools/mcp/ticket_mcp.py` blob `5e3d09ca` + `tools/mcp/selftest.py` blob `9bb6b883` read in full; findings 1+2 confirmed (L440 `Tickets(Path(a.tickets).resolve(), revision=a.revision, …)` — symlink resolved once, revision static); seven-tool surface confirmed; no head movement — no adjustment needed

**Private MR (canonical fix — GitLab API; the human merges there)**

- [ ] Propose the private MR branch (conventional commits): fix `tools/mcp/ticket_mcp.py` — add `--data-root DIR` pod mode with per-call rereads (`DIR/current/tickets.md`, docs, `DIR/current/artifact.json` for `repo_facts`), stop resolving the symlink at startup, keep `--tickets`/`--revision`/`--artifact-produced`/`--artifact-unpacked` accepted and documented as fallbacks/overrides for a no-fetcher setup
- [ ] Same MR: extend `tools/mcp/selftest.py` with a per-call artifact.json check (fixture root: revisions/ + `current` + artifact.json, swap mid-run, assert new facts) — selftest stays green overall (counts are derived from `tickets.md`)
- [ ] Same MR: correct `kubernetes/repo-sync.md` (the narrowed artifact is served by source-watcher's storage, NOT source-controller), drop the stale "privileged runner" flag from the phase-5 evaluation text, and add one STATE/tickets line noting the fetcher's home is now `urmanac/chudmax-mcp` (private `k8s/fetcher` copy = frozen history, no drift management)

**The mock (public)**

- [ ] Write `k8s/tickets-mcp-mock/ticket_mcp_mock.py` — FRESH single-file stdlib Python (no copied code text) implementing the FIXED contract: the seven tools with verbatim inputSchemas (keep `default N` descriptions), initialize `2024-11-05` + `serverInfo.name: "chudmax-tickets"`, tools/list + resources/list quirk, tools/call text results (unknown tool `isError`, exceptions as text, `-32601`), stdio line transport (blank/unparsable skipped), HTTP (POST → 200 one JSON object, notification → 202 empty, GET → 405 `Allow: POST`, malformed → 400 `-32700`, `listening on <host>:<port>`), middle-trim tickets (40/60, omission note + `max_chars=N returns all`), end-trim docs, resolve-based readable set
- [ ] Pod mode `--data-root <root>`: every call rereads `<root>/current/` (tickets, docs) and `<root>/current/artifact.json` for `repo_facts` (url, revision, digest, produced, unpacked, source, origin_revision when present, tickets by status); honest answers when absent; legacy revision flags accepted as fallbacks (`--data-root` wins)
- [ ] Bearer-token option: `--bearer-token-file PATH` — HTTP only, token file read PER REQUEST, `Authorization: Bearer` enforced once set (missing/wrong/unreadable → 401, fail-closed), stdio unaffected, default off
- [ ] Write `fixture/`: synthetic `tickets.md` (few tickets across done/in-progress/open/blocked/wont-do, one long enough to trim), mock `STATE.md`, a couple of mock `docs/` + `decisions/` records, small `README.md` — canonical grammar, nothing from the private repo
- [ ] Write `test_tickets_mcp_mock.py` (subprocess, keyed results): all seven tools over BOTH transports, 202-empty/405/400, trim fingerprints + advertised-default cross-check, the per-call proof (fixture root v1 → swap to v2 WITHOUT restart → prune v1 → still answers), bearer-token checks (401 / pass / rotation), hygiene denylist (no LAN-shaped addresses, token-ish strings, real hostnames)
- [ ] Run the suite in this sandbox until exit 0; record the receipt in this task directory with the three labels
- [ ] Write `k8s/tickets-mcp-mock/Dockerfile` (python:3.12-alpine, COPY-only — no RUN, numeric non-root USER, stdio default entrypoint) and `k8s/tickets-mcp-mock/README.md` (what it is / what it is not; the bearer option; the fixed contract)
- [ ] Podman proof in-sandbox: `podman build --platform linux/amd64,linux/arm64 --manifest localhost/chudmax-tickets-mock:0.1.0 -f k8s/tickets-mcp-mock/Dockerfile k8s/tickets-mcp-mock`; both arches verified in the manifest; amd64 HTTP smoke (initialize 200 / notification 202 / GET 405 / malformed 400); arm64 best-effort per the phase-3 precedent (binfmt denied in this sandbox — host-side qemu exec is the proven workaround)

**The fetcher (public, same PR)**

- [ ] F6: fix `coreFlags` in `k8s/fetcher/main.go` to assign CoreOpts AFTER `fs.Parse`; regression test parses real flags (`--retries/--keep/--max-download-bytes/--max-untar-bytes`) and asserts the values reach CoreOpts
- [ ] Kinder startup: `watch.go` startup-Get NotFound → retry with backoff and stay up (other errors still exit loudly); fake-client test covers NotFound-then-success; update NOTES.txt (waiting, not crash-looping)
- [ ] Origin revision: watch mode reads `status.artifact.metadata["org.opencontainers.image.revision"]` → CoreOpts → `ArtifactMeta.OriginRevision` (`json:"origin_revision,omitempty"`); unit test (present when set, absent when not); `k8s/fetcher/README.md` documents the field (fetch/one-shot mode omits it)

**The chart (public, same PR)**

- [ ] F3: pod-level `automountServiceAccountToken: false` (values knob moves to pod level — rename flagged in the PR), invalid container-level field removed; fetcher container gets a projected volume (serviceAccountToken `path: token` + kube-root-ca.crt ConfigMap source, mounted at `/var/run/secrets/kubernetes.io/serviceaccount`); only the fetcher mounts it
- [ ] F4: egress `sourceController.port` default → 9090 and the rule scoped to the serving controller's PODS (podSelector + namespace knob); values knobs stay
- [ ] F5: apiserver egress defaults to the Cilium-compatible podSelector (apiserver static pods, `component: kube-apiserver`, namespace knob default `kube-system`); ipBlock on the service CIDR stays as the alternative (`apiServer.mode: podSelector|cidr`); both documented in values comments + chart README
- [ ] Deviation: `server.enabled` default TRUE; `server.image` defaults to `ghcr.io/urmanac/chudmax/tickets-mock:0.1.0` (unpublished — build-it-yourself note); working default command/args (`--http 8080 --data-root /data`); fetcher default renamed `ghcr.io/urmanac/chudmax/fetcher`; values comments + root README + NOTES.txt rewritten (BYO = override `server.*`; the auth option: `server.auth.{enabled,secretName,secretKey}` mounting the Secret readOnly at `/var/run/mcp-auth` and appending `--bearer-token-file`)
- [ ] Image hygiene: pod-level securityContext (runAsNonRoot, seccomp RuntimeDefault) + both containers `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]`; bump `k8s/image/Dockerfile`'s alpine 3.21 → 3.22 (and the CI smoke helper)
- [ ] Write `k8s/chart/chudmax-mcp/README.md` (created; docs-only): the default install (mock in pod mode), the BYO override example, the auth option, the waiting-not-crashlooping behavior, the egress knobs; `helm lint` + `helm template` (mock-enabled defaults + fetcher-only variant) pass locally

**CI (public)**

- [ ] Extend `.github/workflows/image-chart.yml`: kubeconform (Flux + k8s schemas) on the RENDERED templates in both value variants (fallback: the phase-4 flux-schema precedent); Python job for the mock suite (setup-python pinned 3.12); `mock-image` job (both arches, arch-count check, HTTP smoke, no push); Go jobs gain the new fetcher tests; all existing jobs stay green

**Delivery**

- [ ] Update the root `README.md` (mock-by-default, new image names, build commands for BOTH images, chart README pointer); leave no stale `chudmax/mcp` references
- [ ] Propose the public PR via `propose_pull_request` (no approval wait) with the two Fable answers in the description: (a) bearer token — specified in `kubernetes/mcp.md`, NOT implemented by phase 1, implemented by the mock as a values-driven option; (b) origin revision — exposed via `status.artifact.metadata["org.opencontainers.image.revision"]` (GitRepository fallback writes the revision string), so the fetcher records `origin_revision` in artifact.json; include the LICENSE flag line and the values-knob rename note; three labels on all claims; CI green + in-sandbox verification recorded in this task directory; merge by CoS/owner (the private MR merges separately by the human)
- [ ] Call `mark_task_complete` only after the public PR merges
