#!/bin/sh
# Invoked by nginx-rtmp's exec_publish every time a publisher starts
# publishing - i.e. on the first connect of a stream AND on every
# reconnect after a dropped one.
#
# This is the half that makes a booking survive a flaky uplink. If a
# recording session is still active for this playback_id (see
# rec-session.sh) then the previous part was cut short by the publisher
# going away, not by anyone stopping the recording - so start recording
# again straight away. record-done.sh keeps every part; they're joined
# into one .mp4 when the booking actually stops.
#
# Does nothing at all for a stream nobody asked to record, which is the
# usual case: recording stays manual-only.
#
# args: <playback_id>
set -eu

# same reason as record-done.sh: nginx-rtmp swallows an exec'd child's
# output, and this runs as the unprivileged worker user
exec >>/data/record-done.log 2>&1

PLAYBACK_ID=$1

. /usr/local/bin/rec-session.sh
load_rec_config

session_exists "$PLAYBACK_ID" || exit 0
[ "$(session_get "$PLAYBACK_ID" state)" = active ] || exit 0

# Serialize against record-done.sh finalizing this same playback_id: it
# holds this lock for its whole run and destroys the session at the end, so
# resuming underneath it would attach a new part to a session that's about
# to disappear.
exec 9>"$(lock_path "$PLAYBACK_ID")"
flock -x 9

# it may have finished stopping while we waited for the lock
session_exists "$PLAYBACK_ID" || exit 0
[ "$(session_get "$PLAYBACK_ID" state)" = active ] || exit 0
[ "$(session_get "$PLAYBACK_ID" recording)" != 1 ] || exit 0

# nginx-rtmp fires exec_publish as the publisher is being set up, and the
# control module can only start a recorder once the stream is actually
# registered - so the first attempt can lose that race by a few
# milliseconds. Retry briefly rather than lose the rest of the booking.
i=1
while [ "$i" -le 10 ]; do
    sleep 1
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1/internal/control/record/start?app=${RTMP_APP:-stream}&name=${PLAYBACK_ID}&rec=rec1" \
        2>/dev/null || echo 000)
    case "$STATUS" in
        2??)
            # close the gap BEFORE flipping `recording`, so the gap length
            # measures time without footage rather than time without a
            # publisher - the two differ by however long this retry loop
            # took to get the recorder open again
            GAP=$(gap_close "$PLAYBACK_ID")
            session_set "$PLAYBACK_ID" recording 1
            PARTS=$(session_parts "$PLAYBACK_ID" | grep -c . || true)
            rec_log "session ${PLAYBACK_ID}: publisher reconnected, recording resumed (part $((PARTS + 1)))${GAP:+, ${GAP}s of footage missing}"
            exit 0
            ;;
    esac
    i=$((i + 1))
done

rec_log "session ${PLAYBACK_ID}: publisher reconnected but record/start kept failing (last status ${STATUS}) - session left active, will retry on next publish"
