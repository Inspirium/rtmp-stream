#!/bin/sh
# finalize_session() - turn a finished session's .flv parts into the single
# .mp4 the backend is waiting for, upload it, and report the outcome.
#
# Sourced (never executed) by record-done.sh, record-finalize.sh and
# session-watchdog.sh. rec-session.sh must be sourced first.
#
# THE CALLER MUST ALREADY HOLD that playback_id's flock (see record-done.sh)
# - record-done.sh holds it for its whole run, so re-taking it here would
# deadlock against ourselves. record-finalize.sh is the wrapper that takes
# the lock for callers who don't hold it yet.

# usage: finalize_session <playback_id>
finalize_session() {
    _id=$1
    load_rec_config

    _name=$(session_get "$_id" name)
    _rec_dir=${REC_DIR:-/tmp/rec}

    # Last chance to learn the codec. On an explicit /control/record/stop
    # the camera is usually still publishing, so /stat still has it; on a
    # watchdog timeout the publisher is long gone and this does nothing,
    # leaving whatever record-start or the watchdog managed to catch.
    session_capture_codec "$_id"
    _codec=$(session_get "$_id" video_codec)

    # the camera really has stopped recording by the time we get here,
    # whatever happens to the file below - tell the backend first, before
    # any of the parts that can fail
    send_camera_status "$_id" false

    # A gap still open at this point never closed: the publisher went away
    # and the session is ending without it ever coming back - RESUME_TIMEOUT
    # expiring, or a stop called while the camera was still offline.
    #
    # The recording simply stops there, but a backend stamps the end of its
    # coverage from the "recording":false above, which is NOW - up to
    # RESUME_TIMEOUT after the last frame was actually written. Left
    # unreported it would believe it holds footage for that tail and skip
    # repairing it. So close the gap out and report it like any other; it
    # lands at the very end of the file, which is exactly where the footage
    # stops.
    _open=$(session_get "$_id" gap_open)
    case "$_open" in
        ''|*[!0-9]*) ;;
        *)
            _now=$(date +%s)
            session_unset "$_id" gap_open
            if [ "$((_now - _open))" -le 0 ]; then
                # stopped in the same second the publisher went away: no
                # footage is actually missing, and a zero-length gap is just
                # a row for a backend to store and subtract nothing from
                rec_log "session ${_id}: ended as the publisher went away, no footage missing"
            else
                _all=$(session_parts "$_id" | grep -c . 2>/dev/null || true)
                : "${_all:=0}"
                printf '%s %s %s\n' "$_open" "$_now" "$_all" >>"$(session_dir "$_id")/gaps" 2>/dev/null || true
                chmod 666 "$(session_dir "$_id")/gaps" 2>/dev/null || true
                rec_log "session ${_id}: ended with the publisher still away - trailing gap of $((_now - _open))s"
            fi
            ;;
    esac

    # Did the publisher drop at any point? Only then is it worth measuring
    # each part, which costs an ffprobe apiece - the common case is one
    # unbroken part and no measuring at all.
    _has_gaps=0
    if [ -n "$(session_gaps "$_id")" ]; then
        _has_gaps=1
    fi

    # drop zero-byte parts: a publisher that connected but never delivered a
    # keyframe before dropping again leaves one behind, and ffmpeg's concat
    # demuxer chokes on them
    _list=$(session_dir "$_id")/concat.txt
    _meta=$(session_dir "$_id")/parts.meta
    : >"$_list"
    : >"$_meta"
    _count=0
    _idx=0
    _first=""
    for _p in $(session_parts "$_id"); do
        _idx=$((_idx + 1))
        [ -s "$_p" ] || { rec_log "skipping empty part ${_p}"; continue; }
        printf "file '%s'\n" "$_p" >>"$_list"
        _count=$((_count + 1))
        [ -n "$_first" ] || _first=$_p
        if [ "$_has_gaps" -eq 1 ]; then
            # "<position in the parts list> <seconds of footage>", so a gap
            # recorded as "after N parts" can be turned into an offset into
            # the joined file below
            _d=$(ffprobe -v error -show_entries format=duration \
                    -of default=nw=1:nk=1 "$_p" 2>/dev/null || true)
            case "$_d" in ''|*[!0-9.]*) _d=0 ;; esac
            printf '%s %s\n' "$_idx" "$_d" >>"$_meta"
        fi
    done

    if [ "$_count" -eq 0 ]; then
        rec_log "session ${_id} finished with no usable footage - nothing to upload"
        _key_name=${_name:-$_id}
        send_video_status "${_key_name}.mp4" failed "" "" no_footage "$_codec"
        session_destroy "$_id"
        return 0
    fi

    # no ?filename= was given at start time, so fall back to the raw
    # timestamped name nginx-rtmp picked for the first part
    if [ -z "$_name" ]; then
        _name=$(basename "$_first" .flv)
    fi

    _mp4="${_rec_dir}/${_name}.mp4"
    _n=2
    while target_taken "$_mp4"; do
        if [ "$_n" -gt 50 ]; then
            # 50 recordings under one name is not a real scenario - reaching
            # here means the "is this taken?" check itself is broken (a
            # bucket listing answering yes to everything, say). Bail out to
            # a name nothing can collide with rather than spin forever
            # holding this playback_id's lock, which would wedge the stream.
            _mp4="${_rec_dir}/${_name}-$(date +%s).mp4"
            rec_log "no free name for ${_name}.mp4 after ${_n} tries - falling back to $(basename "$_mp4")"
            break
        fi
        _mp4="${_rec_dir}/${_name}-${_n}.mp4"
        _n=$((_n + 1))
    done
    _base=$(basename "$_mp4")

    if [ "$_count" -eq 1 ]; then
        # single part - the common case, no drop happened. Plain remux, same
        # as this script did before sessions existed.
        if ! ffmpeg -y -loglevel error -i "$_first" \
                -c copy -movflags +faststart "$_mp4"; then
            rec_log "ffmpeg remux FAILED for ${_base} - keeping ${_first}"
            send_video_status "$_base" failed "" "" remux_failed "$_codec"
            session_destroy "$_id"
            return 1
        fi
    else
        # the publisher dropped and came back at least once. Every part came
        # off the same encoder at the same settings and starts on a keyframe
        # (wait_key on), so the concat demuxer can stitch them without a
        # re-encode; it rebases each part's timestamps onto the end of the
        # previous one, which is exactly the gapless join we want.
        rec_log "session ${_id}: joining ${_count} parts into ${_base}"
        if ! ffmpeg -y -loglevel error -f concat -safe 0 -i "$_list" \
                -c copy -movflags +faststart "$_mp4"; then
            rec_log "ffmpeg concat FAILED for ${_base} - keeping parts in ${_rec_dir}"
            send_video_status "$_base" failed "" "" concat_failed "$_codec"
            session_destroy "$_id"
            return 1
        fi
    fi

    # A publish the muxers can't read - H.265 (the HLS/DASH muxers and this
    # recorder all only understand H.264), or an encoder that never sends a
    # keyframe - still produces an .flv, because nginx-rtmp writes whatever
    # arrives. It just has no video in it: the recorder skips every video
    # frame waiting for a keyframe it never recognises. ffmpeg -c copy then
    # copies that nothing quite happily and exits 0, so without this check
    # the success path below reports "ready" for a file with no picture.
    #
    # That's the expensive failure: the backend reconciler treats the
    # booking as fully covered, never reports a gap, and so never asks the
    # camera for its own SD-card copy - which is intact, and gets
    # overwritten while nobody goes to fetch it. Report failed instead and
    # keep the file for diagnosis.
    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
            -of csv=p=0 "$_mp4" 2>/dev/null | grep -q video; then
        rec_log "no video stream in ${_base} - encoder is probably publishing H.265 or sending no keyframes; keeping ${_mp4}"
        send_video_status "$_base" failed "" "" no_video_track "$_codec"
        session_destroy "$_id"
        return 1
    fi

    if [ "${UPLOAD_ENABLED:-false}" != true ]; then
        rec_log "object storage not configured, keeping ${_mp4} local"
        session_destroy "$_id"
        return 0
    fi

    if ! load_s3_env; then
        rec_log "${S3_ENV_FILE} missing, cannot upload ${_base}"
        send_video_status "$_base" failed "" "" storage_unconfigured "$_codec"
        session_destroy "$_id"
        return 1
    fi

    _dest="s3://${SPACES_BUCKET}/${SPACES_PREFIX}/${DOMAIN}/${_base}"
    if s5cmd --endpoint-url "$S3_ENDPOINT_URL" --log error cp "$_mp4" "$_dest" >/dev/null 2>&1; then
        _size=$(wc -c <"$_mp4" | tr -d ' ')
        rec_log "uploaded ${_base} to ${_dest} (${_count} part(s), ${_size} bytes)"
        send_video_status "$_base" ready "$_size" "$(gaps_json "$_id" "$_meta")" "" "$_codec"
        if [ "${KEEP_LOCAL_RECORDINGS:-false}" != true ]; then
            rm -f "$_mp4"
            for _p in $(session_parts "$_id"); do rm -f "$_p"; done
        fi
        session_destroy "$_id"
        return 0
    fi

    rec_log "upload FAILED for ${_base}, keeping local copies in ${_rec_dir}"
    send_video_status "$_base" failed "" "" upload_failed "$_codec"
    session_destroy "$_id"
    return 1
}

