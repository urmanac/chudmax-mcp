# The chudmax fetcher image: the artifact sidecar only. The pod's MCP server
# runs in its own container (the chart's default is the published canonical
# ticket server, k8s/tickets-mcp/ — bring your own by overriding values);
# nothing else belongs in this image.
#
# Build context is k8s/ (not the repo root):
#
#   podman build --platform linux/amd64,linux/arm64 \
#     --manifest <name>:<tag> -f k8s/image/Dockerfile k8s
#
# The whole manifest-list build is emulation-free: both the Go builder and the
# user-file stage are pinned to $BUILDPLATFORM (the Go stage cross-compiles per
# TARGETARCH; the users stage generates the final base's own /etc/passwd and
# /etc/group plus the nonroot entry, so the final stage needs no RUN at all —
# every RUN in a manifest-list build otherwise executes target-arch binaries
# and wants qemu binfmt).

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
WORKDIR /src
COPY fetcher/go.mod fetcher/go.sum ./
RUN go mod download
COPY fetcher/ ./
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -trimpath -ldflags="-s -w" -o "/out/fetcher" .

# The final stage's user, generated FROM the exact same alpine base so there is
# no drift: the base's own passwd/group plus the nonroot entry (uid/gid 65532,
# the distroless convention). alpine's base already carries the CA bundle the
# fetcher needs for the kube-apiserver's HTTPS.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS users
RUN { cat /etc/passwd; echo "nonroot:x:65532:65532:Linux User,,,:/:/sbin/nologin"; } > /passwd \
 && { cat /etc/group;  echo "nonroot:x:65532:"; } > /group

FROM alpine:3.22
# GHCR links the published image to this repo via this label.
LABEL org.opencontainers.image.source=https://github.com/urmanac/chudmax-mcp
COPY --from=users /passwd /etc/passwd
COPY --from=users /group /etc/group
COPY --from=build /out/fetcher /usr/local/bin/fetcher
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/fetcher"]
