# chudmax-mcp

The packaging home for the ChudMax MCP pod: the artifact-fetcher sidecar, the
published canonical ticket server, and the chart that runs both.

Flux (source-controller) fetches, verifies and packs a git repo and serves the
result as an artifact; source-watcher's ArtifactGenerator narrows it to what
the ticket server reads. The fetcher in [`k8s/fetcher/`](k8s/fetcher/) is the
consuming side: it watches one ExternalArtifact, downloads the tarball, checks
the digest, unpacks beside the previous copy, and swaps a symlink so a reader
never sees half a tree. No git code, no restarts, no half-updated reads.

## What this repo delivers

- **The fetcher** — one small Go binary, two modes:
  - `fetch --url URL --digest sha256:... --root DIR` — one-shot: download,
    verify, unpack, swap.
  - `watch --namespace NS --name NAME --root DIR` — read the one ExternalArtifact
    the pod's Role allows (`get`, `watch`) at startup, then watch it; re-reads
    every minute as a fallback and reconnects when the stream drops. An
    artifact that does not exist yet (a fresh install) is waited for, not fatal.
- **The published ticket server** — [`k8s/tickets-mcp/`](k8s/tickets-mcp/):
  the canonical tickets-mcp itself, published byte-exact from the source-of-truth
  repo (where the real data stays private): the seven read-only tools over stdio
  and HTTP, the fixed per-call contract — every call rereads `current` and its
  `artifact.json` — and the optional bearer auth. The `tickets.md` / docs /
  decisions files beside it are **invented, test-only fixtures** for the server's
  own selftest; no real ticket data ever enters this repo.
- **The volume contract** — see [`k8s/fetcher/README.md`](k8s/fetcher/README.md):
  content-addressed revision dirs, a `current` symlink swapped atomically, and
  an `artifact.json` beside every tree (url, revision, digest, produced,
  unpacked, origin_revision, source).

## The chart's default install

`helm install` runs TWO containers: the fetcher sidecar and the published
server (`--http 8080 --host 0.0.0.0 --data-root /data`), with a Service and an
ingress NetworkPolicy for the server's port. The published server is the real
interface, not an example; the chart README
([`k8s/chart/chudmax-mcp/README.md`](k8s/chart/chudmax-mcp/README.md)) covers
the defaults, the bring-your-own override, and the optional bearer auth.

## Install

```
go install github.com/urmanac/chudmax-mcp/k8s/fetcher@latest
fetcher fetch --url <artifact-url> --digest <sha256:...> --root /data
```

The chart:

```
helm install chudmax-mcp k8s/chart/chudmax-mcp
```

Two things a fresh install does not have yet:

- **The ExternalArtifact.** The chart only needs its name
  (`externalArtifact.name`) — source-watcher's ArtifactGenerator creates it;
  the manifests live in `k8s/repo-sync/`. Until it exists, the fetcher
  container WAITS (logging and retrying every resync period — it does not
  crash-loop) and self-heals once the artifact appears.
- **The published images.** The default tags
  `ghcr.io/urmanac/chudmax/fetcher:0.1.0` and
  `ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0` are unpublished until the
  publishing milestone. Build them yourself meanwhile:

  ```
  podman build --platform linux/amd64,linux/arm64 \
    --manifest ghcr.io/urmanac/chudmax/fetcher:0.1.0 \
    -f k8s/image/Dockerfile k8s
  podman build --platform linux/amd64,linux/arm64 \
    --manifest ghcr.io/urmanac/chudmax/tickets-mcp:0.1.0 \
    -f k8s/tickets-mcp/Dockerfile k8s/tickets-mcp
  ```

## Status

- The fetcher is complete and tested (tarball fixtures over HTTP, fake-client
  watch tests; no cluster needed), including the phase-4b fixes: the shared
  tunables actually parse (a regression test locks the order), the fresh-install
  wait replaces the startup crash, and artifact.json records the origin revision
  the generator annotates.
- The published server is the canonical implementation, byte-exact, tested by
  its own selftest: 32 checks over both transports against the synthetic fixture
  tree, including the per-call proof (a symlink swap is visible on the next call
  without a restart, pruning the starting revision changes nothing, and docs
  reread per call), the relative-launch shape, and the bearer option
  (fail-closed 401s, per-request token rotation).
- CI runs on every push: vet, tests, arm64 build check for the fetcher
  (`fetcher-test`); chart lint/template in three value variants, kubeconform on
  the rendered templates, and two-architecture image builds for BOTH images, no
  push (`image-chart`); the server's selftest plus the fixture-hygiene check
  (`tickets-test`); the Flux-schema
  validation of the repo-sync manifests (`repo-sync-validate`).
- Both images are manifest lists for amd64 and arm64 with emulation-free builds
  (the fetcher cross-compiles; the ticket server has no RUN at all).
