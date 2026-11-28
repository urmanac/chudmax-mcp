# chudmax — the umbrella chart

The whole installable ChudMax stack as one release:

- **engine** (`oci://ghcr.io/urmanac/chudmax-engine` — published by
  `urmanac/chudmax-engine`) — the pointer: a Service without a selector + the
  EndpointSlice at `engine.endpoint.host` (empty default; the real address is
  installer-supplied, phase 11+).
- **web** (`oci://ghcr.io/urmanac/chudmax-web` — published by
  `urmanac/chudmax-web`) — Strata `--engine mock`: real `/health`, `/mcp`,
  `/v1/chat/completions` with the scripted MockEngine; the image
  (`ghcr.io/urmanac/chudmax/web`) is built and cosign-signed by that repo's CI
  (the Strata pin lives in its `web-image/README.md`).
- **mcp** (`file://../../chart/chudmax-mcp`, referenced read-only) — the
  fetcher sidecar + the published canonical ticket server (4b defaults); the
  fetcher waits for an ExternalArtifact until the repo-sync objects run.

## Pins

| What | Value |
|---|---|
| Strata (the web image's source) | `de34ebaa521d8f628b4bb1884e5c34101730299a` (tag `v0.2.21-mbp.rtx.1`) |
| kind (the rehearsal) | `v0.33.0` |
| The images' references | `ghcr.io/urmanac/chudmax/{web,fetcher,tickets-mcp}:0.1.0` — published by their repos' CI on `v<semver>` tags (cosign-signed, public packages); the rehearsal pulls web and builds fetcher/tickets in-repo |

## Install

    helm dependency update k8s/umbrella/chudmax
    helm install chudmax k8s/umbrella/chudmax -n chudmax --create-namespace \
      --set engine.endpoint.host=<your-engine-host>     # e.g. the engine's address; empty = no endpoints

The children are named deterministically (`chudmax-engine`, `chudmax-web`,
`chudmax-mcp`) via `fullnameOverride` regardless of the release name.

## The rehearsal

`kind-smoke.sh` (same directory) proves, on stock kind with the chart defaults:

1. `/health` through the **engine Service** — pod → selectorless Service →
   EndpointSlice → **external host** (the mock engine container runs OUTSIDE
   kind on the docker bridge — the exact production topology; the LAN address
   in production, the bridge here);
2. the web pod answering `/health` through its Service (the curl's Host header
   is the Service DNS name — Strata's DNS-rebinding guard and its
   `STRATA_ALLOWED_HOSTS` auto default are thereby proven);
3. the mcp pod: Running; the server answering HTTP 200 (`initialize`) on its
   POD port (the Service admits only READY pods and the fetcher sidecar is
   not-ready pre-artifact **by design** — the Service's empty endpoint set is
   recorded as the honest receipt); the fetcher's logs showing the apiserver
   **404 NotFound** ("does not exist yet, waiting") — with kindnet enforcing
   NetworkPolicy, a *blocked* fetcher and a *waiting* one look identical on
   pod status; the 404 in the logs is what proves the egress rule let it reach
   kube-apiserver. The rehearsal ships a **minimal ExternalArtifact CRD as a
   mapping fixture** (no Flux controller — phase 5's rehearsal owns the real
   artifact flow); without a served mapping the fetcher's client fails at
   discovery instead of answering 404;
4. **no Cilium CRDs** rendered/installed with the chart defaults on stock kind
   (phase 5's `apiServer.mode: auto` gate passes cleanly) — asserted on the
   CRD shape, not the word (the mcp chart's egress template explains Cilium in
   comments that render verbatim);

NOT proven here: the commit→tickets data path (phase 5's rehearsal owns it).

## The published children (the phase-10 split)

The engine and web subcharts left the workbench at the phase-10 milestone:
they live in their own public repos and publish OCI charts (cosign-signed) on
`v<semver>` tags — `urmanac/chudmax-engine`, `urmanac/chudmax-web` — and this
chart's dependencies resolve those references (`helm dependency update`,
credential-free once the GHCR packages are public). The mcp chart remains
in-tree in this repo. The web image is published by `urmanac/chudmax-web` (the
`ghcr.io/urmanac/chudmax/web` package); this repo's kind rehearsal pulls it.
