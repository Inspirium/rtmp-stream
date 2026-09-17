#!/bin/sh
# Shared helpers for the relay-session state machine. Sourced (never
# executed) by relay-start.cgi, relay-stop.cgi, relay-run.sh and
# session-watchdog.sh.
#
# A *relay* re-publishes one live stream to somebody else's RTMP ingest -
# YouTube Live, Twitch, a club's own server - while it is still being
# ingested, recorded and played back here exactly as before. The relay is
# a second consumer of the stream, not a replacement for anything: stop it
# and nothing else on this box notices.
#
# This deliberately reuses the recording session machinery's shape rather
# than inventing a second one: one directory per playback_id, one file per
# field, a flock per playback_id, the same webhook helper. What it does
# NOT reuse is the recording session itself. The two are independent - a
# booking can be recorded without being streamed and streamed without
# being recorded - so they get separate directories and separate locks.
# Sharing a lock would have a relay restart block on a recording finalize,
# which can take minutes on a long booking.
#
# Sourcing this also sources rec-session.sh, for rec_log/webhook_post/
# stat_publishers. Everything here is prefixed relay_ so nothing collides.

. /usr/local/bin/rec-session.sh

RELAY_SESSIONS_DIR=/data/relay-sessions
RELAY_CONFIG=/data/.relay-config

# --- session state ------------------------------------------------------
# One directory per playback_id, one file per field:
#
#   target    full rtmp:// or rtmps:// URL *including the stream key* -
#             the one genuinely secret thing here, see relay_redact below
#   state     active | stopping
#   pid       relay-run.sh's pid, so a stop can signal it
#   started   epoch seconds the relay was asked for
#   updated   epoch seconds of the last change (the watchdog's clock)
#   connected epoch seconds ffmpeg last had a working output, absent until
#             the first one - the difference between "never reached the
#             target" and "reached it and lost it", which want different
#             advice
#   restarts  how many times ffmpeg has been respawned this session
#   reason    why a finished session ended, as a stable slug

relay_dir() { printf '%s/%s' "$RELAY_SESSIONS_DIR" "$1"; }

relay_exists() { [ -d "$(relay_dir "$1")" ]; }

# Relays get their own lock namespace. Sharing lock_path with the recording
# session would serialise a relay restart behind a recording finalize -
# an ffmpeg concat over an hour of footage - and the relay would be down
# for all of it.
relay_lock_path() {
    _l="/tmp/rec-pending/$1.relay.lock"
    if [ ! -e "$_l" ]; then
        ( umask 000; mkdir -p /tmp/rec-pending && : >"$_l" ) 2>/dev/null || true
    fi
    printf '%s' "$_l"
}

relay_get() {
    _d=$(relay_dir "$1")
    [ -f "$_d/$2" ] || return 0
    cat "$_d/$2" 2>/dev/null || true
}

relay_set() {
    _d=$(relay_dir "$1")
    mkdir -p "$_d" 2>/dev/null || true
    printf '%s' "$3" >"$_d/$2" 2>/dev/null || true
    # The target carries a stream key. Everything else in here is boring,
    # but this one file is a credential for somebody else's channel, so it
    # is not world-readable the way the rest of the session is. Only root
    # (the CGIs, the watchdog) and relay-run.sh, which root spawns, ever
    # need to read it.
    if [ "$2" = target ]; then
        chmod 600 "$_d/$2" 2>/dev/null || true
    else
        chmod 666 "$_d/$2" 2>/dev/null || true
    fi
    if [ "$2" != updated ]; then
        printf '%s' "$(date +%s)" >"$_d/updated" 2>/dev/null || true
        chmod 666 "$_d/updated" 2>/dev/null || true
    fi
}

relay_unset() { rm -f "$(relay_dir "$1")/$2" 2>/dev/null || true; }

relay_create() {
    _d=$(relay_dir "$1")
    mkdir -p "$_d" 2>/dev/null || true
    chmod 755 "$_d" 2>/dev/null || true
    relay_set "$1" target "$2"
    relay_set "$1" state active
    relay_set "$1" restarts 0
    relay_set "$1" started "$(date +%s)"
}

relay_destroy() { rm -rf "$(relay_dir "$1")" 2>/dev/null || true; }

relay_ids() {
    [ -d "$RELAY_SESSIONS_DIR" ] || return 0
    for _p in "$RELAY_SESSIONS_DIR"/*; do
        [ -d "$_p" ] || continue
        basename "$_p"
    done
}

# --- secrets ------------------------------------------------------------
# A relay target is an ingest URL with the stream key as its last path
# component: rtmps://a.rtmps.youtube.com/live2/abcd-efgh-ijkl. Whoever
# reads that line can broadcast to the club's channel until they notice
# and rotate it - so it must never reach the log, the webhook, or an error
# message. Everything user-visible goes through here.
#
# Keeps enough to be diagnosable (which service, which app) and drops
# exactly the secret: rtmps://a.rtmps.youtube.com/live2/***

relay_redact() {
    printf '%s' "$1" | sed 's#/[^/]*$#/***#'
}

# --- config -------------------------------------------------------------
# relay-run.sh is spawned by a CGI and inherits nothing useful, same
# problem as the recording scripts - docker-entrypoint.sh writes what it
# needs here.

load_relay_config() {
    [ -f "$RELAY_CONFIG" ] || return 0
    # shellcheck disable=SC1090
    . "$RELAY_CONFIG"
}

# --- webhooks -----------------------------------------------------------
# {"playback_id","event":"relay","relaying":true|false,"reason"?}
#
# Sent on the transitions that change what an operator would be told:
# started, and ended (with why). Deliberately NOT sent when ffmpeg is
# respawned mid-session after the publisher blinked - the relay is still
# up as far as anybody is concerned, exactly the reasoning behind
# send_camera_status not flapping on every reconnect.
#
# usage: send_relay_status <playback_id> <true|false> [reason]
send_relay_status() {
    _payload=$(printf '{"playback_id":"%s","event":"relay","relaying":%s' "$1" "$2")
    if [ -n "${3:-}" ]; then
        _payload="${_payload}$(printf ',"reason":"%s"' "$3")"
    fi
    _payload="${_payload}}"

    if webhook_post "$_payload"; then
        rec_log "relay webhook notified: relaying=$2${3:+ reason=$3} playback_id=$1"
    else
        rec_log "relay webhook FAILED: relaying=$2${3:+ reason=$3} playback_id=$1"
    fi
}

# --- finishing ----------------------------------------------------------
# End a session and say why, exactly once. Called from relay-run.sh when
# it gives up, and from relay-stop.cgi when an operator stops it.
#
# The webhook goes out before the directory is removed, so a backend that
# answers slowly can't race the state away.
#
# usage: relay_finish <playback_id> <reason>
relay_finish() {
    relay_exists "$1" || return 0
    rec_log "relay ${1}: ended ($2)"
    send_relay_status "$1" false "$2"
    relay_destroy "$1"
}

# Is this playback_id currently publishing to us? The relay has nothing to
# pull from when it isn't, which is the difference between "wait, the
# camera will be back" and "this target is rejecting us".
relay_publisher_present() {
    stat_publishers | while read -r _pid _bw _codec; do
        [ "$_pid" = "$1" ] || continue
        printf 'yes'
        break
    done
}
