# chudmax-engine — the engine pointer chart

The ChudMax engine runs where it runs (the GPU host) and is never containerized.
This chart gives the cluster a **stable in-cluster name for that external
engine**: a Service **without a selector** (nothing selects pods — there are
none) plus a manual **EndpointSlice** at the engine's address. Nothing here
renders a workload, on purpose.

## The alias note (why a pointer Service)

Installers point pods and config at the Service name once:

    http://<fullname>.<namespace>.svc:<service.port>      # default port 8080

When the engine moves or changes ports, only the EndpointSlice changes — no
client is touched. The Service port (`service.port`, default 8080, with the
named `targetPort: http`) is deliberately decoupled from the EndpointSlice port
(`endpoint.port`) — the named ports connect them, so the engine's own port can
differ from the client-facing one.

## Values

| Value | Default | Meaning |
|---|---|---|
| `service.port` | `8080` | The client-facing port (the stable in-cluster name). |
| `endpoint.host` | `""` (empty) | **SET THIS TO YOUR ENGINE'S ADDRESS.** Empty → the Service renders with no endpoints; the EndpointSlice renders only when set. The real address is installer-supplied and never committed (same hygiene as credentials). |
| `endpoint.port` | `8080` | The engine's port at that host (the EndpointSlice port). |
| `test.enabled` | `true` | The `/health` Helm test hook ("first test of any cluster"). |
| `test.image` | `curlimages/curl:8.12.1` | The hook pod's image. |

## The first test of any cluster

    helm test <release>

A hook pod curls `/health` through the Service and passes on 200. With the
endpoint unset it fails by design. The identical hook rehearses the mock engine
on kind (the umbrella's rehearsal) and the real engine on the platform
(phase 11) — one probe, two lifetimes.

## Alternatives and notes

- **Legacy Endpoints** (core/v1) work identically if a platform prefers them;
  EndpointSlice is the modern object and is what ships here.
- Endpoint IPs must not be ClusterIPs — this names a real host (the LAN address
  in production; the docker bridge in the kind rehearsal).
- No RBAC (nothing watches anything), no NetworkPolicy (nothing to protect),
  no image (nothing to run).
- The address is values-driven and effectively required: CI templates use RFC
  5737 documentation IPs (`203.0.113.10`); a real LAN address never enters a
  public artifact.
