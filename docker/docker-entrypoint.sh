#!/bin/sh
# Renders this container's nginx site config from DOMAIN/SPACES_*/CONTROL_*
# env vars, wires up object storage credentials, then hands off to nginx.
set -eu

: "${DOMAIN:?DOMAIN env var is required, e.g. stream1.example.com}"
: "${SPACES_PREFIX:=recordings}"
: "${KEEP_LOCAL_RECORDINGS:=false}"
: "${TLS_MODE:=proxy}"
export DOMAIN

case "$TLS_MODE" in
    proxy|manual|letsencrypt) ;;
    *)
        echo "[setup] TLS_MODE must be one of: proxy, manual, letsencrypt (got '$TLS_MODE')" >&2
        exit 1
        ;;
esac

NGINX_PREFIX=/usr/local/nginx
TEMPLATES=$NGINX_PREFIX/conf/templates
CONF_D=$NGINX_PREFIX/conf/conf.d
RTMP_D=$NGINX_PREFIX/conf/rtmp.d
LOCATIONS_D=$NGINX_PREFIX/conf/site-locations

mkdir -p "$CONF_D" "$RTMP_D" "$LOCATIONS_D" /tmp/rec /tmp/hls /tmp/dash /tmp/rec-pending /var/www/certbot
rm -f "$CONF_D"/*.conf "$RTMP_D"/*.conf
# nginx workers run as the compiled-in default user, not root - make sure
# they can write recordings/segments regardless of what that user turns
# out to be
chmod 1777 /tmp/rec /tmp/hls /tmp/dash
# /tmp/rec-pending holds pending record-start.cgi filenames: written by
# root (via fcgiwrap) but read AND DELETED by record-done.sh, which runs
# as the nginx worker's user - no sticky bit here, since sticky would let
# only a file's owner delete it, and these two users need to delete each
# other's files
chmod 777 /tmp/rec-pending

# --- object storage (DigitalOcean Spaces or any S3-compatible endpoint) --
# mc's config (holds the Spaces secret key) has to live somewhere the
# *upload* step can also read it: exec_record_done below runs record-done.sh
# as the nginx worker's unprivileged user (not root), which strips HOME and
# every other env var except TZ, so the default $HOME/.mc here (root's,
# mode 700) would be unreachable from there. /data is already the
# cross-user-writable volume (see stream_keys.map above); MC_CONFIG_DIR
# pins mc to a spot on it instead, opened up just enough for that worker
# user to read.
export MC_CONFIG_DIR=/data/.mc
mkdir -p "$MC_CONFIG_DIR"

UPLOAD_ENABLED=false
if [ -n "${SPACES_KEY:-}" ] && [ -n "${SPACES_SECRET:-}" ] \
   && [ -n "${SPACES_BUCKET:-}" ] && [ -n "${SPACES_ENDPOINT:-}" ]; then
    # a bad key/endpoint here shouldn't take the whole stream down - fall
    # back to local-only recording and let the operator fix it later
    if mc alias set spaces "https://${SPACES_ENDPOINT}" "$SPACES_KEY" "$SPACES_SECRET" >/dev/null 2>&1; then
        UPLOAD_ENABLED=true
        # mc also writes/creates under here at run time (e.g. certs/CAs),
        # not just config.json - the worker user needs write, not just read
        chmod -R 777 "$MC_CONFIG_DIR"
        echo "[setup] recordings will be uploaded to spaces/${SPACES_BUCKET}/${SPACES_PREFIX}/${DOMAIN}/"
    else
        echo "[setup] failed to reach SPACES_ENDPOINT (${SPACES_ENDPOINT}) - recordings stay local only, in /tmp/rec" >&2
    fi
else
    echo "[setup] SPACES_ENDPOINT/SPACES_BUCKET/SPACES_KEY/SPACES_SECRET not all set - recordings stay local only, in /tmp/rec"
fi
# non-empty placeholders: an empty token here would shift the positional
# args nginx passes to record-done.sh via exec_record_done
: "${SPACES_BUCKET:=-}"
: "${SPACES_PREFIX:=-}"

# --- ingest keys vs playback ids ----------------------------------------
# stream_keys.map (on the /data volume, so it survives restarts) holds
# every valid "<stream_key>" playback_id; pair. playback_id is a one-way
# sha256 encoding of stream_key - derivable from the key, but the key
# can't be recovered from it - so a known playback URL can't be used to
# publish. Add more keys any time with `docker exec <container>
# mint-key.sh`, no restart needed. Here we only seed the map on first
# boot: from STREAM_KEY if given, otherwise by generating one, and only
# if it's not already there (so restarts don't grow the file).
MAP_FILE=/data/stream_keys.map
LOCK_FILE=/data/stream_keys.map.lock
mkdir -p /data
touch "$MAP_FILE" "$LOCK_FILE"

sha256_16() { printf '%s' "$1" | openssl dgst -sha256 -hex | awk '{print $NF}' | cut -c1-16; }

if [ -n "${STREAM_KEY:-}" ]; then
    # gets written verbatim into an nginx-parsed map file below - restrict
    # to a safe charset rather than risk config injection from .env
    case "$STREAM_KEY" in
        *[!A-Za-z0-9_-]*)
            echo "[setup] STREAM_KEY must only contain letters, digits, '_' or '-'" >&2
            exit 1
            ;;
    esac
    SEEDED_KEY=$STREAM_KEY
elif [ ! -s "$MAP_FILE" ]; then
    SEEDED_KEY=$(openssl rand -hex 20)
    echo "[setup] generated an initial stream key (keep it secret)"
    echo "[setup] set STREAM_KEY env var to pin this across restarts"
else
    SEEDED_KEY=""
fi

if [ -n "$SEEDED_KEY" ]; then
    SEEDED_PLAYBACK_ID=$(sha256_16 "$SEEDED_KEY")
    (
        flock -x 9
        if ! grep -qF "\"${SEEDED_KEY}\"" "$MAP_FILE"; then
            printf '"%s" %s;\n' "$SEEDED_KEY" "$SEEDED_PLAYBACK_ID" >> "$MAP_FILE"
        fi
    ) 9>"$LOCK_FILE"
    echo "[setup] publish to:  rtmp://${DOMAIN}/stream/${SEEDED_PLAYBACK_ID}?key=${SEEDED_KEY}"
    echo "[setup] play back:   http://${DOMAIN}/hls/${SEEDED_PLAYBACK_ID}.m3u8"
    echo "${SEEDED_PLAYBACK_ID}" > "$NGINX_PREFIX/html/playback-id.txt"
fi
echo "[setup] mint more stream keys any time: docker exec <container> mint-key.sh"
echo "[setup] or via the API:                 POST /admin/keys (Authorization: Bearer <token>)"

# --- admin API (POST/DELETE /admin/keys, see admin-api.cgi) ------------
# lets an external backend mint/revoke keys over HTTP instead of needing
# docker exec. Served via fcgiwrap, which we start ourselves - nginx just
# proxies /admin to it. Put this behind HTTPS in production: the bearer
# token below is a plain secret on the wire otherwise.
if [ -z "${ADMIN_API_TOKEN:-}" ]; then
    ADMIN_API_TOKEN=$(openssl rand -hex 24)
    echo "[setup] generated ADMIN_API_TOKEN (keep this secret): ${ADMIN_API_TOKEN}"
    echo "[setup] set ADMIN_API_TOKEN env var to pin this across restarts"
fi
export ADMIN_API_TOKEN
mkdir -p /run
rm -f /run/fcgiwrap.sock
fcgiwrap -s unix:/run/fcgiwrap.sock &
# nginx workers run as the compiled-in default user (not root, see the
# /tmp/rec note above) - wait for fcgiwrap to create the socket, then
# open it up so that user can connect to it too
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S /run/fcgiwrap.sock ] && break
    sleep 0.2
done
chmod 666 /run/fcgiwrap.sock

# --- /control API basic auth ------------------------------------------
CONTROL_HTPASSWD=$NGINX_PREFIX/conf/control.htpasswd
CONTROL_USER=${CONTROL_USER:-admin}
if [ -z "${CONTROL_PASS:-}" ]; then
    CONTROL_PASS=$(openssl rand -base64 18)
    echo "[setup] generated /control password for user '${CONTROL_USER}': ${CONTROL_PASS}"
    echo "[setup] set CONTROL_USER/CONTROL_PASS env vars to pin this across restarts"
fi
printf '%s:%s\n' "$CONTROL_USER" "$(openssl passwd -apr1 "$CONTROL_PASS")" > "$CONTROL_HTPASSWD"

# --- render this container's site config -------------------------------
# site-locations holds the location{} blocks shared by the :80 and (if
# enabled below) :443 server blocks - kept in one file so the security-
# sensitive `allow 127.0.0.1` locations can't drift between two copies.
rm -f "$LOCATIONS_D"/*.conf
envsubst '$DOMAIN' \
    < "$TEMPLATES/site-locations.conf.template" > "$LOCATIONS_D/${DOMAIN}.conf"

envsubst '$DOMAIN' \
    < "$TEMPLATES/http-site.conf.template" > "$CONF_D/${DOMAIN}.conf"

export UPLOAD_ENABLED SPACES_BUCKET SPACES_PREFIX KEEP_LOCAL_RECORDINGS
envsubst '$DOMAIN $UPLOAD_ENABLED $SPACES_BUCKET $SPACES_PREFIX $KEEP_LOCAL_RECORDINGS' \
    < "$TEMPLATES/rtmp-site.conf.template" > "$RTMP_D/${DOMAIN}.conf"

echo "[setup] configured for ${DOMAIN}"

# --- TLS -----------------------------------------------------------------
# TLS_MODE=proxy (default): nothing to do - terminate TLS in front of this
#   container (see nginx-vhost.sh / README's "Multiple deployments on one
#   machine"). No :443 is rendered or listened on.
# TLS_MODE=manual: bring your own cert - place it (before or after first
#   start) at /etc/letsencrypt/live/${DOMAIN}/{fullchain,privkey}.pem on
#   the certs-data volume (see docker-compose.tls.yml), e.g. via
#   `docker cp`. Rendered as :443 as soon as it's found; no renewal
#   handling, that's on you.
# TLS_MODE=letsencrypt: this container requests and renews its own cert
#   via certbot's webroot plugin. Requires DOMAIN's public DNS to already
#   point at this machine and port 80 (for the HTTP-01 challenge, before
#   any cert exists) plus 443 to be reachable from the internet - see
#   docker-compose.tls.yml.
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [ "$TLS_MODE" = letsencrypt ] && [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    : "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required when TLS_MODE=letsencrypt}"
    echo "[setup] TLS_MODE=letsencrypt: requesting a certificate for ${DOMAIN}"
    # The HTTP-01 challenge needs something answering :80 for ${DOMAIN}
    # right now, but the final nginx (started via `exec` below, possibly
    # with :443 added) isn't up yet - start a short-lived daemonized
    # nginx with just the :80 config rendered so far, use it to pass the
    # challenge, then stop it. `exec "$@"` at the bottom always starts
    # the real, final one.
    if nginx; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            curl -sf "http://127.0.0.1/.well-known/acme-challenge/" >/dev/null 2>&1 && break
            sleep 0.5
        done
        if certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
            --non-interactive --agree-tos --no-eff-email -m "$LETSENCRYPT_EMAIL"; then
            echo "[setup] certificate obtained for ${DOMAIN}"
        else
            echo "[setup] certbot failed for ${DOMAIN} - staying on HTTP only for now, will retry on next restart" >&2
        fi
        nginx -s quit || true
        # give the temporary master a moment to release :80 before the
        # real nginx binds it below
        sleep 1
    else
        echo "[setup] temporary nginx (for the ACME challenge) failed to start - staying on HTTP only for now" >&2
    fi
fi

if [ "$TLS_MODE" != proxy ] && [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
    export SSL_CERT_PATH="$CERT_DIR/fullchain.pem"
    export SSL_CERT_KEY_PATH="$CERT_DIR/privkey.pem"
    envsubst '$DOMAIN $SSL_CERT_PATH $SSL_CERT_KEY_PATH' \
        < "$TEMPLATES/https-site.conf.template" > "$CONF_D/${DOMAIN}-ssl.conf"
    echo "[setup] HTTPS enabled on :443 for ${DOMAIN}"
elif [ "$TLS_MODE" != proxy ]; then
    echo "[setup] TLS_MODE=$TLS_MODE but no cert found at ${CERT_DIR} - staying on HTTP only" >&2
fi

if [ "$TLS_MODE" = letsencrypt ]; then
    # background renewal loop - certbot no-ops until the cert is actually
    # due, so a coarse interval is fine. Survives as a child of the real
    # nginx (started via exec below, same PID, same process tree).
    (
        while true; do
            sleep 12h
            certbot renew --webroot -w /var/www/certbot --quiet \
                --deploy-hook "nginx -s reload"
        done
    ) &
fi

# record-done.sh (see there) can't write to nginx's own stdout/stderr -
# it runs as the nginx worker's unprivileged user via exec_record_done,
# which can't reach PID 1's fds, and nginx-rtmp doesn't forward exec'd
# children's output anywhere on its own. It logs to a plain file instead;
# tail that into this process's own stdout/stderr (still fd 1/2 of the
# container at this point, before exec below hands them to nginx) so it
# ends up in `docker compose logs` same as everything else. Forked here,
# so it keeps running as its own process after exec replaces this shell.
: >/tmp/record-done.log
chmod 666 /tmp/record-done.log
tail -F -n0 /tmp/record-done.log &

exec "$@"
