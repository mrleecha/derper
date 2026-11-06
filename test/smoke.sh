#!/bin/sh
# Smoke test for the derper image:
#   1. build the image
#   2. start it with a self-signed manual certificate
#   3. verify the certificate/key were copied and renamed
#   4. verify HTTPS /derp/probe works
#   5. verify fixed flags (manual, no HTTP, fail-closed default) reached derper
#
# Requires: docker, openssl, curl.

set -eu
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-derper:smoke}"
CONTAINER="${CONTAINER:-derper-smoke-$$}"
HOST_PORT="${HOST_PORT:-18443}"

TMP_CERTS="$(mktemp -d)"
cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$TMP_CERTS"
}
trap cleanup EXIT INT TERM

cat >"$TMP_CERTS/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = derper.test

[v3]
subjectAltName = DNS:derper.test
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$TMP_CERTS/source.key" \
    -out "$TMP_CERTS/source.crt" \
    -config "$TMP_CERTS/openssl.cnf" >/dev/null 2>&1

echo "==> building $IMAGE"
build_args=""
if [ -n "${TAILSCALE_VERSION:-}" ]; then
    build_args="--build-arg TAILSCALE_VERSION=$TAILSCALE_VERSION"
fi
# shellcheck disable=SC2086
docker build $build_args -t "$IMAGE" . >/dev/null

echo "==> checking required environment variables"
if docker run --rm "$IMAGE" >/dev/null 2>&1; then
    echo "FAIL: container started without DERP_HOSTNAME / cert / key" >&2
    exit 1
fi

echo "==> checking --version passthrough"
docker run --rm "$IMAGE" --version | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "FAIL: unexpected --version output" >&2
    exit 1
}

echo "==> starting container"
docker run -d --name "$CONTAINER" \
    -p "127.0.0.1:$HOST_PORT:8443/tcp" \
    -e DERP_HOSTNAME=derper.test \
    -e DERP_CERT_FILE=/certs-source/source.crt \
    -e DERP_KEY_FILE=/certs-source/source.key \
    -e DERP_ADDR=:8443 \
    -e DERP_STUN=true \
    -e DERP_STUN_PORT=3479 \
    -e DERP_VERIFY_CLIENTS=false \
    -e DERP_VERIFY_CLIENT_URL=https://127.0.0.1:1/verify \
    -v "$TMP_CERTS/source.crt:/certs-source/source.crt:ro" \
    -v "$TMP_CERTS/source.key:/certs-source/source.key:ro" \
    --tmpfs /var/lib/derper \
    "$IMAGE" >/dev/null

echo "==> waiting for /derp/probe"
i=0
until curl -fsS -k --resolve "derper.test:$HOST_PORT:127.0.0.1" \
    "https://derper.test:$HOST_PORT/derp/probe" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
        echo "FAIL: derper did not become ready in 30s" >&2
        docker logs "$CONTAINER" >&2 || true
        exit 1
    fi
    sleep 1
done

echo "==> checking copied certificate filenames"
docker exec "$CONTAINER" sh -c 'test -s /var/lib/derper/certs/derper.test.crt'
docker exec "$CONTAINER" sh -c 'test -s /var/lib/derper/certs/derper.test.key'

key_mode="$(docker exec "$CONTAINER" stat -c '%a' /var/lib/derper/certs/derper.test.key)"
[ "$key_mode" = "600" ] || {
    echo "FAIL: private key mode is $key_mode, expected 600" >&2
    exit 1
}

echo "==> checking flags passed to derper"
cmdline="$(docker exec "$CONTAINER" sh -c 'tr "\0" " " < /proc/1/cmdline')"
for expected in \
    "--certmode=manual" \
    "--http-port=-1" \
    "--stun=true" \
    "--stun-port=3479" \
    "--verify-clients=false" \
    "--verify-client-url-fail-open=false"; do
    case "$cmdline" in
        *"$expected"*) ;;
        *)
            echo "FAIL: $expected not found in: $cmdline" >&2
            exit 1
            ;;
    esac
done

echo "PASS"
