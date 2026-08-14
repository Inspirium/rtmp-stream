#!/bin/sh
# Invoked by nginx-rtmp's exec_record_done once a manually-triggered
# recording finishes writing its raw .flv file. Remuxes it to .mp4 with
# ffmpeg - named from the pending ?filename=... set at record/start time
# (see record-start.cgi), if any, otherwise the raw timestamped name -
# and, if object storage was configured, uploads it and cleans up the
# local copies.
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
    if [ "$KEEP_LOCAL" != "true" ]; then
        rm -f "$RAW_PATH" "$MP4_PATH"
    fi
else
    echo "[record-done] upload FAILED for ${BASENAME}, keeping local copies (${RAW_PATH}, ${MP4_PATH})" >&2
    exit 1
fi
