# The published ticket server's image: the canonical server, nothing else.
#
# k8s/tickets-mcp/tools/mcp/ticket_mcp.py is the source-of-truth server's file,
# published byte-exact (the per-call contract: every call rereads <data-root>/current,
# facts from artifact.json read per call). The fixture tree beside this Dockerfile is
# TEST-ONLY - the selftest runs against it; the image carries no fixtures and no data.
#
# COPY-only by design: no RUN anywhere, so the multi-platform manifest build needs no
# emulation (the multi-arch python base carries the arch difference; the fetcher image
# needs its cross-compile pin, this one does not).
FROM python:3.12-alpine
# GHCR links the published image to this repo via this label.
LABEL org.opencontainers.image.source=https://github.com/urmanac/chudmax-mcp

COPY tools/mcp/ticket_mcp.py /app/ticket_mcp.py

# The same non-root uid the fetcher image runs as.
USER 65532:65532

# Default: stdio in pod mode against /data (the fetcher's volume contract; honest
# answers until the first artifact lands). HTTP is the chart's business:
# command/args run --http <port> --host 0.0.0.0 --data-root /data.
ENTRYPOINT ["python3", "/app/ticket_mcp.py"]
CMD ["--data-root", "/data"]
