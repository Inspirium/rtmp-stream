#!/bin/sh
# Shared helpers for the recording-session state machine. Sourced (never
# executed) by record-start.cgi, record-stop.cgi, record-resume.sh,
# record-done.sh, record-finalize.sh, session-watchdog.sh and
# cleanup-recordings.sh.
#
# A *session* is one booking's worth of recording: everything between a
# /control/record/start and its matching /control/record/stop, even if the
# publisher drops and reconnects several times in between.
#
# nginx-rtmp can't reopen a recording it has already closed - a dropped
# publisher ends the .flv for good - so each publish produces its own
# "part". The parts are concatenated into a single .mp4 when the session
# actually stops, so the backend still sees exactly one file under the key
# it was handed up front: one Video row, one `ready` webhook, no change on
# that side. Before this existed a 2-second uplink blip silently ended the
# recording and the rest of the booking was lost (see README's
# "Reconnects and resumed recordings").
#
# State lives on /data - the persistent volume - not /tmp, so a
# `docker compose up -d` mid-booking doesn't lose it either: the publisher
# reconnects, exec_publish fires record-resume.sh, and recording carries
# on into a new part.
#
# Everything here is written by two different users - root (fcgiwrap, for
# the CGIs, plus the watchdog) and the nginx worker's unprivileged user
# (record-done.sh / record-resume.sh, spawned by nginx-rtmp's exec_*
# directives) - hence the permissive modes below. Same reasoning as
# /tmp/rec-pending in docker-entrypoint.sh.

SESSIONS_DIR=/data/rec-sessions
REC_CONFIG=/data/.rec-config
REC_LOG=/tmp/record-done.log
WEBHOOK_ENV_FILE=/data/.webhook-env
S3_ENV_FILE=/data/.s3-env

# nginx-rtmp doesn't forward an exec'd child's stdout/stderr anywhere, and
# the worker user can't open PID 1's fds to write there itself - so
# everything logs to this plain file, which docker-entrypoint.sh tails into
# the container's real stdout. See the note at the top of record-done.sh.
rec_log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$REC_LOG" 2>/dev/null || true
}

# --- session state ------------------------------------------------------
# One directory per playback_id, one file per field - no parsing, and each
# field can be updated independently by whichever user gets there first:
#
#   name       output basename, no extension (from ?filename=... at start)
#   state      active | stopping
#   recording  1 while a recorder is open, 0 between parts
#   parts      newline-separated absolute .flv paths, in playback order
#   updated    epoch seconds of the last change (session-watchdog.sh's clock)

# Path of a playback_id's flock file, created if it isn't there yet.
#
# It has to be openable for writing by BOTH users involved: root, for the
# CGIs and the watchdog, and the nginx worker's unprivileged user, for the
# scripts nginx-rtmp spawns. Whoever gets there first creates it, so the
# creating umask decides - and root's default 022 would hand the worker a
# read-only file and deadlock the whole session on it. Force 666 by
# creating it in a subshell with umask 000 rather than chmod-ing after the
# fact, which only works when you already own the file.
lock_path() {
    _l="/tmp/rec-pending/$1.lock"
    if [ ! -e "$_l" ]; then
        ( umask 000; mkdir -p /tmp/rec-pending && : >"$_l" ) 2>/dev/null || true
    fi
    printf '%s' "$_l"
}

session_dir() { printf '%s/%s' "$SESSIONS_DIR" "$1"; }

session_exists() { [ -d "$(session_dir "$1")" ]; }

session_get() {
    _d=$(session_dir "$1")
    [ -f "$_d/$2" ] || return 0
    cat "$_d/$2" 2>/dev/null || true
}

session_set() {
    _d=$(session_dir "$1")
    mkdir -p "$_d" 2>/dev/null || true
    printf '%s' "$3" >"$_d/$2" 2>/dev/null || true
    chmod 666 "$_d/$2" 2>/dev/null || true
    # every write bumps the clock the watchdog reads, so a session that
    # goes quiet is always visible as "nothing happened since $updated"
    if [ "$2" != updated ]; then
        printf '%s' "$(date +%s)" >"$_d/updated" 2>/dev/null || true
        chmod 666 "$_d/updated" 2>/dev/null || true
    fi
}

session_create() {
    _d=$(session_dir "$1")
    mkdir -p "$_d" 2>/dev/null || true
    chmod 777 "$_d" 2>/dev/null || true
    : >"$_d/parts" 2>/dev/null || true
    chmod 666 "$_d/parts" 2>/dev/null || true
    session_set "$1" name "$2"
    session_set "$1" state active
    session_set "$1" recording 0
    session_set "$1" started "$(date +%s)"
}

session_destroy() { rm -rf "$(session_dir "$1")" 2>/dev/null || true; }

session_unset() { rm -f "$(session_dir "$1")/$2" 2>/dev/null || true; }

session_add_part() {
    _d=$(session_dir "$1")
    mkdir -p "$_d" 2>/dev/null || true
    printf '%s\n' "$2" >>"$_d/parts" 2>/dev/null || true
    chmod 666 "$_d/parts" 2>/dev/null || true
    session_set "$1" updated "$(date +%s)"
}

