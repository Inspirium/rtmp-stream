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

# --- nginx liveness ------------------------------------------------------
# Everything below this line assumes nginx answers. On 2026-09-10 it stopped
# answering: the single worker (worker_processes 1, see nginx.conf) spun at
# 100% CPU in userspace and never accepted a connection again. The container
# stayed "Up", so the restart policy saw nothing to restart, and this loop
# kept ticking happily beside a dead server for thirty-one hours.
#
# The poll is the same /stat the session logic already depends on, which is
# why a failure here has to skip the sweep below rather than let it run: with
# /stat and /control both unreachable, session_force_stop's status read comes
# back empty, the MAX_SESSION branch takes that for "nothing was recording",
# and live bookings get finalized as failed. Doing nothing is strictly better.
#
# Escalation, in two steps:
#
#   LIVENESS_FAILS ticks down   -> SIGKILL the worker(s). The master respawns
#                                  them, which is what fixed 2026-09-10 by
#                                  hand, and costs only the current viewers a
#                                  reconnect. Recordings survive: the session
#                                  state is on /data and the parts are on disk.
#   twice that, still down      -> the master is wedged too, so stop the
#                                  container and let `restart: unless-stopped`
#                                  rebuild it.
#
# Set 0 to disable the check entirely.
LIVENESS_FAILS=${LIVENESS_FAILS:-6}
LIVE_FAILS=0

# `ps` isn't in the image, so read the worker pids straight out of /proc.
# nginx rewrites its argv, so a worker's cmdline is its process title
# verbatim - "nginx: worker process" - and the master is always pid 1 here.
nginx_worker_pids() {
    for _proc in /proc/[0-9]*; do
        _wpid=${_proc#/proc/}
        if [ "$_wpid" = 1 ]; then
            continue
        fi
        _title=$(tr '\0' ' ' <"${_proc}/cmdline" 2>/dev/null) || _title=""
        case "$_title" in
            'nginx: worker process'*) printf '%s\n' "$_wpid" ;;
        esac
    done
}

rec_log "session watchdog started (idle limit ${TIMEOUT}s, max session ${MAX_SESSION}s, publisher state polled every ${INTERVAL}s, nginx liveness after ${LIVENESS_FAILS} failed poll(s))"

while true; do
    sleep "$INTERVAL"
    NOW=$(date +%s)

    # Is nginx answering at all? See the note above: when it isn't, the whole
    # sweep below is skipped rather than run against a server that can't reply.
    if [ "$LIVENESS_FAILS" -gt 0 ]; then
        if curl -sf -m 5 -o /dev/null http://127.0.0.1/stat 2>/dev/null; then
            if [ "$LIVE_FAILS" -gt 0 ]; then
                rec_log "nginx liveness: /stat answering again after ${LIVE_FAILS} failed poll(s)"
            fi
            LIVE_FAILS=0
        else
            LIVE_FAILS=$((LIVE_FAILS + 1))
            DOWN_FOR=$((LIVE_FAILS * INTERVAL))
            rec_log "nginx liveness: /stat unanswered (${LIVE_FAILS}/${LIVENESS_FAILS}, ${DOWN_FOR}s)"

            if [ "$LIVE_FAILS" -eq "$LIVENESS_FAILS" ]; then
                # space-separated so it both logs and word-splits cleanly
                WPIDS=$(nginx_worker_pids | tr '\n' ' ')
                WPIDS=${WPIDS% }
                if [ -n "$WPIDS" ]; then
                    rec_log "nginx liveness: wedged ${DOWN_FOR}s - killing worker(s) ${WPIDS} so the master respawns them"
                    for W in $WPIDS; do
                        kill -9 "$W" 2>/dev/null || true
                    done
                else
                    rec_log "nginx liveness: wedged ${DOWN_FOR}s and no worker process to kill - waiting to stop the container instead"
                fi
            elif [ "$LIVE_FAILS" -eq $((LIVENESS_FAILS * 2)) ]; then
                rec_log "nginx liveness: still down after ${DOWN_FOR}s and a worker respawn - stopping the container for the restart policy"
                kill -TERM 1 2>/dev/null || true
            fi

            continue
        fi
    fi

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
