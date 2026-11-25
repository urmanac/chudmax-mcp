# The mock ticket server's image: the mock, its fixture, nothing else.
#
# COPY-only by design: no RUN anywhere, so the multi-platform manifest build
# needs no emulation (the multi-arch python base carries the arch difference;
# the fetcher image needs its cross-compile pin, this one does not).
FROM python:3.12-alpine

COPY ticket_mcp_mock.py /app/ticket_mcp_mock.py
COPY fixture /app/fixture

# The same non-root uid the fetcher image runs as. The fixture is world-readable.
USER 65532:65532

# Default entrypoint: stdio over the bundled fixture. Pod mode is the chart's
# business: command/args run --http <port> --data-root /data.
ENTRYPOINT ["python3", "/app/ticket_mcp_mock.py"]
