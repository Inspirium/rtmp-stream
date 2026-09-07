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
set -eu

exec >>/data/record-done.log 2>&1

PLAYBACK_ID=${1:?usage: record-finalize.sh <playback_id>}

. /usr/local/bin/rec-session.sh
. /usr/local/bin/rec-finalize.sh

exec 9>"$(lock_path "$PLAYBACK_ID")"
flock -x 9

session_exists "$PLAYBACK_ID" || { rec_log "no session for ${PLAYBACK_ID}, nothing to finalize"; exit 0; }

session_set "$PLAYBACK_ID" state stopping
finalize_session "$PLAYBACK_ID"
