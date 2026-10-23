#!/bin/sh
# Thin wrapper that takes a playback_id's flock and finalizes its session -
# joins the .flv parts into one .mp4, uploads it, reports the outcome.
#
# For callers that DON'T already hold the lock. record-done.sh and
# record-stop.cgi hold it for their whole run and call finalize_session()
# directly instead (see rec-finalize.sh); this is what session-watchdog.sh
# and a human at `docker exec` use.
#
#   docker exec <container> record-finalize.sh <playback_id>
#   docker exec <container> record-finalize.sh <playback_id>.fin-<...>   (a detached session)
set -eu

exec >>/data/record-done.log 2>&1

PLAYBACK_ID=${1:?usage: record-finalize.sh <playback_id>}

. /usr/local/bin/rec-session.sh
. /usr/local/bin/rec-finalize.sh

# A session finalize_session already moved aside (see session_detach) that
# a restart interrupted mid-upload. It no longer owns the playback_id's
# slot, so it needs no slot lock - finalize_detached takes the finalize
# lock it shares with every other finalize of that camera.
if session_is_detached "$PLAYBACK_ID"; then
    session_exists "$PLAYBACK_ID" || exit 0
    finalize_detached "$PLAYBACK_ID" "${PLAYBACK_ID%%.fin-*}"
    exit $?
fi

exec 9>"$(lock_path "$PLAYBACK_ID")"
flock -x 9

session_exists "$PLAYBACK_ID" || { rec_log "no session for ${PLAYBACK_ID}, nothing to finalize"; exit 0; }

session_set "$PLAYBACK_ID" state stopping
finalize_session "$PLAYBACK_ID"
