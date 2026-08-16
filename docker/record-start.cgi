#!/bin/sh
# CGI script (via fcgiwrap) that fronts /control/record/start. Stashes an
# optional caller-supplied output filename keyed by playback_id, then
# forwards the actual start trigger to the loopback-only
# /internal/control/record/start. record-done.sh (see rtmp-site template)
# picks the stashed name back up via $name when the recording closes.
#
# Also POSTs {"playback_id","recording":true} to WEBHOOK_URL (Bearer
# WEBHOOK_TOKEN), if configured, once the start actually succeeds - see
# the "video status webhook" section in docker-entrypoint.sh and
# record-done.sh's matching "recording":false webhook, sent whichever
# way this camera's recording eventually stops (explicit
# /control/record/stop, a dropped publisher, or an error). fcgiwrap
# runs as root and inherits this container's exported env, unlike
# record-done.sh (see there) - so unlike that script, this one can just
# read WEBHOOK_URL/WEBHOOK_TOKEN directly, no /data/.webhook-env needed.
set -eu

PENDING_DIR=/tmp/rec-pending

respond() {
    printf 'Status: %s\r\n\r\n' "$1"
    exit 0
}

safe_charset() {
    case "$1" in
        "") return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        *..*) return 1 ;;
        .*) return 1 ;;
        *) return 0 ;;
    esac
}

APP=${RTMP_APP:-stream}
NAME=${RTMP_NAME:-}
REC=${RTMP_REC:-rec1}
FILENAME=${RTMP_FILENAME:-}

case "$APP" in *[!A-Za-z0-9._-]*) respond "400 Bad Request" ;; esac
case "$REC" in *[!A-Za-z0-9._-]*) respond "400 Bad Request" ;; esac
if [ -z "$NAME" ] || ! safe_charset "$NAME"; then
    respond "400 Bad Request"
fi

if [ -n "$FILENAME" ]; then
    if ! safe_charset "$FILENAME"; then
        respond "400 Bad Request"
    fi
    printf '%s' "$FILENAME" > "${PENDING_DIR}/${NAME}.filename"
fi

STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1/internal/control/record/start?app=${APP}&name=${NAME}&rec=${REC}")

case "$STATUS" in
    2??)
        if [ -n "${WEBHOOK_URL:-}" ]; then
            curl -sf -m 5 -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${WEBHOOK_TOKEN:-}" \
                -d "$(printf '{"playback_id":"%s","recording":true}' "$NAME")" \
                >/dev/null 2>&1 || true
        fi
        ;;
esac

respond "$STATUS"
