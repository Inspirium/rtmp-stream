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

# Serialize against record-done.sh / record-stop.cgi working on this
# playback_id's previous session. They only hold this lock for the quick
# bookkeeping: the slow join and upload run after the session has been
# moved out of the way (see finalize_session), so this waits seconds, not
# the length of an upload.
exec 9>"$(lock_path "$NAME")"
flock -x 9

# A stop that has closed the recorder but whose record-done.sh hasn't run
# yet leaves the previous booking here as `stopping`. Its last part is on
# its way to it, and a session created over it now would receive that part
# instead - the previous booking's ending, filed as a dropout in this one.
# record-done.sh moves it aside within a moment of getting the lock, so
# hand the lock over and wait for that.
_waited=0
while session_exists "$NAME" && [ "$(session_get "$NAME" state)" = stopping ] && [ "$_waited" -lt 10 ]; do
    flock -u 9
    sleep 1
    flock -x 9
    _waited=$((_waited + 1))
done
if session_exists "$NAME" && [ "$(session_get "$NAME" state)" = stopping ]; then
    rec_log "session ${NAME}: previous session still stopping after ${_waited}s - opening the new one over it"
    session_destroy "$NAME"
fi

# An active session already here means this camera is already booked for
# recording. It happens when a start is retried - the caller timed out on
# an earlier one that went through anyway - and it is the caller's latest
# word on what the recording is called. Take the session over rather than
# reset it: resetting threw away its parts and set it "not recording" while
# the recorder was running, so the watchdog later closed it as no_footage
# and the real footage was uploaded under a name nobody was waiting for.
_created=0
if session_exists "$NAME" && [ "$(session_get "$NAME" state)" = active ]; then
    _previous=$(session_get "$NAME" name)
    if [ -n "$FILENAME" ] && [ "$FILENAME" != "$_previous" ]; then
        session_set "$NAME" name "$FILENAME"
        session_set "$NAME" started "$(date +%s)"
        rec_log "session ${NAME}: start for ${FILENAME}.mp4 while already open${_previous:+ as ${_previous}.mp4} - continuing the same recording under the new name"
    fi

    if [ "$(session_get "$NAME" recording)" = 1 ]; then
        # nginx-rtmp would answer 204 to a second start, which reads as
        # "nothing publishing" - the opposite of the truth
        rec_log "session ${NAME}: already recording${FILENAME:+ as ${FILENAME}.mp4}"
        send_camera_status "$NAME" true
        respond "200 OK"
    fi
else
    # An empty name is fine and means "no ?filename= was given":
    # rec-finalize.sh then falls back to the raw timestamped name nginx-rtmp
    # gave the first part.
    session_create "$NAME" "$FILENAME"
    _created=1
fi

STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1/internal/control/record/start?app=${APP}&name=${NAME}&rec=${REC}")

# nginx-rtmp answers 200 only when it actually opened a recorder, and 204
# when there was no live stream of that name to record - which happens for
# a genuine typo, but far more often because the booking started a moment
# before the camera finished connecting.
case "$STATUS" in
    200)
        session_set "$NAME" recording 1
        rec_log "session ${NAME}: recording started${FILENAME:+ as ${FILENAME}.mp4}"
        # something is publishing right now, so this is the earliest point
        # the codec can be read. The 202 branch below deliberately doesn't
        # try: nothing is publishing yet, so there'd be nothing to read.
        session_capture_codec "$NAME"
        send_camera_status "$NAME" true
        respond "$STATUS"
        ;;
    204)
        # Leave the session open with recording=0 rather than throwing it
        # away. This is exactly the state a session is in between a drop
        # and a reconnect, so exec_publish/record-resume.sh will start
        # recording the instant the camera turns up - which is what the
        # caller asked for, just a few seconds later than it asked.
        #
        # If the camera never turns up, session-watchdog.sh closes this out
        # after RESUME_TIMEOUT and reports it as failed, so an armed
        # session can't linger for a stream that will never exist.
        rec_log "session ${NAME}: nothing publishing yet, armed${FILENAME:+ for ${FILENAME}.mp4} - recording starts when the camera connects"
        send_camera_status "$NAME" true
        # 202: accepted, not yet recording - distinguishable from the 200
        # above, and still a 2xx for callers that only check for success
        respond "202 Accepted"
        ;;
esac

# anything else really is a refusal - don't leave a session behind for
# record-resume.sh to act on the next time this stream publishes. One we
# took over stays: it has parts of a booking already in it.
if [ "$_created" -eq 1 ]; then
    session_destroy "$NAME"
fi
rec_log "session ${NAME}: record/start refused by nginx-rtmp (status ${STATUS})"
respond "$STATUS"
