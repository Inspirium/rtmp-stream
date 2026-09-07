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

exec >>/data/record-done.log 2>&1

. /usr/local/bin/rec-session.sh
load_rec_config

TIMEOUT=${RESUME_TIMEOUT:-600}
INTERVAL=30

# Backstop against a session that is never stopped. RESUME_TIMEOUT below
# only catches a publisher that went AWAY; a session whose camera keeps
# publishing and whose stop never arrives is skipped forever by the
# recording check, because from here it is indistinguishable from a very
# long booking. One of those ran for sixteen hours in August and wrote a
# 37 GB .flv before anyone noticed.
#
# Deliberately generous: tripping this on a real booking ends it early and
# the rest of that match is lost, which is worse than the disk. Four hours
# is roughly four times the longest booking we have seen. Set 0 to disable.
MAX_SESSION=${MAX_SESSION_SECONDS:-14400}

rec_log "session watchdog started (idle limit ${TIMEOUT}s, max session ${MAX_SESSION}s, publisher state polled every ${INTERVAL}s)"

while true; do
    sleep "$INTERVAL"
    NOW=$(date +%s)

    # "is this camera sending video right now", reported when it changes.
    # Lives here because this is the only loop that already runs on a tick
    # short enough for the answer to still be true when it arrives.
    report_publisher_states || true

    for ID in $(session_ids); do
        [ "$(session_get "$ID" state)" = active ] || continue

        # Opportunistic, and deliberately above the recording check below:
        # a session that IS recording is exactly the one whose publisher is
        # live and readable. A booking that started before its camera
        # connected has no codec recorded yet, and this is what fills it in
        # once the camera turns up. No-ops once we have a value.
        session_capture_codec "$ID" || true

        # Maximum duration, checked BEFORE the recording test below - a
        # runaway session is precisely one that is still recording, so the
        # skip below would never let us see it.
        STARTED=$(session_get "$ID" started)
        case "$STARTED" in ''|*[!0-9]*) STARTED="" ;; esac
        if [ "$MAX_SESSION" -gt 0 ] && [ -n "$STARTED" ]; then
            AGE=$((NOW - STARTED))
            if [ "$AGE" -ge "$MAX_SESSION" ]; then
                rec_log "session ${ID}: running ${AGE}s (limit ${MAX_SESSION}s) - no stop ever arrived, closing it out"
                # Has to go through a real stop: the recorder is still open,
                # so finalizing directly would find no banked parts, report
                # the booking failed, and leave nginx-rtmp writing the .flv
                # for as long as the camera stays up. See session_force_stop.
                ST=$(session_force_stop "$ID")
                case "$ST" in
                    200)
                        # recorder closed - record-done.sh finalizes
                        rec_log "session ${ID}: recorder closed, finalizing via record-done"
                        ;;
                    *)
                        rec_log "session ${ID}: nothing was recording (control status ${ST}) - finalizing banked parts here"
                        record-finalize.sh "$ID" || true
                        ;;
                esac
                continue
            fi
        fi

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
