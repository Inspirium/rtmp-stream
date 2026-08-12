#!/bin/sh
# CGI script (invoked by fcgiwrap via the /admin location) implementing
# the key-management API for external backends:
#   POST   /admin/keys               mint a key, body optional: {"playback_id":"..."}
#   DELETE /admin/keys/<stream_key>  revoke a key
# Auth: Authorization: Bearer <ADMIN_API_TOKEN>
set -eu

MAP_FILE=/data/stream_keys.map
LOCK_FILE=/data/stream_keys.map.lock
NGINX_BIN=/usr/local/nginx/sbin/nginx
mkdir -p /data
touch "$MAP_FILE" "$LOCK_FILE"

respond() {
    # $1=status line  $2=json body (optional)
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n\r\n'
    [ -n "${2:-}" ] && printf '%s' "$2"
    exit 0
}

safe_charset() {
    case "$1" in
        "") return 1 ;;
        *[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

sha256_16() { printf '%s' "$1" | openssl dgst -sha256 -hex | awk '{print $NF}' | cut -c1-16; }

# --- auth ---------------------------------------------------------------
TOKEN=${HTTP_AUTHORIZATION:-}
TOKEN=${TOKEN#Bearer }
if [ -z "${ADMIN_API_TOKEN:-}" ] || [ "$TOKEN" != "$ADMIN_API_TOKEN" ]; then
    respond "401 Unauthorized" '{"error":"unauthorized"}'
fi

METHOD=${REQUEST_METHOD:-}
URI=${REQUEST_URI:-}
URI=${URI%%\?*}

case "$METHOD $URI" in

    "POST /admin/keys")
        BODY=""
        if [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null; then
            BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
        fi

        REQUESTED_ID=""
        if [ -n "$BODY" ]; then
            REQUESTED_ID=$(printf '%s' "$BODY" | jq -r '.playback_id // empty' 2>/dev/null) || REQUESTED_ID=""
        fi

        if [ -n "$REQUESTED_ID" ] && ! safe_charset "$REQUESTED_ID"; then
            respond "400 Bad Request" '{"error":"playback_id must only contain letters, digits, _ or -"}'
        fi

        STREAM_KEY=$(openssl rand -hex 20)
        PLAYBACK_ID=${REQUESTED_ID:-$(sha256_16 "$STREAM_KEY")}

        if (
            flock -x 9
            if awk -v id="$PLAYBACK_ID" '$2==id";"{found=1} END{exit !found}' "$MAP_FILE"; then
                exit 1
            fi
            printf '"%s" %s;\n' "$STREAM_KEY" "$PLAYBACK_ID" >> "$MAP_FILE"
        ) 9>"$LOCK_FILE"; then
            :
        else
            respond "409 Conflict" '{"error":"playback_id already in use"}'
        fi

        "$NGINX_BIN" -s reload

        JSON=$(jq -n --arg key "$STREAM_KEY" --arg id "$PLAYBACK_ID" --arg domain "${DOMAIN:-}" '{
            stream_key: $key,
            playback_id: $id,
            publish_url: ("rtmp://" + $domain + "/stream/" + $id + "?key=" + $key),
            playback_url: ("http://" + $domain + "/hls/" + $id + ".m3u8")
        }')
        respond "201 Created" "$JSON"
        ;;

    "DELETE /admin/keys/"*)
        STREAM_KEY=${URI#/admin/keys/}
        if ! safe_charset "$STREAM_KEY"; then
            respond "400 Bad Request" '{"error":"invalid stream key"}'
        fi

        if (
            flock -x 9
            if ! grep -qF "\"${STREAM_KEY}\"" "$MAP_FILE"; then
                exit 1
            fi
            TMP_FILE="$MAP_FILE.tmp.$$"
            grep -vF "\"${STREAM_KEY}\"" "$MAP_FILE" > "$TMP_FILE"
            mv "$TMP_FILE" "$MAP_FILE"
        ) 9>"$LOCK_FILE"; then
            :
        else
            respond "404 Not Found" '{"error":"stream key not found"}'
        fi

        "$NGINX_BIN" -s reload
        respond "204 No Content" ""
        ;;

    *)
        respond "404 Not Found" '{"error":"not found"}'
        ;;
esac
