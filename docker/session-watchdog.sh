#!/bin/sh
# Background loop started by docker-entrypoint.sh - the safety net behind
# the resume-on-reconnect machinery.
#
# A session stays open across a dropped publisher on purpose, waiting for
# the encoder to come back (see rec-session.sh). That's the right call for
# a blip, but a camera can also go away for good: unplugged, rained on,
# venue closed for the night. Without this, that session would sit there
# forever holding its parts, and the backend would wait forever for a
# recording that never arrives.
#
# So: a session whose publisher has been gone longer than RESUME_TIMEOUT
# gets finalized anyway - the footage recorded up to the drop is uploaded
# and reported, exactly as if someone had called /control/record/stop.
set -eu

exec >>/tmp/record-done.log 2>&1

. /usr/local/bin/rec-session.sh
load_rec_config

TIMEOUT=${RESUME_TIMEOUT:-600}
INTERVAL=30

rec_log "session watchdog started (finalizing sessions idle for more than ${TIMEOUT}s)"

while true; do
    sleep "$INTERVAL"
    NOW=$(date +%s)

    for ID in $(session_ids); do
        [ "$(session_get "$ID" state)" = active ] || continue

        # Opportunistic, and deliberately above the recording check below:
        # a session that IS recording is exactly the one whose publisher is
        # live and readable. A booking that started before its camera
        # connected has no codec recorded yet, and this is what fills it in
        # once the camera turns up. No-ops once we have a value.
        session_capture_codec "$ID" || true

        # a recorder is open - the camera is here, nothing to do
        [ "$(session_get "$ID" recording)" != 1 ] || continue

        UPDATED=$(session_get "$ID" updated)
        case "$UPDATED" in ''|*[!0-9]*) continue ;; esac

        IDLE=$((NOW - UPDATED))
        [ "$IDLE" -ge "$TIMEOUT" ] || continue

        rec_log "session ${ID}: publisher gone for ${IDLE}s (limit ${TIMEOUT}s) - finalizing what we have"
        # record-finalize.sh takes the per-playback_id lock, so this can't
        # collide with a record-done.sh or a reconnect landing right now
        record-finalize.sh "$ID" || true
    done
done
