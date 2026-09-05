#!/bin/sh
# CGI script (via fcgiwrap) that fronts /control/record/stop - the mirror
# of record-start.cgi.
#
# Plain rtmp_control can't be used for this any more. A stop has to close
# the *session* (see rec-session.sh) before the recorder shuts down,
# otherwise record-done.sh sees a session that's still active, assumes the
# publisher merely dropped, and waits for a reconnect that isn't coming.
#
# It also has to cope with stopping a booking whose camera is currently
# offline: nginx-rtmp has no recorder to stop in that case and answers 404,
# but the parts recorded before the camera went away are real and the
# caller is entitled to them - so finalize here instead.
#
#   GET /control/record/stop?app=stream&name=<playback_id>&rec=rec1
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

case "$APP" in *[!A-Za-z0-9._-]*) respond "400 Bad Request" ;; esac
case "$REC" in *[!A-Za-z0-9._-]*) respond "400 Bad Request" ;; esac
if [ -z "$NAME" ] || ! safe_charset "$NAME"; then
    respond "400 Bad Request"
fi

. /usr/local/bin/rec-session.sh
. /usr/local/bin/rec-finalize.sh

exec 9>"$(lock_path "$NAME")"
flock -x 9

HAD_SESSION=0
if session_exists "$NAME"; then
    HAD_SESSION=1
    # must happen BEFORE the recorder closes: record-done.sh reads this to
    # tell "the booking is over, join the parts up" from "the uplink
    # blinked, hold on to this part"
    session_set "$NAME" state stopping
fi

STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1/internal/control/record/stop?app=${APP}&name=${NAME}&rec=${REC}")

# nginx-rtmp's control module distinguishes these two for us, and the
# difference decides who finalizes the session:
#
#   200  a recorder really was open and has now been closed. That fires
#        exec_record_done, so record-done.sh gets the last part and
#        finalizes - our job here is done.
#   204  there was nothing to stop: the camera is offline, or recording
#        had already ended. exec_record_done will NOT fire, so if this
#        session has parts banked from before the camera dropped, nobody
#        else is coming to join them up. (204 is also what an unknown
#        stream name returns.)
case "$STATUS" in
    200)
        rec_log "session ${NAME}: stop requested, finalizing via record-done"
        respond "$STATUS"
        ;;
esac

if [ "$HAD_SESSION" -eq 1 ]; then
    rec_log "session ${NAME}: stop requested while nothing was recording (control status ${STATUS}) - finalizing banked parts here"
    finalize_session "$NAME" || true
    # the booking did stop, and its recording is dealt with - the 204 from
    # the control module is about there being no live recorder, which isn't
    # the caller's problem
    respond "200 OK"
fi

respond "$STATUS"
