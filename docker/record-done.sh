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

DEST="spaces/${BUCKET}/${PREFIX}/${DOMAIN}/${BASENAME}"

if mc cp "$MP4_PATH" "$DEST"; then
    echo "[record-done] uploaded ${BASENAME} to ${DEST}"
    if [ "$KEEP_LOCAL" != "true" ]; then
        rm -f "$RAW_PATH" "$MP4_PATH"
    fi
else
    echo "[record-done] upload FAILED for ${BASENAME}, keeping local copies (${RAW_PATH}, ${MP4_PATH})" >&2
    exit 1
fi
