# 0001 - Publish the canonical ticket server from the fixed source

Date: 2026-11-25 (fixture record, written for the selftest)

## Context

The distribution needs the real ticket server available to chart users out of the box.
The source is public-safe by ruling; the data is not, and never enters this repo.

## Decision

Publish `tools/mcp/ticket_mcp.py` byte-exact from the fixed source (the per-call
contract), with the synthetic fixture tree beside it as test-only input for the
selftest. The image carries the server only, never the fixtures.

## Consequences

The published server and the source-of-truth copy stay the same file; the fixtures
stay invented, and the selftest is the proof both of behavior and of public safety.
