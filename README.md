# derper

A small, opinionated Docker image for a self-hosted
[Tailscale DERP server](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers).

Published to GHCR as **`ghcr.io/mrleecha/derper`**.

[![docker](https://github.com/mrleecha/derper/actions/workflows/docker.yml/badge.svg)](https://github.com/mrleecha/derper/actions/workflows/docker.yml)

## Design

- **Manual TLS certificates only.** You provide a certificate chain and private
  key; the entrypoint copies them to the filenames `derper` expects.
- **No ACME, no Let's Encrypt, no HTTP `:80` listener.** Obtain certificates with
  `acme.sh`, `certbot`, Caddy, or your existing PKI.
- **Minimal configuration.** Three required environment variables, six optional.
  Everything else uses safe, fixed defaults.
- **Pinned and reproducible.** Tailscale `v1.104.5`, Go `1.27.3`, Alpine `3.24`.
  Multi-arch: `linux/amd64`, `linux/arm64`.
- **Client verification.** Headscale-compatible admission control, fail-closed
  by default.

The image contains the upstream `tailscale.com/cmd/derper` binary plus a small
entrypoint. It is not affiliated with Tailscale Inc.

## Quick start

You need a certificate whose SAN covers `DERP_HOSTNAME`. A wildcard certificate
works.

```bash
mkdir -p /srv/derper/certs /srv/derper/data

# Example: acme.sh with DNS-01 (use --webroot/--standalone if you have port 80)
acme.sh --issue --dns dns_cf -d example.com -d '*.example.com'
acme.sh --install-cert -d example.com --ecc \
  --key-file       /srv/derper/certs/derp.example.com.key \
  --fullchain-file /srv/derper/certs/fullchain.cer \
  --reloadcmd      "docker compose -f /srv/derper/compose.yaml restart derper"
```

Create `/srv/derper/.env`:

```dotenv
DERP_HOSTNAME=derp.example.com
DERP_CERT_FILE=/certs/fullchain.cer
DERP_KEY_FILE=/certs/derp.example.com.key
DERP_ADDRESS=:8443
```

Create `/srv/derper/compose.yaml`:

```yaml
services:
  derper:
    image: ghcr.io/mrleecha/derper:latest
    # To build from this checkout instead of pulling from GHCR:
    # build: .
    container_name: derper
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - ./certs:/certs:ro
      - ./data:/var/lib/derper
```

Start it:

```bash
cd /srv/derper
docker compose up -d
docker compose logs -f derper
```

Verify:

```bash
curl -fsS https://derp.example.com:8443/derp/probe
```

HTTP `200` with an empty body means the server is healthy.

Then add the node to your DERP map (see [DERP map](#derp-map)).

### `docker run`

```bash
docker run -d --name derper --network host --restart unless-stopped \
  -e DERP_HOSTNAME=derp.example.com \
  -e DERP_CERT_FILE=/certs/fullchain.cer \
  -e DERP_KEY_FILE=/certs/derp.example.com.key \
  -e DERP_ADDRESS=:8443 \
  -v /srv/derper/certs:/certs:ro \
  -v /srv/derper/data:/var/lib/derper \
  ghcr.io/mrleecha/derper:latest
```

## Certificates

`DERP_CERT_FILE` and `DERP_KEY_FILE` are paths **inside the container**. Mount
the directory that contains them read-only (for example `- ./certs:/certs:ro`).

At startup the entrypoint copies them to:

```text
/var/lib/derper/certs/<hostname>.crt   0644
/var/lib/derper/certs/<hostname>.key   0600
```

`<hostname>` is `DERP_HOSTNAME` with every character outside `[a-zA-Z0-9.-]`
removed, matching `cmd/derper/cert.go`. For normal DNS names the filename is
unchanged.

- Both variables are required. There is no fallback to `letsencrypt`.
- The certificate must be valid for `DERP_HOSTNAME`; `derper` verifies this at
  startup and exits on mismatch.
- `derper` reads the certificate once at startup. **Restart the container after
  renewal.** The `acme.sh --reloadcmd` above does this automatically.
- Mount `/var/lib/derper` if you want to keep the server's node key across
  container re-creations.

## Client verification

To prevent other tailnets from using your DERP server, point it at an admission
controller. For Headscale, the endpoint is `/verify`:

```yaml
environment:
  DERP_VERIFY_CLIENT_URL: https://hs.example.com/verify
  DERP_VERIFY_CLIENT_URL_FAIL_OPEN: "false"   # default
```

- The default is **fail-closed** (`false`): if the admission controller is
  unreachable, new clients are rejected. This differs from upstream `derper`,
  whose default is `true`. Set it to `true` only if availability matters more
  than strict admission.
- The controller must be reachable from the container (HTTPS recommended). The
  image includes `ca-certificates`.

If `DERP_VERIFY_CLIENT_URL` is empty, **anyone** who knows the address can add
this DERP to their own DERP map. The entrypoint logs a warning in this case.

## Configuration

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `DERP_HOSTNAME` | yes | — | TLS hostname; must match the certificate |
| `DERP_CERT_FILE` | yes | — | Container path to the certificate chain (PEM) |
| `DERP_KEY_FILE` | yes | — | Container path to the private key (PEM) |
| `DERP_ADDRESS` | no | `:8443` | HTTPS listen address (`:8443`, `:443`, `1.2.3.4:8443`) |
| `DERP_STUN` | no | `true` | Run the STUN server |
| `DERP_STUN_PORT` | no | `3478` | STUN UDP port |
| `DERP_VERIFY_CLIENT_URL` | no | empty | Admission controller URL (e.g. Headscale `/verify`) |
| `DERP_VERIFY_CLIENT_URL_FAIL_OPEN` | no | `false` | Allow clients if the controller is unreachable |
| `DERP_EXTRA_ARGS` | no | empty | Extra `derper` flags, space-separated; appended last |

`DERP_EXTRA_ARGS` is an escape hatch for flags that are intentionally not exposed
as first-class variables. Because it is appended last, it can override any of the
fixed flags below.

### Fixed flags

| Flag | Value |
|---|---|
| `--certmode` | `manual` |
| `--certdir` | `/var/lib/derper/certs` |
| `--http-port` | `-1` (no HTTP `:80` listener) |
| `--derp` | `true` |
| `--verify-clients` | `false` |
| `-c` | `/var/lib/derper/derper.key` |

There is no HTTP listener because this image is manual-cert only: ACME HTTP-01
is not needed, and DERP itself runs over HTTPS. Set `canport80: false` in the
DERP map. If you specifically need DERP-over-HTTP on port 80, override it with
`DERP_EXTRA_ARGS: "--http-port=80"` and open port 80.

### Data

`/var/lib/derper` is the only stateful directory:

```text
/var/lib/derper/derper.key      # node key, created on first start
/var/lib/derper/certs/          # normalized certificate copies
```

Mount it as a volume. Without it, the node key is recreated whenever the
container is recreated.

## Ports and networking

| Port | Protocol | Purpose |
|---|---|---|
| `DERP_ADDRESS` (default `8443`) | TCP | DERP over HTTPS |
| `DERP_STUN_PORT` (default `3478`) | UDP | STUN |

- `network_mode: host` is recommended. DERP identifies clients by source IP, and
  Docker bridge port mapping performs SNAT. Tailscale also requires custom DERP
  servers to be directly reachable, not behind NAT or a load balancer.
- Allow inbound and outbound **ICMP**.
- The default HTTPS port is `8443` because `443` is often already used by
  Caddy/Nginx. To use the standard port, set `DERP_ADDRESS=:443`. The port you
  choose must match `derpport` in the DERP map.
- Use a firewall to allow only the ports above. There is no need to open `80`.

## DERP map

Headscale (`derp.yaml`) example:

```yaml
regions:
  900:
    regionid: 900
    regioncode: home
    regionname: Home
    nodes:
      - name: home
        regionid: 900
        hostname: derp.example.com
        ipv4: 203.0.113.10
        derpport: 8443         # or 443 if DERP_ADDRESS=:443
        stunport: 3478         # match DERP_STUN_PORT
        canport80: false
```

For Tailscale's hosted control plane, add the same node under
`derpMap.Regions` in the tailnet policy file. Region IDs `900`–`999` are reserved
for custom DERP servers, and a region can contain only one DERP node.

## Building and publishing

Local build:

```bash
make build                 # tags derper:dev
make test                  # builds + runs the smoke test

# Pin a different Tailscale release
make build TAILSCALE_VERSION=v1.105.0
```

The GitHub Actions workflow (`.github/workflows/docker.yml`) runs the smoke test
and publishes a multi-arch image to GHCR:

- push to `main` → `latest`, `sha-<commit>`
- tag `v1.104.5` → `1.104.5`, `1.104`, `latest`
- pull request → build only, no push

The workflow publishes to `ghcr.io/mrleecha/derper`.

After the first publish, set the package visibility to **public** in
GitHub → your profile/org → Packages → `derper` → Settings.

Releasing a new image:

```bash
git tag v1.104.5
git push origin v1.104.5
```

To build for a specific architecture locally:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/mrleecha/derper:dev --load .
```

### Upgrading Tailscale

1. Change `TAILSCALE_VERSION` in the `Dockerfile`.
2. Check the tag's `go.mod`: if it requires a newer Go version, bump `GO_IMAGE`.
3. Run `make test`.
4. Tag the repository with the same version and let CI publish, or build/push
   manually.

## Troubleshooting

```bash
# Health probe (HTTPS listener)
curl -fsS https://derp.example.com:8443/derp/probe

# Container logs
docker logs -f derper

# Flags actually passed to derper (derper is PID 1)
docker exec derper sh -c 'tr "\0" " " < /proc/1/cmdline; echo'

# Certificate filenames and permissions
docker exec derper ls -l /var/lib/derper/certs
```

| Symptom | Cause |
|---|---|
| `cert invalid for hostname "..."` | Certificate does not cover `DERP_HOSTNAME` |
| `cert mismatch with hostname` | Client SNI differs from `DERP_HOSTNAME`; check the DERP map `hostname` |
| `can not load x509 key pair` | Wrong paths, missing files, or key does not match the certificate |
| `address already in use` | The `DERP_ADDRESS` TCP port or `DERP_STUN_PORT` UDP port is taken; change it |
| Clients get rejected after Headscale restarts | Expected with fail-closed; wait for the controller or set `DERP_VERIFY_CLIENT_URL_FAIL_OPEN=true` |
| Clients do not use this DERP | The DERP map has not propagated, or `derpport` is wrong; check `tailscale netcheck` |

## Security

- DERP relays end-to-end encrypted traffic and cannot read it.
- Without `DERP_VERIFY_CLIENT_URL`, the server is an open relay for any tailnet
  that adds it. Public deployments should configure verification.
- The container runs as root so it can bind ports below 1024. To drop privileges,
  set `user:` and `cap_add: [NET_BIND_SERVICE]` in compose, and make
  `/var/lib/derper` writable by that user.

## License

BSD-3-Clause. The `derper` binary is part of
[Tailscale](https://github.com/tailscale/tailscale) and is distributed under the
same license.
