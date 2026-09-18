#!/bin/sh
# CGI script (via fcgiwrap) that fronts /control/relay/stop. Ends a relay
# session and takes its ffmpeg down with it.
#
#   POST /control/relay/stop
#   {"name":"<playback_id>"}
#
# POST with a JSON body to match relay-start.cgi rather than the query
# string the recording control routes use. Nothing secret passes here, so
# this is only symmetry - but the pair being consistent with each other
# matters more than either being consistent with the recorder, which they
# already differ from in shape.
#
# Ordering is the subtle part, for the same reason it is in
# record-stop.cgi: the state goes to `stopping` BEFORE anything is
# signalled, so relay-run.sh reads a deliberate stop rather than treating
# the dying ffmpeg as another dropped uplink and respawning it underneath
# us.
#
# 200 when a relay was running and is now stopped, 204 when there was
# nothing to stop - which is not an error. A booking that ends after its
# camera already vanished has had its relay closed out by the supervisor's
# own resume timeout, and the scheduler's stop then legitimately finds
# nothing left to do.
set -eu

respond() {
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n\r\n'
    [ -n "${2:-}" ] && printf '%s' "$2"
    exit 0
}

if [ "${REQUEST_METHOD:-}" != POST ]; then
    respond "405 Method Not Allowed" '{"error":"post a json body"}'
fi

BODY=""
if [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null; then
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
fi

NAME=$(printf '%s' "$BODY" | jq -r '.name // empty' 2>/dev/null) || NAME=""

case "$NAME" in
    "") respond "400 Bad Request" '{"error":"name is required"}' ;;
    *[!A-Za-z0-9._-]*) respond "400 Bad Request" '{"error":"name must only contain letters, digits, . _ or -"}' ;;
esac

. /usr/local/bin/relay-session.sh

# Bounded, and it proceeds without the lock rather than giving up.
#
# A stop that blocks is worse than a stop that races: whatever is wrong
# here, the thing on the other end is still broadcasting, and killing the
# supervisor by pid is safe whether or not we hold the lock. The
# unbounded `flock -x 9` this replaces is exactly how a relay once ran on
# for nine minutes after it was stopped.
exec 9>"$(relay_lock_path "$NAME")"
if ! flock -w 10 -x 9; then
    rec_log "relay ${NAME}: could not take the session lock in 10s - stopping anyway"
fi

if ! relay_exists "$NAME"; then
    respond "204 No Content"
fi

relay_set "$NAME" state stopping

PID=$(relay_get "$NAME" pid)
if [ -n "$PID" ]; then
    # TERM reaches the supervisor, whose trap passes it on to ffmpeg. Not
    # KILL: an ffmpeg killed outright leaves the far end holding a
    # half-open ingest connection, and YouTube in particular then refuses
    # the next publish for a minute or two as "already streaming" - which
    # turns one stopped booking into a broken next one.
    kill -TERM "$PID" 2>/dev/null || true
fi

relay_finish "$NAME" stopped

respond "200 OK" '{"status":"stopped"}'
