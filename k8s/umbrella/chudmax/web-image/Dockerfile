# The ChudMax web image: the public Strata (github.com/kingdonb/Strata) at the
# pinned SHA recorded in this directory's README (..). Strata ships no
# Dockerfile — this is phase 6's, minimal on purpose:
#   - python:3.12-slim (the published tickets-mcp image's python family);
#   - the runtime wheels only (terminal/requirements.txt — no build tools;
#     every dependency ships aarch64 wheels, so nothing compiles);
#   - non-root uid 65532 (the established image pattern);
#   - ENTRYPOINT is Strata's serve.server, so the image also runs standalone
#     (the bridge mock engine: docker run <img> --engine mock --host 0.0.0.0
#     --port 8080) — the chart passes the same args as command/args.
# First non-COPY-only image in this effort: a pip install cannot cross-compile,
# so the arm64 leg runs under qemu binfmt in CI; the sandbox (binfmt denied)
# builds amd64 only and records that honestly.
#
# Build (from a Strata checkout at the pin):
#   podman build -t ghcr.io/urmanac/chudmax/web:0.1.0 -f web-image/Dockerfile <strata-checkout>
FROM python:3.12-slim

COPY terminal/ /app/terminal/
WORKDIR /app/terminal

RUN pip install --no-cache-dir -r requirements.txt

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["python", "-m", "serve.server"]
