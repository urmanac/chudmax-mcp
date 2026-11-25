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

This repo does not ship a ticket server. Whatever MCP server runs beside the
fetcher reads the files the fetcher maintains — through the `current` symlink,
rereading on every call. Point it at your own ticket server (or the file-backed
schema of your choice); the fetcher only keeps the files current.

## Install

```
go install github.com/urmanac/chudmax-mcp/k8s/fetcher@latest
fetcher fetch --url <artifact-url> --digest <sha256:...> --root /data
```

Container images and the Helm chart (the pod wiring: shared volume, namespaced
Role `get`/`watch`, NetworkPolicies) land with the packaging work in this repo.

## Status

- The fetcher is complete and tested (tarball fixtures over HTTP, fake-client
  watch tests; no cluster needed).
- CI runs on every push: vet, tests, arm64 build check.
