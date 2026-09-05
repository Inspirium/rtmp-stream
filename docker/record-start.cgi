#!/bin/sh
# CGI script (via fcgiwrap) that fronts /control/record/start. Opens a
# recording *session* for this playback_id - stashing the caller-supplied
# output filename - then forwards the actual start trigger to the
# loopback-only /internal/control/record/start.
#
# The session is what makes a booking survive a dropped publisher: it stays
# open across reconnects (record-resume.sh restarts the recorder,
# record-done.sh banks each .flv as a part) until /control/record/stop
# closes it, at which point the parts become one .mp4 under the stashed
# name. See rec-session.sh for the whole picture.
#
# Also POSTs {"playback_id","recording":true} to WEBHOOK_URL, if one is
# configured, once the start actually succeeds - the opening half of the
# camera status webhook. Its matching "recording":false is sent from
# rec-finalize.sh when the session ENDS (an explicit stop, or the publisher
# staying gone past RESUME_TIMEOUT) - deliberately not on an ordinary
# reconnect, which the booking rides straight through.
set -eu

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
if [ -n "$FILENAME" ] && ! safe_charset "$FILENAME"; then
    respond "400 Bad Request"
fi

. /usr/local/bin/rec-session.sh

# Serialize against a record-done.sh still finalizing this playback_id's
# previous session - it destroys the session directory when it's done, and
# would take a session opened here down with it.
exec 9>"$(lock_path "$NAME")"
flock -x 9

# An empty name is fine and means "no ?filename= was given": rec-finalize.sh
# then falls back to the raw timestamped name nginx-rtmp gave the first part.
session_create "$NAME" "$FILENAME"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1/internal/control/record/start?app=${APP}&name=${NAME}&rec=${REC}")

case "$STATUS" in
    2??)
        session_set "$NAME" recording 1
        rec_log "session ${NAME}: recording started${FILENAME:+ as ${FILENAME}.mp4}"
        send_camera_status "$NAME" true
        ;;
    *)
        # nothing is recording, so don't leave a session behind for
        # record-resume.sh to act on the next time this stream publishes
        session_destroy "$NAME"
        rec_log "session ${NAME}: record/start refused by nginx-rtmp (status ${STATUS})"
        ;;
esac

respond "$STATUS"
