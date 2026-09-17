#!/bin/sh
# The relay supervisor: keeps one ffmpeg alive re-publishing a local
# stream to somebody else's RTMP ingest, for as long as the relay session
# is active. Spawned detached by relay-start.cgi, one per playback_id.
#
# ffmpeg is a poor daemon and a fine worker. It exits the moment its input
# ends - which here means every time the camera's uplink blinks - so the
# thing that makes a relay survive a two-second drop is this loop, not
# ffmpeg. Same lesson as recording: the session is the unit that survives,
# the process underneath it is disposable.
#
# The stream is *remuxed, never re-encoded*. The fleet publishes 1080p30
# H.264 with a one-second keyframe interval, inside YouTube's four-second
# maximum and better than its two-second recommendation, so the video is
# already exactly what the far end wants and copying it costs almost no
# CPU. That matters on a box that is also running the ingest: transcoding
# four concurrent courts would need a machine we do not have, and copying
# them needs only the uplink to carry a second copy of each.
#
# Audio is the one thing that may need work - see probe_audio below.
#
# args: <playback_id>
set -eu

# Nothing reads this process's stdout: it's detached from the CGI that
# spawned it. Same log as everything else, tailed into the container's
# output by docker-entrypoint.sh.
exec >>/data/record-done.log 2>&1

PLAYBACK_ID=$1

. /usr/local/bin/relay-session.sh
load_rec_config
load_relay_config

SOURCE="rtmp://127.0.0.1/${RTMP_APP:-stream}/${PLAYBACK_ID}"
TARGET=$(relay_get "$PLAYBACK_ID" target)
SAFE_TARGET=$(relay_redact "$TARGET")

if [ -z "$TARGET" ]; then
    rec_log "relay ${PLAYBACK_ID}: no target recorded, refusing to start"
    relay_finish "$PLAYBACK_ID" no_target
    exit 0
fi

# How long the source may stay away before the relay gives up. Shares the
# recording default: a camera gone this long is not coming back inside the
# booking, and holding somebody's YouTube broadcast open on the hope that
# it is costs them a dead stream on their channel.
RESUME_LIMIT=${RELAY_RESUME_TIMEOUT:-${RESUME_TIMEOUT:-600}}

# Consecutive attempts that die almost immediately *while the camera is
# publishing normally*. The source is fine, so it is the far end refusing
# us - a revoked key, a channel that isn't live-enabled, a typo'd ingest
# URL - and retrying that forever just writes the same error to the log a
# thousand times.
FAST_FAIL_SECONDS=${RELAY_FAST_FAIL_SECONDS:-5}
FAST_FAIL_LIMIT=${RELAY_FAST_FAIL_LIMIT:-5}

FFMPEG_PIDFILE="/tmp/rec-pending/${PLAYBACK_ID}.relay.ffmpeg"

relay_set "$PLAYBACK_ID" pid "$$"

