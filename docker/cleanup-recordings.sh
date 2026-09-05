#!/bin/sh
# Sweeps /tmp/rec. Run hourly by docker-entrypoint.sh, and by hand any time:
#
#   docker exec <container> cleanup-recordings.sh --dry-run
#   docker exec <container> cleanup-recordings.sh --older-than 3
#   docker exec <container> cleanup-recordings.sh --force        # see below
#
# Normally the recordings volume looks after itself: rec-finalize.sh deletes
# each recording's parts and .mp4 as soon as the upload is confirmed (unless
# KEEP_LOCAL_RECORDINGS=true). What accumulates is the wreckage of the times
# that didn't happen - a container killed mid-recording, an upload that
# failed against a bucket whose credentials had just changed, a publisher
# that connected and never sent a keyframe. Left alone that fills the disk,
# and a full disk takes every stream on the box down with it.
#
# The default sweep only removes what it can prove is disposable:
#
#   * zero-byte .flv files older than a day (a recorder that never got a
#     frame - there is nothing in them by definition)
#   * files older than the retention window whose upload to object storage
#     is confirmed by listing the bucket
#
# Anything older than the window that ISN'T in the bucket is footage that
# never made it off this machine. That gets reported, never deleted, until
# someone passes --force - at which point it goes too. Files belonging to a
# session that's still open, and anything written in the last few minutes,
# are never touched at either setting.
set -eu

. /usr/local/bin/rec-session.sh
load_rec_config

REC_DIR=${REC_DIR:-/tmp/rec}
RETENTION_DAYS=${RECORDING_RETENTION_DAYS:-7}
DRY_RUN=0
FORCE=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=1 ;;
        --force)       FORCE=1 ;;
        --quiet)       QUIET=1 ;;
        --older-than)  RETENTION_DAYS=${2:?--older-than needs a number of days}; shift ;;
        -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             echo "cleanup-recordings.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift
done

# --quiet drops the per-file chatter (a box with a hundred stale files
# would otherwise write a hundred lines an hour into the container log) but
# always keeps the summary, so the scheduled sweep still says what it did
say()     { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
summary() { printf '%s\n' "$*"; }

human() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

PROTECTED=$(mktemp)
REMOTE=$(mktemp)
LISTING=$(mktemp)
trap 'rm -f "$PROTECTED" "$REMOTE" "$LISTING"' EXIT

# --- what is off limits -------------------------------------------------
# Every part of every open session: those files ARE the booking currently
# being recorded, and rec-finalize.sh still needs them.
for id in $(session_ids); do
    session_parts "$id" >>"$PROTECTED"
done

# --- what is already safely in object storage ---------------------------
# One listing for the whole prefix rather than a HEAD per file: a few
# thousand recordings would otherwise mean a few thousand round trips.
if [ "${UPLOAD_ENABLED:-false}" = true ] && load_s3_env; then
    s5cmd --endpoint-url "$S3_ENDPOINT_URL" --log error \
        ls "s3://${SPACES_BUCKET}/${SPACES_PREFIX}/${DOMAIN}/" 2>/dev/null \
        | awk '{print $NF}' >"$REMOTE" || true
else
    say "[cleanup] object storage not configured - nothing can be confirmed as uploaded"
fi

# a .flv part is represented in the bucket by the .mp4 it was joined into
uploaded()  { grep -qxF "$(basename "$1" | sed 's/\.flv$//; s/\.mp4$//').mp4" "$REMOTE" 2>/dev/null; }
protected() { grep -qxF "$1" "$PROTECTED" 2>/dev/null; }

NOW=$(date +%s)
DAY=86400
FREED=0; DELETED_N=0
KEPT=0;  KEPT_N=0

# -mmin +5 keeps our hands off a recorder that's writing right now: an open
# .flv is touched continuously, so anything younger than that may well be
# live. The session protection above covers the same ground for known
# bookings; this catches recordings started outside one.
find "$REC_DIR" -maxdepth 1 -type f -mmin +5 2>/dev/null | sort >"$LISTING"

# read from a redirect, not a pipe - a piped `while` runs in a subshell and
# the totals below would be lost when it exits
while read -r f; do
    [ -f "$f" ] || continue
    protected "$f" && continue

    size=$(stat -c %s "$f" 2>/dev/null) || continue
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    age_days=$(( (NOW - mtime) / DAY ))

    reason=""
    case "$f" in
        *.flv) [ "$size" -eq 0 ] && [ "$age_days" -ge 1 ] && reason="empty recording" ;;
    esac

    if [ -z "$reason" ]; then
        # everything else has to be past the retention window first
        [ "$age_days" -ge "$RETENTION_DAYS" ] || continue
        if uploaded "$f"; then
            reason="uploaded, ${age_days}d old"
        elif [ "$FORCE" -eq 1 ]; then
            reason="never uploaded, ${age_days}d old, --force"
        else
            say "[cleanup] keeping $(basename "$f") ($(human "$size")) - never uploaded, pass --force to delete"
            KEPT=$((KEPT + size)); KEPT_N=$((KEPT_N + 1))
            continue
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        say "[cleanup] would delete $(basename "$f") ($(human "$size")) - ${reason}"
    else
        rm -f "$f" || continue
        say "[cleanup] deleted $(basename "$f") ($(human "$size")) - ${reason}"
    fi
    FREED=$((FREED + size)); DELETED_N=$((DELETED_N + 1))
done <"$LISTING"

VERB="freed"
[ "$DRY_RUN" -eq 1 ] && VERB="would free"
if [ "$DELETED_N" -gt 0 ] || [ "$KEPT_N" -gt 0 ] || [ "$QUIET" -eq 0 ]; then
    summary "[cleanup] ${VERB} $(human "$FREED") across ${DELETED_N} file(s); kept ${KEPT_N} un-uploaded file(s) holding $(human "$KEPT"); $(df -h "$REC_DIR" | awk 'NR==2 {print $4 " free (" $5 " used)"}')"
fi
