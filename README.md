# chudmax-mcp

The artifact-fetcher sidecar and the packaging home for the ChudMax MCP pod.

Flux (source-controller) fetches, verifies and packs a git repo and serves the
result as an artifact. The fetcher in [`k8s/fetcher/`](k8s/fetcher/) is the
consuming side: it watches one ExternalArtifact, downloads the tarball, checks
the digest, unpacks beside the previous copy, and swaps a symlink so a reader
never sees half a tree. No git code, no restarts, no half-updated reads.

## What this repo delivers

- **The fetcher** — one small Go binary, two modes:
  - `fetch --url URL --digest sha256:... --root DIR` — one-shot: download,
    verify, unpack, swap.
  - `watch --namespace NS --name NAME --root DIR` — read the one ExternalArtifact
    the pod's Role allows (`get`, `watch`) at startup, then watch it; re-reads
    every minute as a fallback and reconnects when the stream drops.
- **The volume contract** — see [`k8s/fetcher/README.md`](k8s/fetcher/README.md):
  content-addressed revision dirs, a `current` symlink swapped atomically, and
  an `artifact.json` beside every tree (url, revision, digest, produced,
  unpacked, source).

## Bring your own MCP server

The fetcher image ships the fetcher and nothing else — this repo does not ship
a ticket server. The chart runs an optional, values-driven second container for
your own MCP server: it mounts the same shared volume and reads the files the
fetcher maintains — through the `current` symlink, rereading on every call. The
volume contract your server codes against is documented in
[`k8s/fetcher/README.md`](k8s/fetcher/README.md).

```yaml
server:
  enabled: true
  image:
    repository: <your-server-image>
    tag: <tag>
  command: ["<your-server-binary>"]
  args: ["--root", "/data/current"]
  port: 8080
```

When the server is enabled, the chart also renders its Service and an ingress
NetworkPolicy for that port; disabled, the pod is fetcher-only.

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
  container exits and restarts with backoff (its startup read is
  fatal by design) and self-heals once the artifact appears.
- **The published image.** The default tag `ghcr.io/urmanac/chudmax/mcp:0.1.0`
  is unpublished until the publishing milestone. Build it yourself meanwhile:

  ```
  podman build --platform linux/amd64,linux/arm64 \
    --manifest ghcr.io/urmanac/chudmax/mcp:0.1.0 \
    -f k8s/image/Dockerfile k8s
  ```

## Status

- The fetcher is complete and tested (tarball fixtures over HTTP, fake-client
  watch tests; no cluster needed).
- CI runs on every push: vet, tests, arm64 build check for the fetcher
  (`fetcher-test`); chart lint/template and a two-architecture image build, no
  push (`image-chart`).
- The image is one manifest list for amd64 and arm64 with an emulation-free
  build (the Dockerfile pins its run stages to the build platform and
  cross-compiles the Go binary).
