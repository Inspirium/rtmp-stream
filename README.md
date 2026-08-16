# SportyPlus rtmp-stream

A self-contained Docker image for RTMP ingest with HLS/DASH playback,
manual recording (auto-remuxed to `.mp4` via ffmpeg, optionally uploaded
to S3-compatible object storage), and dynamic stream-key management. One
container = one subdomain = one machine; run it on as many machines as
you need, each with its own `.env`.

Built on nginx + [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module),
compiled from source in the image.

## Contents

- [Quick start](#quick-start)
- [Concepts: stream key vs. playback ID](#concepts-stream-key-vs-playback-id)
- [Publishing](#publishing)
- [Playback](#playback)
- [Managing stream keys](#managing-stream-keys)
- [Recording](#recording)
- [Object storage (DigitalOcean Spaces / S3)](#object-storage-digitalocean-spaces--s3)
- [Status webhook](#status-webhook)
- [TLS / HTTPS](#tls--https)
- [Multiple streams / multiple machines / multiple deployments](#multiple-streams--multiple-machines--multiple-deployments)
  - [Multiple deployments on one machine](#multiple-deployments-on-one-machine)
- [Monitoring](#monitoring)
- [Environment variables](#environment-variables)
- [Security notes](#security-notes)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Quick start

On each machine you want to run a stream server:

```sh
git clone <this repo>   # or just copy the directory over
cd stream
./setup.sh              # interactive: subdomain, stream key, Spaces creds, etc.
docker compose pull     # fetch the prebuilt image (fast — skips compiling nginx)
docker compose up -d
docker compose logs      # prints the publish URL, playback URL, and any auto-generated secrets
```

`setup.sh` writes `.env` (mode `600`, since it holds secrets). Re-run it
any time to change values — it keeps your previous answers as defaults
and backs up the old `.env` first.

If you'd rather configure by hand, copy `.env.example` to `.env` and
fill it in yourself; every field is commented.

Every push to `master` publishes a fresh image to
`ghcr.io/inspirium/rtmp-stream` (`.github/workflows/docker-publish.yml`)
— that's what `docker compose pull` fetches, so a deploy is just a pull
and a restart, not a from-source nginx build. To build locally instead
(e.g. testing a Dockerfile change before it's pushed), use
`docker compose up -d --build`. To pin a specific version instead of
`latest`, set `IMAGE_TAG=<git-sha-or-vX.Y.Z>` in `.env`.

> **First-time repo setup:** GHCR packages default to private. After the
> first successful run of `docker-publish.yml`, open the package under
> the repo's **Packages** tab on GitHub and set its visibility to
> **Public** — otherwise `docker compose pull` will need a
> `docker login ghcr.io` first on every deployment machine.

Point your DNS for the subdomain you chose at the machine, and open
ports `80` (HTTP: playback, control, admin API) and `1935` (RTMP
ingest). Open `443` too if you're using `TLS_MODE=letsencrypt` or
`manual` (see [TLS / HTTPS](#tls--https)) — leave it closed if you're
terminating TLS with a reverse proxy instead (the default,
`TLS_MODE=proxy`), since that proxy owns 443, not this container.

## Concepts: stream key vs. playback ID

Every stream has two identifiers, and they are deliberately never the
same value:

- **Stream key** — secret. This is what an encoder (OBS, ffmpeg, ...)
  authenticates with to publish. Never shown in any playback URL,
  `/stat`, `/control`, or recording.
- **Playback ID** — public. This is what appears in HLS/DASH URLs and
  is safe to share with viewers.

The playback ID is a one-way `sha256(stream_key)` (truncated to 16 hex
chars) unless you explicitly choose your own when minting a key via the
API. Knowing the playback ID does not let you derive the stream key or
publish over the stream — a viewer with a playback link can't hijack
your broadcast.

Each stream key/playback ID pair is independent, so **one machine can
carry several concurrent streams** — see
[Multiple streams / multiple machines](#multiple-streams--multiple-machines).

## Publishing

Point your encoder at:

```
rtmp://<DOMAIN>/stream/<playback_id>?key=<stream_key>
```

e.g. in OBS, set the "Stream Key" field to `<playback_id>?key=<stream_key>`
with the server URL `rtmp://<DOMAIN>/stream`.

The first stream key is generated automatically on first start (or set
via `STREAM_KEY` in `.env`) — check `docker compose logs` for the full
publish URL. Mint more any time; see
[Managing stream keys](#managing-stream-keys).

## Playback

```
HLS:  http://<DOMAIN>/hls/<playback_id>.m3u8
DASH: http://<DOMAIN>/dash/<playback_id>.mpd
```

A minimal test player is served at `http://<DOMAIN>/` — it pre-fills the
first playback ID automatically and lets you type in others.

## Managing stream keys

**Via the container**, no restart required — the running stream is
unaffected either way:

```sh
docker exec <container> mint-key.sh
docker exec <container> revoke-key.sh <stream_key>
```

**Via HTTP**, so another backend can issue/revoke keys without shell
access to the machine — requires `Authorization: Bearer <ADMIN_API_TOKEN>`
(auto-generated on first start if not set in `.env`; check
`docker compose logs`):

```sh
# mint a key with an auto-derived playback id
curl -X POST -H "Authorization: Bearer $ADMIN_API_TOKEN" \
  http://<DOMAIN>/admin/keys

# mint a key with your own playback id (e.g. matching your own room/user id)
curl -X POST -H "Authorization: Bearer $ADMIN_API_TOKEN" \
  -H "Content-Type: application/json" -d '{"playback_id":"room-1234"}' \
  http://<DOMAIN>/admin/keys

# revoke
curl -X DELETE -H "Authorization: Bearer $ADMIN_API_TOKEN" \
  http://<DOMAIN>/admin/keys/<stream_key>
```

`POST /admin/keys` returns:

```json
{
  "stream_key": "...",
  "playback_id": "...",
  "publish_url": "rtmp://<DOMAIN>/stream/<playback_id>?key=<stream_key>",
  "playback_url": "http://<DOMAIN>/hls/<playback_id>.m3u8"
}
```

Both routes (shell and HTTP) write to the same key store
(`stream_keys.map` on the `key-data` volume, so it survives container
restarts) and are safe to use concurrently — writes are `flock`-guarded.

## Recording

Recording is manual only — publishing alone never records anything.
Start/stop over HTTP (basic auth: `CONTROL_USER` / `CONTROL_PASS`, see
`docker compose logs` for an auto-generated password if you didn't set
one), or with the Start/Stop Recording buttons on the test player page:

```sh
curl -u "$CONTROL_USER:$CONTROL_PASS" \
  "http://<DOMAIN>/control/record/start?app=stream&name=<playback_id>&rec=rec1"

curl -u "$CONTROL_USER:$CONTROL_PASS" \
  "http://<DOMAIN>/control/record/stop?app=stream&name=<playback_id>&rec=rec1"
```

**Custom output filename** — add `&filename=<name>` to the start call
(letters, digits, `._-` only):

```sh
curl -u "$CONTROL_USER:$CONTROL_PASS" \
  "http://<DOMAIN>/control/record/start?app=stream&name=<playback_id>&rec=rec1&filename=board_meeting_2026"
```

Without a filename, recordings get a timestamped default name. If a
name collides with an existing file, a `-2`, `-3`, ... suffix is added
automatically — nothing gets overwritten.

nginx-rtmp writes a raw `.flv`; once you stop, ffmpeg remuxes it to a
seekable, widely-playable `.mp4` (`-c copy`, no re-encode — fast and
cheap). If object storage is configured (see below) the `.mp4` is
uploaded and the local copies are deleted; otherwise everything stays
under `/tmp/rec` in the container (the `rec-data` volume), browsable at
`http://<DOMAIN>/recordings/` — closed to everything but `127.0.0.1` by
default, since these are full recorded videos.

## Object storage (DigitalOcean Spaces / S3)

Set in `.env` (or via `setup.sh`):

```
SPACES_ENDPOINT=nyc3.digitaloceanspaces.com
SPACES_BUCKET=my-space-name
SPACES_KEY=...
SPACES_SECRET=...
SPACES_PREFIX=recordings
```

Works with any S3-compatible endpoint (AWS S3, Backblaze B2, MinIO,
...), not just DigitalOcean. Recordings land at
`<bucket>/<prefix>/<domain>/<filename>.mp4`. Leave these blank to keep
recordings local-only. If the endpoint is unreachable or the
credentials are wrong at container start, the stream still starts
normally — recordings just stay local until you fix it.

## Status webhook

Set `WEBHOOK_URL` in `.env` (or via `setup.sh`) to have this container
push status to a backend instead of it having to poll for changes. Two
independent things get POSTed there, both authenticated the same way:

```
WEBHOOK_URL=https://your-backend.example.com/api/webhook/...
WEBHOOK_TOKEN=...
```

**Recording outcome** (`record-done.sh`) — once a recording finishes
remuxing and (if object storage is configured) uploading:

```json
{ "key": "<prefix>/<domain>/<filename>.mp4", "status": "ready", "size": 123456789 }
```

or, if ffmpeg failed or the upload didn't make it, `"status": "failed"`
with no `size`. `key` is exactly what the file lands at in the Space —
`<prefix>/<domain>/<filename>.mp4`, the same value a backend already
knows upfront if it set the recording's filename via `?filename=...`
(see [Recording](#recording)). Nothing is sent for recordings kept
local-only (no object storage configured) — those never reach a "ready"
state a remote backend could act on.

**Camera recording status** (`record-start.cgi` / `record-done.sh`) —
whether a given camera (`playback_id`) is currently recording, sent
`true` the moment `/control/record/start` succeeds and `false` the
moment the recording actually stops — whether that's an explicit
`/control/record/stop`, a dropped publisher, or an error partway
through remuxing/uploading:

```json
{ "playback_id": "<playback_id>", "recording": true }
```

Both requests carry `Authorization: Bearer <WEBHOOK_TOKEN>` so the
receiving backend can tell which server sent them; leave
`WEBHOOK_TOKEN` blank if the endpoint doesn't need one. Nothing is sent
at all if `WEBHOOK_URL` is unset. Delivery is fire-and-forget: a failed
webhook call is logged (`docker compose logs`) but not retried.

## TLS / HTTPS

Set via `TLS_MODE` in `.env` (or via `setup.sh`) — one of:

| `TLS_MODE` | What happens |
|---|---|
| `proxy` *(default)* | Nothing — this container only ever serves plain HTTP on `:80`. Terminate TLS yourself in front of it (a reverse proxy already on the machine, a load balancer, ...). `nginx-vhost.sh` prints a ready-to-use nginx server block for this. No `:443` is opened by this container. |
| `manual` | You supply the cert. Place `fullchain.pem` and `privkey.pem` at `/etc/letsencrypt/live/<DOMAIN>/` on the `certs-data` volume (e.g. `docker cp` them in, before or after first start) and the container serves `:443` with them. No renewal handling — that's on you. |
| `letsencrypt` | The container requests and renews its own cert via `certbot`'s webroot plugin, no external proxy needed. Requires `LETSENCRYPT_EMAIL`, `DOMAIN`'s public DNS already pointing at this machine, and ports `80`+`443` reachable from the internet (`80` for the HTTP-01 challenge, before any cert exists). Renews automatically in the background; `docker compose logs` shows `[setup] certificate obtained` on success. |

`manual` and `letsencrypt` both need the `:443` publish and a place to
persist certs across restarts, which live in a separate compose file so
`TLS_MODE=proxy` deployments (the default) never get `:443` occupied by
this container:

```sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Certs persist on the `certs-data` volume, so they survive restarts and
`letsencrypt` won't re-request one it already has. Switching
`TLS_MODE` back to `proxy` later just stops the `:443` server block
from being rendered — nothing needs cleaning up.

## Multiple streams / multiple machines / multiple deployments

- **One machine, several streams**: mint additional keys (see above).
  Each gets its own playback ID, so each stream gets its own isolated
  HLS/DASH output and recordings, all under the same `DOMAIN`.
- **Several machines**: this whole directory is the image + per-machine
  config surface. Copy it to each machine, run `./setup.sh` with that
  machine's own `DOMAIN`, and `docker compose pull && docker compose up
  -d`. Nothing is shared between machines by default — each has its own
  key store
  and its own recordings volume.
- **Several deployments, one machine** (e.g. alongside other services,
  or several unrelated `DOMAIN`s on the same box): see below.

### Multiple deployments on one machine

By default this container doesn't claim ports 80/443 on the host — its
plain-HTTP port binds to `127.0.0.1` only (`HTTP_BIND`/`HTTP_PORT` in
`.env`, default `127.0.0.1:8080`), meant to sit behind a reverse proxy
you already run for TLS and routing. RTMP (`RTMP_PORT`, default `1935`)
is a raw TCP protocol, so it can't share that proxy — it's bound
directly and needs its own port per deployment.

Each deployment gets its own directory (own `.env`, own key store, own
recordings volume — nothing is shared, same as the multiple-machines
case above, just on one box):

```sh
mkdir -p /opt/streams && cd /opt/streams

git clone <this repo> stream1 && cd stream1
./setup.sh              # DOMAIN=stream1.example.com; HTTP_PORT/RTMP_PORT
                         # auto-bumped past whatever's already listening
docker compose up -d --build
./nginx-vhost.sh | sudo tee /etc/nginx/sites-available/stream1.example.com.conf
sudo ln -s /etc/nginx/sites-available/stream1.example.com.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d stream1.example.com     # or your usual TLS flow
sudo ufw allow 1935/tcp                         # RTMP bypasses nginx entirely

cd /opt/streams
git clone <this repo> stream2 && cd stream2
./setup.sh               # picks the next free ports, e.g. 8081/1936
docker compose up -d --build
./nginx-vhost.sh | sudo tee /etc/nginx/sites-available/stream2.example.com.conf
# ... same symlink/certbot/ufw steps, with stream2's own port/domain
```

`nginx-vhost.sh` reads `DOMAIN`/`HTTP_PORT` from that directory's `.env`
and prints a server block that proxies to the container — including
`return 403` on `/auth/publish`, `/internal/control/record/start`, and
`/recordings`. Those paths are meant to be reachable only from
`127.0.0.1` *inside the container* (see
[Security notes](#security-notes)); once a host-level proxy forwards to
the container over `127.0.0.1`, the container can no longer tell a
proxied internet request apart from a real loopback one, so the block
has to happen at the proxy instead. Re-run `./nginx-vhost.sh` after
changing `DOMAIN` or `HTTP_PORT` to regenerate it.

If a machine runs nothing else and you'd rather expose HTTP directly
without a reverse proxy (the pre-multi-deployment default), set
`HTTP_BIND=0.0.0.0` in `.env`.

## Monitoring

```
http://<DOMAIN>/stat
```

An XML+XSL status page (uptime, bandwidth, active streams, clients).
`worker_processes` is intentionally pinned to `1` — nginx-rtmp's
session/stat/control state is per-worker, so a stream published to one
worker would be invisible to `/stat` and `/control` on another.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | *(required)* | Subdomain this container serves |
| `HTTP_BIND` | `127.0.0.1` | Host interface for `HTTP_PORT`; set `0.0.0.0` to expose HTTP directly with no reverse proxy |
| `HTTP_PORT` | `8080` | Host port proxied to the container's plain-HTTP port 80 |
| `RTMP_PORT` | `1935` | Host port for RTMP ingest (always public — RTMP can't go through an HTTP reverse proxy) |
| `STREAM_KEY` | auto-generated | Seeds one initial stream key on first boot |
| `ADMIN_API_TOKEN` | auto-generated | Bearer token for `/admin/keys` |
| `CONTROL_USER` | `admin` | `/control` basic auth username |
| `CONTROL_PASS` | auto-generated | `/control` basic auth password |
| `SPACES_ENDPOINT` | *(unset)* | S3-compatible endpoint host, e.g. `nyc3.digitaloceanspaces.com` |
| `SPACES_BUCKET` | *(unset)* | Bucket / Space name |
| `SPACES_KEY` | *(unset)* | Access key |
| `SPACES_SECRET` | *(unset)* | Secret key |
| `SPACES_PREFIX` | `recordings` | Key prefix inside the bucket |
| `KEEP_LOCAL_RECORDINGS` | `false` | Keep local `.flv`/`.mp4` after a successful upload |
| `WEBHOOK_URL` | *(unset)* | Backend endpoint POSTed recording outcomes and camera recording status — see [Status webhook](#status-webhook) |
| `WEBHOOK_TOKEN` | *(unset)* | Sent as `Authorization: Bearer <token>` on webhook calls |
| `TLS_MODE` | `proxy` | `proxy` (external TLS termination), `manual` (bring your own cert), or `letsencrypt` (container manages its own via certbot) — see [TLS / HTTPS](#tls--https) |
| `LETSENCRYPT_EMAIL` | *(unset)* | Required if `TLS_MODE=letsencrypt`; renewal/expiry notices only |
| `HTTPS_PORT` | `443` | Host port for HTTPS when `TLS_MODE=manual`/`letsencrypt` (`docker-compose.tls.yml`) |

Auto-generated secrets are printed once, in `docker compose logs`, on
first start. Set them explicitly in `.env` to pin them across restarts.

## Security notes

- Put `DOMAIN` behind HTTPS before relying on this for anything real —
  `ADMIN_API_TOKEN`, `CONTROL_PASS`, and stream keys are all plain
  secrets on the wire otherwise. See [TLS / HTTPS](#tls--https): either
  terminate TLS with a reverse proxy you already run (`TLS_MODE=proxy`,
  the default), or let this container manage its own cert
  (`TLS_MODE=letsencrypt`/`manual`).
- If you're running `TLS_MODE=proxy`, make sure your reverse proxy
  itself blocks `/auth/publish`, `/internal/control/record/start`, and
  `/recordings` rather than forwarding them — see `nginx-vhost.sh`. Once
  a same-host proxy forwards to this container over `127.0.0.1`, the
  container can no longer distinguish a proxied internet request from a
  real loopback one, so the `allow 127.0.0.1` below only holds if the
  proxy itself enforces it too.
- `/admin/keys` is reachable from anywhere (an external backend needs
  to reach it), gated only by the bearer token — not by an IP
  allow-list. Keep the token secret.
- `/control` is gated by HTTP basic auth.
- `/recordings` and internal-only endpoints (`/auth/publish`,
  `/internal/control/record/start`) are restricted to `127.0.0.1`.
- Recording is opt-in per stream — nothing is ever recorded just by
  publishing.
- `WEBHOOK_TOKEN` is sent outbound to `WEBHOOK_URL` on every recording
  and every recording start/stop —
  use an `https://` URL or it's a plain secret on the wire, same as the
  others above.

## Project layout

```
Dockerfile                  builds nginx + nginx-rtmp-module + ffmpeg + fcgiwrap + certbot
docker-compose.yml           one service, reads .env
docker-compose.tls.yml       overlay: :443 + certs-data volume, for TLS_MODE=manual/letsencrypt
setup.sh                     interactive .env writer
nginx-vhost.sh               prints a host nginx server block from .env (TLS_MODE=proxy)
.env.example                 every variable, documented

.github/workflows/
  docker-publish.yml         builds + pushes the image to GHCR on push to master / version tags

docker/
  nginx.conf                 main nginx config (loads per-domain configs from templates)
  templates/
    site-locations.conf.template  shared locations: HLS/DASH, /control, /admin, /auth/publish, player
    http-site.conf.template       :80 vhost - ACME challenge + the shared locations
    https-site.conf.template      :443 vhost (TLS_MODE=manual/letsencrypt only) - same shared locations
    rtmp-site.conf.template       RTMP ingest app: hls/dash output, recorder
  docker-entrypoint.sh       renders templates, seeds the key store, starts fcgiwrap, handles TLS_MODE, execs nginx
  mint-key.sh / revoke-key.sh   key management (docker exec)
  admin-api.cgi               key management (HTTP API, POST/DELETE /admin/keys)
  record-start.cgi            captures ?filename=... on record/start
  record-done.sh              ffmpeg remux + object storage upload + status webhook, on recording stop

html/
  player.html                 minimal HLS test player + recording controls
  stat.xsl                    /stat status page styling
```

## Troubleshooting

- **Nothing recorded** — recording is manual; you must call
  `/control/record/start` (or click the button) after publishing
  starts. Check `docker compose logs` for `[record-done]` lines.
- **`/stat` shows no active stream** — make sure `worker_processes 1`
  hasn't been changed; with more than one worker, a stream published to
  one worker is invisible to requests served by another.
- **Publish rejected (`Input/output error` in the encoder)** — the key
  is wrong, revoked, or being used to claim a playback ID it wasn't
  minted for. Re-check the exact publish URL from `mint-key.sh` /
  `POST /admin/keys`.
- **Recordings not uploading** — check `docker compose logs` for
  `SPACES_*` warnings at startup; a bad endpoint/credential doesn't
  crash the container, it just falls back to local-only recording.
- **`TLS_MODE=letsencrypt` certificate not issued** — check `docker
  compose logs` for `certbot failed`; a bad/unreachable-from-internet
  `DOMAIN` doesn't crash the container, it just stays on HTTP only and
  retries on the next restart. Common causes: DNS for `DOMAIN` doesn't
  point at this machine yet, or port `80`/`443` isn't actually reachable
  from the internet (firewall, or `docker-compose.tls.yml` wasn't
  included in `up -d`).

## License

[MIT](LICENSE)
