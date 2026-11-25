# Requirements: chudmax k8s phase 4b mock ticket server

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

T-0037 phase 4b (owner direction 2026-11-25; **major steering update** after Fable's code review — F3–F6 verified against the public repo, findings 1+2 verified in the canonical): Kingdon says fix before phase 5. The card's scope grows; **the per-call contract becomes the central design constraint**: files open through `current` on EVERY call, and `repo_facts` facts come from `artifact.json` read per call.

**One contract, fixed in both places:**

1. **Canonical fix — private repo MR** (GitLab API; the human merges there): fix `tools/mcp/ticket_mcp.py` — per-call reread through the symlink; facts from `artifact.json` per call; keep the old flags accepted but documented as fallbacks/overrides for a no-fetcher setup. Same MR: correct `kubernetes/repo-sync.md` (the narrowed artifact is served by source-watcher, NOT source-controller — the public phase-4 README already has this right; the plan doc is wrong), drop the stale "privileged runner" flag from the phase-5 evaluation text, add one STATE/tickets line noting the fetcher's home is now `urmanac/chudmax-mcp` (the private `k8s/fetcher` copy is frozen history — no drift management, just the note).
2. **The mock — public PR:** implements the FIXED contract from day one (per-call reads, artifact.json facts). Signature compatibility means the FIXED canonical's surface — tool names, params, response shapes, transports, the artifact.json contract. Sequence: the canonical fix defines the contract; the mock mirrors it.

**Chart hardening (same public PR, all findings verified):** F3 (invalid container-level `automountServiceAccountToken`), F4 (egress port/podSelector), F5 (Cilium-compatible apiserver rule), the owner's deviation (**the mock is part of the Helm install** — `server.enabled` defaults TRUE with the mock image; naming splits to `ghcr.io/urmanac/chudmax/fetcher` and `ghcr.io/urmanac/chudmax/tickets-mock`), pod-level securityContext + alpine off 3.21 (EOL), F6 (the fetcher's flag bug), kinder startup, and CI kubeconform against rendered templates.

Everything happens in `urmanac/chudmax-mcp` (public PR) plus one private MR on `kingdonb/chudmax` (GitLab API, human merges). Public `main` @ `67d8616` (phases 2–4 merged). No registry push (ghcr.io is phase 10). The box is untouched; nothing lands on `main` unreviewed; conventional commits; the three labels on every claim.

## Preconditions (verified, 2026-11-25)

