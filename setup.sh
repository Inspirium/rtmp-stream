#!/usr/bin/env bash
# Interactive per-machine setup: writes .env for docker-compose.yml with
# this machine's subdomain and object storage credentials. Re-run any
# time to change values — existing answers are kept as defaults, and the
# previous .env is backed up before being overwritten.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=.env
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a || true

prompt() {
    local label=$1 default=${2:-} value
    read -r -p "$label${default:+ [$default]}: " value
    echo "${value:-$default}"
}

prompt_secret() {
    local label=$1 default=${2:-} value
    read -r -s -p "$label${default:+ [set, press enter to keep]}: " value
    echo >&2
    echo "${value:-$default}"
}

# Picks $1 if free, otherwise the next free port after it (skipping
# anything currently LISTENing on the host) - so running this a second
# time in a sibling directory for another deployment just works, instead
# of silently colliding with the first one on `docker compose up`.
next_free_port() {
    local port=$1
    if ! command -v ss >/dev/null 2>&1; then
        echo "$port"
        return
    fi
    while ss -tln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1))
    done
    echo "$port"
}

echo "== rtmp-stream setup =="
echo

DOMAIN=$(prompt "Subdomain for this machine (e.g. stream1.example.com)" "${DOMAIN:-}")
[ -n "$DOMAIN" ] || { echo "DOMAIN is required" >&2; exit 1; }

echo
echo "-- ports --"
echo "   deploying more than one instance on this machine? each needs its"
echo "   own HTTP_PORT and RTMP_PORT - defaults below are auto-bumped past"
echo "   whatever's already listening on this host."
HTTP_PORT=$(prompt "Host HTTP port (behind your reverse proxy)" "$(next_free_port "${HTTP_PORT:-8080}")")
RTMP_PORT=$(prompt "Host RTMP port (public, for encoders)" "$(next_free_port "${RTMP_PORT:-1935}")")
HTTP_BIND="${HTTP_BIND:-127.0.0.1}"

echo
echo "-- TLS / HTTPS --"
echo "   proxy       (default) terminate TLS yourself in front of this"
echo "               container - see nginx-vhost.sh. Nothing to answer below."
echo "   manual      you supply a cert; this container serves :443 with it."
echo "   letsencrypt this container gets + renews its own cert via certbot."
echo "               DOMAIN's DNS must already point here; needs :80 and"
echo "               :443 reachable from the internet (docker-compose.tls.yml)."
while :; do
    TLS_MODE=$(prompt "TLS_MODE (proxy/manual/letsencrypt)" "${TLS_MODE:-proxy}")
    case "$TLS_MODE" in proxy|manual|letsencrypt) break ;; esac
    echo "must be one of: proxy, manual, letsencrypt" >&2
done
if [ "$TLS_MODE" = letsencrypt ]; then
    while :; do
        LETSENCRYPT_EMAIL=$(prompt "Email for Let's Encrypt renewal/expiry notices" "${LETSENCRYPT_EMAIL:-}")
        [ -n "$LETSENCRYPT_EMAIL" ] && break
        echo "required for TLS_MODE=letsencrypt" >&2
    done
else
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
fi
if [ "$TLS_MODE" != proxy ]; then
    HTTPS_PORT=$(prompt "Host HTTPS port" "${HTTPS_PORT:-443}")
else
    HTTPS_PORT="${HTTPS_PORT:-443}"
fi

echo
echo "-- initial stream key --"
echo "   the secret the encoder publishes with. Its playback id (the"
echo "   public id used in viewer URLs) is derived automatically and"
echo "   can't be reversed back to this key. Leave blank to auto-generate."
echo "   Mint more keys any time later with: docker exec <container> mint-key.sh"
STREAM_KEY=$(prompt_secret "Stream key (blank = auto-generate)" "${STREAM_KEY:-}")

echo
echo "-- DigitalOcean Spaces (or any S3-compatible endpoint) --"
echo "   leave endpoint blank to skip and keep recordings local only"
SPACES_ENDPOINT=$(prompt "Endpoint" "${SPACES_ENDPOINT:-nyc3.digitaloceanspaces.com}")
if [ -n "$SPACES_ENDPOINT" ]; then
    SPACES_BUCKET=$(prompt "Bucket / Space name" "${SPACES_BUCKET:-}")
    SPACES_KEY=$(prompt "Access key" "${SPACES_KEY:-}")
    SPACES_SECRET=$(prompt_secret "Secret key" "${SPACES_SECRET:-}")
    SPACES_PREFIX=$(prompt "Key prefix" "${SPACES_PREFIX:-recordings}")
else
    SPACES_BUCKET=""; SPACES_KEY=""; SPACES_SECRET=""; SPACES_PREFIX="recordings"
fi

echo
echo "-- /control API basic auth --"
echo "   leave password blank to auto-generate one on first start"
CONTROL_USER=$(prompt "Username" "${CONTROL_USER:-admin}")
CONTROL_PASS=$(prompt_secret "Password" "${CONTROL_PASS:-}")

echo
echo "-- admin API token --"
echo "   lets another backend mint/revoke stream keys over HTTP"
echo "   (POST/DELETE /admin/keys) instead of needing shell access here."
echo "   Leave blank to auto-generate one on first start."
ADMIN_API_TOKEN=$(prompt_secret "Admin API token (blank = auto-generate)" "${ADMIN_API_TOKEN:-}")

if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
    echo
    echo "existing .env backed up"
fi

cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN

HTTP_BIND=$HTTP_BIND
HTTP_PORT=$HTTP_PORT
RTMP_PORT=$RTMP_PORT

TLS_MODE=$TLS_MODE
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
HTTPS_PORT=$HTTPS_PORT

STREAM_KEY=$STREAM_KEY

SPACES_ENDPOINT=$SPACES_ENDPOINT
SPACES_BUCKET=$SPACES_BUCKET
SPACES_KEY=$SPACES_KEY
SPACES_SECRET=$SPACES_SECRET
SPACES_PREFIX=$SPACES_PREFIX

CONTROL_USER=$CONTROL_USER
CONTROL_PASS=$CONTROL_PASS

ADMIN_API_TOKEN=$ADMIN_API_TOKEN

KEEP_LOCAL_RECORDINGS=${KEEP_LOCAL_RECORDINGS:-false}
EOF
chmod 600 "$ENV_FILE"

echo
echo "wrote $ENV_FILE for $DOMAIN (HTTP_PORT=$HTTP_PORT, RTMP_PORT=$RTMP_PORT, TLS_MODE=$TLS_MODE)"
echo "next:"
if [ "$TLS_MODE" = proxy ]; then
    echo "  docker compose pull && docker compose up -d"
    echo "  ./nginx-vhost.sh          # prints an nginx server block for this instance"
else
    echo "  docker compose -f docker-compose.yml -f docker-compose.tls.yml pull"
    echo "  docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d"
    if [ "$TLS_MODE" = manual ]; then
        echo "  # then docker cp your fullchain.pem/privkey.pem into the container at"
        echo "  # /etc/letsencrypt/live/$DOMAIN/ (on the certs-data volume) and restart"
    fi
fi
