# chudmax-mcp — the pod's chart

One chart, one pod, two containers: the **fetcher sidecar** (keeps
`/data/current` on the newest verified Flux artifact — see the volume contract
in [`k8s/fetcher/README.md`](../../fetcher/README.md)) and the **MCP server
container**, which by default is this repo's own **mock ticket server**
([`k8s/tickets-mcp-mock/`](../../tickets-mcp-mock/)).

## The default install

```
helm install <release> k8s/chart/chudmax-mcp
```

The default values run the mock in pod mode: `--http 8080 --host 0.0.0.0
--data-root /data`. Every mock call rereads `/data/current` and its
`artifact.json`, so a fetcher swap is visible on the next call without a
restart. Before the ExternalArtifact exists (the `k8s/repo-sync/` work
creates it), the fetcher WAITS — logging and retrying every resync period, no
crash-loop — and self-heals when the artifact appears. The readiness probe is
honest about the wait: the pod is ready only once `/data/current` exists.

Both default image tags (`ghcr.io/urmanac/chudmax/fetcher:0.1.0`,
`ghcr.io/urmanac/chudmax/tickets-mock:0.1.0`) are unpublished until the
phase-10 publishing milestone — build and load them yourself meanwhile:

```
podman build --platform linux/amd64,linux/arm64 \
  --manifest ghcr.io/urmanac/chudmax/fetcher:0.1.0 -f k8s/image/Dockerfile k8s
podman build --platform linux/amd64,linux/arm64 \
  --manifest ghcr.io/urmanac/chudmax/tickets-mock:0.1.0 \
  -f k8s/tickets-mcp-mock/Dockerfile k8s/tickets-mcp-mock
```

## Bring your own server

Override the `server.*` values — keep `--data-root` pointed at the shared
volume so the per-call contract holds:

```
helm upgrade <release> k8s/chart/chudmax-mcp \
  --set server.image.repository=<your-image> \
  --set server.image.tag=<tag> \
  --set server.command[0]=<your-server-binary> \
  --set server.args[0]=--http \
  --set server.args[1]=8080 \
  --set server.args[2]=--data-root \
  --set server.args[3]=/data
```

Set `server.enabled=false` to run the fetcher alone (no Service, no ingress
policy). The values knob `automountServiceAccountToken` is POD-level (the
only level the field exists at); the fetcher gets a short-lived projected
token plus the cluster CA regardless, so a user server is not handed
credentials it did not ask for.

## Optional bearer auth

`server.auth.{enabled,secretName,secretKey}`: when enabled, the chart mounts
the Secret read-only at `/var/run/mcp-auth` and appends
`--bearer-token-file /var/run/mcp-auth/<key>` to the server's args. The mock
reads the file PER REQUEST, so rotating the Secret needs no restart. The
token VALUE never appears in values — only the Secret's name. (The bearer
token is what `kubernetes/mcp.md` specifies for the hub-facing deployment:
it identifies a caller, not a person.)

## The egress knobs

The egress NetworkPolicy is default-on; the rules it renders:

- DNS (kube-system, UDP/TCP 53),
- the **kube-apiserver** on 443 — `mode: podSelector` by default (the
  apiserver's static pods, `component: kube-apiserver` in the namespace the
  values name; Cilium matches policy on the resolved backend, which the
  service-CIDR ipBlock alternative — `mode: cidr` — is unreliable under),
- the **artifact server** — source-watcher's storage (default port 9090),
  scoped to that controller's PODS via `sourceController.selector`,

plus `networkPolicy.egress.extra` passthrough. The podSelectors hit ALL
containers in the pod: a server with other egress needs adjusts the
passthroughs or disables the policies. Match your platform's Flux install
(the phase-12 inventory walks it).
