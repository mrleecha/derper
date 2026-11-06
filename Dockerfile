# syntax=docker/dockerfile:1

# Tailscale v1.104.5's go.mod requires Go >= 1.27.3. Check the tag's go.mod
# before bumping TAILSCALE_VERSION.
ARG GO_IMAGE=golang:1.27.3-alpine
ARG RUNTIME_IMAGE=alpine:3.24

FROM ${GO_IMAGE} AS build

ARG TAILSCALE_VERSION=v1.104.5

RUN apk add --no-cache ca-certificates git
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    VERSION_NO_V="${TAILSCALE_VERSION#v}" && \
    CGO_ENABLED=0 go install -trimpath \
        -ldflags="-s -w -X tailscale.com/version.longStamp=${VERSION_NO_V} -X tailscale.com/version.shortStamp=${VERSION_NO_V}" \
        tailscale.com/cmd/derper@${TAILSCALE_VERSION}

FROM ${RUNTIME_IMAGE}

ARG TAILSCALE_VERSION=v1.104.5

LABEL org.opencontainers.image.title="derper" \
      org.opencontainers.image.description="Minimal self-hosted Tailscale DERP server with manual TLS certificates" \
      org.opencontainers.image.version="${TAILSCALE_VERSION}" \
      org.opencontainers.image.licenses="BSD-3-Clause"

RUN apk add --no-cache ca-certificates \
 && mkdir -p /var/lib/derper/certs

COPY --from=build /go/bin/derper /usr/local/bin/derper
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/derper /usr/local/bin/docker-entrypoint.sh

# The HTTPS listener is DERP_ADDR (443 by default); STUN is 3478/udp.
# The HTTP :80 listener is deliberately disabled (--http-port=-1).
EXPOSE 443/tcp 3478/udp

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
