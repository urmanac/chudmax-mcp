# Proofs: chudmax k8s phase 8 image automation rehearsal

## Sandbox pre-flight (2026-11-27, `verified-here`, no cluster — the standing kind constraint)

Run: `REHEARSAL_PREFLIGHT_ONLY=1 bash k8s/image-automation/image-automation-rehearse.sh` — the
script's own runner-side half (no cluster, no docker):

```
RECEIPT: seed repo at /tmp/image-automation-git/repo.git — main=84d4c831… (the SHA that must never move)
RECEIPT: git server up on :38080 with required basic auth (identity fluxbot)
RECEIPT: the auth fence bites: an unauthenticated ls-remote is refused
RECEIPT: control push to review/image-updates: ACCEPTED (the branch the automation may write)
RECEIPT: the review ref deleted after the control — the automation must create it itself
RECEIPT: control push to main with the SAME credential: DENIED by the pre-receive hook
RECEIPT: pre-flight complete: auth + hook mechanics proven without a cluster
```

- The authed gittestserver module builds (`go vet` + `go build`, zero deps) and enforces basic
  auth: an unauthenticated `git ls-remote` fails fast (`GIT_TERMINAL_PROMPT=0` — the first run
  hung on git's credential prompt; fixed by exporting it in the script).
- **The prompt-hang receipt (`handoff-reported`, the run's CI note):** the pre-fix run's
  unauthenticated `git ls-remote` sat on the terminal for 90 minutes — git opens `/dev/tty` to
  prompt for a username when basic auth is required, unless `GIT_TERMINAL_PROMPT=0` is set; a
  `git-remote-http` child survived the script's kill and held the pts. The fix is an export at
  the top of the script (covers every git call) plus the env set on the check itself, and the
  re-run finishes in seconds under a 120s `timeout` guard.
- **The hook-semantics bug the pre-flight caught (`verified-here`):** the first draft installed
  the stdin-reading main-protection as an `update` hook — but the `update` hook takes
  refname/oldrev/newrev as `$1-3` and its stdin is EMPTY, so the `while read` loop hit EOF and
  the main push was ACCEPTED. The correct shape is a **pre-receive** hook (stdin lines, one
  shot, rejects the push) — `main-protect-hook.sh` is now installed as `hooks/pre-receive` and
  the denial control proves it bites. The hook file's comment carries the lesson.
- Credential hygiene: the summary and the logs greped clean for the credential pattern
  (`fluxbot:<hex>` / `Authorization: Basic`) after the run — `verified-here`.

## Local manifest validation (2026-11-27, `verified-here`, sandbox)

- `flux` CLI v2.10.1 downloaded standalone; **the `schema` command is a PLUGIN** (`unknown
  command "schema"` without it) — installed with `flux plugin install schema` (v0.18.0). In CI
  the flux2 action's `plugins: schema` input does the same thing.
- `flux schema validate <8 manifest files> --schema-location default -v`: **15 resources
  found, Valid: 15, Invalid: 0** — the base set, the rehearsal variants, AND the core kinds
  (Deployment/Service/NetworkPolicy are validated too).
- **Finding:** the validator rejects the plain-values fixture (`/apiVersion: missing required
  property`) — a values file is not a manifest. The CI validate step therefore validates the
  EIGHT manifest files explicitly (multi-path args verified to work) and leaves
  `values-fixture.yaml` to the parse + marker checks.
- The base/rehearsal lockstep greps pass (the three image paths in both shapes, the three
  `$imagepolicy` markers, `review/image-updates` in both automations).
- The RFC1918 hygiene grep over `k8s/image-automation/` is clean.
- `bash -n` on the script + `sh -n` on the hook: clean; the workflow YAML parses.

## What could NOT run here (`speculation` until the CI kind job greens it)

- The kind cluster, Flux install with the image controllers, the registry:2 stand-in, the
  image builds/pushes, the three beats (scan → policy → automation), the status/event
  receipts, and the final ref-list assert — all CI-authoritative (`k8s/image-automation.yml`'s
  `rehearsal` job; `REHEARSAL_PREFLIGHT_ONLY` is never set there).
- Specific unverified mechanics riding into CI (each has a receipt or a recorded fallback in
  the script): the marker env surviving `http-backend → receive-pack → pre-receive` (the hook
  is identity-independent, so the fallback is free); the go-git basic-auth challenge flow
  against the wrapper (401 + WWW-Authenticate); `flux schema validate` multi-arg in CI (same
  binary as the local receipt); podman push over the NodePort with the registries.conf.d
  insecure entry.