# Would writing this .mp4 clobber an earlier recording? Checks object
# storage as well as the local disk: with KEEP_LOCAL_RECORDINGS=false the
# local copy is deleted right after upload, so a local-only check would
# happily reuse a name that already exists in the bucket and overwrite a
# previous recording there.
target_taken() {
    [ -e "$1" ] && return 0
    [ "${UPLOAD_ENABLED:-false}" = true ] || return 1
    load_s3_env || return 1
    s5cmd --endpoint-url "$S3_ENDPOINT_URL" --log error \
        ls "s3://${SPACES_BUCKET}/${SPACES_PREFIX}/${DOMAIN}/$(basename "$1")" \
        >/dev/null 2>&1
}

# Every gap in this recording as a JSON array, each one placed on the
# finished file's timeline:
#
#   [{"started_at":1788623712,"ended_at":1788623717,"seconds":5,"offset":6.533}]
#
# started_at/ended_at are wall clock. Every gap here that closed on a
# reconnect was also reported live at the time; a trailing gap - one the
# publisher never came back from - appears only here, since there was no
# reconnect to announce it. `offset` is where the gap sits in the joined
# .mp4 - the total footage recorded before it - which is what lets a
# backend mark it on a timeline rather than just say "8 minutes are
# missing somewhere"; a trailing gap's offset is therefore the full
# duration. Empty array when the recording ran unbroken.
#
# usage: gaps_json <playback_id> <parts.meta>
gaps_json() {
    _acc=""
    _gaps=$(session_gaps "$1")
    [ -n "$_gaps" ] || { printf '[]'; return 0; }

    # `while read` from a heredoc, not a pipe: a pipeline's subshell would
    # throw away everything accumulated here
    while read -r _gs _ge _gb; do
        [ -n "${_gb:-}" ] || continue
        _off=$(awk -v n="$_gb" '$1 <= n { s += $2 } END { printf "%.3f", s + 0 }' "$2" 2>/dev/null)
        : "${_off:=0.000}"
        _acc="${_acc:+${_acc},}$(printf '{"started_at":%s,"ended_at":%s,"seconds":%s,"offset":%s}' \
            "$_gs" "$_ge" "$((_ge - _gs))" "$_off")"
    done <<GAPS
$_gaps
GAPS
    printf '[%s]' "$_acc"
}

