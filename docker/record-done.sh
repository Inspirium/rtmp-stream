#!/bin/sh
# Invoked by nginx-rtmp's exec_record_done once a manually-triggered
# recording finishes writing its raw .flv file. Remuxes it to .mp4 with
# ffmpeg - named from the pending ?filename=... set at record/start time
# (see record-start.cgi), if any, otherwise the raw timestamped name -
# and, if object storage was configured, uploads it and cleans up the
# local copies. If a status webhook was configured, also POSTs the
# outcome (ready/failed) so a backend doesn't have to poll object
# storage to find out (see WEBHOOK_URL in README.md).
#
# args: <raw_flv_path> <playback_id> <domain> <upload_enabled: true|false> <bucket> <prefix> <keep_local: true|false>
set -eu

# nginx-rtmp's exec_record_done doesn't forward this script's stdout/
# stderr into `docker compose logs` - they just go nowhere, and writing
# directly to PID 1's fds (the usual /proc/1/fd/1 trick) doesn't work
# either: this runs as the nginx worker's unprivileged user, which can't
# open root's end of that pipe. Instead, append to a plain log file this
# user CAN write to; docker-entrypoint.sh tails that file in the
# background straight into the container's real stdout/stderr.
exec >>/tmp/record-done.log 2>&1

RAW_PATH=$1
PLAYBACK_ID=$2
DOMAIN=$3
UPLOAD_ENABLED=$4
BUCKET=$5
PREFIX=$6
KEEP_LOCAL=$7

# Starting a new recording for this playback_id before this script has
# finished with the previous one (e.g. stop/start called back to back) races
# two record-done.sh invocations against each other: without this lock, both
# independently see the target .mp4 name as free (the "don't clobber" check
# below is a plain [ -e ]) and pick the same path, so whichever ffmpeg finishes
# last silently overwrites - and uploads over - the other's recording, and (if
# a webhook is configured) both report "ready" for the same key. Serializing
# per playback_id here, before that check runs, makes the second invocation
# see the first's finished file and correctly fall through to the -2 suffix.
# Held for the rest of the script (through upload) so webhook posts for this
# playback_id stay ordered too; released automatically when the process exits
# and fd 9 closes. Scoped per playback_id, not global, so unrelated concurrent
# streams on this same server don't serialize against each other.
exec 9>"/tmp/rec-pending/${PLAYBACK_ID}.lock"
flock -x 9

# exec_record_done runs this as the nginx worker's unprivileged user, not
# root, with every env var but TZ stripped - so WEBHOOK_URL/WEBHOOK_TOKEN
# can't reach it as env vars directly, same problem as the S3 credentials
# below. docker-entrypoint.sh wrote them to this file on the shared /data
# volume instead.
WEBHOOK_ENV_FILE=/data/.webhook-env
WEBHOOK_SENT=0

# POSTs {"key", "status", "size"?} to WEBHOOK_URL, authenticated as this
# server (Bearer WEBHOOK_TOKEN) so VideoStatusWebhookController can look
# up which VideoServer sent it. `key` matches what VideoStorageService
# gave this recording's Video row upfront (<prefix>/<domain>/<basename>),
# i.e. everything s5cmd's $DEST carries after the bucket. No-op if no
# webhook was configured, or if $BASENAME isn't known yet (see the EXIT
# trap below).
send_webhook() {
    status=$1
    size=${2:-}

    [ -f "$WEBHOOK_ENV_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$WEBHOOK_ENV_FILE"
    [ -n "${WEBHOOK_URL:-}" ] || return 0
    [ -n "${BASENAME:-}" ] || return 0

    key="${PREFIX}/${DOMAIN}/${BASENAME}"
    if [ -n "$size" ]; then
        payload=$(printf '{"key":"%s","status":"%s","size":%s}' "$key" "$status" "$size")
    else
        payload=$(printf '{"key":"%s","status":"%s"}' "$key" "$status")
    fi

    if curl -sf -m 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${WEBHOOK_TOKEN:-}" \
        -d "$payload" >/dev/null; then
        echo "[record-done] webhook notified: ${status} ${key}"
    else
        echo "[record-done] webhook call FAILED for ${key} (status=${status})" >&2
    fi
    WEBHOOK_SENT=1
}

# Anything below that exits non-zero (ffmpeg, the missing-S3-env-file
# check, a failed upload) should still tell the webhook this recording
# didn't make it, so a backend waiting on it doesn't stay stuck on
# "processing" forever. Only fires once BASENAME is known (see
# send_webhook) and only if a success webhook wasn't already sent.
notify_failure_on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$WEBHOOK_SENT" -eq 0 ]; then
        send_webhook failed
    fi
}
trap notify_failure_on_exit EXIT

DIR=$(dirname "$RAW_PATH")
PENDING_FILE="/tmp/rec-pending/${PLAYBACK_ID}.filename"

if [ -f "$PENDING_FILE" ]; then
    CUSTOM_NAME=$(cat "$PENDING_FILE")
    rm -f "$PENDING_FILE"

    MP4_PATH="${DIR}/${CUSTOM_NAME}.mp4"
    if [ -e "$MP4_PATH" ]; then
        # don't clobber an earlier recording that used the same name
        n=2
        while [ -e "${DIR}/${CUSTOM_NAME}-${n}.mp4" ]; do
            n=$((n + 1))
        done
        MP4_PATH="${DIR}/${CUSTOM_NAME}-${n}.mp4"
    fi
else
    MP4_PATH="${RAW_PATH%.flv}.mp4"
fi
BASENAME=$(basename "$MP4_PATH")

ffmpeg -y -loglevel error -i "$RAW_PATH" -c copy -movflags +faststart "$MP4_PATH"

if [ "$UPLOAD_ENABLED" != "true" ]; then
    echo "[record-done] object storage not configured, keeping ${MP4_PATH} local"
    exit 0
fi

# exec_record_done runs this as the nginx worker's unprivileged user, not
# root, with every env var but TZ stripped - so the S3 credentials s5cmd
# needs can't reach it as env vars directly. docker-entrypoint.sh wrote
# them to this file on the shared /data volume instead; read them back
# here.
S3_ENV_FILE=/data/.s3-env
if [ ! -f "$S3_ENV_FILE" ]; then
    echo "[record-done] ${S3_ENV_FILE} missing, cannot upload ${BASENAME}" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$S3_ENV_FILE"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

DEST="s3://${BUCKET}/${PREFIX}/${DOMAIN}/${BASENAME}"

if s5cmd --endpoint-url "$S3_ENDPOINT_URL" --log error cp "$MP4_PATH" "$DEST" >/dev/null; then
    echo "[record-done] uploaded ${BASENAME} to ${DEST}"
    SIZE=$(wc -c <"$MP4_PATH" | tr -d ' ')
    send_webhook ready "$SIZE"
    if [ "$KEEP_LOCAL" != "true" ]; then
        rm -f "$RAW_PATH" "$MP4_PATH"
    fi
else
    echo "[record-done] upload FAILED for ${BASENAME}, keeping local copies (${RAW_PATH}, ${MP4_PATH})" >&2
    exit 1
fi