# A stop signals this process; pass it straight on to ffmpeg rather than
# leaving an orphan holding the far end's ingest slot open.
cleanup() {
    _p=$(cat "$FFMPEG_PIDFILE" 2>/dev/null || true)
    if [ -n "$_p" ]; then
        kill -TERM "$_p" 2>/dev/null || true
    fi
    rm -f "$FFMPEG_PIDFILE" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT

# --- audio --------------------------------------------------------------
# YouTube (and every other RTMP ingest worth naming) wants an audio track.
# A camera publishing video only produces a broadcast that never leaves
# "starting" - which looks, from the club's side, exactly like the relay
# being broken.
#
# So the source is probed once per attempt and the audio handled three
# ways. Video is copied in all three:
#
#   aac        copy it - the overwhelmingly common case, and free
#   something  transcode just the audio. Cheap (a few percent of a core)
#   else       and unavoidable: FLV over RTMP carries AAC or MP3, and the
#              far end wants AAC
#   none       synthesise silence. The broadcast needs *a* track; it does
#              not need a meaningful one
#
# Probing can fail outright (the camera is between reconnects, the probe
# raced the first keyframe). That is not an error - it just means we do
# not know yet, and the conservative answer is silence, which always
# works. Guessing "copy" when there is no audio to copy does not.
probe_audio() {
    timeout 20 ffprobe -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$SOURCE" 2>/dev/null || true
}

rec_log "relay ${PLAYBACK_ID}: starting, target ${SAFE_TARGET}"
send_relay_status "$PLAYBACK_ID" true

# Epoch of the last moment we know the camera was publishing. Seeded to
# now so a relay armed a few seconds before the camera connects - which is
# the normal case for a booking - gets the full grace period rather than
# being judged against a camera that was never expected yet.
LAST_SEEN=$(date +%s)
FAST_FAILS=0

while :; do
    # The session going away, or going to `stopping`, is the only clean
    # way out of this loop. Checked first so a stop that lands while
    # ffmpeg is dying is noticed before we respawn it.
    relay_exists "$PLAYBACK_ID" || { rec_log "relay ${PLAYBACK_ID}: session gone, supervisor exiting"; exit 0; }
    [ "$(relay_get "$PLAYBACK_ID" state)" = active ] || { rec_log "relay ${PLAYBACK_ID}: stopping, supervisor exiting"; exit 0; }

    if [ -n "$(relay_publisher_present "$PLAYBACK_ID")" ]; then
        LAST_SEEN=$(date +%s)
    else
        _away=$(( $(date +%s) - LAST_SEEN ))
        if [ "$_away" -ge "$RESUME_LIMIT" ]; then
            relay_finish "$PLAYBACK_ID" publisher_gone
            exit 0
        fi
        # Nothing to pull. Don't spin ffmpeg against an empty stream -
        # it would fail instantly and be indistinguishable, in the log,
        # from the far end refusing us.
        sleep 2
        continue
    fi

    AUDIO=$(probe_audio)
    STARTED_AT=$(date +%s)

    # Spelled out three times rather than assembled into a variable: the
    # silence branch needs its second -i between the source and the maps,
    # so the three command lines genuinely differ in shape, and building
    # them by string concatenation would put the stream key - which is
    # what $TARGET is - through a round of word splitting.

    if [ -z "$AUDIO" ]; then
        rec_log "relay ${PLAYBACK_ID}: source has no audio track, relaying silence"
        ffmpeg -nostdin -hide_banner -loglevel warning \
            -analyzeduration 5M -probesize 5M \
            -i "$SOURCE" \
            -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
            -map 0:v:0 -map 1:a:0 \
            -c:v copy -c:a aac -b:a 128k -shortest \
            -f flv -flvflags no_duration_filesize \
            "$TARGET" &
    elif [ "$AUDIO" = aac ]; then
        ffmpeg -nostdin -hide_banner -loglevel warning \
            -analyzeduration 5M -probesize 5M \
            -i "$SOURCE" \
            -map 0:v:0 -map 0:a:0 \
            -c:v copy -c:a copy \
            -f flv -flvflags no_duration_filesize \
            "$TARGET" &
    else
        rec_log "relay ${PLAYBACK_ID}: source audio is ${AUDIO}, transcoding to aac"
        ffmpeg -nostdin -hide_banner -loglevel warning \
            -analyzeduration 5M -probesize 5M \
            -i "$SOURCE" \
            -map 0:v:0 -map 0:a:0 \
            -c:v copy -c:a aac -b:a 128k -ar 44100 \
            -f flv -flvflags no_duration_filesize \
            "$TARGET" &
    fi

    FFMPEG_PID=$!
    printf '%s' "$FFMPEG_PID" >"$FFMPEG_PIDFILE" 2>/dev/null || true

    # `set -e` plus a non-zero child would take the supervisor down with
    # it, which is the one thing this loop exists to prevent.
    wait "$FFMPEG_PID" || true
    rm -f "$FFMPEG_PIDFILE" 2>/dev/null || true

    RAN=$(( $(date +%s) - STARTED_AT ))

    # Long enough to have been a working relay rather than a refused
    # connection. Recorded once: the difference between "never reached
    # the target" and "reached it and lost it" is the first question
    # anybody asks about a stream that isn't appearing.
    if [ "$RAN" -ge "$FAST_FAIL_SECONDS" ]; then
        FAST_FAILS=0
        if [ -z "$(relay_get "$PLAYBACK_ID" connected)" ]; then
            relay_set "$PLAYBACK_ID" connected "$(date +%s)"
            rec_log "relay ${PLAYBACK_ID}: target accepted the stream"
        fi
    elif [ -n "$(relay_publisher_present "$PLAYBACK_ID")" ]; then
        # Died instantly with a healthy source: the far end is the
        # problem, not us.
        FAST_FAILS=$((FAST_FAILS + 1))
        if [ "$FAST_FAILS" -ge "$FAST_FAIL_LIMIT" ]; then
            rec_log "relay ${PLAYBACK_ID}: ${FAST_FAILS} immediate failures against a healthy source - giving up on ${SAFE_TARGET}"
            relay_finish "$PLAYBACK_ID" target_rejected
            exit 0
        fi
    fi

    relay_exists "$PLAYBACK_ID" || exit 0
    [ "$(relay_get "$PLAYBACK_ID" state)" = active ] || exit 0

    RESTARTS=$(relay_get "$PLAYBACK_ID" restarts)
    case "$RESTARTS" in ''|*[!0-9]*) RESTARTS=0 ;; esac
    relay_set "$PLAYBACK_ID" restarts "$((RESTARTS + 1))"
    rec_log "relay ${PLAYBACK_ID}: ffmpeg exited after ${RAN}s, restarting (attempt $((RESTARTS + 2)))"

    sleep 2
done
