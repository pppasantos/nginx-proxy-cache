ARG ALPINE_VERSION=3.24
ARG NGINX_VERSION=1.31.3
ARG HEADERS_MORE_VERSION=v0.37
ARG NDK_VERSION=v0.3.3
ARG SET_MISC_VERSION=v0.33
ARG LUA_NGINX_VERSION=v0.10.28
ARG LUA_RESTY_CORE_VERSION=v0.1.31
ARG LUA_RESTY_LRUCACHE_VERSION=v0.15
ARG LUA_UPSTREAM_VERSION=v0.07

FROM alpine:${ALPINE_VERSION} AS builder

ARG NGINX_VERSION
ARG HEADERS_MORE_VERSION
ARG NDK_VERSION
ARG SET_MISC_VERSION
ARG LUA_NGINX_VERSION
ARG LUA_RESTY_CORE_VERSION
ARG LUA_RESTY_LRUCACHE_VERSION
ARG LUA_UPSTREAM_VERSION

RUN apk add --no-cache \
    bash \
    build-base \
    linux-headers \
    openssl-dev \
    pcre2-dev \
    zlib-dev \
    git \
    gnupg \
    luajit \
    luajit-dev \
    lua5.1 \
    lua5.1-dev \
    luarocks \
    tzdata \
    wget

RUN cp /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime && \
    echo "America/Sao_Paulo" > /etc/timezone && \
    apk del tzdata

ENV LUAJIT_LIB=/usr/lib
ENV LUAJIT_INC=/usr/include/luajit-2.1

WORKDIR /tmp

RUN set -eux; \
    wget -O nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    wget -O nginx.tar.gz.asc "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    for key in pluknet.key arut.key sb.key thresh.key; do \
        if wget -O "${GNUPGHOME}/${key}" "https://nginx.org/keys/${key}"; then \
            gpg --batch --import "${GNUPGHOME}/${key}"; \
        else \
            echo "WARNING: https://nginx.org/keys/${key} is no longer published, skipping"; \
            rm -f "${GNUPGHOME}/${key}"; \
        fi; \
    done; \
    gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz; \
    tar -zxf nginx.tar.gz; \
    rm -rf "${GNUPGHOME}" nginx.tar.gz nginx.tar.gz.asc

RUN set -eux; \
    git clone --depth 1 -b "${HEADERS_MORE_VERSION}" https://github.com/openresty/headers-more-nginx-module.git; \
    git clone --depth 1 -b "${NDK_VERSION}" https://github.com/simpl/ngx_devel_kit.git; \
    git clone --depth 1 -b "${SET_MISC_VERSION}" https://github.com/openresty/set-misc-nginx-module.git; \
    git clone --depth 1 -b "${LUA_NGINX_VERSION}" https://github.com/openresty/lua-nginx-module.git; \
    git clone --depth 1 -b "${LUA_RESTY_CORE_VERSION}" https://github.com/openresty/lua-resty-core.git; \
    git clone --depth 1 -b "${LUA_RESTY_LRUCACHE_VERSION}" https://github.com/openresty/lua-resty-lrucache.git; \
    git clone --depth 1 -b "${LUA_UPSTREAM_VERSION}" https://github.com/openresty/lua-upstream-nginx-module.git; \
    for directory in headers-more-nginx-module ngx_devel_kit set-misc-nginx-module \
        lua-nginx-module lua-resty-core lua-resty-lrucache lua-upstream-nginx-module; do \
        echo "PINNED ${directory} $(git -C "${directory}" rev-parse HEAD)"; \
    done

RUN mkdir -p /usr/local/lib/lua /usr/local/share/lua/5.1 && \
    cp -r lua-resty-core/lib/resty /usr/local/share/lua/5.1/ && \
    cp -r lua-resty-lrucache/lib/resty /usr/local/share/lua/5.1/

WORKDIR /tmp/nginx-${NGINX_VERSION}

RUN ./configure \
    --add-module=/tmp/headers-more-nginx-module \
    --add-module=/tmp/ngx_devel_kit \
    --add-module=/tmp/set-misc-nginx-module \
    --add-module=/tmp/lua-nginx-module \
    --add-module=/tmp/lua-upstream-nginx-module \
    --with-ld-opt="-Wl,-rpath,/usr/lib" \
    --with-pcre \
    --with-http_ssl_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_sub_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_mp4_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_random_index_module \
    --with-http_secure_link_module \
    --with-http_stub_status_module \
    --with-http_auth_request_module \
    --with-threads \
    --with-stream \
    --with-stream_ssl_module \
    --with-http_slice_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-file-aio \
    --with-http_v2_module \
    && make && make install

RUN luarocks-5.1 install lua-resty-redis && \
    luarocks-5.1 install lua-resty-prometheus && \
    luarocks-5.1 install lua-resty-lock && \
    luarocks-5.1 install luaossl && \
    luarocks-5.1 install lua-resty-string && \
    luarocks-5.1 install lua-resty-http && \
    luarocks-5.1 install lua-resty-openssl && \
    luarocks-5.1 install lua-cjson

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
    luajit \
    lua5.1 \
    openssl \
    pcre2 \
    zlib

COPY --from=builder /usr/local/nginx /usr/local/nginx
COPY --from=builder /usr/local/share/lua /usr/local/share/lua
COPY --from=builder /usr/local/lib/lua /usr/local/lib/lua
COPY --from=builder /usr/lib/lua /usr/lib/lua
COPY --from=builder /etc/localtime /etc/localtime
COPY --from=builder /etc/timezone /etc/timezone

ENV LUA_PATH="/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;"
ENV PATH="/usr/local/nginx/sbin:$PATH"

RUN addgroup -S nginx && adduser -S nginx -G nginx

COPY config/* /usr/local/nginx/conf/
COPY lua/* /usr/local/lib/lua/

RUN mkdir -p /var/log/nginx /home/nginx && \
    touch /var/log/nginx/access.log /var/log/nginx/error.log && \
    chown -R nginx:nginx /var/log/nginx /usr/local/lib/lua /usr/local/nginx /run/ /home/nginx

USER nginx
WORKDIR /home/nginx

EXPOSE 8889 8890
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=2 \
    CMD wget -q -Y off -T 3 -O /dev/null  http://127.0.0.1:8889/_nginx_healthcheck || exit 1
ENTRYPOINT ["/bin/sh", "-c", "nginx -g 'daemon off;'"]
