# tickets-mcp-mock — the mock ticket server

A public stand-in for chudmax's canonical ticket server, which stays private
(`kingdonb/chudmax`, `tools/mcp/ticket_mcp.py`) with the real data. The mock is a
fresh implementation of the canonical's signatures — the seven read-only tools, the
stdio + HTTP transports, and the per-call volume contract — carrying none of the
real data: the bundled `fixture/` is invented end to end.

## What it is / what it is not

- **Is:** the worked example behind the chart's default server container; the server
  under test for the phase-5 rehearsal; a runnable reference for anyone coding
  against the volume contract in [`k8s/fetcher/README.md`](../fetcher/README.md).
- **Is not:** the canonical server, and not a copy of its code — same signatures,
  its own implementation, no private material (a hygiene check in the test suite
  asserts the fixture's denylist).

## The fixed per-call contract

With `--data-root DIR`, every call rereads `DIR/current` — the fetcher sidecar's
symlink (see the volume contract in [`k8s/fetcher/README.md`](../fetcher/README.md)):
tickets and docs come from the unpacked tree, and `repo_facts` reads
`DIR/current/artifact.json` fresh on every call (url, revision, digest, produced,
unpacked, source — plus `origin_revision` when the fetcher recorded it). A fetcher
swap is visible on the next call without a restart; pruning the revision the server
started on changes nothing. Without `--data-root`, the mock serves the bundled
fixture (or a `--tickets FILE` you point it at), and the old revision flags
(`--revision`, `--artifact-produced`, `--artifact-unpacked`) remain accepted as
fallbacks for a no-fetcher setup.

## Run it

```
# stdio, bundled fixture (the image's default entrypoint)
podman run -i --rm ghcr.io/urmanac/chudmax/tickets-mock:0.1.0

# HTTP, bundled fixture, port the OS picks (the selftest's mode)
podman run --rm ghcr.io/urmanac/chudmax/tickets-mock:0.1.0 --http 0

# HTTP, pod mode (what the chart's default container runs)
podman run --rm -v <the-shared-volume>:/data \
  ghcr.io/urmanac/chudmax/tickets-mock:0.1.0 --http 8080 --data-root /data
```

Optional bearer auth (HTTP only): `--bearer-token-file PATH` — the token file is
read per request (rotation needs no restart); every POST must carry
`Authorization: Bearer <token>`, and a missing, wrong, or unreadable token is a
fail-closed 401. stdio is a local pipe and stays auth-free.

## Tests

```
python3 k8s/tickets-mcp-mock/test_tickets_mcp_mock.py
```

38 checks: all seven tools over BOTH transports, the 202-empty / 405 / 400 HTTP
semantics, the trim fingerprints (middle for tickets, end for docs, the
advertised-default cross-check), the per-call proof (v1 → swap to v2 without a
restart → prune v1 → still answers), the bearer option with rotation, and the
fixture hygiene denylist.

## The image

```
podman build --platform linux/amd64,linux/arm64 \
  --manifest localhost/chudmax-tickets-mock:0.1.0 \
  -f k8s/tickets-mcp-mock/Dockerfile k8s/tickets-mcp-mock
```

COPY-only Dockerfile (no RUN → no emulation in the manifest build), non-root
(uid 65532, same as the fetcher), stdio-over-fixture as the default entrypoint.
The `ghcr.io/urmanac/chudmax/tickets-mock` tag is unpublished until the phase-10
publishing milestone — build and load it yourself meanwhile.
