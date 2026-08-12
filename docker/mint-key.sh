#!/bin/sh
# Mints a new RTMP stream key, derives its public playback id (a one-way
# sha256 encoding of the key - can't be reversed back to the key), adds
# it to the live key map, and reloads nginx so it's usable immediately
# with no downtime for any other stream already in progress.
#
# Run as: docker exec <container> mint-key.sh
# (the admin API - POST /admin/keys, see admin-api.cgi - can also touch
# the map file, so writes here are flock-guarded against it too)
set -eu

MAP_FILE=/data/stream_keys.map
LOCK_FILE=/data/stream_keys.map.lock
mkdir -p /data
touch "$MAP_FILE" "$LOCK_FILE"

STREAM_KEY=$(openssl rand -hex 20)
PLAYBACK_ID=$(printf '%s' "$STREAM_KEY" | openssl dgst -sha256 -hex | awk '{print $NF}' | cut -c1-16)

(
    flock -x 9
    printf '"%s" %s;\n' "$STREAM_KEY" "$PLAYBACK_ID" >> "$MAP_FILE"
) 9>"$LOCK_FILE"
nginx -s reload

echo "publish to:  rtmp://${DOMAIN:-<domain>}/stream/${PLAYBACK_ID}?key=${STREAM_KEY}"
echo "play back:   http://${DOMAIN:-<domain>}/hls/${PLAYBACK_ID}.m3u8"
