# chudmax — the umbrella chart

The whole installable ChudMax stack as one release:

- **engine** (`subcharts/chudmax-engine`) — the pointer: a Service without a
  selector + the EndpointSlice at `engine.endpoint.host` (empty default; the
  real address is installer-supplied, phase 11+).
- **web** (`subcharts/chudmax-web`) — Strata `--engine mock`: real `/health`,
  `/mcp`, `/v1/chat/completions` with the scripted MockEngine; the image is
  built from the public `kingdonb/Strata` at the pin below (unpublished until
  phase 10 — build/load it yourself until then).
- **mcp** (`file://../../../chart/chudmax-mcp`, referenced read-only) — the
  fetcher sidecar + the published canonical ticket server (4b defaults); the
  fetcher waits for an ExternalArtifact until the repo-sync objects run.

## Pins

| What | Value |
|---|---|
| Strata (the web image's source) | `de34ebaa521d8f628b4bb1884e5c34101730299a` (tag `v0.2.21-mbp.rtx.1`) |
| kind (the rehearsal) | `v0.33.0` |
| The images' references | `ghcr.io/urmanac/chudmax/{web,fetcher,tickets-mcp}:0.1.0` — all unpublished until phase 10; the rehearsal builds and loads them (no registry) |

## Install

    helm dependency build k8s/umbrella/chudmax
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

## Phase-10 note

The in-tree subcharts move out to `urmanac/chudmax-engine` and
`urmanac/chudmax-web` at the publishing milestone, and these `file://`
repositories flip to the published OCI chart references
(`ghcr.io/urmanac/chudmax/*`).
