# Design: chudmax k8s phase 2 fetcher sidecar

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
5. **Placement:** `k8s/fetcher/` Go module (`gitlab.com/kingdonb/chudmax/k8s/fetcher` — assumption, trivially renamed), `main.go` plus a small `internal` split only if it earns it. CI: one `fetcher-test` job appended to the existing `.gitlab-ci.yml` `test` stage — `golang:1.27` image (the lib requires go 1.27), `go vet`, `go test ./...`, and a `GOARCH=arm64 go build` cross-check (the both-arches rule is about images, phase 3; this check keeps the source honest early). Shared runners suffice — no cluster, no podman, no privileged runner in this phase.
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

## What this settles

- The last piece of "the repo reaches the ticket server" that isn't Flux's own (`repo-sync.md`): the consuming side exists and is testable without a cluster.
- Nothing on the box, nothing on the cluster: phase 2 only adds a Go module, its tests, and one CI job.
