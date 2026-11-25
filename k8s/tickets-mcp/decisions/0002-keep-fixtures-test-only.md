# 0002 - Keep the fixtures test-only

Date: 2026-11-25 (fixture record, written for the selftest)

## Context

The fixture tree exercises every tool honestly, which means it must look like a real
ticket file while never being one.

## Decision

Fixtures stay out of the container image and out of any default the chart serves; they
exist for the selftest run. A fixture ticket is invented the moment it is written and
stays invented forever.

## Consequences

The image ships the server alone; the chart's default mode reads a fetched volume, not
the fixtures; nothing private can leak through a file that was never real.