# {"key","status","size"?,"gaps"?} - the per-recording outcome, keyed
# exactly as VideoStorageService named it up front
# (<prefix>/<domain>/<basename>).
send_video_status() {
    _k="${SPACES_PREFIX:-recordings}/${DOMAIN:-unknown}/$1"
    if [ -n "$3" ]; then
        # `gaps` is always present on a "ready", as [] for the usual
        # unbroken recording, so a backend can parse one shape either way
        _payload=$(printf '{"key":"%s","status":"%s","size":%s,"gaps":%s' \
            "$_k" "$2" "$3" "${4:-[]}")
    else
        _payload=$(printf '{"key":"%s","status":"%s"' "$_k" "$2")
    fi
    # Both optional, and both omitted when we don't have them rather than
    # sent empty - the backend validates them as sometimes-present, so a
    # payload without either stays valid and neither side's deploy has to
    # go first. `reason` is a stable slug to switch on, never prose.
    if [ -n "${5:-}" ]; then
        _payload="${_payload}$(printf ',"reason":"%s"' "$5")"
    fi
    if [ -n "${6:-}" ]; then
        _payload="${_payload}$(printf ',"video_codec":"%s"' "$6")"
    fi
    _payload="${_payload}}"
    if webhook_post "$_payload"; then
        rec_log "webhook notified: $2 ${_k}"
    else
        rec_log "webhook call FAILED for ${_k} (status=$2)"
    fi
}
