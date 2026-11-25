# fetcher — the artifact sidecar

The component that keeps a directory current with what Flux serves, without git
and without restarts: Flux (source-controller) fetches, verifies and packs the
repo; fetcher consumes what Flux serves. It takes an artifact URL and digest,
verifies, unpacks beside the previous copy, and swaps a symlink so a reader
never sees half a tree. It is the same library Flux's own controllers consume
with: `fluxcd/pkg/http/fetch`'s ArchiveFetcher (download with retries, `sha256:`
digest check, size-capped untar through `fluxcd/pkg/tar`).

## Modes

```
fetcher fetch --url URL --digest sha256:... --root DIR
# one-shot: download, verify, unpack, swap. What CI proves, and the debugging tool.

`fetcher watch --namespace NS --name NAME --root DIR`
# pod mode: read the one ExternalArtifact (Role: get, watch) at startup - which
# covers a missed event after a restart - then watch it, re-read every --resync
# (default 1m) as a fallback for a silent stream, and reconnect with the same
# period when the stream drops. Every artifact change runs the core; the digest
# already served is a no-op. An artifact that does not exist yet (a fresh
# install, before the repo-sync work creates it) is waited for with a backoff
# of the resync period, not fatal - the fetcher stays up and self-heals
# (T-0037 phase 4b).
```

Shared tunables: `--retries 3`, `--keep 3` (revision dirs kept), `--max-download-bytes`
(100 MiB), `--max-untar-bytes` (200 MiB).

## Volume layout (the contract with the ticket server, phase 3 wiring)

```
<root>/revisions/<digest-hex>/   one complete unpacked tree per digest,
                                 plus artifact.json written by the sidecar
<root>/current -> revisions/<digest-hex>   relative symlink, swapped by
                                 rename(2) - a reader opening through current
                                 sees the whole old tree or the whole new one
```

`artifact.json` (inside each unpacked dir, so it swaps with the content):

```json
{"url": "...", "revision": "main@sha1:...", "digest": "sha256:...",
 "produced": "2026-11-25T15:00:00Z", "unpacked": "2026-11-25T15:00:01Z",
 "origin_revision": "main@sha1:...", "source": "externalartifact chudmax/chudmax-tickets"}
```

`origin_revision` (added T-0037 phase 4b) is the git-side revision the ArtifactGenerator
records beside the generated artifact - source-watcher writes the `org.opencontainers.image.revision`
annotation into the ExternalArtifact's `status.artifact.metadata`, and the fetcher copies it
here while it holds the object (get/watch verbs it already has; no new RBAC). For a
GitRepository source the annotation carries the git revision string (the generator's fallback),
so the git commit stays visible even though `revision` above is the content hash. The one-shot
`fetch` mode reads no object, so it omits the field.

`repo_facts` in pod mode reports these per call - the server reads
`<root>/current/artifact.json` (and the files beside it) through the symlink
every time it is asked; nothing restarts.

## Deployment wiring (next steps)

- The pod's chart mounts the shared volume, manifests the namespaced Role
  (`get`, `watch` on the one ExternalArtifact), and the NetworkPolicies that
  admit the sidecar to source-controller only.
- The core is agnostic about which Flux source made the artifact - the
  GitRepository's own (narrowed by its `ignore` rule) or a generated one; it
  unpacks whatever tarball the ExternalArtifact points at. Phase 4 chose the
  generated one: source-watcher's ArtifactGenerator over the narrowed set,
  manifests in `k8s/repo-sync/` (the ignore-rule fallback is documented there).
- The unit tests use a fake client and real HTTP for the tarball; the
  field-selector watch against a real API server is rehearsed on a cluster.
- mTLS (Flux 2.10): ArchiveFetcher accepts a TLS config; nothing is done now.