session_parts() {
    _d=$(session_dir "$1")
    [ -f "$_d/parts" ] || return 0
    cat "$_d/parts" 2>/dev/null || true
}

session_ids() {
    [ -d "$SESSIONS_DIR" ] || return 0
    for _p in "$SESSIONS_DIR"/*; do
        [ -d "$_p" ] || continue
        basename "$_p"
    done
}

# --- config -------------------------------------------------------------
# docker-entrypoint.sh resolves DOMAIN/UPLOAD_ENABLED/SPACES_* once at
# startup and writes them here, so the exec'd scripts (which get no env at
# all beyond TZ) don't need them threaded through as positional arguments.

load_rec_config() {
    [ -f "$REC_CONFIG" ] || return 0
    # shellcheck disable=SC1090
    . "$REC_CONFIG"
}

load_s3_env() {
    [ -f "$S3_ENV_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$S3_ENV_FILE"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    return 0
}

# --- webhooks -----------------------------------------------------------
# POSTs a JSON body to WEBHOOK_URL as this server (Bearer WEBHOOK_TOKEN).
# No-op when no webhook is configured. Never fails the caller: a backend
# being down must not cost us the recording.

webhook_post() {
    [ -f "$WEBHOOK_ENV_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$WEBHOOK_ENV_FILE"
    [ -n "${WEBHOOK_URL:-}" ] || return 0

    if curl -sf -m 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${WEBHOOK_TOKEN:-}" \
        -d "$1" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# {"playback_id","recording":true|false} - "is this camera recording right
# now", as shown in the backend's camera list. Deliberately NOT sent when a
# publisher drops mid-session: the booking is still recording as far as
# anyone is concerned, record-resume.sh will pick it straight back up, and
# flapping this false/true on every uplink blip would only make the admin
# UI lie in a noisier way.
send_camera_status() {
    if webhook_post "$(printf '{"playback_id":"%s","recording":%s}' "$1" "$2")"; then
        rec_log "camera webhook notified: recording=$2 playback_id=$1"
    else
        rec_log "camera webhook FAILED: recording=$2 playback_id=$1"
    fi
}

# --- gaps ---------------------------------------------------------------
# A gap is the stretch of a booking that has no footage because the
# publisher was away: it opens when a part closes early (record-done.sh
# with the session still active) and closes when the encoder comes back
# (record-resume.sh). The joined-up .mp4 is continuous, so nothing in the
# file itself says a gap is there - the backend has to be told, or it will
# show a 60-minute booking as a 52-minute video with no explanation.
#
# Recorded as one line per closed gap in the session's `gaps` file:
#   <started_at> <ended_at> <parts recorded before it>
# and reported twice: once live, the moment the publisher returns, and
# again in the final "ready" payload with each gap's offset into the
# finished file (see rec-finalize.sh).
#
# A gap the publisher never came back from is reported too, but only in
# that final payload - there was no reconnect to announce it live. It's
# added by rec-finalize.sh when a session ends with one still open, and
# matters more than it looks: a backend stamps the end of its coverage
# from the "recording":false, which lands up to RESUME_TIMEOUT after the
# last frame was written, so without it that tail looks like footage
# we hold.

gap_open() { session_set "$1" gap_open "$(date +%s)"; }

# usage: gap_close <playback_id>; echoes the gap length in seconds, or
# nothing at all if no gap was open
gap_close() {
    _started=$(session_get "$1" gap_open)
    if [ -z "$_started" ]; then
        # No gap on record: this session was mid-recording when the
        # container went down, so record-done.sh never ran to open one.
        # docker-entrypoint.sh seeds gap_open from the session's last
        # known activity in that case, so reaching here means there
        # genuinely wasn't one.
        return 0
    fi
    case "$_started" in ''|*[!0-9]*) session_unset "$1" gap_open; return 0 ;; esac

    _ended=$(date +%s)
    _secs=$((_ended - _started))
    [ "$_secs" -ge 0 ] || _secs=0
    _before=$(session_parts "$1" | grep -c . 2>/dev/null || true)
    : "${_before:=0}"

    printf '%s %s %s\n' "$_started" "$_ended" "$_before" >>"$(session_dir "$1")/gaps" 2>/dev/null || true
    chmod 666 "$(session_dir "$1")/gaps" 2>/dev/null || true
    session_unset "$1" gap_open

    if webhook_post "$(printf '{"playback_id":"%s","event":"gap","started_at":%s,"ended_at":%s,"seconds":%s}' \
            "$1" "$_started" "$_ended" "$_secs")"; then
        rec_log "gap webhook notified: ${_secs}s gap on ${1}"
    else
        rec_log "gap webhook FAILED: ${_secs}s gap on ${1}"
    fi
    printf '%s' "$_secs"
}

session_gaps() {
    _f=$(session_dir "$1")/gaps
    [ -f "$_f" ] || return 0
    cat "$_f" 2>/dev/null || true
}
