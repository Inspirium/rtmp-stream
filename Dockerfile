# syntax=docker/dockerfile:1
ARG NGINX_VERSION=1.26.2
ARG RTMP_MODULE_VERSION=1.2.2

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
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpcre3 zlib1g libssl3 ca-certificates \
        ffmpeg gettext-base openssl curl \
        fcgiwrap jq util-linux certbot \
    && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
        -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/nginx /usr/local/nginx

# mime.types, fastcgi_params etc. come from the build stage's own `make
# install` above - only nginx.conf itself needs overriding
COPY docker/nginx.conf            /usr/local/nginx/conf/nginx.conf
COPY docker/templates/            /usr/local/nginx/conf/templates/
COPY html/                        /usr/local/nginx/html/
COPY docker/docker-entrypoint.sh  /usr/local/bin/docker-entrypoint.sh
COPY docker/record-done.sh        /usr/local/bin/record-done.sh
COPY docker/mint-key.sh           /usr/local/bin/mint-key.sh
COPY docker/revoke-key.sh         /usr/local/bin/revoke-key.sh
COPY docker/admin-api.cgi         /usr/local/bin/admin-api.cgi
COPY docker/record-start.cgi      /usr/local/bin/record-start.cgi

RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/record-done.sh \
             /usr/local/bin/mint-key.sh /usr/local/bin/revoke-key.sh \
             /usr/local/bin/admin-api.cgi /usr/local/bin/record-start.cgi \
    && mkdir -p /usr/local/nginx/conf/conf.d /usr/local/nginx/conf/rtmp.d \
               /usr/local/nginx/conf/site-locations \
               /tmp/rec /tmp/hls /tmp/dash /tmp/rec-pending /data \
               /var/www/certbot

ENV PATH="/usr/local/nginx/sbin:${PATH}"
WORKDIR /usr/local/nginx

EXPOSE 80 443 1935
VOLUME ["/tmp/rec", "/data", "/etc/letsencrypt"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
