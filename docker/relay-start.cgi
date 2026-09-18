#!/bin/sh
# CGI script (via fcgiwrap) that fronts /control/relay/start. Opens a relay
# session for this playback_id and spawns the supervisor that keeps ffmpeg
# re-publishing the stream to the caller-supplied target.
#
#   POST /control/relay/start
#   {"name":"<playback_id>","target":"rtmps://a.rtmps.youtube.com/live2/<key>"}
#
# POST with a JSON body rather than the query string the recording control
# routes use, and that difference is the point: the target's last path
# component IS the far end's stream key, and nginx writes every query
# string it serves to the access log. A key that reaches the log is a key
# that has to be rotated. In a body it is never written down here at all.
# Same reason admin-api.cgi takes its playback_id in a body.
#
# Returns 200 once the supervisor is spawned, NOT once the far end has
# accepted the stream: nothing here waits on somebody else's ingest. The
# relay webhook reports whether it worked, and reports it again with a
# reason when it stops.
set -eu

respond() {
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n\r\n'
    [ -n "${2:-}" ] && printf '%s' "$2"
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

# The target reaches ffmpeg as a single argv element, so shell
# metacharacters are not the risk they would be in a string command. What
# IS a risk is a scheme that makes ffmpeg touch this box instead of the
# network - file:, concat:, /dev/... - which would let a caller choose
# what we do with our own disk. Allow exactly the two protocols a relay
# target can legitimately be, and no whitespace or control characters,
# which nothing valid contains and which is how a second ffmpeg argument
# would be smuggled in.
safe_target() {
    case "$1" in
        rtmp://*|rtmps://*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9./:?=\&_%~@+-]*) return 1 ;;
    esac
    # rtmp://host/app/key - anything shorter is missing either the
    # application or the key, and fails at the far end in a way that reads
    # as "the relay is broken" rather than "the URL is incomplete"
    case "$1" in
        rtmp://*/*/*|rtmps://*/*/*) ;;
        *) return 1 ;;
    esac
    return 0
}

if [ "${REQUEST_METHOD:-}" != POST ]; then
    respond "405 Method Not Allowed" '{"error":"post a json body"}'
fi

BODY=""
if [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null; then
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
fi

NAME=$(printf '%s' "$BODY" | jq -r '.name // empty' 2>/dev/null) || NAME=""
TARGET=$(printf '%s' "$BODY" | jq -r '.target // empty' 2>/dev/null) || TARGET=""

if ! safe_charset "$NAME"; then
    respond "400 Bad Request" '{"error":"name must only contain letters, digits, . _ or -"}'
fi
if ! safe_target "$TARGET"; then
    # Deliberately does not echo the target back: an invalid one is still
    # somebody's credential, and this response is going into whatever log
    # the caller keeps.
    respond "400 Bad Request" '{"error":"target must be an rtmp:// or rtmps:// url of the form scheme://host/app/key"}'
fi

. /usr/local/bin/relay-session.sh

exec 9>"$(relay_lock_path "$NAME")"
flock -x 9

# Already relaying. Restarting would drop the broadcast for as long as the
# far end takes to notice the old connection is gone - so a repeat start
# against the SAME target is a no-op success (the backend's scheduler is
# allowed to be idempotent, and is), and against a DIFFERENT one is a
# conflict the caller resolves with an explicit stop. Silently switching
# targets mid-broadcast would strand whichever one was being watched.
if relay_exists "$NAME" && [ "$(relay_get "$NAME" state)" = active ]; then
    if [ "$(relay_get "$NAME" target)" = "$TARGET" ]; then
        respond "200 OK" '{"status":"already_relaying"}'
    fi
    rec_log "relay ${NAME}: refused, already relaying to a different target"
    respond "409 Conflict" '{"error":"already relaying to a different target"}'
fi

# A session left behind by a supervisor that died without cleaning up.
relay_destroy "$NAME"
relay_create "$NAME" "$TARGET"

# setsid, so the supervisor survives this CGI exiting - fcgiwrap reaps the
# request's process group, and a plain background job would go with it the
# moment nginx got its response. stdin closed and output redirected for
# the same reason: anything still holding the CGI's pipes keeps the
# request open, and nginx sits waiting on a response it already has.
#
# 9>&- is not optional and cost a live broadcast to learn. fd 9 is the
# flock this CGI is holding, and a child inherits it: without this the
# supervisor holds the relay's lock for its entire life, every later
# /control/relay/stop blocks forever on `flock -x 9`, nginx logs a 499
# when the caller gives up, and the relay keeps pushing to somebody's
# channel long after they pressed stop. Closing it here is what makes the
# lock mean "a CGI is mutating this session" rather than "this session
# exists".
setsid /usr/local/bin/relay-run.sh "$NAME" </dev/null >/dev/null 2>&1 9>&- &

rec_log "relay ${NAME}: session opened for $(relay_redact "$TARGET")"
respond "200 OK" '{"status":"relaying"}'
