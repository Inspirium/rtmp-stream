#!/bin/sh
# Removes a stream key from the live key map and reloads nginx, so it can
# no longer be used to publish. Does not stop a publish already in
# progress under that key - drop it separately if needed, e.g.:
#   GET /control/drop/publisher?app=stream&name=<playback_id>
#
# Run as: docker exec <container> revoke-key.sh <stream_key>
# (the admin API - DELETE /admin/keys/<key>, see admin-api.cgi - can also
# touch the map file, so writes here are flock-guarded against it too)
set -eu

MAP_FILE=/data/stream_keys.map
LOCK_FILE=/data/stream_keys.map.lock
STREAM_KEY=${1:?usage: revoke-key.sh <stream_key>}
touch "$LOCK_FILE"

(
    flock -x 9
    if ! grep -qF "\"$STREAM_KEY\"" "$MAP_FILE" 2>/dev/null; then
        echo "not found in $MAP_FILE: $STREAM_KEY" >&2
        exit 1
    fi
    TMP_FILE="$MAP_FILE.tmp.$$"
    grep -vF "\"$STREAM_KEY\"" "$MAP_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$MAP_FILE"
) 9>"$LOCK_FILE"
nginx -s reload

echo "revoked: $STREAM_KEY"
