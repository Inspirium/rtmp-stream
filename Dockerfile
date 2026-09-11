# syntax=docker/dockerfile:1
ARG NGINX_VERSION=1.26.2
ARG RTMP_MODULE_VERSION=1.2.2
ARG S5CMD_VERSION=2.3.0

FROM debian:bookworm-slim AS build
ARG NGINX_VERSION
ARG RTMP_MODULE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates wget git \
        libpcre3-dev zlib1g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
    && tar xzf "nginx-${NGINX_VERSION}.tar.gz" \
    && git clone --branch "v${RTMP_MODULE_VERSION}" --depth 1 \
        https://github.com/arut/nginx-rtmp-module.git

WORKDIR /build/nginx-${NGINX_VERSION}
RUN ./configure \
        --prefix=/usr/local/nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-threads \
        --add-module=../nginx-rtmp-module \
    && make -j"$(nproc)" \
    && make install

FROM debian:bookworm-slim
ARG S5CMD_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpcre3 zlib1g libssl3 ca-certificates \
        ffmpeg gettext-base openssl curl \
        fcgiwrap jq util-linux certbot \
    && curl -fsSL "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-64bit.tar.gz" \
        | tar xz -C /usr/local/bin s5cmd \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/nginx /usr/local/nginx

# mime.types, fastcgi_params etc. come from the build stage's own `make
# install` above - only nginx.conf itself needs overriding
COPY docker/nginx.conf            /usr/local/nginx/conf/nginx.conf
COPY docker/templates/            /usr/local/nginx/conf/templates/
COPY html/                        /usr/local/nginx/html/
COPY docker/docker-entrypoint.sh  /usr/local/bin/docker-entrypoint.sh
COPY docker/record-done.sh        /usr/local/bin/record-done.sh
COPY docker/record-resume.sh      /usr/local/bin/record-resume.sh
COPY docker/record-finalize.sh    /usr/local/bin/record-finalize.sh
COPY docker/session-watchdog.sh   /usr/local/bin/session-watchdog.sh
COPY docker/cleanup-recordings.sh /usr/local/bin/cleanup-recordings.sh
COPY docker/mint-key.sh           /usr/local/bin/mint-key.sh
COPY docker/revoke-key.sh         /usr/local/bin/revoke-key.sh
COPY docker/admin-api.cgi         /usr/local/bin/admin-api.cgi
COPY docker/record-start.cgi      /usr/local/bin/record-start.cgi
COPY docker/record-stop.cgi       /usr/local/bin/record-stop.cgi
# sourced, not executed - the session state machine (rec-session.sh) and
# the join/upload half of it (rec-finalize.sh), shared by all of the above
COPY docker/rec-session.sh        /usr/local/bin/rec-session.sh
COPY docker/rec-finalize.sh       /usr/local/bin/rec-finalize.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/record-done.sh \
             /usr/local/bin/record-resume.sh /usr/local/bin/record-finalize.sh \
             /usr/local/bin/session-watchdog.sh /usr/local/bin/cleanup-recordings.sh \
             /usr/local/bin/mint-key.sh /usr/local/bin/revoke-key.sh \
             /usr/local/bin/admin-api.cgi /usr/local/bin/record-start.cgi \
             /usr/local/bin/record-stop.cgi \
    && mkdir -p /usr/local/nginx/conf/conf.d /usr/local/nginx/conf/rtmp.d \
               /usr/local/nginx/conf/site-locations \
               /tmp/rec /tmp/hls /tmp/dash /tmp/rec-pending \
               /data /data/rec-sessions \
               /var/www/certbot

ENV PATH="/usr/local/nginx/sbin:${PATH}"
WORKDIR /usr/local/nginx

# Visibility only - Docker's restart policy reacts to a container exiting,
# never to an unhealthy one, so this recovers nothing by itself (that job is
# session-watchdog.sh's liveness check). What it buys is that a wedged nginx
# reads as "unhealthy" in `docker ps` instead of "Up 3 days", which is the
# line that made the 2026-09-10 outage invisible for thirty-one hours.
#
# /stat is the honest probe here: it's served by the worker and rendered by
# the rtmp module, so it only answers if the part that actually breaks - the
# worker's event loop - is still turning. A static file would be served from
# the same wedged loop and tell us nothing extra, but a TCP check on 1935
# would have passed throughout the outage: that socket is held by the master.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS -m 5 -o /dev/null http://127.0.0.1/stat || exit 1

EXPOSE 80 443 1935
VOLUME ["/tmp/rec", "/data", "/etc/letsencrypt"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