- [x] **Findings 1+2 confirmed in the canonical** (`kingdonb/chudmax` `main` @ `de442410`, still the head; `tools/mcp/ticket_mcp.py` blob `5e3d09ca`, fetched read-only): `main()` L440 does `Tickets(Path(a.tickets).resolve(), revision=a.revision, …)` — the `current` symlink is resolved ONCE at startup and `--revision` is captured once at launch, so after a fetcher swap the server reads the stale tree (which retention deletes) and `repo_facts` never sees new facts (`verified-here`).
- [x] **F3 confirmed:** `k8s/chart/chudmax-mcp/templates/deployment.yaml` L63 sets `automountServiceAccountToken` on the server CONTAINER — the field is pod-level only; a real install with `server.enabled=true` would be rejected (`verified-here`).
- [x] **F4/F5 confirmed:** egress template — `sourceController.port` default 80 with a namespace-only selector; apiserver rule is an `ipBlock` on the service CIDR (`values.yaml` `apiServer.cidr: 10.96.0.0/12`) — unreliable under Cilium (Cozystack's CNI) (`verified-here`).
- [x] **F6 confirmed:** `k8s/fetcher/main.go` L85–92 — `coreFlags(fs)` dereferences the `fs.Int` pointers BEFORE `fs.Parse` runs (L53/L69), so `--retries/--keep/--max-download-bytes/--max-untar-bytes` are all no-ops (`verified-here`).
- [x] **Startup behavior confirmed:** `watch.go` L75–77 — the startup `Get` returns its error to `main`'s `exitOn` → `log.Fatal` → CrashLoop until the ExternalArtifact exists (`verified-here`).
- [x] **Bearer token question answered** by reading the private `kubernetes/mcp.md` (`verified-here`): it IS specified — "A bearer token in the hub's `headers`, from a Secret, so reaching the port is not enough by itself. It identifies a caller (the harness), not a person." Phase 1 did NOT implement it (no auth check anywhere in `ticket_mcp.py`'s HTTP handler or the selftest). Therefore the mock implements it as a values-driven option, default off.
- [x] **Origin-revision question answered** (`verified-here`, source-watcher `main` controller + test read): the ArtifactGenerator writes `org.opencontainers.image.revision` into the generated ExternalArtifact's `status.artifact.metadata` (NOT object annotations); a client with `get`/`watch` on `externalartifacts` reads it with no extra RBAC. Caveat: for a GitRepository source, current source-controller populates no artifact metadata, so the generator's fallback writes the GitRepository revision string (`main@sha1:<sha>`) — the git commit stays visible either way.
- [x] Seven read-only tool signatures + protocol semantics recorded (`verified-here`): `list_tickets`, `get_ticket`, `search_tickets`, `repo_facts`, `list_docs`, `read_doc`, `search_docs`; blobs `5e3d09ca` (server) / `9bb6b883` (selftest); the canonical selftest asserts `serverInfo.name == "chudmax-tickets"` and cross-checks advertised `default N` caps against trim behavior.
- [x] Volume contract: `k8s/fetcher/README.md` — `revisions/<digest-hex>/`, `current` symlink swapped by rename(2), `artifact.json` (url, revision, digest, produced, unpacked, source) per tree (`verified-here`). The chart dir has no README yet.

## User stories

1. **As a user installing the chart**, `helm install` gives me a working pod out of the box: the fetcher sidecar keeping `/data/current` fresh and the mock ticket server answering MCP (HTTP on the Service port) from the volume — with sane hardened defaults (pod-level token automount off, non-root, dropped capabilities), and I can override `server.*` to bring my own server.
2. **As the owner**, I want the canonical server's per-call contract FIXED in the private repo (one MR, my merge), so the real deployment stops serving stale trees after fetcher swaps — and the private plan docs corrected where they were wrong.
3. **As the phase-5 rehearsal**, I deploy THIS mock as the server under test and exercise the fixed contract for real: two commits in a row, then a third after retention — the server sees each swap without restarting.
4. **As an MCP client author**, I can drive the mock over stdio or HTTP (optionally bearer-token-protected) and get exactly the canonical's tool surface and transport semantics.
5. **As CI**, I want every push to re-prove everything: the mock suite (both transports + the per-call swap proof), the fetcher regression tests (flags + origin_revision + kind startup), kubeconform on the rendered chart (the check that would have caught F3), and both-arches image builds with no push.

## Acceptance criteria

**The contract (both places):**
- [ ] The private MR fixes `ticket_mcp.py`: the tickets path and artifact facts are reread on every call (no startup resolve of the symlink); a `--data-root` pod mode reads `<root>/current/tickets.md` + `<root>/current/artifact.json` per call; the old flags (`--revision/--artifact-produced/--artifact-unpacked`, and a plain `--tickets` file) stay accepted, documented as fallbacks/overrides for a no-fetcher setup; the canonical selftest stays green and gains a per-call artifact.json check (fixture root, symlink swap).
- [ ] The same private MR corrects `kubernetes/repo-sync.md` (source-watcher serves the narrowed artifact), drops the stale phase-5 "privileged runner" flag from the evaluation text, and adds the STATE/tickets line recording the fetcher's home (`urmanac/chudmax-mcp`; private copy frozen). Selftest count parity holds (it derives counts from `tickets.md`).
- [ ] The mock implements the fixed contract from day one: `--data-root <root>` → every call rereads `<root>/current/` (tickets, docs) and `<root>/current/artifact.json` for `repo_facts` (url, revision, digest, produced, unpacked, source — plus `origin_revision` when the fetcher recorded it); honest answers when the tree or artifact.json is absent; legacy flags accepted as fallbacks (`--data-root` wins).
- [ ] **The per-call contract's test proof (this card):** fixture root at v1 → server reads v1; symlink swapped to v2 → server sees v2 WITHOUT restart; v1 pruned (retention) → the server still answers. In the mock suite against a fixture root; phase 5 rehearses it for real with two commits in a row plus a third after retention.

**The mock (public):**
- [ ] `k8s/tickets-mcp-mock/`: fresh single-file Python 3 stdlib server (no copied code text; the canonical is code-only reference, never its data), fixture (a few mock tickets in the canonical grammar, a mock STATE.md, a couple of mock docs/decisions records — zero real data), and a subprocess-based test suite in the canonical selftest's style (keyed results): all seven tools over BOTH transports, 202-empty/405/400 semantics, trim fingerprints (middle for tickets, end for docs, advertised-default cross-check), the per-call swap proof, and the fixture hygiene denylist (no LAN addresses, token-ish strings, real hostnames).
- [ ] Signature-compatible with the fixed canonical: seven tools with verbatim inputSchemas (incl. the load-bearing `default N` descriptions), `initialize` (`2024-11-05`, `serverInfo.name: "chudmax-tickets"` — the canonical selftest asserts it), tools/list + resources/list quirk, tools/call text results (unknown tool → `isError`; exceptions as text; `-32601` fallback), stdio one-object-per-line with silent skips; HTTP POST → 200 one JSON object, notification → 202 empty, GET → 405 `Allow: POST`, malformed → 400 `-32700`, `listening on <host>:<port>` stdout line.
- [ ] Bearer-token option (mcp.md specifies it; phase 1 didn't implement it): mock flag `--bearer-token-file PATH` — the token file is read per request (rotation without restart); a POST without/with a wrong `Authorization: Bearer` → 401, fail-closed if the file is unreadable; stdio unaffected. Default OFF.
- [ ] One OCI image builds as a manifest list for `linux/amd64` and `linux/arm64` under podman (COPY-only, no RUN → no emulation), non-root, stdio-over-fixture default entrypoint; built in CI alongside the fetcher image; no registry push.

**The chart (public):**
- [ ] F3 fixed: pod-level `automountServiceAccountToken: false` (the values knob moves to pod level), the invalid container-level field removed, and the FETCHER container gets a projected `serviceAccountToken` volume (with the kube-root-ca.crt ConfigMap source so in-cluster config keeps working — the CA gotcha); only the fetcher mounts it.
- [ ] F4 fixed: egress `sourceController.port` default → 9090 (source-watcher's storage), the rule scoped to the serving controller's PODS (podSelector + namespace knob); values knobs stay.
- [ ] F5 fixed: apiserver egress defaults to the Cilium-compatible podSelector pattern (apiserver static pods, `component: kube-apiserver`); the ipBlock stays as a values alternative; both documented.
- [ ] The deviation: `server.enabled` defaults TRUE with `server.image` defaulting to the mock (`ghcr.io/urmanac/chudmax/tickets-mock:0.1.0`, unpublished until phase 10 — build-it-yourself note) and working default command/args (HTTP on `server.port`, `--data-root /data`); fetcher image default renamed to `ghcr.io/urmanac/chudmax/fetcher`; README + NOTES updated (override values = bring your own).
- [ ] Pod-level securityContext (runAsNonRoot, seccomp RuntimeDefault) + containers drop ALL capabilities; the fetcher image's alpine base bumps off 3.21 (EOL) — both images re-proven in CI.
- [ ] `helm lint` green; `helm template` renders the hardened defaults (mock enabled: Service + ingress policy present, pod-level automount false, securityContext set) and a server-disabled variant; the chart README (created) documents the default install, the BYO override, the auth option, and the crashloop→waiting behavior change.

**The fetcher (public):**
- [ ] F6 fixed: `coreFlags` assigns CoreOpts AFTER `fs.Parse`; a regression test parses real flags and asserts the values reach CoreOpts.
- [ ] Kinder startup: a startup-Get NotFound (fresh install) retries with backoff and stays up; other errors still exit loudly; NOTES.txt updated.
- [ ] Origin revision recorded: watch mode reads the ExternalArtifact's `status.artifact.metadata["org.opencontainers.image.revision"]` and the fetcher writes it into artifact.json as `origin_revision` (omitted when absent); `k8s/fetcher/README.md` documents the field; a unit test covers it.
- [ ] Existing fetcher workflows stay green alongside the new tests.

**CI (public):**
- [ ] kubeconform (with Flux + k8s schemas) validates the RENDERED chart templates in both value variants — the check that would have caught F3; the phase-4 flux-schema precedent is the fallback if the runner fights it.
- [ ] The mock test job (Python), the `mock-image` job (both arches, arch-count check, HTTP smoke: initialize 200, notification 202, GET 405, malformed 400), and the updated chart template variants all run; existing jobs stay green.

**Flow:**
- [ ] Branch off public `main` (`67d8616`); conventional commits; three labels on every claim; box untouched; the private MR proposed via the GitLab API (human merges); the public PR via `propose_pull_request` (no approval wait); CI green + in-sandbox verification before merge; merge authority CoS/owner; `mark_task_complete` only after the public PR merges; the missing-LICENSE flag rides in the PR description.
- [ ] **The PR description answers Fable's two questions** (pre-drafted in `design.md`): (a) the bearer token — specified in `kubernetes/mcp.md`, NOT implemented by phase 1, implemented by the mock as a values-driven option; (b) the narrowed artifact's revision — a content hash, but the origin revision IS exposed (annotation `org.opencontainers.image.revision` in `status.artifact.metadata`; GitRepository sources get the revision-string fallback), so the fetcher records it as `origin_revision` in artifact.json.

## Out of scope (owned by other phases or decisions)

- Publishing any image (ghcr.io, cosign) — phase 10. Live-cluster rehearsal of the fixed contract — phase 5 (deploys this mock; two commits + a third after retention).
- The engine/web charts, umbrella, canary, Hermes — phases 6–9. Placement — phases 11+.
- The canonical repo's real data and anything beyond the source-only reference reads.
- The repo's LICENSE choice — owner-deferred; flagged, not decided here.

## Open Questions

1. **F5's "default namespace":** the brief says the apiserver podSelector targets "the apiserver static pods: default namespace, `component: kube-apiserver`". Kubeadm puts apiserver static pods in **kube-system** — I assume "default namespace" means that standard home (values knob `apiServer.selector.namespace` defaults `kube-system`, `component: kube-apiserver`). If it literally meant the `default` namespace, the knob turns; say the word at review.
