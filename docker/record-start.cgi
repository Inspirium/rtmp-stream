#!/bin/sh
# CGI script (via fcgiwrap) that fronts /control/record/start. Stashes an
# optional caller-supplied output filename keyed by playback_id, then
# forwards the actual start trigger to the loopback-only
# /internal/control/record/start. record-done.sh (see rtmp-site template)
# picks the stashed name back up via $name when the recording closes.
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

respond "$STATUS"
