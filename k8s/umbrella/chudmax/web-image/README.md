# The ChudMax web image (Strata)

Phase 6's image for the web chart. Strata ships no Dockerfile, so this
directory carries one: `python:3.12-slim`, the runtime wheels from
`terminal/requirements.txt` (no build tools — nothing compiles), non-root uid
65532, `ENTRYPOINT python -m serve.server`.

## The pin

| What | Value |
|---|---|
| Source | `github.com/kingdonb/Strata` (public, MIT) |
| Pinned SHA | `de34ebaa521d8f628b4bb1884e5c34101730299a` |
| Tag at the pin | `v0.2.21-mbp.rtx.1` |

A moving `main` never silently changes the image: `kind-smoke.sh` and CI fetch
this exact SHA. Bump the pin by editing the table here and the consumers
(`kind-smoke.sh` reads `STRATA_PIN`, defaulting to it).

## Build and load

    git fetch --depth 1 https://github.com/kingdonb/Strata de34ebaa521d8f628b4bb1884e5c34101730299a
    podman build -t ghcr.io/urmanac/chudmax/web:0.1.0 -f web-image/Dockerfile <strata-checkout>
    podman save --format docker-archive -o web.tar ghcr.io/urmanac/chudmax/web:0.1.0
    kind load image-archive web.tar

The image is tagged with the chart's default reference, so
`pullPolicy: IfNotPresent` uses the loaded image and no registry is touched.
Phase 7's Flagger canary reuses the same image and pin — nothing thrown away.

## Arches

Both arches build in CI (the arm64 leg under qemu binfmt — this is the first
non-COPY-only image in the effort; a pip install cannot cross-compile). The
sandbox builds amd64 only (binfmt denied there) and records it honestly.
Every runtime dependency ships aarch64 wheels — verify on any pin bump.
