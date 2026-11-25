# Design: chudmax k8s phase 2 fetcher sidecar

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

The fetcher is the only new code in the T-0037 plan and it is deliberately tiny: everything hard about fetching is already Flux's job (git, packing, digesting, serving) and the consuming side is a solved problem with a published library. The sidecar is a thin loop around it. Requirements are in `requirements.md` in this directory; the plan texts it implements are `kubernetes/phases.md` (phase 2 row) and `kubernetes/repo-sync.md` ("The fetcher") on `main` @ `9950942f` (`verified-here`).

## Shape

```
source-controller (Flux)                    mcp pod (phase 3 wiring)
  serves artifact tarball over HTTP           +--------------------------+
        |                                     | fetcher sidecar (Go)     |
        |  status.artifact.url                |  watch mode:             |
        |  status.artifact.digest             |   GET the one External   |
        v                                     |   Artifact at startup,   |
  GET url, verify sha256 digest               |   then watch it          |
        |                                     |   (Role: get, watch)     |
        v                                     |  fetch mode (CI):        |
  unpack to  <root>/revisions/<digest-hex>/   |   URL + digest by flag   |
  write artifact.json into it                 |        |                 |
  atomic swap: symlink + rename()             |        v                 |
        |                                     |  <root>/current symlink  |
        +------------------------------------>|        |                 |
                                              |  ticket server reads     |
                                              |  /data/current/...       |
                                              |  (rereads every call)    |
                                              +--------------------------+
```

