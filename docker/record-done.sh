#!/bin/sh
# Invoked by nginx-rtmp's exec_record_done once a manually-triggered
# recording finishes writing its raw .flv file - which happens both when
# the recording is deliberately stopped AND whenever the publisher simply
# goes away. Those two cases are no longer the same thing:
#
#   * session still active  -> the publisher dropped mid-booking. Keep the
#     .flv as a part and stop there; record-resume.sh starts a fresh part
#     the moment the encoder reconnects (see rec-session.sh).
#   * session marked stopping -> the booking really is over. Concatenate
#     every part into one .mp4, upload it, report the outcome.
#
# args: <raw_flv_path> <playback_id>
# (everything else - domain, bucket, prefix, upload/keep flags - comes from
# /data/.rec-config, written by docker-entrypoint.sh, because this script
# gets no environment of its own; see below.)
set -eu

# nginx-rtmp's exec_record_done doesn't forward this script's stdout/
# stderr into `docker compose logs` - they just go nowhere, and writing
# directly to PID 1's fds (the usual /proc/1/fd/1 trick) doesn't work
# either: this runs as the nginx worker's unprivileged user, which can't
# open root's end of that pipe. Instead, append to a plain log file this
# user CAN write to; docker-entrypoint.sh tails that file in the
# background straight into the container's real stdout/stderr.
exec >>/tmp/record-done.log 2>&1

RAW_PATH=$1
PLAYBACK_ID=$2

. /usr/local/bin/rec-session.sh
. /usr/local/bin/rec-finalize.sh

# Starting a new recording for this playback_id before this script has
# finished with the previous one (e.g. stop/start called back to back) races
# two record-done.sh invocations against each other: without this lock, both
# independently see the target .mp4 name as free (the "don't clobber" check
# in rec-finalize.sh is a plain [ -e ]) and pick the same path, so whichever
# ffmpeg finishes last silently overwrites - and uploads over - the other's
# recording, and (if a webhook is configured) both report "ready" for the
# same key. Serializing per playback_id here, before that check runs, makes
# the second invocation see the first's finished file and correctly fall
# through to the -2 suffix. Held for the rest of the script (through upload)
# so webhook posts for this playback_id stay ordered too; released
# automatically when the process exits and fd 9 closes. Scoped per
# playback_id, not global, so unrelated concurrent streams on this same
# server don't serialize against each other. session-watchdog.sh and
# record-stop.cgi take the same lock via record-finalize.sh.
exec 9>"$(lock_path "$PLAYBACK_ID")"
flock -x 9

# The recorder is closed either way, so this playback_id is not recording
# right now - session-watchdog.sh reads this to spot a session whose
# publisher never came back.
session_set "$PLAYBACK_ID" recording 0
session_add_part "$PLAYBACK_ID" "$RAW_PATH"

STATE=$(session_get "$PLAYBACK_ID" state)

case "$STATE" in
    active)
        # A drop, not a stop. Deliberately silent towards the backend: no
        # "recording":false, no video status - as far as the booking is
        # concerned this recording is still running, and it will be again
        # within a second or two of the encoder reconnecting.
        rec_log "session ${PLAYBACK_ID}: publisher went away, part kept ($(basename "$RAW_PATH")) - waiting for reconnect"
        ;;
    stopping)
        finalize_session "$PLAYBACK_ID"
        ;;
    *)
        # No session at all: someone drove the recorder through the
        # loopback /internal/control endpoint directly, or this is a part
        # left over from an image that predates sessions. Treat it as a
        # one-part session that's already over, which is exactly the old
        # behaviour - remux, upload, report.
        rec_log "no session for ${PLAYBACK_ID}, finalizing $(basename "$RAW_PATH") on its own"
        session_create "$PLAYBACK_ID" "$(basename "${RAW_PATH%.flv}")"
        session_add_part "$PLAYBACK_ID" "$RAW_PATH"
        session_set "$PLAYBACK_ID" state stopping
        finalize_session "$PLAYBACK_ID"
        ;;
esac
