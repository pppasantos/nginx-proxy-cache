FROM alpine:3.21.5 as builder
RUN apk add --no-cache \
    bash \
    build-base \
    linux-headers \
    openssl-dev \
    pcre-dev \
    zlib-dev \
    curl \
    git \
    luajit \
    luajit-dev \
    lua5.1 \
    lua5.1-dev \
    lua-cjson \
    lua-resty-http \
    luarocks \
    tzdata \
    wget \
    openssl-dev
RUN cp /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime && \
    echo "America/Sao_Paulo" > /etc/timezone && \
    apk del tzdata
ENV LUAJIT_LIB=/usr/lib
ENV LUAJIT_INC=/usr/include/luajit-2.1
WORKDIR /tmp
RUN echo "http://nginx.org/packages/alpine/v3.12/main" >> /etc/apk/repositories && \
    wget https://nginx.org/keys/nginx_signing.rsa.pub && \
    mv nginx_signing.rsa.pub /etc/apk/keys/
RUN wget http://nginx.org/download/nginx-1.26.0.tar.gz && \
    tar -zxvf nginx-1.26.0.tar.gz
RUN git clone https://github.com/openresty/headers-more-nginx-module.git && \
    git clone https://github.com/simpl/ngx_devel_kit.git && \
    git clone https://github.com/openresty/set-misc-nginx-module.git && \
    git clone https://github.com/openresty/lua-nginx-module.git && \
    git clone https://github.com/openresty/lua-resty-core.git && \
    git clone https://github.com/openresty/lua-resty-lrucache.git && \
    git clone https://github.com/openresty/srcache-nginx-module.git && \
    git clone https://github.com/openresty/lua-upstream-nginx-module.git
RUN mkdir -p /usr/local/lib/lua /usr/local/share/lua/5.1 && \
    cp -r lua-resty-core/lib/resty /usr/local/share/lua/5.1/ && \
    cp -r lua-resty-lrucache/lib/resty /usr/local/share/lua/5.1/
WORKDIR /tmp/nginx-1.26.0
RUN ./configure \
    --add-module=/tmp/headers-more-nginx-module \
    --add-module=/tmp/ngx_devel_kit \
    --add-module=/tmp/set-misc-nginx-module \
    --add-module=/tmp/lua-nginx-module \
    --add-module=/tmp/srcache-nginx-module \
    --add-module=/tmp/lua-upstream-nginx-module \
    --with-ld-opt="-Wl,-rpath,/usr/lib" \
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
    luarocks-5.1 install luaossl
FROM alpine:3.21.5
RUN apk add --no-cache \
    bash \
    build-base \
    linux-headers \
    openssl-dev \
    pcre-dev \
    zlib-dev \
    curl \
    git \
    stunnel \
    luajit \
    luajit-dev \
    lua5.1 \
    lua5.1-dev \
    lua-cjson \
    lua-resty-http \
    luarocks \
    tzdata \
    wget \
    openssl \
    openssl-dev
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
RUN mkdir -p /var/log/nginx /var/cache/nginx/rpaas/nginx /var/cache/nginx/rpaas/nginx_tmp && \
    touch /var/log/nginx/access.log /var/log/nginx/error.log && \
    chown -R nginx:nginx /var/log/nginx /var/cache/nginx
USER nginx
EXPOSE 8889 8890
ENTRYPOINT ["/bin/bash", "-c", "nginx -g 'daemon off;'"]
