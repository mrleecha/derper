#!/bin/sh
# Minimal entrypoint for the public derper image.
#
# TLS certificates are always managed manually:
#   DERP_CERT_FILE / DERP_KEY_FILE
#     -> /var/lib/derper/certs/<hostname>.crt
#     -> /var/lib/derper/certs/<hostname>.key
#
# Everything else is fixed (see README). DERP_EXTRA_ARGS is the escape hatch.

set -eu

CERT_DIR=/var/lib/derper/certs
CONFIG_FILE=/var/lib/derper/derper.key

log() {
    printf '%s derper-entrypoint: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
    log "error: $*"
    exit 1
}

# Keep `docker run --rm <image> --version` / `--help` usable.
case "${1:-}" in
    --version|-version|--help|-help|-h)
        exec /usr/local/bin/derper "$@"
        ;;
esac

if [ "$#" -gt 0 ]; then
    die "unexpected command arguments: $* (use DERP_* environment variables)"
fi

DERP_HOSTNAME="${DERP_HOSTNAME:-}"
DERP_CERT_FILE="${DERP_CERT_FILE:-}"
DERP_KEY_FILE="${DERP_KEY_FILE:-}"
DERP_ADDRESS="${DERP_ADDRESS:-:8443}"
DERP_STUN="${DERP_STUN:-true}"
DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
DERP_VERIFY_CLIENT_URL="${DERP_VERIFY_CLIENT_URL:-}"
DERP_VERIFY_CLIENT_URL_FAIL_OPEN="${DERP_VERIFY_CLIENT_URL_FAIL_OPEN:-false}"
DERP_EXTRA_ARGS="${DERP_EXTRA_ARGS:-}"

[ -n "$DERP_HOSTNAME" ] || die "DERP_HOSTNAME is required"
[ -n "$DERP_ADDRESS" ] || die "DERP_ADDRESS must not be empty"
[ -n "$DERP_CERT_FILE" ] || die "DERP_CERT_FILE is required (this image is manual-cert only)"
[ -n "$DERP_KEY_FILE" ] || die "DERP_KEY_FILE is required (this image is manual-cert only)"

[ -f "$DERP_CERT_FILE" ] || die "DERP_CERT_FILE not found: $DERP_CERT_FILE"
[ -f "$DERP_KEY_FILE" ] || die "DERP_KEY_FILE not found: $DERP_KEY_FILE"
[ -r "$DERP_CERT_FILE" ] || die "DERP_CERT_FILE not readable: $DERP_CERT_FILE"
[ -r "$DERP_KEY_FILE" ] || die "DERP_KEY_FILE not readable: $DERP_KEY_FILE"
[ -s "$DERP_CERT_FILE" ] || die "DERP_CERT_FILE is empty: $DERP_CERT_FILE"
[ -s "$DERP_KEY_FILE" ] || die "DERP_KEY_FILE is empty: $DERP_KEY_FILE"

case "$DERP_VERIFY_CLIENT_URL" in
    "") ;;
    http://*|https://*) ;;
    *) die "DERP_VERIFY_CLIENT_URL must be an http(s) URL: $DERP_VERIFY_CLIENT_URL" ;;
esac

if [ -z "$DERP_VERIFY_CLIENT_URL" ]; then
    log "warning: DERP_VERIFY_CLIENT_URL is empty; this DERP will accept any client"
fi

# Must match cmd/derper/cert.go's unsafeHostnameCharacters: [^a-zA-Z0-9-.]
sanitize_hostname() {
    printf '%s' "$1" | sed 's/[^a-zA-Z0-9.-]//g'
}

install_cert_file() {
    src=$1
    dst=$2
    mode=$3

    if [ -e "$dst" ] && [ "$src" -ef "$dst" ]; then
        log "source and destination are the same file, leaving it untouched: $dst"
        return 0
    fi

    tmp="${dst}.tmp.$$"
    cp "$src" "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dst"
}

base="$(sanitize_hostname "$DERP_HOSTNAME")"
[ -n "$base" ] || die "cannot derive a certificate filename from DERP_HOSTNAME: $DERP_HOSTNAME"

mkdir -p "$CERT_DIR"
install_cert_file "$DERP_CERT_FILE" "$CERT_DIR/$base.crt" 0644
install_cert_file "$DERP_KEY_FILE" "$CERT_DIR/$base.key" 0600

log "certificate: $DERP_CERT_FILE -> $CERT_DIR/$base.crt"
log "private key: $DERP_KEY_FILE -> $CERT_DIR/$base.key"

set -- \
    "--hostname=$DERP_HOSTNAME" \
    "--certmode=manual" \
    "--certdir=$CERT_DIR" \
    "--a=$DERP_ADDRESS" \
    "--http-port=-1" \
    "--stun=$DERP_STUN" \
    "--stun-port=$DERP_STUN_PORT" \
    "--derp=true" \
    "-c=$CONFIG_FILE" \
    "--verify-clients=false" \
    "--verify-client-url=$DERP_VERIFY_CLIENT_URL" \
    "--verify-client-url-fail-open=$DERP_VERIFY_CLIENT_URL_FAIL_OPEN"

if [ -n "$DERP_EXTRA_ARGS" ]; then
    # Intentional word splitting: allows passing several extra flags at once.
    # shellcheck disable=SC2086
    set -- "$@" $DERP_EXTRA_ARGS
fi

log "starting: hostname=$DERP_HOSTNAME addr=$DERP_ADDRESS stun=$DERP_STUN stun_port=$DERP_STUN_PORT verify_client_url=${DERP_VERIFY_CLIENT_URL:-<none>} fail_open=$DERP_VERIFY_CLIENT_URL_FAIL_OPEN"

exec /usr/local/bin/derper "$@"