One binary, two modes (the card's literal contract plus the pod mode from `repo-sync.md`):

- `fetcher fetch --url <url> --digest <sha256:...> --root <dir>` — one-shot: download, verify, unpack, swap. This is what CI drives against a tarball; it is also the debugging tool.
- `fetcher watch --namespace <ns> --name <name> --root <dir>` — pod mode: GET the named ExternalArtifact once at startup (this is what covers a missed event after a restart), then `watch` it (field selector `metadata.name=<name>`, resuming from the GET's resourceVersion) and re-check on a 1-minute resync timer; every observed `status.artifact` change runs the same core as `fetch`.

## Key decisions

1. **Reuse `fluxcd/pkg/http/fetch`'s `ArchiveFetcher`** — the exact library Flux's own consumers use (kustomize-controller fetches artifacts with it: `fetch.New`, `WithRetries`, `WithMaxDownloadSize`, `WithUntar(tar.WithMaxUntarSize(...))` — `verified-here` from its source on GitHub, 2026-11-25). It downloads over HTTP with retries, verifies the `sha256:` digest, and untars through `fluxcd/pkg/tar` (path-traversal-safe, size-capped). The sidecar writes no git code and reimplements no verification.
2. **Content-addressed unpack + atomic symlink swap.** Each new digest unpacks into `<root>/revisions/<digest-hex>/`; then a symlink is created at a temp name and `rename()`d over `<root>/current` — atomic on the same filesystem, so a reader opening through `current` sees either the whole old tree or the whole new tree. Same-digest arrivals (and a restart) are no-ops; retention keeps the last 3 revision dirs. The sidecar also writes `artifact.json` (url, revision, digest, produced = `lastUpdateTime`, unpacked-at) *inside* the unpack dir before the swap, so metadata and content swap atomically together and the ticket server's later per-call read of `repo_facts` facts needs no restart (phase 3 wiring).
3. **Watch = one named object, minimum verbs.** The Role is namespaced and grants `get`, `watch` on that one ExternalArtifact — exactly the card's prescription. Startup does a `get` (self-heal after restart); the watch stream carries changes; the 1-minute resync catches silently dropped streams. A `list`-based informer cache would be simpler code but adds the `list` verb — declined for now; phase 4 owns the final "smallest Role" answer and can add it then.
4. **Failure policy: never make things worse.** Digest mismatch or network failure → log, retry inside ArchiveFetcher, keep serving the previous tree. The watcher reconnects on stream drop. Nothing is deleted before a swap succeeds.
5. **Placement:** `k8s/fetcher/` Go module, `main.go` plus a small `internal` split only if it earns it. Module path: `github.com/urmanac/chudmax-mcp/k8s/fetcher` in the public repo (re-pointed from the private repo's path when the work was re-homed). CI: a `fetcher-test` job — Go 1.27 (the lib requires it), `go vet`, `go test ./...`, and a `GOARCH=arm64 go build` cross-check (the both-arches rule is about images, phase 3; this check keeps the source honest early). On the private source-of-truth repo it ran as a provider-CI job; the public repo carries it as GitHub Actions. Shared runners suffice — no cluster, no podman, no privileged runner in this phase.
6. **mTLS ready (phase 17), nothing done now:** `ArchiveFetcher` accepts `WithTLSConfig`; the artifact URL is in-cluster HTTP until then (`repo-sync.md`).

## Proof basis for the design (`verified-here`, this sandbox, 2026-11-25)

A throwaway spike ran the whole core loop in `/tmp/fetch-spike` (not committed anywhere):

- `fluxcd/pkg/http/fetch@v0.32.0` + `fluxcd/pkg/tar@v1.4.0` + `source-controller/api@v1.10.2` resolve and build (latest versions today per proxy.golang.org; kustomize-controller and source-watcher pin the same `http/fetch` major line).
- An `ArchiveFetcher` fetched a tarball over plain HTTP from an in-process server, verified its `sha256:` digest, and untarred it into a digest-named dir; files read back correctly through the swapped `current` symlink.
- A wrong digest failed with a digest-mismatch error and the previous symlink/tree stayed untouched — the "reader never sees half a tree / keeps last good" property holds with the library as-is.
- An `ExternalArtifact` manifest decoded with the `source.toolkit.fluxcd.io/v1` types (`status.artifact.url/revision/digest/lastUpdateTime` present).
- A controller-runtime fake-client watch over an ExternalArtifact delivered a change event with the updated artifact — the phase-2 unit-test approach for the watch layer works.
- Gotcha recorded: fluxcd modules pin `github.com/opencontainers/go-digest` at pseudo-version `v1.0.1-0.20220411205349-bde1400a84be` (BLAKE3 support); a consumer must require that same version or `blake3` fails to compile.

What stays `speculation` until a later phase: the narrowed ArtifactGenerator artifact's exact tarball layout (phase 4's question — the core is layout-agnostic), real-API-server watch semantics (field-selector watch; proven against the fake client only — phase 5 rehearses for real), and the in-cluster RBAC wiring (phase 3 manifests it).

## Where this work lives (changed 2026-11-25, after the merge)

- MR !19 (the fetcher sidecar) is merged on `the private source-of-truth repo` `main` @ `de442410` — durable there (`verified-here`).
- The project's primary repo moved the same day: **`urmanac/chudmax-mcp` on GitHub** (Helix repo row `code-chudmax-mcp-01m89tvjwc7kvty959ethn6e97`, external_type github, attached via OAuth; the sandbox clone's origin is the Helix proxy `the Helix git proxy/git/code-chudmax-mcp-…`). `verified-here` from the Helix API.
- These helix-specs docs are re-homed on that repo's pre-seeded `helix-specs` branch (rebased onto its init commit, no force); the GitLab `helix-specs` branch stays as the historical record.
- Going forward: spec docs push to `chudmax-mcp`'s `helix-specs` branch via the proxy origin; whether the old repo's `main` content (tickets, tools, kubernetes plan docs) migrates here is the human's call — deliberately not done by the agent.

## Repo re-home directive (human, 2026-11-25, post-merge)

- The old repo does **not** migrate. `the private source-of-truth repo` (GitLab) stays as the private record; MR !19 (the fetcher, merged @ `de442410`) is durable there.
- New work goes in the new public repos: `urmanac/chudmax-mcp`, `urmanac/chudmax-engine`, `urmanac/chudmax-web` (GitHub, attached to the Helix project 2026-11-25). Scope tight per repo; more repos only if a scope demands it.
- The fetcher sidecar belongs in `chudmax-mcp` (the human's reasoning: that is where the fetched clone will live, fetched by Flux alongside it). The deliverable bar is "something complete that folks can install" while **not** delivering the entire ticket MCP — the ticket MCP is bundled and may move into the repo over time.
- Proposed boundary (agent, for the human's confirmation): `chudmax-mcp` owns the artifact-consuming side and the packaging that bundles the pod's components; the fetcher enters as source now, the ticket MCP enters as a pinned, digest-checked build-time bundle until it moves in; tickets/STATE/plans/decisions never enter the public repos.
- The fetcher's REPO is not the repo it fetches: the artifact source (tickets.md, STATE.md, docs) is still the private repo's `main` (or "fetched another way", human's words) — that distinction lands in the phase-4 spec, not in the public repos.
- Helix workflow mechanics learned while finishing the re-home (`verified-here`, 2026-11-25): a task in `implementation_failed` cannot propose PRs; `helix spectask move <id> implementation` restores the state (only a move to `backlog` clears anything). The PR proposal tool (`prp_01m89w5p33as1kjx75f07ppcb6`) grants push rights to a NEW branch name only (`rehome/t0039-fetcher-sidecar`; an already-pushed branch name is rejected), and on approval the agent pushes the approved commit to that branch. Git pushes through the Helix proxy propagate new-commit pushes to GitHub within ~1-2 minutes, but branch DELETIONS and force-resets do NOT propagate — a leftover branch needs one-click deletion in the GitHub UI.
- Public-repo policy (final, human-confirmed): this repo's `helix-specs` branch is a public surface and pushes to it are expected, public-safe by construction; the docs were re-published here as a sanitized mirror (full-fidelity notes stay on the private repo's `helix-specs` branch, which the human keeps as the official source of truth and does not intend to open-source). Branch deletions and force-resets do not propagate through the Helix git proxy — superseded history on a public branch is removed by deleting the branch in the provider UI and pushing the clean chain fresh, if ever needed.

- Board bookkeeping: the phase-2 card reads `implementation_failed` — drift, because the repo row it was attached to was deleted mid-task; the work is delivered and merged (receipts above). Phase 3 (mcp image and chart) is queued for spec generation and will be written against the new repo layout.

## What this settles

- The last piece of "the repo reaches the ticket server" that isn't Flux's own (`repo-sync.md`): the consuming side exists and is testable without a cluster.
- Nothing on the box, nothing on the cluster: phase 2 only adds a Go module, its tests, and one CI job.

## Implementation proof (2026-11-25, delivered as MR !19 — `verified-here`)

Branch `feat/t0039-fetcher-sidecar` off `main` @ `9950942f`, commit `9250d828`, MR !19 opened via the GitLab API (not merged; the human merges). All checks run in this sandbox against the branch checkout:

- `go vet ./...` clean; `go test -race -count=1 ./...`: **10/10 PASS** — happy path, digest mismatch keeps the previous tree (and no temp leftovers), second-revision swap + retention 3, same-digest no-op + rollback (no re-download, artifact.json preserved), unsafe-input refusals (empty digest, non-sha256, malformed; a `current` symlink outside `revisions/` is refused), watch: startup read acts on the artifact already there, change event swaps, resync fallback catches a change when the stream is silent, reconnect catches a change when the stream dropped, failed fetch keeps the previous tree.
- Binary smoke test against a real tarball server: swap=true, relative symlink `revisions/<hex>`, correct `artifact.json`, second run swapped=false, bad digest exits 1, unknown subcommand exits 2.
- `GOARCH=arm64 go build` succeeds (cross-compile honesty check; images come in phase 3).
- `python3 tools/mcp/selftest.py` on the branch: **19/19 PASS, exit 0** (ticket count check reads 39 vs 39 — the suite derives both counts from `tickets.md`).
- CI (`verified-here` via the provider API): the `fetcher-test` job **succeeded** — `go vet` clean, `go test -count=1` ok, arm64 build ok; shared runners, no cluster, no privileged runner. One unrelated job failed once on a transient registry-image pull timeout and passed on retry (infrastructure, not code).
- Reviewer-dispositioned defaults implemented as adopted: `artifact.json` inside the unpack dir; 1-minute resync (also the reconnect backoff); retention 3; caps 100/200 MiB — all flag-overridable, flagged in the MR description for merge review.
- Post-merge verification (after the human merged, 2026-11-25): fresh clone of `main` @ `de442410` — `k8s/fetcher/` present, STATE.md reads 39 tickets / 23 done, T-0039 in `tickets.md`, `selftest.py` **19/19 PASS, exit 0** (`verified-here`).
- Labels: everything above `verified-here`; real-API-server watch semantics stay `speculation` until phase 5's rehearsal; the ArtifactGenerator-vs-GitRepository-artifact question stays with phase 4 (`speculation` in `repo-sync.md`).
